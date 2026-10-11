import Foundation

// 개발자의 설정을 건드리지 않고 설치·재시도·취소를 검증합니다.
func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw AppFailure(message: message) }
}
func mustFail(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw AppFailure(message: "실패해야 하는 설치가 성공했습니다.")
}
let fm = FileManager.default
do {
    #if !arch(arm64)
    print("자동 설치 검사는 Apple Silicon 전용이므로 이 아키텍처에서는 건너뜁니다.")
    exit(0)
    #endif
    if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--real-install" {
        let python = try RuntimeInstaller().install(resources: URL(fileURLWithPath: CommandLine.arguments[2]),
            directory: URL(fileURLWithPath: CommandLine.arguments[3])) { print($0) }
        print("실제 설치 완료: \(python)")
        exit(0)
    }
    let root = fm.temporaryDirectory.appendingPathComponent("sorinote-installer-test-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let resources = root.appendingPathComponent("패키지 도구")
    let directory = root.appendingPathComponent("사용자 데이터")
    try fm.createDirectory(at: resources, withIntermediateDirectories: true)
    let uv = resources.appendingPathComponent("uv")
    let script = #"""
    #!/bin/sh
    dir="$(dirname "$0")"
    if [ -f "$dir/wait" ]; then
      touch "$dir/started"
      exec /bin/sleep 20
    fi
    if [ "$1" = "venv" ]; then
      for target in "$@"; do :; done
      mkdir -p "$target/bin"
      printf '#!/bin/sh\nexit 0\n' > "$target/bin/python"
      chmod 755 "$target/bin/python"
    fi
    if [ "$1" = "pip" ] && [ -f "$dir/fail" ]; then exit 1; fi
    exit 0
    """#
    try script.write(to: uv, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)
    let requirements = resources.appendingPathComponent("requirements.lock.txt")
    try Data("test==1\n".utf8).write(to: requirements)
    let python = try RuntimeInstaller().install(resources: resources, directory: directory) { _ in }
    try require(AppSettings.managedPython(in: directory) == python, "설치 완료 포인터가 잘못되었습니다.")
    print("통과: 한글·공백 경로의 첫 설치와 관리 경로 인식")
    let same = try RuntimeInstaller().install(resources: resources, directory: directory) { _ in }
    try require(same == python, "완료된 환경을 불필요하게 다시 만들었습니다.")
    print("통과: 완료된 환경 재사용")
    let manifest = directory.appendingPathComponent("runtime/runtime.json")
    let previous = try Data(contentsOf: manifest)
    try Data("test==2\n".utf8).write(to: requirements)
    try Data().write(to: resources.appendingPathComponent("fail"))
    try mustFail { _ = try RuntimeInstaller().install(resources: resources, directory: directory) { _ in } }
    try require(try Data(contentsOf: manifest) == previous, "실패한 설치가 기존 포인터를 바꿨습니다.")
    try require(try fm.contentsOfDirectory(atPath: directory.appendingPathComponent("runtime/engines").path).count == 1,
                "불완전한 환경이 남았습니다.")
    print("통과: 설치 실패 시 기존 환경 보존과 불완전한 환경 정리")
    try fm.removeItem(at: resources.appendingPathComponent("fail"))
    let replacement = try RuntimeInstaller().install(resources: resources, directory: directory) { _ in }
    try require(replacement != python && fm.isExecutableFile(atPath: python), "재설치가 이전 환경을 지웠습니다.")
    print("통과: 변경된 의존성 설치와 이전 환경 보존")
    let cancelled = RuntimeInstaller(); cancelled.cancel()
    try mustFail { _ = try cancelled.install(resources: resources, directory: directory) { _ in } }
    print("통과: 실행 전 취소")
    try Data("test==3\n".utf8).write(to: requirements)
    try Data().write(to: resources.appendingPathComponent("wait"))
    let running = RuntimeInstaller()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        defer { done.signal() }
        do { _ = try running.install(resources: resources, directory: directory) { _ in }; fatalError("취소 실패") }
        catch is CancellationError { }
        catch { fatalError("예상 밖 설치 오류: \(error)") }
    }
    let deadline = Date().addingTimeInterval(5)
    while !fm.fileExists(atPath: resources.appendingPathComponent("started").path) && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    try require(Date() < deadline, "설치 작업 시작 시간 초과")
    try mustFail { _ = try RuntimeInstaller().install(resources: resources, directory: directory) { _ in } }
    print("통과: 중복 설치 잠금")
    running.cancel()
    try require(done.wait(timeout: .now() + 5) == .success, "설치 취소 시간 초과")
    try require(AppSettings.managedPython(in: directory) == replacement, "취소가 이전 환경에 영향을 줬습니다.")
    print("통과: 실행 중 취소와 이전 환경 유지")
    let escaped = try JSONSerialization.data(withJSONObject: ["pythonPath": "/usr/bin/python3"])
    try escaped.write(to: manifest)
    try require(AppSettings.managedPython(in: directory) == nil, "관리 폴더 밖의 경로가 자동 적용되었습니다.")
    print("통과: 자동 감지 경로 범위 제한")
    print("자동 설치 8개 검사 통과")
} catch {
    fputs("자동 설치 검사 실패: \(error.localizedDescription)\n", stderr)
    exit(1)
}
