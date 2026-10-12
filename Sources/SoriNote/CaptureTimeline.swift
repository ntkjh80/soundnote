import Foundation

/// 입력 장치가 달라도 같은 시계의 시각을 기준으로 섞습니다. 아래 코드는 녹음 큐 한 곳에서만 호출합니다.
final class CaptureTimeline {
    static let sampleRate = 16_000.0
    private struct Interval { let start: Double; var end: Double?; let frame: Int64 }
    private var intervals: [Interval]
    private var blocks: [Int64: [Float]] = [:]
    private let blockSize: Int64 = 1024
    private(set) var writtenFrames: Int64 = 0
    private(set) var lateFrames: Int64 = 0
    private let emit: ([Float]) throws -> Void

    init(start: Double, emit: @escaping ([Float]) throws -> Void) {
        intervals = [Interval(start: start, end: nil, frame: 0)]
        self.emit = emit
    }
    func frame(at time: Double) -> Int64 {
        for interval in intervals.reversed() where time >= interval.start {
            return min(Int64(14_400 * Self.sampleRate), interval.frame + Int64((max(0, min(time, interval.end ?? time) - interval.start) * Self.sampleRate).rounded()))
        }
        return 0
    }
    func pause(at time: Double) {
        guard intervals.last?.end == nil else { return }
        intervals[intervals.count - 1].end = max(intervals.last!.start, time)
    }
    func resume(at time: Double) {
        guard let end = intervals.last?.end, time >= end else { return }
        intervals.append(Interval(start: time, end: nil, frame: frame(at: time)))
    }
    func add(_ samples: [Float], at time: Double, gain: Float) {
        guard time.isFinite, gain.isFinite, !samples.isEmpty else { return }
        let end = time + Double(samples.count) / Self.sampleRate
        // 일시 정지 전에 수집됐지만 늦게 도착한 버퍼도 원래 녹음 구간에 배치합니다.
        for interval in intervals where interval.start < end && (interval.end ?? end) > time {
            let lower = max(time, interval.start), upper = min(end, interval.end ?? end)
            let skip = max(0, Int(((lower - time) * Self.sampleRate).rounded()))
            let count = min(samples.count - skip, max(0, Int(((upper - lower) * Self.sampleRate).rounded())))
            let start = interval.frame + Int64(((lower - interval.start) * Self.sampleRate).rounded())
            guard count > 0 else { continue }
            for index in 0..<count {
                let frame = start + Int64(index)
                guard frame >= writtenFrames else { lateFrames += 1; continue }
                let key = frame / blockSize, offset = Int(frame % blockSize)
                if blocks[key] == nil { blocks[key] = [Float](repeating: 0, count: Int(blockSize)) }
                let value = samples[skip + index]
                if value.isFinite { blocks[key]![offset] += value * gain }
            }
        }
    }
    func flush(until time: Double) throws {
        let end = frame(at: time)
        while writtenFrames < end {
            let key = writtenFrames / blockSize, offset = Int(writtenFrames % blockSize)
            let count = Int(min(end - writtenFrames, blockSize - Int64(offset)))
            let block = blocks[key] ?? [Float](repeating: 0, count: Int(blockSize))
            try emit(Array(block[offset..<(offset + count)]).map { min(1, max(-1, $0)) })
            writtenFrames += Int64(count)
            if writtenFrames % blockSize == 0 { blocks.removeValue(forKey: key) }
        }
    }
}

/// 16kHz 모노 PCM WAV를 조금씩 저장합니다. 매초 헤더를 갱신해 예기치 않은 종료에도 복구하기 쉽게 합니다.
final class PCMRecordingWriter {
    let url: URL
    private var file: FileHandle?
    private var bytes: UInt32 = 0
    private var checkpointBytes: UInt32 = 0

