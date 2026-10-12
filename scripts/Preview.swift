import AppKit
import SwiftUI

/// 실제 사용자 화면을 캡처하지 않고, 앱의 SwiftUI를 예시 데이터로 직접 렌더링합니다.
@main
struct Preview {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let store = AppStore()
        store.settings = AppSettings()
        var entry = Entry(id: "preview", title: "제품팀 주간 회의", kind: "meeting",
            created: "2026-10-11T09:00:00+09:00",
            text: "금요일까지 온보딩 초안을 완성하기로 했습니다. 민수는 검색 기능을 확인하고 지민은 문서를 작성합니다.",
            segments: [], summary: "핵심 요약\n\n첫 사용자가 편하게 시작할 수 있도록 온보딩 흐름과 검색 기능을 함께 점검했습니다.\n\n결정 사항\n\n• 첫 버전은 맥 안에서 처리하는 방식으로 제공합니다.\n• 온보딩 초안은 금요일까지 마무리합니다.\n\n할 일\n\n• 지민 — 온보딩 문서 초안 작성 · 금요일\n• 민수 — 검색 기능 테스트 결과 공유 · 목요일\n\n확인이 필요한 내용\n\n디자인 검토 일정은 다음 회의에서 정합니다.",
            audio_path: "", warning: "")
        if CommandLine.arguments.contains("--intervals") {
            store.settings.intervalSummaryEnabled = true
            entry.summary = ""
            entry.interval_seconds = 300
            entry.interval_notes = [
                IntervalNote(ordinal: 0, start: 0, end: 300, summary: "**온보딩 흐름 정리**\n\n첫 사용자의 설정 단계를 줄이기로 했습니다. 지민은 금요일까지 안내 문서 초안을 작성합니다.", status: "complete"),
                IntervalNote(ordinal: 1, start: 300, end: 600, summary: "**검토 일정 조정**\n\n앞서 논의한 문서 초안의 검토를 다음 주 월요일로 잡았습니다. 초안 작성 기한은 금요일로 유지합니다. 검색 기능 점검은 민수가 맡습니다.", status: "complete"),
                IntervalNote(ordinal: 2, start: 600, end: 660, summary: "", status: "transcribed")]
        }
        store.selected = entry
        store.selectedID = entry.id
        store.entries = [EntryPreview(id: entry.id, title: entry.title, kind: "meeting", created: entry.created,
            preview: entry.text, summarized: 1, audio_path: ""),
            EntryPreview(id: "reference", title: "온보딩 기획안", kind: "document", created: "2026-10-10",
                         preview: "", summarized: 0, audio_path: "")]
        let settings = CommandLine.arguments.contains("--settings")
        let setup = CommandLine.arguments.contains("--setup")
        if CommandLine.arguments.contains("--features-off") { store.settings.qaEnabled = false; store.settings.diarization = false }
        let audioSettings = CommandLine.arguments.contains("--audio-settings")
        if audioSettings { store.settings.audio.source = .both }
        if CommandLine.arguments.contains("--api") {
            store.settings.embedding = ModelProfile(provider: "openai", url: "http://127.0.0.1:1234/v1", model: "my-embedding-model")
        }
        let content = setup ? AnyView(RuntimeSetupView(store: store, onClose: {}, previewNetwork: CommandLine.arguments.contains("--company-setup")))
            : audioSettings ? AnyView(AudioSettingsView(store: store, audio: store.audio, previewMode: true))
            : settings ? AnyView(SettingsView(store: store, previewMode: true, previewEnvironment: CommandLine.arguments.contains("--features-off"), previewIntervals: CommandLine.arguments.contains("--intervals")))
            : AnyView(ContentView(store: store, audio: store.audio, previewMode: true))
        let view = NSHostingView(rootView: content)
        let size = setup ? NSSize(width: 730, height: 700) : audioSettings ? NSSize(width: 660, height: 700) : settings ? NSSize(width: 850, height: 740) : NSSize(width: 1280, height: 820)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("렌더링 실패") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG 생성 실패") }
        let path = URL(fileURLWithPath: CommandLine.arguments[1])
        try png.write(to: path)
        print("예시 화면 저장: \(path.path)")
    }
}
