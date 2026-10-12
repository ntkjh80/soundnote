import Foundation
import CryptoKit
import Darwin

/// 시스템 Python은 수정하지 않습니다. 전용 환경은 검증이 끝난 뒤에만 앱에 연결합니다.
final class RuntimeInstaller: @unchecked Sendable {
    static let pythonVersion = "3.12.15"
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private let inherited: [String: String]
    private let availableCapacity: @Sendable (URL) throws -> Int64?
    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         availableCapacity: @escaping @Sendable (URL) throws -> Int64? = {
             try $0.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
         }) { inherited = environment; self.availableCapacity = availableCapacity }
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

    func install(resources: URL, directory: URL, options: RuntimeSettings = RuntimeSettings(), preferredPython: String = "",
                 progress: @escaping @Sendable (String) -> Void) throws -> String {
        try checkCancellation()
        #if !arch(arm64)
        throw AppFailure(message: "로컬 음성·검색 엔진 설치는 Apple Silicon 맥에서 사용할 수 있습니다.")
        #else
        try options.network.validate()
        let fm = FileManager.default
        let runtime = directory.appendingPathComponent("runtime", isDirectory: true)
        try fm.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // OS 잠금은 비정상 종료 후 자동 해제됩니다. 다른 창의 설치를 가로채지 않습니다.
        let fd = open(runtime.appendingPathComponent("install.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AppFailure(message: "설치 폴더를 열지 못했습니다. 폴더 권한을 확인하세요.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AppFailure(message: "다른 창에서 설치 중입니다. 해당 작업을 마친 뒤 다시 시도하세요.") }
        defer { flock(fd, LOCK_UN) }
        let requirements = resources.appendingPathComponent("requirements.lock.txt")
        let digest = SHA256.hash(data: try Data(contentsOf: requirements)).map { String(format: "%02x", $0) }.joined()
        let manifest = runtime.appendingPathComponent("runtime.json")
        var env = options.network.environment(inherited: inherited)
        env["UV_CACHE_DIR"] = runtime.appendingPathComponent("cache").path
        env["UV_PYTHON_INSTALL_DIR"] = runtime.appendingPathComponent("python").path
        env["UV_PYTHON_BIN_DIR"] = runtime.appendingPathComponent("bin").path
        env["UV_LINK_MODE"] = "copy"
        let uv = resources.appendingPathComponent("uv").path
        if !(env["UV_INSECURE_HOST"] ?? "").isEmpty {
            progress("터미널에서 지정한 uv 인증서 예외가 적용됩니다. 모델 다운로드에는 적용되지 않습니다.")
        }
        progress("1/4 · 사용할 Python과 가상 환경을 확인하는 중")
        // 명시적으로 다른 환경을 선택한 경우에는 이전 포인터로 되돌아가지 않습니다.
        if options.mode == .automatic,
           let data = try? Data(contentsOf: manifest),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           value["requirementsSHA256"] == digest, let python = AppSettings.managedPython(in: directory) {
            do { try verify(python, requirements: requirements, env: env); return python }
            catch is CancellationError { throw CancellationError() }
            catch { progress("기존 환경을 보존하고 새 실행 환경을 준비합니다") }
        }

        if options.mode == .existingVenv {
            let source = options.sourcePython.trimmingCharacters(in: .whitespacesAndNewlines)
            guard try inspect(source, env: env).venv else {
                throw AppFailure(message: "선택한 Python은 venv가 아닙니다. 가상 환경의 bin/python 파일을 선택하세요.")
            }
            do { try verify(source, requirements: requirements, env: env); return source }
            catch is CancellationError { throw CancellationError() }
            catch {
                guard options.installMissingPackages else {
                    throw AppFailure(message: "venv의 실행 검사를 통과하지 못했습니다. 아래 원인을 확인하세요. 패키지가 없거나 버전이 다르면 '선택한 venv에 필수 패키지 설치'를 켜거나 기존 Python으로 전용 venv를 만드세요.\n\n" + error.localizedDescription)
                }
            }
            progress("3/4 · 선택한 venv에 필요한 패키지를 설치하는 중")
            // 사용자가 직접 선택한 환경은 sync로 불필요한 패키지를 삭제하지 않습니다.
            try packages(uv, python: source, requirements: requirements, env: env, options: options, sync: false)
            try verify(source, requirements: requirements, env: env)
            return source
        }

        var source: String?
        if options.mode == .localPython {
            source = options.sourcePython.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try inspect(source!, env: env)
        } else if options.mode == .automatic {
            for candidate in candidates(preferred: preferredPython) {
                do {
                    let info = try inspect(candidate, env: env)
                    if info.venv {
                        do { try verify(candidate, requirements: requirements, env: env); return candidate }
                        catch is CancellationError { throw CancellationError() }
                        catch { /* 준비가 덜 된 외부 venv는 수정하지 않고 새 환경의 Python으로만 사용합니다. */ }
                    }
                    source = candidate; break
                } catch is CancellationError { throw CancellationError() }
                catch { continue }
            }
        }
        if source == nil {
            guard (options.mode == .download || options.allowPythonDownload),
                  !options.network.offline, !["1", "true"].contains(env["UV_OFFLINE"] ?? "") else {
                throw AppFailure(message: "사용할 수 있는 ARM64 Python 3.12가 없습니다. 기존 Python 또는 venv의 bin/python을 선택하세요. 현재 설정에서는 Python을 다운로드하지 않습니다.")
            }
            progress("2/4 · Python \(Self.pythonVersion)을 준비하는 중")
            try run(uv, ["python", "install", "--no-bin", Self.pythonVersion], env: env, step: "Python 다운로드")
            // uv가 자체 관리하는 Python만 선택합니다. 여기서 추가 다운로드는 허용하지 않습니다.
            source = Self.pythonVersion
        } else {
            progress("2/4 · 설치된 Python을 사용합니다. Python 다운로드는 건너뜁니다.")
        }
        let available = try availableCapacity(runtime)
        if let available, available < 12_000_000_000 { throw AppFailure(message: "엔진 설치에는 최소 12GB, 모델까지 준비하려면 25GB 이상의 여유 공간을 확보하세요.") }
        let engines = runtime.appendingPathComponent("engines", isDirectory: true)
        try fm.createDirectory(at: engines, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let engine = engines.appendingPathComponent(String(digest.prefix(12)) + "-" + UUID().uuidString, isDirectory: true)
        let python = engine.appendingPathComponent("bin/python").path
        var published = false
        // venv 안에는 절대 경로가 있습니다. 완성한 폴더를 옮기는 대신 포인터만 교체합니다.
        defer { if !published { try? fm.removeItem(at: engine) } }
        var arguments = ["venv", "--no-project", "--no-python-downloads", "--python", source!]
        if source == Self.pythonVersion { arguments.append("--managed-python") }
        arguments.append(engine.path)
        try run(uv, arguments, env: env, step: "전용 venv 생성")
        progress("3/4 · 음성·검색 패키지를 설치하는 중")
        try packages(uv, python: python, requirements: requirements, env: env, options: options, sync: true)
        progress("4/4 · Python 버전과 설치한 엔진을 확인하는 중")
        let verified = try verify(python, requirements: requirements, env: env)
        let data = try JSONSerialization.data(withJSONObject: ["pythonPath": python, "requirementsSHA256": digest,
            "pythonVersion": verified.version, "sourcePython": source!], options: [.sortedKeys])
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try data.write(to: manifest, options: .atomic)
        published = true
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        return python
        #endif
    }

    private func candidates(preferred: String) -> [String] {
        var paths = [preferred]
        if let venv = inherited["VIRTUAL_ENV"] { paths.append(venv + "/bin/python") }
        for folder in (inherited["PATH"] ?? "").split(separator: ":") where folder.hasPrefix("/") {
            paths += [String(folder) + "/python3.12", String(folder) + "/python3"]
        }
        paths += ["/opt/homebrew/bin/python3.12", "/opt/homebrew/opt/python@3.12/bin/python3.12", "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12"]
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && $0 != "/usr/bin/python3" && seen.insert($0).inserted }
    }

    private struct PythonInfo: Decodable { let major: Int; let minor: Int; let patch: Int?; let machine: String; let venv: Bool
        var version: String { "\(major).\(minor)" + (patch.map { ".\($0)" } ?? "") } }
    private func inspect(_ python: String, env: [String: String]) throws -> PythonInfo {
        guard python.hasPrefix("/"), python != "/usr/bin/python3", FileManager.default.isExecutableFile(atPath: python) else {
            throw AppFailure(message: "실행할 수 있는 Python의 절대 경로를 선택하세요. macOS 기본 /usr/bin/python3는 사용하지 않습니다.")
        }
        let code = "import json,sys,platform; print(json.dumps(dict(major=sys.version_info.major,minor=sys.version_info.minor,patch=sys.version_info.micro,machine=platform.machine(),venv=sys.prefix!=sys.base_prefix)))"
        let output = try run(python, ["-I", "-B", "-c", code], env: env, step: "Python 버전 확인")
        guard let data = output.data(using: .utf8), let info = try? JSONDecoder().decode(PythonInfo.self, from: data),
              info.major == 3, info.minor == 12, info.machine == "arm64" else {
            throw AppFailure(message: "이 앱의 로컬 엔진은 ARM64 Python 3.12를 사용합니다. 다른 버전이나 Rosetta용 Python 대신 호환되는 실행 파일을 선택하세요.")
        }
        return info
    }

    @discardableResult
    private func verify(_ python: String, requirements: URL, env: [String: String]) throws -> PythonInfo {
        let info = try inspect(python, env: env)
        // import 성공만으로는 EmbeddingGemma 2 지원을 보장하지 못하므로 잠금 파일의 버전도 확인합니다.
        let code = #"""
        import importlib.metadata as m, pathlib, re, sys
        for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
            match = re.fullmatch(r'([A-Za-z0-9_.-]+)==([^\s;]+)', line.strip())
            if match:
                name, expected = match.groups()
                assert m.version(name) == expected, f'{name}: required {expected}, installed {m.version(name)}'
        import mlx_whisper, torch, torchaudio, pyannote.audio, sentence_transformers, transformers, imageio_ffmpeg, truststore
        """#
        try run(python, ["-I", "-B", "-c", code, requirements.path], env: env, step: "필수 패키지 확인")
        return info
    }

    private func packages(_ uv: String, python: String, requirements: URL, env: [String: String], options: RuntimeSettings, sync: Bool) throws {
        var args = ["pip", sync ? "sync" : "install", "--python", python, "--no-python-downloads", "--no-build"]
        if !options.network.packageIndexURL.isEmpty { args += ["--default-index", options.network.packageIndexURL] }
        if !options.network.wheelhousePath.isEmpty { args += ["--no-index", "--find-links", options.network.wheelhousePath] }
        if !sync { args.append("-r") }
        args.append(requirements.path)
        try run(uv, args, env: env, step: "음성·검색 패키지 설치")
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String], env: [String: String], step: String) throws -> String {
        try checkCancellation()
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments; task.environment = env
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = pipe; task.standardError = pipe
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try task.run(); process = task; lock.unlock() }
        catch { lock.unlock(); throw AppFailure(message: "\(step)을 시작하지 못했습니다. 실행 파일 경로와 권한을 확인하세요.") }
        // 출력은 즉시 비워 교착을 막고, 진단용 마지막 64KB만 메모리에 보관합니다. 디스크에는 쓰지 않습니다.
        var tail = Data()
        var cutLine = false
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            tail.append(chunk)
            if tail.count > 65_536 { tail = Data(tail.suffix(65_536)); cutLine = true }
        }
        task.waitUntilExit()
        lock.lock(); process = nil; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw CancellationError() }
        // 잘린 URL 중간부터 시작하는 줄은 통째로 버려 자격 증명 일부가 노출되지 않게 합니다.
        if cutLine {
            if let newline = tail.firstIndex(of: 10) { tail.removeSubrange(...newline) } else { tail.removeAll() }
        }
        let output = String(decoding: tail, as: UTF8.self)
        guard task.terminationStatus == 0 else {
            throw InstallationDiagnostics.failure(step: step, status: task.terminationStatus, output: output, environment: env)
        }
        return output
    }
}
