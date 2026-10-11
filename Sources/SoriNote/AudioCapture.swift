import AVFoundation
import CoreAudio
import ScreenCaptureKit

struct MicrophoneDevice: Identifiable {
    let id: String
    let name: String
    let deviceID: AudioDeviceID
}

/// 장치 UID를 저장하므로 USB 장치를 다시 연결해 숫자 ID가 바뀌어도 같은 마이크를 찾습니다.
enum MicrophoneDevices {
    static func list() -> [MicrophoneDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.compactMap { device in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var length: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &length) == noErr, length > 0 else { return nil }
            let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(length), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { memory.deallocate() }
            guard AudioObjectGetPropertyData(device, &streams, 0, nil, &length, memory) == noErr else { return nil }
            let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
            guard buffers.contains(where: { $0.mNumberChannels > 0 }),
                  let uid = text(device, kAudioDevicePropertyDeviceUID), let name = text(device, kAudioObjectPropertyName) else { return nil }
            return MicrophoneDevice(id: uid, name: name, deviceID: device)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private static func text(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

struct CaptureStatus {
    var elapsed: Double = 0
    var microphone: Double = 0
    var system: Double = 0
    var lateFrames: Int64 = 0
}

/// 가변 상태는 queue 안에서만 접근합니다. 공개 제어 메서드도 이 큐를 거치므로 Sendable을 수동 보증합니다.
/// ScreenCaptureKit 콜백과 마이크 버퍼를 한 큐에서 변환·정렬합니다. 화면 픽셀은 요청하거나 저장하지 않습니다.
final class AudioCaptureSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Source: Hashable { case microphone, system }
    let queue = DispatchQueue(label: "app.sorinote.audio.capture", qos: .userInitiated)
    private let settings: AudioSettings
    private let writer: PCMRecordingWriter
    private var timeline: CaptureTimeline!
    private var converters: [Source: AVAudioConverter] = [:]
    private var meters: [Source: (Double, Double)] = [:]
    private var timer: DispatchSourceTimer?
    private var failure: Error?
    private var closed = false
    private var stopping = false
    private let onFailure: (String) -> Void
    private let format = AVAudioFormat(standardFormatWithSampleRate: CaptureTimeline.sampleRate, channels: 1)!
    static func now() -> Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }

    init(url: URL, settings: AudioSettings, onFailure: @escaping (String) -> Void) throws {
        self.settings = settings; self.onFailure = onFailure
        writer = try PCMRecordingWriter(url: url)
        super.init()
        timeline = CaptureTimeline(start: Self.now()) { [writer] values in try writer.append(values) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
        timer.setEventHandler { [weak self] in self?.flush() }
        self.timer = timer; timer.resume()
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        systemBuffer(buffer)
    }
    // 실제 콜백과 합성 버퍼 검사가 같은 변환 경로를 사용합니다. 반드시 queue에서 호출합니다.
    func systemBuffer(_ buffer: CMSampleBuffer) {
        guard buffer.isValid, CMSampleBufferDataIsReady(buffer),
              let description = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let inputFormat = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = CMSampleBufferGetNumSamples(buffer)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        pcm.frameLength = AVAudioFrameCount(frames)
        let result = CMSampleBufferCopyPCMDataIntoAudioBufferList(buffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard result == noErr else { fail(AppFailure(message: "시스템 오디오 버퍼를 읽지 못했습니다.")); return }
        consume(pcm, at: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer)), source: .system)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, !self.stopping, !self.closed else { return }
            self.fail(AppFailure(message: "시스템 오디오 캡처가 멈췄습니다. 녹음은 임시 파일에 보관했습니다. 권한과 오디오 장치를 확인하세요."))
        }
    }
    func microphone(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        // 오디오 엔진은 콜백 종료 뒤 버퍼를 재사용합니다. 소유한 사본만 비동기 큐에 넘깁니다.
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<source.count {
            if let a = target[index].mData, let b = source[index].mData {
                memcpy(a, b, Int(source[index].mDataByteSize))
            }
        }
        let timestamp = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : Double.nan
        queue.async { [weak self] in self?.consume(copy, at: timestamp, source: .microphone) }
    }
    private func consume(_ input: AVAudioPCMBuffer, at time: Double, source: Source) {
        guard !closed, failure == nil else { return }
        guard time.isFinite, abs(time - Self.now()) < 10 else {
            fail(AppFailure(message: "녹음 입력의 시간 정보를 맞추지 못했습니다. 오디오 장치를 다시 연결하고 녹음을 시작하세요.")); return
        }
        do {
            let converter: AVAudioConverter
            if let existing = converters[source], existing.inputFormat == input.format { converter = existing }
            else {
                guard let value = AVAudioConverter(from: input.format, to: format) else {
                    throw AppFailure(message: "선택한 오디오 장치의 입력 형식을 변환할 수 없습니다.")
                }
                value.primeMethod = .none; converters[source] = value; converter = value
            }
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 256
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var supplied = false, error: NSError?
            let result = converter.convert(to: output, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return input
            }
            guard result != .error, error == nil else { throw error ?? AppFailure(message: "오디오 형식 변환에 실패했습니다.") as NSError }
            guard output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            let peak = Double(samples.reduce(Float(0)) { $1.isFinite ? max($0, abs($1)) : $0 })
            meters[source] = (min(1, peak), Self.now())
            let gain = source == .microphone ? settings.microphoneGain : settings.systemGain
            // 두 소스가 함께 커질 때 여유를 두고, 마지막 저장 단계에서도 클리핑을 제한합니다.
            timeline.add(samples, at: time, gain: Float(gain * (settings.source == .both ? 0.5 : 1)))
        } catch { fail(error) }
    }
    private func flush() {
        guard !closed, failure == nil else { return }
        do {
            // 입력별 도착 지연을 흡수합니다. 아직 쓰지 않은 0.5초 구간만 메모리에 둡니다.
            try timeline.flush(until: Self.now() - 0.5)
            if timeline.frame(at: Self.now()) >= Int64(14_400 * CaptureTimeline.sampleRate) {
                fail(AppFailure(message: "4시간 녹음 한도에 도달해 녹음을 멈췄습니다. 임시 녹음은 다음 실행에서 복구합니다."))
            }
        } catch { fail(error) }
    }
    private func fail(_ error: Error) {
        guard failure == nil, !closed else { return }
        failure = error
        onFailure((error as? AppFailure)?.message ?? "녹음을 저장하지 못했습니다. 디스크 공간과 오디오 장치를 확인하세요. 임시 파일은 보관합니다.")
    }
    func externalFailure(_ message: String) { queue.async { [weak self] in self?.fail(AppFailure(message: message)) } }
    func setPaused(_ paused: Bool) {
        queue.sync {
            if paused { timeline.pause(at: Self.now()) } else { timeline.resume(at: Self.now()) }
            meters.removeAll()
        }
    }
    func status() -> CaptureStatus {
        queue.sync {
            let now = Self.now()
            func level(_ source: Source) -> Double {
                guard let meter = meters[source], now - meter.1 < 0.6 else { return 0 }
                return meter.0
            }
            return CaptureStatus(elapsed: Double(timeline.frame(at: now)) / CaptureTimeline.sampleRate,
                                 microphone: level(.microphone), system: level(.system), lateFrames: timeline.lateFrames)
        }
    }
    func beginStop() { queue.sync { stopping = true; timeline.pause(at: Self.now()) } }
    func finish() throws -> URL {
        try queue.sync {
            guard !closed else { return writer.url }
            timer?.cancel(); timer = nil
            defer { closed = true }
            // stopCapture 완료 뒤 큐를 비운 다음 마지막 0.5초를 저장합니다.
            try timeline.flush(until: Self.now())
            try writer.close()
            return writer.url
        }
    }
}

