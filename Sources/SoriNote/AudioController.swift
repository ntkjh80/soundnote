import AVFoundation
import SwiftUI

@MainActor
final class AudioController: NSObject, ObservableObject {
    @Published var recording = false
    @Published var paused = false
    @Published var elapsed: Double = 0
    @Published var level: Double = 0
    @Published var playing = false
    @Published var playhead: Double = 0
    @Published var duration: Double = 0
    @Published var recordingError: String?
    @Published var microphoneLevel: Double = 0
    @Published var systemLevel: Double = 0
    @Published var activeSource: RecordingSource = .microphone
    @Published var captureNotice: String?
    private(set) var recordingURL: URL?
    var availableFrames: Int64 { session?.status().writtenFrames ?? 0 }
    /// 녹음 중지와 마지막 파일 쓰기가 겹쳐도 완료를 기다린 뒤 원음을 넘깁니다.
    func completedRecordingURL() async throws -> URL? {
        if let finishing { return try await finishing.value }
        return recordingURL
    }
    private var session: AudioCaptureSession?
    private var sessionID: UUID?
    private var finishing: Task<URL?, Error>?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var playerURL: URL?

    override init() {
        super.init()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        if let session, recording {
            let status = session.status()
            elapsed = status.elapsed
            microphoneLevel = paused ? 0 : status.microphone
            systemLevel = paused ? 0 : status.system
            level = max(microphoneLevel, systemLevel)
            if status.lateFrames > 1600 { captureNotice = "일부 오디오가 늦게 도착했습니다. 녹음 후 원음을 확인하세요." }
        }
        if let player {
            playing = player.isPlaying
            playhead = player.currentTime
            duration = player.duration
        }
    }

    func start(settings: AudioSettings) async throws {
        guard session == nil else { return }
        guard finishing == nil else { throw AppFailure(message: "앞선 녹음을 마무리하고 있습니다. 잠시 뒤 다시 시작하세요.") }
        try settings.validate()
        if settings.source.usesMicrophone {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard allowed else {
                throw AppFailure(message: "마이크 접근이 필요합니다. 시스템 설정 → 개인정보 보호 및 보안 → 마이크에서 소리노트를 허용하세요.")
            }
        }
        stopPlayback()
        let folder = AppSettings.directory.appendingPathComponent("drafts")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(UUID().uuidString + ".wav")
        let capture = AudioCaptureSession()
        recordingError = nil; captureNotice = nil; elapsed = 0
        let identifier = UUID()
        session = capture; sessionID = identifier; recordingURL = url
        do {
            try await capture.start(url: url, settings: settings) { [weak self] message in
                Task { @MainActor in
                    guard let self, self.sessionID == identifier else { return }
                    self.recordingError = message
                    if self.recording { _ = try? await self.stop() }
                }
            }
            guard sessionID == identifier else { throw CancellationError() }
            if let message = recordingError { throw AppFailure(message: message) }
            activeSource = settings.source
            recording = true; paused = false
        } catch {
            _ = try? await capture.stop()
            session = nil; sessionID = nil; recordingURL = nil
            // 모든 입력이 시작되기 전 실패한 새 임시 파일만 정리합니다.
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func pauseOrResume() {
        guard let session, recording else { return }
        session.setPaused(!paused)
        paused.toggle()
        microphoneLevel = 0; systemLevel = 0; level = 0
    }

    func stop() async throws -> URL? {
        if let finishing { return try await finishing.value }
        guard let session else { return nil }
        self.session = nil; sessionID = nil
        recording = false; paused = false; level = 0; microphoneLevel = 0; systemLevel = 0
        let task = Task { @MainActor in try await session.stop() }
        finishing = task
        defer { finishing = nil }
        return try await task.value
    }

    func play(_ path: String, at seconds: Double? = nil) throws {
        let url = URL(fileURLWithPath: path)
        if playerURL != url { player = try AVAudioPlayer(contentsOf: url); playerURL = url }
        guard let player else { return }
        if let seconds { player.currentTime = min(max(0, seconds), player.duration); player.play() }
        else if player.isPlaying { player.pause() } else { player.play() }
        tick()
    }

    func stopPlayback() { player?.stop(); playing = false }
}