    init(url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(bytes: 0),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw AppFailure(message: "녹음 파일을 만들지 못했습니다. 저장 공간을 확인하세요.")
        }
        file = try FileHandle(forWritingTo: url)
        try file?.seekToEnd()
    }
    func append(_ samples: [Float]) throws {
        guard let file else { throw AppFailure(message: "이미 종료된 녹음 파일입니다.") }
        guard UInt64(bytes) + UInt64(samples.count) * 2 <= UInt64(UInt32.max) - 36 else {
            throw AppFailure(message: "녹음 파일의 크기 한도에 도달했습니다.")
        }
        var pcm = samples.map { Int16((min(1, max(-1, $0.isFinite ? $0 : 0)) * 32767).rounded()).littleEndian }
        let data = pcm.withUnsafeMutableBytes { Data($0) }
        try file.write(contentsOf: data)
        bytes += UInt32(data.count)
        if bytes - checkpointBytes >= 32_000 { try checkpoint() }
    }
    private func checkpoint() throws {
        guard let file else { return }
        try file.seek(toOffset: 0)
        try file.write(contentsOf: Self.header(bytes: bytes))
        try file.seekToEnd()
        try file.synchronize()
        checkpointBytes = bytes
    }
    func close() throws {
        try checkpoint()
        try file?.close()
        file = nil
    }
    deinit { try? close() }

    private static func header(bytes: UInt32) -> Data {
        var data = Data("RIFF".utf8)
        func add<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        add(bytes + 36); data.append(Data("WAVEfmt ".utf8)); add(UInt32(16))
        add(UInt16(1)); add(UInt16(1)); add(UInt32(16_000)); add(UInt32(32_000))
        add(UInt16(2)); add(UInt16(16)); data.append(Data("data".utf8)); add(bytes)
        return data
    }
    /// 이미 기록된 PCM 본문만 읽습니다. 녹음 큐를 멈추거나 파일 전체를 복사하지 않습니다.
    static func copyRange(from source: URL, to target: URL, start: Int64, end: Int64) throws {
        let available = try frameCount(source)
        guard start >= 0, end > start, end <= available, end - start <= 30 * 60 * 16_000 else {
            throw AppFailure(message: "아직 저장되지 않았거나 너무 긴 녹음 구간입니다.")
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: target.path, contents: header(bytes: UInt32((end - start) * 2)),
                attributes: [.posixPermissions: 0o600]) else { throw AppFailure(message: "구간 사본을 만들지 못했습니다.") }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        try output.seekToEnd()
        try input.seek(toOffset: UInt64(44 + start * 2))
        var remaining = (end - start) * 2
        while remaining > 0 {
            guard let data = try input.read(upToCount: Int(min(65_536, remaining))), !data.isEmpty else {
                throw AppFailure(message: "녹음 구간을 끝까지 읽지 못했습니다.")
            }
            try output.write(contentsOf: data)
            remaining -= Int64(data.count)
        }
        try output.synchronize()
    }
    static func frameCount(_ url: URL) throws -> Int64 {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let data = try input.read(upToCount: 44) ?? Data()
        let expected = header(bytes: 0)
        guard data.count == 44, data[0..<4] == expected[0..<4], data[8..<40] == expected[8..<40] else {
            throw AppFailure(message: "소리노트의 WAV 녹음 형식이 아닙니다.")
        }
        let size = try input.seekToEnd()
        return Int64(max(44, size) - 44) / 2
    }
    static func repairDraft(_ url: URL) throws {
        let file = try FileHandle(forUpdating: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        guard length >= 44, length - 44 <= UInt64(UInt32.max) - 36 else {
            throw AppFailure(message: "복구할 녹음 파일의 크기가 올바르지 않습니다.")
        }
        try file.seek(toOffset: 0)
        let old = try file.read(upToCount: 44) ?? Data()
        let expected = header(bytes: 0)
        guard old.count == 44, old[0..<4] == expected[0..<4], old[8..<40] == expected[8..<40] else {
            throw AppFailure(message: "소리노트의 WAV 녹음 형식이 아닙니다.")
        }
        // 마지막 PCM 샘플이 반만 기록됐으면 그 1바이트만 제외합니다.
        let bytes = UInt32((length - 44) / 2 * 2)
        try file.truncate(atOffset: UInt64(bytes) + 44)
        try file.seek(toOffset: 0); try file.write(contentsOf: header(bytes: bytes))
        try file.synchronize()
    }
}

/// 처리 속도가 느려도 이미 끝난 구간 다음부터 하나씩 꺼냅니다. 간격은 벽시계가 아닌 녹음 길이입니다.
struct RecordingIntervalCursor {
    let framesPerInterval: Int64
    var processedFrames: Int64 = 0
    init(minutes: Int) { framesPerInterval = Int64(minutes) * 60 * 16_000 }
    func next(availableFrames: Int64, finished: Bool) -> Range<Int64>? {
        guard framesPerInterval > 0, availableFrames > processedFrames else { return nil }
        let end = min(availableFrames, processedFrames + framesPerInterval)
        guard finished || end - processedFrames == framesPerInterval else { return nil }
        return processedFrames..<end
    }
}
