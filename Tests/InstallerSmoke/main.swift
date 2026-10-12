import Foundation

// 실제 사용자 설정·Python·네트워크를 건드리지 않는 설치 회귀 검사입니다.
func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw AppFailure(message: message) }
}
@discardableResult func mustFail(_ operation: () throws -> Void) throws -> String {
    do { try operation() } catch { return error.localizedDescription }
    throw AppFailure(message: "실패해야 하는 설치가 성공했습니다.")
}
let fm = FileManager.default
do {
    #if !arch(arm64)
    print("자동 설치 검사는 Apple Silicon 전용입니다."); exit(0)
    #endif
    if CommandLine.arguments.count >= 4 && CommandLine.arguments[1] == "--real-install" {
        var options = RuntimeSettings()
        if CommandLine.arguments.count >= 5 { options.mode = .localPython; options.sourcePython = CommandLine.arguments[4] }
        if CommandLine.arguments.contains("--existing") { options.mode = .existingVenv }
        let python = try RuntimeInstaller().install(resources: URL(fileURLWithPath: CommandLine.arguments[2]),
            directory: URL(fileURLWithPath: CommandLine.arguments[3]), options: options) { print($0) }
        print("실제 설치 완료: \(python)"); exit(0)
    }
    let root = fm.temporaryDirectory.appendingPathComponent("sorinote-installer-test-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let resources = root.appendingPathComponent("패키지 도구")
    let directory = root.appendingPathComponent("사용자 데이터")
    try fm.createDirectory(at: resources, withIntermediateDirectories: true)
    func put(_ value: String, at url: URL, executable: Bool = false) throws {
        try value.write(to: url, atomically: true, encoding: .utf8)
        if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }
    let pythonScript = #"""
    #!/bin/sh
    case "$*" in
      *json.dumps*) printf '{"major":3,"minor":12,"machine":"arm64","venv":true}\n';;
      *) if [ -f "$(dirname "$0")/bad" ]; then echo 'PackageNotFoundError: truststore' >&2; exit 1; fi;;
    esac
    """#
    try put(pythonScript, at: resources.appendingPathComponent("template"))
    let script = #"""
    #!/bin/sh
    dir="$(dirname "$0")"
    printf '%s\n' "$*" >> "$dir/calls"
    printf '%s\n' "${UV_SYSTEM_CERTS}|${UV_PYTHON_INSTALL_MIRROR}|${UV_DEFAULT_INDEX}|${HTTPS_PROXY}|${UV_INSECURE_HOST}|${UV_NO_CONFIG}" > "$dir/env"
    if [ -f "$dir/wait" ]; then touch "$dir/started"; exec /bin/sleep 20; fi
    if [ "$1" = "venv" ]; then
      for target in "$@"; do :; done
      mkdir -p "$target/bin"
      cp "$dir/template" "$target/bin/python"
      chmod 755 "$target/bin/python"
    fi
    if [ "$1" = "pip" ]; then
      if [ -f "$dir/fail" ]; then cat "$dir/fail" >&2; exit 1; fi
      previous=''
      for argument in "$@"; do
        if [ "$previous" = '--python' ]; then rm -f "$(dirname "$argument")/bad"; fi
        previous="$argument"
      done
    fi
    """#
    try put(script, at: resources.appendingPathComponent("uv"), executable: true)
    let requirements = resources.appendingPathComponent("requirements.lock.txt")
    try put("test==1\n", at: requirements)
    var download = RuntimeSettings(); download.mode = .download
    let environment = ["PATH": "/usr/bin:/bin", "UV_PYTHON_INSTALL_MIRROR": "https://mirror.example/python",
                       "UV_DEFAULT_INDEX": "https://index.example/simple", "HTTPS_PROXY": "http://proxy.example:8080",
                       "UV_INSECURE_HOST": "old-example", "UV_NO_CONFIG": "true", "UV_TARGET": "/not-allowed"]
    func installer() -> RuntimeInstaller { RuntimeInstaller(environment: environment, availableCapacity: { _ in 100_000_000_000 }) }
    let python = try installer().install(resources: resources, directory: directory, options: download) { _ in }
    try require(AppSettings.managedPython(in: directory) == python, "설치 완료 포인터 오류")
    print("통과: 한글·공백 경로 첫 설치")
    let captured = try String(contentsOf: resources.appendingPathComponent("env"), encoding: .utf8)
    try require(captured.contains("true|https://mirror.example/python|https://index.example/simple|http://proxy.example:8080|old-example|true"), "터미널 네트워크 설정이 사라짐")
    try require(DownloadSettings().environment(inherited: environment)["UV_TARGET"] == nil, "설치 경로 변경 옵션이 남음")
    print("통과: 인증서·프록시·미러 상속과 대상 변경 차단")
    let same = try installer().install(resources: resources, directory: directory) { _ in }
    try require(same == python, "완료된 환경을 다시 만들었습니다.")
    print("통과: 준비된 전용 환경 재사용")
    let manifest = directory.appendingPathComponent("runtime/runtime.json")
    let previous = try Data(contentsOf: manifest)
    try put("test==2\n", at: requirements)
    try put("SSL certificate verify failed https://name:my-secret@private.example/path?token=hidden\nAuthorization: Bearer another-secret\n", at: resources.appendingPathComponent("fail"))
    let failure = try mustFail { _ = try installer().install(resources: resources, directory: directory, options: download) { _ in } }
    try require(failure.contains("인증서") && !failure.contains("my-secret") && !failure.contains("hidden") && !failure.contains("another-secret"), "진단에 인증 정보가 노출됨")
    try require(try Data(contentsOf: manifest) == previous, "실패가 기존 포인터를 변경함")
    try require(try fm.contentsOfDirectory(atPath: directory.appendingPathComponent("runtime/engines").path).count == 1, "실패한 환경이 남음")
    print("통과: 실패 복구·이전 환경 보존·진단 비밀 정보 제거")
    try put(String(repeating: "x", count: 180_000) + "\ncertificate failed\n", at: resources.appendingPathComponent("fail"))
    let bounded = try mustFail { _ = try installer().install(resources: resources, directory: directory, options: download) { _ in } }
    try require(bounded.count < 7000 && bounded.contains("certificate failed"), "대용량 출력 처리 실패")
    print("통과: 대용량 오류 출력 교착 방지와 메모리 제한")
    try fm.removeItem(at: resources.appendingPathComponent("fail"))
    let replacement = try installer().install(resources: resources, directory: directory, options: download) { _ in }
    try require(replacement != python && fm.isExecutableFile(atPath: python), "재설치가 이전 환경을 지움")
    print("통과: 의존성 변경 재설치")

    let external = root.appendingPathComponent("회사 venv/bin")
    try fm.createDirectory(at: external, withIntermediateDirectories: true)
    let externalPython = external.appendingPathComponent("python")
    try put(pythonScript, at: externalPython, executable: true)
    var existing = RuntimeSettings(); existing.mode = .existingVenv; existing.sourcePython = externalPython.path
    let calls = resources.appendingPathComponent("calls")
    try put("", at: calls)
    let connected = try installer().install(resources: resources, directory: directory, options: existing) { _ in }
    try require(connected == externalPython.path && (try String(contentsOf: calls, encoding: .utf8)).isEmpty, "venv 연결이 다운로드를 실행함")
    print("통과: 준비된 외부 venv를 변경 없이 연결")
    try put("", at: external.appendingPathComponent("bad"))
    _ = try mustFail { _ = try installer().install(resources: resources, directory: directory, options: existing) { _ in } }
    try require(try String(contentsOf: calls, encoding: .utf8).isEmpty, "동의 없이 venv를 수정함")
    existing.installMissingPackages = true
    _ = try installer().install(resources: resources, directory: directory, options: existing) { _ in }
    try require(try String(contentsOf: calls, encoding: .utf8).contains("pip install --python") && !String(contentsOf: calls, encoding: .utf8).contains("python install"), "외부 venv 패키지 설치 방식 오류")
    print("통과: 명시적으로 허용한 venv 패키지 설치만 실행")
    var local = existing; local.mode = .localPython
    try put("", at: calls)
    _ = try installer().install(resources: resources, directory: directory, options: local) { _ in }
    try require(try !String(contentsOf: calls, encoding: .utf8).contains("python install"), "기존 Python 모드에서 다운로드 실행")
    print("통과: 기존 Python으로 전용 venv 생성")
    var offline = local; offline.mode = .download; offline.network.offline = true
    try put("", at: calls)
    _ = try mustFail { _ = try installer().install(resources: resources, directory: directory, options: offline) { _ in } }
    try require(try String(contentsOf: calls, encoding: .utf8).isEmpty, "오프라인 모드에서 Python 다운로드 실행")
    print("통과: 오프라인 다운로드 차단")
    let incompatible = pythonScript.replacingOccurrences(of: "\"minor\":12", with: "\"minor\":13")
    try put(incompatible, at: externalPython, executable: true)
    _ = try mustFail { _ = try installer().install(resources: resources, directory: directory, options: local) { _ in } }
    print("통과: 호환되지 않는 Python 거절")
    try put(pythonScript, at: externalPython, executable: true)
    let fresh = root.appendingPathComponent("활성 venv 테스트")
    let activated = RuntimeInstaller(environment: ["PATH": "/usr/bin:/bin", "VIRTUAL_ENV": external.deletingLastPathComponent().path])
    let auto = try activated.install(resources: resources, directory: fresh) { _ in }
    try require(auto == externalPython.path, "활성 venv를 인식하지 못함")
    print("통과: 활성화한 venv 자동 감지")

    var network = DownloadSettings(); network.proxyURL = "http://user:password@example.org"
    _ = try mustFail { try network.validate() }
    network.proxyURL = "http://proxy.example:8080"; network.packageIndexURL = "https://internal.example/simple"
    network.offline = true
    let configured = network.environment(inherited: ["NO_PROXY": "company.local", "UV_INDEX_URL": "https://old.example"])
    try require(configured["UV_DEFAULT_INDEX"] == network.packageIndexURL && configured["UV_INDEX_URL"] == nil && configured["NO_PROXY"]!.contains("company.local,localhost,127.0.0.1"), "명시한 네트워크 설정 우선순위 오류")
    try require(configured["SORINOTE_OFFLINE"] == "1", "모델에 오프라인 설정 누락")
    let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{\"pythonPath\":\"/existing/python\"}".utf8))
    try require(legacy.runtime == RuntimeSettings() && legacy.pythonPath == "/existing/python", "이전 설정 이전 실패")
    print("통과: 네트워크 설정 검증·우선순위·이전 설정 호환")

    let lowDisk = RuntimeInstaller(environment: environment, availableCapacity: { _ in 1_000 })
    _ = try mustFail { _ = try lowDisk.install(resources: resources, directory: directory, options: local) { _ in } }
    try require(try String(contentsOf: calls, encoding: .utf8).isEmpty, "디스크 부족 상태에서 패키지 설치 실행")
    print("통과: 디스크 부족 시 기존 환경 보존")

    let cancelled = installer(); cancelled.cancel()
    _ = try mustFail { _ = try cancelled.install(resources: resources, directory: directory) { _ in } }
    print("통과: 시작 전 취소")
    let beforeCancel = try Data(contentsOf: manifest)
    try put("", at: resources.appendingPathComponent("wait"))
    let running = installer(), done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        defer { done.signal() }
        do { _ = try running.install(resources: resources, directory: directory, options: download) { _ in }; fatalError("취소 실패") }
        catch is CancellationError { }
        catch { fatalError("예상 밖 오류: \(error)") }
    }
    let deadline = Date().addingTimeInterval(5)
    while !fm.fileExists(atPath: resources.appendingPathComponent("started").path) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    try require(Date() < deadline, "설치 시작 시간 초과")
    _ = try mustFail { _ = try installer().install(resources: resources, directory: directory, options: download) { _ in } }
    running.cancel()
    try require(done.wait(timeout: .now() + 5) == .success, "취소 시간 초과")
    try require(try Data(contentsOf: manifest) == beforeCancel, "취소가 이전 환경에 영향을 줌")
    print("통과: 중복 설치 잠금·실행 중 취소·이전 환경 유지")
    try put("{\"pythonPath\":\"/usr/bin/python3\"}", at: manifest)
    try require(AppSettings.managedPython(in: directory) == nil, "관리 경로 밖 Python이 자동 적용됨")
    print("통과: 자동 감지 범위 제한")
    print("자동 설치 17개 시나리오 통과")
} catch {
    fputs("자동 설치 검사 실패: \(error.localizedDescription)\n", stderr); exit(1)
}
