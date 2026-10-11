import Foundation
import CryptoKit
import Darwin

/// 사용자 폴더에 전용 엔진을 만듭니다. Process와 취소 상태는 잠금으로 보호합니다.
final class RuntimeInstaller: @unchecked Sendable {
    static let pythonVersion = "3.12.15"
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    static var resources: URL? {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("installer"),
              FileManager.default.isExecutableFile(atPath: folder.appendingPathComponent("uv").path) else { return nil }
        return folder
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = process; lock.unlock()
        if let task, task.isRunning {
            task.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            }
        }
    }
    func checkCancellation() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
    func install(resources: URL, directory: URL, progress: @escaping @Sendable (String) -> Void) throws -> String {
        try checkCancellation()
        #if !arch(arm64)
        throw AppFailure(message: "자동 설치는 Apple Silicon 맥에서 사용할 수 있습니다.")
        #else
        let fm = FileManager.default
        let runtime = directory.appendingPathComponent("runtime", isDirectory: true)
        try fm.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // OS 잠금은 비정상 종료 후 자동 해제됩니다. 다른 설치를 가로채지 않습니다.
        let fd = open(runtime.appendingPathComponent("install.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AppFailure(message: "설치 폴더를 열지 못했습니다. 폴더 권한을 확인하세요.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AppFailure(message: "다른 창에서 설치 중입니다. 해당 작업을 마친 뒤 다시 시도하세요.") }
        defer { flock(fd, LOCK_UN) }
        let requirements = resources.appendingPathComponent("requirements.lock.txt")
        let digest = SHA256.hash(data: try Data(contentsOf: requirements)).map { String(format: "%02x", $0) }.joined()
        let manifest = runtime.appendingPathComponent("runtime.json")
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("UV_") && !$0.key.hasPrefix("PIP_") }
        env["UV_NO_CONFIG"] = "1"
        env["UV_CACHE_DIR"] = runtime.appendingPathComponent("cache").path
        env["UV_PYTHON_INSTALL_DIR"] = runtime.appendingPathComponent("python").path
        env["UV_PYTHON_BIN_DIR"] = runtime.appendingPathComponent("bin").path
        env["UV_LINK_MODE"] = "copy"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["PYANNOTE_METRICS_ENABLED"] = "0"
        env["DO_NOT_TRACK"] = "1"
        env.removeValue(forKey: "PYTHONPATH"); env.removeValue(forKey: "PYTHONHOME")
        let probe = "import sys; assert sys.version_info[:2] == (3, 12); import mlx_whisper, torch, torchaudio, pyannote.audio, sentence_transformers, transformers, imageio_ffmpeg"
        progress("전용 실행 환경을 확인하는 중")
        if let data = try? Data(contentsOf: manifest),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           value["requirementsSHA256"] == digest, value["pythonVersion"] == Self.pythonVersion,
           let python = AppSettings.managedPython(in: directory) {
            do {
                try run(python, ["-c", probe], env: env, step: "기존 실행 환경 확인")
                return python
            } catch is CancellationError { throw CancellationError() }
            catch { progress("기존 환경을 보존하고 새 실행 환경으로 복구합니다") }
        }
        let available = try runtime.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let available, available < 12_000_000_000 { throw AppFailure(message: "설치에는 최소 12GB, 모델까지 준비하려면 25GB 이상의 여유 공간을 확보하세요.") }
        let uv = resources.appendingPathComponent("uv").path
        progress("Python \(Self.pythonVersion)을 준비하는 중 · 첫 설치에는 인터넷이 필요합니다")
        try run(uv, ["python", "install", "--no-bin", Self.pythonVersion], env: env, step: "Python 다운로드")
        let engines = runtime.appendingPathComponent("engines", isDirectory: true)
        try fm.createDirectory(at: engines, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let engine = engines.appendingPathComponent(String(digest.prefix(12)) + "-" + UUID().uuidString, isDirectory: true)
        let python = engine.appendingPathComponent("bin/python").path
        var published = false
        // 가상 환경은 내부에 절대 경로가 있어 옮기지 않습니다. 완성된 뒤 포인터만 교체합니다.
        defer { if !published { try? fm.removeItem(at: engine) } }
        progress("소리노트 전용 Python 환경을 만드는 중")
        try run(uv, ["venv", "--no-project", "--managed-python", "--no-python-downloads", "--python", Self.pythonVersion, engine.path], env: env, step: "전용 환경 생성")
        progress("음성·검색 엔진을 설치하는 중 · 네트워크에 따라 몇 분 이상 걸릴 수 있습니다")
        try run(uv, ["pip", "sync", "--python", python, "--no-build", "--index-url", "https://pypi.org/simple", requirements.path], env: env, step: "음성·검색 패키지 설치")
        progress("설치한 음성·검색 엔진을 확인하는 중")
        try run(python, ["-c", probe], env: env, step: "설치된 엔진 확인")
        let data = try JSONSerialization.data(withJSONObject: ["pythonPath": python, "requirementsSHA256": digest,
                                                              "pythonVersion": Self.pythonVersion], options: [.sortedKeys])
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try data.write(to: manifest, options: .atomic)
        published = true
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        return python
        #endif
    }
    private func run(_ executable: String, _ arguments: [String], env: [String: String], step: String) throws {
        try checkCancellation()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments; task.environment = env
        task.standardInput = FileHandle.nullDevice
        // 라이브러리의 경로·인증 정보가 새지 않도록 단계와 종료 코드만 보고합니다.
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try task.run(); process = task; lock.unlock() }
        catch { lock.unlock(); throw AppFailure(message: "\(step)을 시작하지 못했습니다. 설치 패키지를 다시 확인하세요.") }
        task.waitUntilExit()
        lock.lock(); process = nil; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard task.terminationStatus == 0 else { throw AppFailure(message: "\(step)에 실패했습니다(종료 코드 \(task.terminationStatus)). 인터넷 연결·디스크 여유 공간을 확인하고 다시 설치하세요. 기존 기록은 유지됩니다.") }
    }
}
