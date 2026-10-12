import Foundation
import Darwin

/// UI는 로컬 서버 포트를 열지 않습니다. 요청 한 번에 워커 하나를 실행합니다.
final class WorkerClient: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let active = process
        lock.unlock()
        if let active, active.isRunning {
            active.terminate()
            // 모델의 C 연산 때문에 SIGTERM 처리가 늦어지는 경우도 취소할 수 있어야 합니다.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if active.isRunning { kill(active.processIdentifier, SIGKILL) }
            }
        }
    }

    func execute(python: String, request: Data, environment suppliedEnvironment: [String: String]? = nil, update: @escaping @Sendable (Data) -> Void = { _ in }, progress: @escaping @Sendable (String) -> Void) throws -> Data {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("worker/main.py")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("worker/main.py")
        let script = [bundled, source].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
        guard let script else { throw AppFailure(message: "앱 안에서 처리 엔진을 찾지 못했습니다. 앱을 다시 빌드해 주세요.") }
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw AppFailure(message: "Python 실행 파일이 없습니다. 설정에서 설치된 Python의 절대 경로를 지정하세요.")
        }
        let task = Process()
        let input = Pipe(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: python)
        task.arguments = ["-u", script.path]
        task.standardInput = input
        task.standardOutput = output
        // 라이브러리 로그에는 파일 경로나 토큰이 들어갈 수 있어 저장하지 않습니다.
        task.standardError = FileHandle.nullDevice
        var environment = suppliedEnvironment ?? ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "PYTHONPATH")
        environment.removeValue(forKey: "PYTHONHOME")
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["PYANNOTE_METRICS_ENABLED"] = "0"
        if let binary = Bundle.main.resourceURL?.appendingPathComponent("installer/ollama/ollama"),
           FileManager.default.isExecutableFile(atPath: binary.path) {
            environment["SORINOTE_OLLAMA_BIN"] = binary.path
        }
        task.environment = environment
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try task.run(); process = task; lock.unlock() }
        catch { lock.unlock(); throw error }
        defer {
            if task.isRunning { task.terminate() }
            lock.lock(); process = nil; lock.unlock()
        }
        try input.fileHandleForWriting.write(contentsOf: request)
        try input.fileHandleForWriting.close()
        var buffer = Data()
        var result: Data?
        var failure: String?
        func consume(_ line: Data) {
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            switch event["event"] as? String {
            case "entry":
                if let value = event["data"], let data = try? JSONSerialization.data(withJSONObject: value) { update(data) }
            case "progress": progress(event["message"] as? String ?? "처리 중")
            case "result": result = try? JSONSerialization.data(withJSONObject: event["data"] ?? [:])
            case "error": failure = event["message"] as? String
            default: break
            }
        }
        while true {
            let bytes = output.fileHandleForReading.availableData
            if bytes.isEmpty { break }
            buffer.append(bytes)
            while let newline = buffer.firstIndex(of: 10) {
                consume(buffer.subdata(in: 0..<newline))
                buffer.removeSubrange(0...newline)
            }
        }
        if !buffer.isEmpty { consume(buffer) }
        task.waitUntilExit()
        lock.lock(); let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw CancellationError() }
        if let failure { throw AppFailure(message: failure) }
        guard task.terminationStatus == 0, let result else {
            throw AppFailure(message: "처리 엔진이 종료되었습니다. Python 버전과 설치 상태를 확인해 주세요.")
        }
        return result
    }
}
