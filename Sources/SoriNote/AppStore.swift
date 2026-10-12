import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppStore: ObservableObject {
    @Published var settings = AppSettings.load()
    @Published var entries: [EntryPreview] = []
    @Published var selectedID: String?
    @Published var selected: Entry?
    @Published var busy = false
    @Published var liveProcessing = false
    @Published var liveSummaryPaused = false
    private var operationTask: Task<Void, Never>?
    private var activeCallID: UUID?
    @Published var progress = ""
    @Published var error: String?
    @Published var notice: String?
    @Published var answer: Answer?
    @Published var checks: [Check] = []
    @Published var search = ""
    @Published var showingSetup = false
    @Published var setupFinished = false
    @Published var setupRuntimeReady = false
    let audio = AudioController()
    private var activeWorker: WorkerClient?
    private var activeExport: EntryExportJob?
    private var exportTask: Task<URL, Error>?
    private var activeInstaller: RuntimeInstaller?
    private var installerTask: Task<String, Error>?
    var needsRuntimeSetup: Bool {
        RuntimeInstaller.resources != nil && (settings.pythonPath == "/usr/bin/python3" || !FileManager.default.isExecutableFile(atPath: settings.pythonPath))
    }

    var filtered: [EntryPreview] {
        entries.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
            || $0.preview.localizedCaseInsensitiveContains(search) }
    }

    func call<T: Decodable>(_ action: String, fields: [String: Any] = [:], as type: T.Type) async throws -> T {
        // macOS의 기본 Python 경로는 개발 도구 설치 창을 띄울 수 있어 준비 전에 실행하지 않습니다.
        guard !needsRuntimeSetup else { throw AppFailure(message: "공통 환경에서 자동 설치 / 복구를 먼저 실행하세요.") }
        guard action != "ask" || settings.qaEnabled else {
            throw AppFailure(message: "질문 답변이 꺼져 있습니다. 모델 및 환경 설정에서 다시 켜 주세요.")
        }
        var request = fields
        request["action"] = action
        request["dataDir"] = AppSettings.directory.path
        request["config"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
        var secrets: [String: String] = [:]
        // 목록 조회나 문서 저장에는 키체인 접근 자체가 필요하지 않습니다.
        if ["prepare", "install_models", "transcribe", "summarize", "ask", "diagnostic", "interval", "continueIntervals", "finalizeIntervals"].contains(action) {
            let enabledKeys = Set(ModelStage.allCases.filter { settings.isEnabled($0) }.map(\.keyName) + ["hfToken"])
            for name in Keychain.names where enabledKeys.contains(name) { secrets[name] = try Keychain.read(name) }
        }
        request["secrets"] = secrets
        let data = try JSONSerialization.data(withJSONObject: request)
        let python = settings.pythonPath
        let usesModels = ["prepare", "install_models", "transcribe", "summarize", "ask", "diagnostic", "interval", "continueIntervals", "finalizeIntervals"].contains(action)
        if usesModels { try settings.runtime.network.validate() }
        let environment = usesModels ? settings.runtime.network.environment() : nil
        let worker = WorkerClient()
        activeWorker = worker
        let callID = UUID(); activeCallID = callID
        defer { activeWorker = nil; activeCallID = nil }
        let owner = self
        let response = try await Task.detached(priority: .userInitiated) {
            try worker.execute(python: python, request: data, environment: environment, update: { data in
                guard let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return }
                Task { @MainActor in
                    guard owner.activeCallID == callID, owner.selectedID == entry.id else { return }
                    owner.selected = entry
                }
            }) { message in
                Task { @MainActor in if owner.activeCallID == callID { owner.progress = message } }
            }
        }.value
        return try JSONDecoder().decode(type, from: response)
    }

    func perform(_ message: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; progress = message; notice = nil
        operationTask = Task {
            defer { busy = false; progress = "" }
            do { try await operation() }
            catch is CancellationError {
                notice = "작업을 취소했습니다. 이미 저장된 내용은 유지됩니다."
                try? await refresh()
            }
            catch {
                self.error = error.localizedDescription
                // 중간 커밋 뒤 오류가 나도 '이어서 처리'와 저장된 전사문을 바로 보여 줍니다.
                try? await refresh()
            }
        }
    }

    func waitForOperation() async { if let operationTask { await operationTask.value } }

    func cancel() {
        if liveProcessing { liveSummaryPaused = true }
        activeWorker?.cancel()
        activeExport?.cancel()
        activeInstaller?.cancel()
    }

    func waitForInstaller() async { if let installerTask { _ = await installerTask.result } }

    func installRuntime(options: RuntimeSettings, prepareModels: Bool) {
        guard !busy, !audio.recording, let resources = RuntimeInstaller.resources else { return }
        do { try saveRuntimeOptions(options) } catch { self.error = error.localizedDescription; return }
        error = nil; setupFinished = false; setupRuntimeReady = false
        let installer = RuntimeInstaller()
        let directory = AppSettings.directory
        let preferred = settings.pythonPath
        activeInstaller = installer
        let task = Task.detached(priority: .userInitiated) {
            try installer.install(resources: resources, directory: directory, options: options, preferredPython: preferred) { message in
                Task { @MainActor in self.progress = message }
            }
        }
        installerTask = task
        perform("실행 환경을 준비하는 중") {
            defer { self.activeInstaller = nil; self.installerTask = nil }
            let python = try await task.value
            try installer.checkCancellation()
            var updated = self.settings; updated.pythonPath = python
            try updated.save(); self.settings = updated
            // 모델 다운로드가 실패해도 검증된 venv를 다시 설치할 필요가 없습니다.
            self.setupRuntimeReady = true
            try await self.refresh()
            if prepareModels { let _: [String: String] = try await self.call("install_models", as: [String: String].self) }
            try installer.checkCancellation()
            self.setupFinished = true
            self.notice = prepareModels ? "실행 환경과 선택한 로컬 모델을 준비했습니다." : "실행 환경을 준비했습니다. 모델은 설정에서 이어서 준비할 수 있습니다."
        }
    }

    func saveRuntimeOptions(_ options: RuntimeSettings) throws {
        try options.network.validate()
        var updated = settings; updated.runtime = options
        try updated.save(); settings = updated
    }

    func retrySetupModels(options: RuntimeSettings) {
        guard !busy, !audio.recording, setupRuntimeReady else { return }
        do { try saveRuntimeOptions(options) } catch { self.error = error.localizedDescription; return }
        error = nil
        perform("모델 준비를 다시 시작하는 중") {
            let _: [String: String] = try await self.call("install_models", as: [String: String].self)
            self.setupFinished = true
            self.notice = "선택한 로컬 모델을 준비했습니다."
        }
    }

    func waitForExport() async {
        // 앱 종료 때 복사 취소와 임시 파일 정리가 끝날 때까지 기다립니다.
        if let exportTask { _ = await exportTask.result }
    }

    func refresh() async throws {
        struct Listing: Decodable { let entries: [EntryPreview] }
        entries = try await call("list", as: Listing.self).entries
        if let id = selectedID, entries.contains(where: { $0.id == id }) {
            selected = try await call("get", fields: ["id": id], as: Entry.self)
        } else { selected = nil; selectedID = nil }
    }

    func launch() {
        if needsRuntimeSetup {
            showingSetup = true; return
        }
        perform("기록을 불러오는 중") {
            try await self.refresh()
            let folder = AppSettings.directory.appendingPathComponent("drafts")
            let drafts = (try? FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: nil)) ?? []
            var recovered = 0, failed = 0
            for url in drafts where ["m4a", "wav"].contains(url.pathExtension) {
                do {
                    if url.pathExtension == "wav" { try PCMRecordingWriter.repairDraft(url) }
                    let link = url.appendingPathExtension("json")
                    if let data = try? Data(contentsOf: link),
                       let association = try? JSONDecoder().decode([String: String].self, from: data),
                       let id = association["entryID"] {
                        let entry: Entry = try await self.call("get", fields: ["id": id], as: Entry.self)
                        if entry.audio_path.isEmpty {
                            let _: Entry = try await self.call("attachAudio", fields: ["id": id, "audioPath": url.path], as: Entry.self)
                        }
                    } else {
                        let _: Entry = try await self.call("create", fields: ["title": "복구된 녹음",
                            "kind": "meeting", "audioPath": url.path], as: Entry.self)
                    }
                    try FileManager.default.removeItem(at: url)
                    try? FileManager.default.removeItem(at: link)
                    recovered += 1
                } catch is CancellationError { throw CancellationError() }
                catch { failed += 1 } // 손상된 한 파일 때문에 다른 녹음의 복구를 막지 않습니다.
            }
            if recovered > 0 { try await self.refresh() }
            if recovered > 0 || failed > 0 {
                self.notice = "남은 녹음 \(recovered)개를 복구했습니다." + (failed > 0 ? " 복구하지 못한 \(failed)개는 데이터 폴더의 drafts에 보관했습니다." : "")
            }
        }
    }

    func select(_ id: String) {
        guard !busy else { return }
        audio.stopPlayback()
        selectedID = id; answer = nil
        perform("기록을 여는 중") {
            self.selected = try await self.call("get", fields: ["id": id], as: Entry.self)
        }
    }

    func demo() {
        perform("예시 기록 추가 중") {
            self.selected = try await self.call("create", fields: ["title": "예시 · 소리노트 첫 회의",
                "kind": "document", "text": "[00:00] 지민: 이번 주 금요일까지 온보딩 초안을 정리하겠습니다.\n"
                    + "[00:12] 민수: 제가 목요일에 검색 기능 테스트 결과를 공유할게요.\n"
                    + "[00:25] 지민: 첫 버전은 로컬 처리로 출시하고, 클라우드 연결은 선택 사항으로 제공합시다.\n"
                    + "[00:38] 민수: 좋습니다. 디자인 검토 일정은 다음 회의에서 정하겠습니다."], as: Entry.self)
            self.selectedID = self.selected?.id
            try await self.refresh()
        }
    }

    func importFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .pdf, .plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        perform("파일을 가져오는 중") {
            for url in urls {
                var fields: [String: Any] = ["title": url.deletingPathExtension().lastPathComponent]
                switch url.pathExtension.lowercased() {
                case "pdf":
                    guard let document = PDFDocument(url: url), !document.isLocked else {
                        throw AppFailure(message: "PDF를 열지 못했습니다. 암호가 걸려 있는지 확인하세요.")
                    }
                    let text = (0..<document.pageCount).compactMap { index -> String? in
                        guard let value = document.page(at: index)?.string else { return nil }
                        return "[\(index + 1)쪽]\n" + value
                    }.joined(separator: "\n\n")
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AppFailure(message: "PDF에서 글자를 찾지 못했습니다. 스캔 PDF는 먼저 OCR로 변환해 주세요.")
                    }
                    fields["text"] = text; fields["kind"] = "document"
                case "txt", "md", "markdown", "text":
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 10_000_000 else { throw AppFailure(message: "텍스트 파일은 10MB 이하로 나누어 주세요.") }
                    fields["text"] = try String(contentsOf: url, encoding: .utf8)
                    fields["kind"] = "document"
                default:
                    fields["kind"] = "meeting"; fields["audioPath"] = url.path
                }
                self.selected = try await self.call("create", fields: fields, as: Entry.self)
                self.selectedID = self.selected?.id
            }
            try await self.refresh()
        }
    }

    func startRecording() {
        perform("녹음 입력과 권한 확인 중") {
            if self.settings.intervalSummaryEnabled {
                try self.settings.validate()
                if self.needsRuntimeSetup { throw AppFailure(message: "자동 구간 요약을 사용하려면 먼저 실행 환경을 준비하세요.") }
            }
            try await self.audio.start(settings: self.settings.audio)
            if self.settings.intervalSummaryEnabled {
                do { try await self.runIntervalRecording() }
                catch { _ = try? await self.audio.stop(); throw error }
            }
        }
    }

    func stopRecording() {
        guard audio.recording else { return }
        if liveProcessing {
            // AI 워커가 바빠도 입력 중지는 즉시 별도 경로로 실행합니다.
            Task { @MainActor in
                do { _ = try await self.audio.stop() }
                catch { self.error = error.localizedDescription }
            }
            return
        }
        perform("녹음을 저장하는 중") {
            guard let url = try await self.audio.stop() else { return }
            let title = "회의 " + Date().formatted(date: .abbreviated, time: .shortened)
            self.selected = try await self.call("create", fields: ["title": title, "kind": "meeting",
                "audioPath": url.path], as: Entry.self)
            self.selectedID = self.selected?.id
            try FileManager.default.removeItem(at: url)
            try await self.refresh()
        }
    }

    /// 녹음 큐와 AI 작업은 독립적으로 진행합니다. AI는 한 구간씩 처리하고 메모리에 대기열을 쌓지 않습니다.
    private func runIntervalRecording() async throws {
        liveSummaryPaused = false
        defer { liveProcessing = false; liveSummaryPaused = false }
        guard let draftURL = audio.recordingURL else { throw AppFailure(message: "녹음 파일이 없습니다.") }
        let title = "회의 " + Date().formatted(date: .abbreviated, time: .shortened)
        let entry: Entry = try await call("create", fields: ["title": title, "kind": "meeting", "intervalRecording": true], as: Entry.self)
        selected = entry; selectedID = entry.id; answer = nil
        // 비정상 종료해도 이미 만든 구간 요약과 원음을 같은 기록으로 복구합니다.
        let link = draftURL.appendingPathExtension("json")
        try JSONEncoder().encode(["entryID": entry.id]).write(to: link, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: link.path)
        try await refresh()
        liveProcessing = true
        var cursor = RecordingIntervalCursor(minutes: settings.intervalMinutes)
        var source = draftURL
        var attached = false
        while true {
            let finished = !audio.recording
            if finished && !attached {
                guard let url = try await audio.completedRecordingURL() else { throw AppFailure(message: "완료된 녹음 파일이 없습니다.") }
                let saved: Entry = try await call("attachAudio", fields: ["id": entry.id, "audioPath": url.path], as: Entry.self)
                source = URL(fileURLWithPath: saved.audio_path); selected = saved; attached = true
                try? FileManager.default.removeItem(at: draftURL)
                try? FileManager.default.removeItem(at: link)
            }
            if liveSummaryPaused {
                progress = "자동 구간 요약이 중지되었습니다. 녹음은 계속 저장합니다."
                if finished { break }
                try await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            let frames = finished ? try PCMRecordingWriter.frameCount(source) : audio.availableFrames
            guard let range = cursor.next(availableFrames: frames, finished: finished) else {
                if finished { break }
                progress = "다음 구간을 기다리는 중 · \(settings.intervalMinutes)분마다 자동 요약"
                try await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sorinote-live-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let chunk = folder.appendingPathComponent("chunk.wav")
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                let input = source
                try await Task.detached(priority: .utility) {
                    try PCMRecordingWriter.copyRange(from: input, to: chunk, start: range.lowerBound, end: range.upperBound)
                }.value
                if liveSummaryPaused { continue }
                selected = try await call("interval", fields: ["id": entry.id, "audioPath": chunk.path,
                    "start": Double(range.lowerBound) / 16_000, "end": Double(range.upperBound) / 16_000], as: Entry.self)
                cursor.processedFrames = range.upperBound
            } catch {
                liveSummaryPaused = true
                notice = error is CancellationError ? "자동 요약을 중지했습니다. 녹음은 계속합니다." :
                    "자동 요약을 멈췄습니다. 녹음은 계속합니다. " + error.localizedDescription
                try? await refresh()
            }
        }
        if !liveSummaryPaused, cursor.processedFrames > 0 {
            selected = try await call("finalizeIntervals", fields: ["id": entry.id], as: Entry.self)
            notice = "녹음과 구간 요약을 저장했습니다."
        } else {
            notice = "녹음을 저장했습니다. ‘구간 처리 이어하기’로 남은 전사와 요약을 처리할 수 있습니다."
        }
        try await refresh()
    }

    func processSelected(_ action: String) {
        guard let id = selected?.id else { return }
        perform(action == "transcribe" || action == "continueIntervals" ? "문자 변환 준비 중" : "요약 준비 중") {
            self.selected = try await self.call(action, fields: ["id": id], as: Entry.self)
            self.answer = nil
            try await self.refresh()
        }
    }

    func edit(title: String, text: String) {
        guard let entry = selected else { return }
        perform("변경 사항 저장 중") {
            var fields: [String: Any] = ["id": entry.id, "title": title]
            if text != entry.text { fields["text"] = text }
            self.selected = try await self.call("edit", fields: fields, as: Entry.self)
            self.answer = nil
            try await self.refresh()
        }
    }

    func renameSpeaker(old: String, new: String) {
        guard let id = selected?.id else { return }
        perform("화자 이름 변경 중") {
            self.selected = try await self.call("renameSpeaker", fields: ["id": id, "old": old, "new": new], as: Entry.self)
            self.answer = nil
            try await self.refresh()
        }
    }

    func ask(_ question: String, all: Bool) {
        guard settings.qaEnabled else {
            error = "질문 답변이 꺼져 있습니다. 모델 및 환경 설정에서 다시 켜 주세요."
            return
        }
        let scope = all ? "" : selectedID ?? ""
        answer = nil
        perform("질문에 맞는 자료를 찾는 중") {
            self.answer = try await self.call("ask", fields: ["question": question, "id": scope], as: Answer.self)
        }
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        audio.stopPlayback()
        perform("기록을 삭제하는 중") {
            let _: [String: String] = try await self.call("delete", fields: ["id": id], as: [String: String].self)
            self.selected = nil; self.selectedID = nil; self.answer = nil
            try await self.refresh()
        }
    }

    func export(_ format: ExportFormat) {
        guard !busy, !audio.recording, let entry = selected, format.isAvailable(for: entry) else { return }
        let url: URL
        if format == .bundle {
            let panel = NSOpenPanel()
            panel.title = "녹음과 전사문을 보관할 폴더"
            panel.message = "선택한 위치에 회의 제목의 새 폴더를 만들고 녹음, 전사문.txt, 회의록.md를 저장합니다."
            panel.prompt = "여기에 저장"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
            url = selectedURL
        } else {
            let panel = NSSavePanel()
            panel.title = format.title.replacingOccurrences(of: "…", with: "")
            let suffix = format.fileExtension(for: entry)
            if let type = UTType(filenameExtension: suffix) { panel.allowedContentTypes = [type] }
            panel.nameFieldStringValue = EntryExportJob.safeName(entry.title) + (suffix.isEmpty ? "" : "." + suffix)
            panel.message = format == .audio ? "앱에 보관된 녹음을 같은 형식으로 복사합니다. 원본은 유지됩니다."
                : "현재 저장된 원문과 수정한 화자 이름을 UTF-8로 저장합니다."
            guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
            url = selectedURL
        }
        guard !busy, !audio.recording else { return }
        let replacing = FileManager.default.fileExists(atPath: url.path)
        let protected = AppSettings.directory
        let job = EntryExportJob()
        activeExport = job
        // 파일 크기와 관계없이 화면과 취소 버튼이 응답하도록 복사는 별도 작업에서 실행합니다.
        let task = Task.detached(priority: .userInitiated) {
            try job.write(format, entry: entry, destination: url,
                          protectedDirectory: protected, replaceExisting: replacing)
        }
        exportTask = task
        perform(format == .bundle ? "녹음과 전사문을 저장하는 중" : "파일을 저장하는 중") {
            defer { self.activeExport = nil; self.exportTask = nil }
            do {
                let result = try await task.value
                self.notice = format == .bundle ? "‘\(result.lastPathComponent)’ 폴더에 녹음·전사문·회의록을 저장했습니다."
                    : "‘\(result.lastPathComponent)’ 파일을 저장했습니다."
            } catch is CancellationError {
                // 내보내기는 DB를 바꾸지 않으므로 취소 후 워커를 다시 실행할 필요가 없습니다.
                self.notice = "파일 저장을 취소했습니다. 원본과 기존 저장 파일은 유지됩니다."
            }
        }
    }

    func diagnostic() {
        perform("설치 상태를 확인하는 중") {
            struct Response: Decodable { let checks: [Check] }
            self.checks = try await self.call("diagnostic", as: Response.self).checks
        }
    }

    func prepare(role: String? = nil) {
        perform("모델 준비 중") {
            let response = try await self.call("prepare", fields: role.map { ["role": $0] } ?? [:], as: [String: String].self)
            self.notice = response["message"]
        }
    }

    func reindex() {
        perform("검색 색인 초기화 중") {
            let response = try await self.call("reindex", as: [String: String].self)
            self.notice = response["message"]
        }
    }
}
