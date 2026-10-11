import Foundation
import AVFoundation
import CoreMedia

// 실제 마이크나 시스템 소리를 수집하지 않습니다. 시각·샘플·파일 복구와 Apple PCM 변환 API를 검증합니다.
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw AppFailure(message: message) }
}
func near(_ lhs: Float, _ rhs: Float) -> Bool { abs(lhs - rhs) < 0.0001 }
var checks = 0

do {
    var output: [Float] = []
    let timeline = CaptureTimeline(start: 100) { output.append(contentsOf: $0) }
    timeline.add([Float](repeating: 0.4, count: 1600), at: 100, gain: 1)
    timeline.add([Float](repeating: 0.3, count: 800), at: 100.05, gain: 1)
    try timeline.flush(until: 100.1)
    try check(output.count == 1600 && near(output[100], 0.4) && near(output[900], 0.7), "두 소스의 시간 정렬 실패")
    checks += 1
    timeline.add([1, 1], at: 100, gain: 1)
    try check(timeline.lateFrames == 2, "늦게 도착한 샘플을 기존 파일에 중복 기록함")
    checks += 1

    output = []
    let paused = CaptureTimeline(start: 10) { output.append(contentsOf: $0) }
    paused.pause(at: 10.1)
    paused.resume(at: 20)
    // 일시 정지 전에 수집된 지연 버퍼와 재개 구간만 남아야 합니다.
    paused.add([Float](repeating: 0.5, count: 3200), at: 10, gain: 1)
    paused.add([Float](repeating: 1, count: 100), at: 15, gain: 1)
    paused.add([Float](repeating: 0.2, count: 1600), at: 20, gain: 1)
    try paused.flush(until: 20.1)
    try check(output.count == 3200 && near(output[0], 0.5) && near(output[2000], 0.2), "일시 정지 시간 제거 또는 지연 버퍼 정렬 실패")
    checks += 1

    output = []
    let silence = CaptureTimeline(start: 0) { output.append(contentsOf: $0) }
    silence.add([2, -2, .nan], at: 0, gain: 1)
    try silence.flush(until: 0.001)
    try check(output.count == 16 && output[0] == 1 && output[1] == -1 && output[2...].allSatisfy { $0 == 0 }, "무음 채우기·클리핑 처리 실패")
    checks += 1
    try check(silence.frame(at: 100_000) == 230_400_000, "4시간 녹음 한도 오류")
    checks += 1

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("recording.wav")
    let writer = try PCMRecordingWriter(url: url)
    try writer.append([Float](repeating: 0.25, count: 1600)); try writer.close()
    let file = try AVAudioFile(forReading: url)
    try check(file.length == 1600 && file.processingFormat.sampleRate == 16000, "생성한 WAV를 Apple 오디오 API에서 읽지 못함")
    checks += 1
    // 비정상 종료처럼 본문에 비해 헤더의 데이터 길이가 작게 남은 상황을 재현합니다.
    let handle = try FileHandle(forUpdating: url)
    try handle.seek(toOffset: 40); try handle.write(contentsOf: Data([0, 0, 0, 0])); try handle.close()
    try PCMRecordingWriter.repairDraft(url)
    let repaired = try AVAudioFile(forReading: url)
    try check(repaired.length == 1600, "중단된 녹음 헤더 복구 실패")
    checks += 1
    let invalid = folder.appendingPathComponent("invalid.wav")
    try Data(repeating: 1, count: 60).write(to: invalid)
    do { try PCMRecordingWriter.repairDraft(invalid); throw AppFailure(message: "잘못된 WAV를 복구 대상으로 받음") }
    catch let error as AppFailure { try check(error.message == "소리노트의 WAV 녹음 형식이 아닙니다.", "형식 검사 실패") }
    checks += 1

    var settings = AudioSettings(); settings.source = .both
    let resultURL = folder.appendingPathComponent("converted.wav")
    var captureError: String?
    let sink = try AudioCaptureSink(url: resultURL, settings: settings) { captureError = $0 }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let now = AudioCaptureSink.now()
    // 같은 변환기를 여러 버퍼에 재사용해 청크 경계와 스테레오 downmix도 확인합니다.
    for chunk in 0..<10 {
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        pcm.frameLength = 480
        for channel in 0..<2 { for index in 0..<480 {
            pcm.floatChannelData![channel][index] = 0.3 * sin(Float(chunk * 480 + index) * 2 * .pi * 440 / 48000)
        } }
        let time = now + Double(chunk) * 0.01
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: 480, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        try check(status == noErr, "합성 CMSampleBuffer 생성 실패")
        try check(CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr, "합성 PCM 연결 실패")
        CMSampleBufferSetDataReady(sample!)
        sink.queue.sync { sink.systemBuffer(sample!) }
        sink.microphone(pcm, time: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: time)))
    }
    Thread.sleep(forTimeInterval: 0.13)
    sink.beginStop(); _ = try sink.finish()
    try check(captureError == nil, "합성 입력 변환 실패: \(captureError ?? "")")
    let mixed = try AVAudioFile(forReading: resultURL)
    let decoded = AVAudioPCMBuffer(pcmFormat: mixed.processingFormat, frameCapacity: AVAudioFrameCount(mixed.length))!
    try mixed.read(into: decoded)
    let data = Array(UnsafeBufferPointer(start: decoded.floatChannelData![0], count: Int(decoded.frameLength)))
    let peak = data.map(abs).max() ?? 0
    try check(mixed.length >= 1600 && peak > 0.20 && peak < 0.4 && data[800..<1500].filter { abs($0) > 0.05 }.count > 300, "48kHz 스테레오 입력을 16kHz 모노로 혼합하지 못함")
    checks += 1
    print("오디오 검사 \(checks)개 통과: 정렬, 지연, 일시 정지, 무음, 클리핑, 시간 한도, WAV 저장·복구, 실제 PCM 변환")
} catch {
    fputs("오디오 검사 실패: \(error.localizedDescription)\n", stderr)
    exit(1)
}
