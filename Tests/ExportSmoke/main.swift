import Foundation

// 실제 회의 대신 합성 파일로, 복사 무결성과 실패 시 기존 파일 보존을 확인합니다.
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw AppFailure(message: message) }
}
func expectFailure(line: Int = #line, _ operation: () throws -> Void) throws {
    do { try operation() }
    catch { return }
    throw AppFailure(message: "실패해야 할 저장이 성공했습니다. 검사 소스 \(line)행")
}
var passed = 0
func test(_ name: String, _ operation: () throws -> Void) throws {
    try operation(); passed += 1; print("통과: \(name)")
}

do {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("sorinote-export-test-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    let protected = root.appendingPathComponent("앱 데이터")
    let exports = root.appendingPathComponent("내보낸 파일")
    try fm.createDirectory(at: protected, withIntermediateDirectories: false)
    try fm.createDirectory(at: exports, withIntermediateDirectories: false)
    let source = protected.appendingPathComponent("원본.wav")
    let writer = try PCMRecordingWriter(url: source)
    // 여러 복사 청크를 지나게 해서 첫 청크 이후 취소와 전체 바이트 비교를 검사합니다.
    try writer.append(Array(repeating: 0.25, count: 1_200_000))
    try writer.close()
    let original = try Data(contentsOf: source)
    let entry = Entry(id: "test", title: "한글 회의 🎙️", kind: "meeting", created: "2026-10-11T09:00:00+09:00",
        text: "[00:01] 지민: 금요일까지 초안을 완성합니다.\n[01:03] 민수: 검색을 맡겠습니다.",
        segments: [Segment(start: 1, end: 2, speaker: "옛 이름", text: "수정 전 문장")],
        summary: "지민은 초안, 민수는 검색을 담당합니다.", audio_path: source.path, warning: "")
    func save(_ kind: ExportFormat, _ url: URL, entry value: Entry? = nil, replace: Bool = false) throws -> URL {
        try EntryExportJob().write(kind, entry: value ?? entry, destination: url,
                                   protectedDirectory: protected, replaceExisting: replace)
    }
    func noTemporaryFiles() throws {
        let names = try fm.contentsOfDirectory(atPath: exports.path)
        try require(!names.contains(where: { $0.hasPrefix(".sorinote-export-") }), "임시 파일이 남았습니다.")
    }

    try test("묶음의 녹음 바이트·확장자, 한국어 전사문·시각·화자·요약") {
        let folder = try save(.bundle, exports)
        try require(try Data(contentsOf: folder.appendingPathComponent("녹음.wav")) == original, "원본과 사본이 다름")
        let text = try String(contentsOf: folder.appendingPathComponent("전사문.txt"), encoding: .utf8)
        try require(text.contains(entry.text) && !text.contains("수정 전 문장"), "최신 원문 대신 옛 구간을 저장함")
        let md = try String(contentsOf: folder.appendingPathComponent("회의록.md"), encoding: .utf8)
        try require(md.contains(entry.summary) && md.contains(entry.created), "요약·작성 시각 누락")
        try require(try fm.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700, "폴더 권한 오류")
        try require(try fm.attributesOfItem(atPath: folder.appendingPathComponent("녹음.wav").path)[.posixPermissions] as? Int == 0o600, "녹음 권한 오류")
    }
    try test("같은 제목을 여러 번 저장해도 이전 묶음 보존") {
        let folder = try save(.bundle, exports)
        try require(folder.lastPathComponent == entry.title + " (2)", "중복 이름 처리 실패")
        try require(fm.fileExists(atPath: exports.appendingPathComponent(entry.title + "/전사문.txt").path), "이전 묶음 손실")
    }
    try test("녹음 단독 저장과 기존 M4A의 확장자 보존") {
        let wav = try save(.audio, exports.appendingPathComponent("회의.wav"))
        try require(try Data(contentsOf: wav) == original, "WAV 복사 실패")
        // M4A 디코딩 검사가 아닌, 가져온 파일을 재인코딩 없이 보존하는 경로 검사입니다.
        let legacy = protected.appendingPathComponent("기존.m4a")
        let bytes = Data([0, 0, 0, 24, 102, 116, 121, 112, 77, 52, 65, 32])
        try bytes.write(to: legacy)
        let old = Entry(id: "old", title: "기존 기록", kind: "meeting", created: "", text: entry.text,
                        segments: [], summary: "", audio_path: legacy.path, warning: "")
        let folder = try save(.bundle, exports, entry: old)
        try require(try Data(contentsOf: folder.appendingPathComponent("녹음.m4a")) == bytes, "M4A 확장자·바이트 손실")
    }
    try test("문서·미전사 녹음의 메뉴 조건, 시각 없는 수정문과 요약 전 Markdown") {
        let document = Entry(id: "doc", title: "문서", kind: "document", created: "", text: "직접 고친 내용 🙂",
                             segments: [], summary: "", audio_path: "", warning: "")
        try require(!ExportFormat.bundle.isAvailable(for: document) && !ExportFormat.audio.isAvailable(for: document), "문서에 녹음 메뉴 활성화")
        let txt = try save(.transcript, exports.appendingPathComponent("문서.txt"), entry: document)
        try require(try String(contentsOf: txt, encoding: .utf8).hasSuffix(document.text + "\n"), "수정문 손실")
        let md = try save(.markdown, exports.appendingPathComponent("문서.md"), entry: document)
        try require(try String(contentsOf: md, encoding: .utf8).contains("아직 요약하지 않았습니다."), "요약 없음 안내 누락")
        var pending = entry; pending.text = "  \n"
        try require(ExportFormat.audio.isAvailable(for: pending) && !ExportFormat.bundle.isAvailable(for: pending)
                    && !ExportFormat.transcript.isAvailable(for: pending), "전사 전 조건 오류")
        try expectFailure { _ = try save(.bundle, exports, entry: pending) }
        try require(!ExportFormat.markdown.isAvailable(for: nil), "선택 항목 없음 처리 오류")
    }
    try test("파일 이름의 경로·숨김·긴 한글·빈 제목 처리") {
        let safe = EntryExportJob.safeName("../회의:/자료\\\n")
        try require(!safe.hasPrefix(".") && !safe.contains("/") && !safe.contains(":"), "경로 이탈 가능")
        try require(EntryExportJob.safeName("...") == "제목 없는 기록", "빈 제목 처리 오류")
        try require(EntryExportJob.safeName(String(repeating: "한글🙂", count: 200)).utf8.count <= 140, "이름 길이 초과")
        var tricky = entry; tricky.title = "../../회의"
        let folder = try save(.bundle, exports, entry: tricky)
        try require(folder.deletingLastPathComponent().standardizedFileURL.path == exports.standardizedFileURL.path,
                    "상위 폴더로 이탈함")
    }
    try test("확인 없는 덮어쓰기 거절과 확인 후 완성본 교체") {
        let target = exports.appendingPathComponent("교체.txt")
        try Data("기존 내용".utf8).write(to: target)
        try expectFailure { _ = try save(.transcript, target) }
        try require(try String(contentsOf: target, encoding: .utf8) == "기존 내용", "기존 파일 훼손")
        _ = try save(.transcript, target, replace: true)
        try require(try String(contentsOf: target, encoding: .utf8).contains(entry.text), "교체 실패")
    }
    try test("복사 중 취소하면 기존 파일과 녹음 보존, 임시 결과 정리") {
        let target = exports.appendingPathComponent("취소.wav")
        let before = Data("덮어쓰면 안 되는 내용".utf8)
        try before.write(to: target)
        let job = EntryExportJob()
        do {
            _ = try job.write(.audio, entry: entry, destination: target, protectedDirectory: protected,
                              replaceExisting: true, copied: { _ in job.cancel() })
            throw AppFailure(message: "복사 도중 취소가 무시됨")
        } catch is CancellationError { }
        try require(try Data(contentsOf: target) == before, "취소하면서 기존 파일 변경")
        try require(try Data(contentsOf: source) == original, "원본 변경")
        try noTemporaryFiles()
    }
    try test("묶음 복사 취소와 실행 전 취소는 결과 폴더를 남기지 않음") {
        let before = try fm.contentsOfDirectory(atPath: exports.path).sorted()
        let job = EntryExportJob()
        do {
            _ = try job.write(.bundle, entry: entry, destination: exports, protectedDirectory: protected,
                              copied: { _ in job.cancel() })
            throw AppFailure(message: "묶음 복사 취소가 무시됨")
        } catch is CancellationError { }
        job.cancel()
        do {
            _ = try job.write(.bundle, entry: entry, destination: exports, protectedDirectory: protected)
            throw AppFailure(message: "실행 전 취소가 무시됨")
        } catch is CancellationError { }
        try require(try fm.contentsOfDirectory(atPath: exports.path).sorted() == before, "취소 후 결과가 남음")
    }
    try test("녹음 유실 오류는 기존 파일과 이전 묶음을 보존") {
        let missing = Entry(id: "lost", title: "유실", kind: "meeting", created: "", text: entry.text,
                            segments: [], summary: "", audio_path: protected.appendingPathComponent("없음.wav").path, warning: "")
        let target = exports.appendingPathComponent("교체.txt")
        let before = try Data(contentsOf: target)
        try expectFailure { _ = try save(.audio, target, entry: missing, replace: true) }
        try expectFailure { _ = try save(.bundle, exports, entry: missing) }
        try require(try Data(contentsOf: target) == before, "읽기 실패 후 기존 파일 손실")
        try noTemporaryFiles()
    }
    try test("앱 데이터 폴더와 그 폴더를 가리키는 링크로 내보내기 거절") {
        let alias = root.appendingPathComponent("데이터 링크")
        try fm.createSymbolicLink(at: alias, withDestinationURL: protected)
        try expectFailure { _ = try save(.audio, source, replace: true) }
        try expectFailure { _ = try save(.bundle, protected) }
        try expectFailure { _ = try save(.bundle, alias) }
        try expectFailure { _ = try save(.transcript, alias.appendingPathComponent("설정.txt")) }
        try require(try Data(contentsOf: source) == original, "앱 원본 훼손")
    }
    try test("파일 대신 폴더 덮어쓰기·없는 부모 폴더 거절") {
        let folder = exports.appendingPathComponent("남겨 둘 폴더")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let marker = folder.appendingPathComponent("중요.txt")
        try Data("보존".utf8).write(to: marker)
        try expectFailure { _ = try save(.transcript, folder, replace: true) }
        try expectFailure { _ = try save(.transcript, exports.appendingPathComponent("없는 폴더/기록.txt")) }
        try require(try String(contentsOf: marker, encoding: .utf8) == "보존", "기존 폴더 손실")
        try noTemporaryFiles()
    }
    try test("녹음 원본을 지워도 내보낸 녹음·전사문은 독립적으로 남음") {
        try fm.removeItem(at: source)
        let folder = exports.appendingPathComponent(entry.title)
        try require(try Data(contentsOf: folder.appendingPathComponent("녹음.wav")) == original, "내보낸 파일이 사본이 아님")
        try require(try String(contentsOf: folder.appendingPathComponent("전사문.txt"), encoding: .utf8).contains(entry.text), "전사문 손실")
    }
    print("내보내기 검사 \(passed)개 통과")
} catch {
    fputs("검사 실패: \(error.localizedDescription)\n", stderr)
    exit(1)
}