/// 마이크는 AVAudioEngine, 컴퓨터 내부 소리는 ScreenCaptureKit에서 직접 받습니다.
@MainActor
final class AudioCaptureSession {
    private var engine: AVAudioEngine?
    private var stream: SCStream?
    private var sink: AudioCaptureSink?
    private var configurationObserver: NSObjectProtocol?

    func start(url: URL, settings: AudioSettings, onFailure: @escaping (String) -> Void) async throws {
        try settings.validate()
        var filter: SCContentFilter?
        if settings.source.usesSystem {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else { throw AppFailure(message: "시스템 오디오 캡처에 사용할 디스플레이를 찾지 못했습니다.") }
                filter = SCContentFilter(display: display, excludingWindows: [])
            } catch {
                throw AppFailure(message: "시스템 오디오 접근이 필요합니다. 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음에서 소리노트를 허용한 뒤 앱을 다시 실행하세요.")
            }
        }
        let sink = try AudioCaptureSink(url: url, settings: settings, onFailure: onFailure)
        self.sink = sink
        do {
            if let filter {
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 48_000; configuration.channelCount = 2
                configuration.width = 2; configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                configuration.queueDepth = 3
                let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
                try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
                self.stream = stream
                try await stream.startCapture()
            }
            if settings.source.usesMicrophone {
                let engine = AVAudioEngine(), input: AVAudioInputNode
                input = engine.inputNode
                if !settings.microphoneID.isEmpty {
                    guard let device = MicrophoneDevices.list().first(where: { $0.id == settings.microphoneID }), let unit = input.audioUnit else {
                        throw AppFailure(message: "선택한 마이크가 연결되어 있지 않습니다. 음성 설정에서 장치를 다시 선택하세요.")
                    }
                    var id = device.deviceID
                    guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                               &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
                        throw AppFailure(message: "선택한 마이크를 열지 못했습니다. 다른 장치나 시스템 기본 마이크를 선택하세요.")
                    }
                }
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw AppFailure(message: "마이크 입력 형식이 올바르지 않습니다.") }
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak sink] buffer, time in sink?.microphone(buffer, time: time) }
                self.engine = engine
                engine.prepare(); try engine.start()
                configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                    object: engine, queue: nil) { [weak sink] _ in
                    sink?.externalFailure("녹음 중 마이크 장치나 입력 형식이 변경됐습니다. 현재 녹음은 임시 파일에 보관합니다. 음성 설정을 확인한 뒤 다시 녹음하세요.")
                }
            }
        } catch {
            _ = try? await stop()
            throw error
        }
    }
    func status() -> CaptureStatus { sink?.status() ?? CaptureStatus() }
    func setPaused(_ value: Bool) { sink?.setPaused(value) }
    func stop() async throws -> URL? {
        guard let sink else { return nil }
        sink.beginStop()
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer); configurationObserver = nil }
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0); self.engine = nil }
        if let stream { try? await stream.stopCapture(); self.stream = nil }
        self.sink = nil
        return try sink.finish()
    }
}
