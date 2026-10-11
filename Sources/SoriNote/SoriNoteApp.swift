import AppKit
import SwiftUI

@main
struct SoriNoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup("소리노트") {
            ContentView(store: store, audio: store.audio)
                .frame(minWidth: 1080, minHeight: 720)
                .onAppear { delegate.store = store }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .importExport) {
                Button("파일 가져오기…") { store.importFiles() }
                    .keyboardShortcut("o").disabled(store.busy || store.audio.recording)
                Menu("내보내기") { ExportMenuItems(store: store) }
                    .disabled(store.selected == nil || store.busy || store.audio.recording)
            }
        }
        Settings { SettingsView(store: store).frame(width: 850, height: 740) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateLater }
        guard let store, store.busy || store.audio.recording else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "진행 중인 작업을 마치고 종료할까요?"
        alert.informativeText = "AI 작업, 설치와 내보내기는 취소됩니다. 녹음 중이라면 파일을 보관하고 다음 실행에서 복구합니다."
        alert.addButton(withTitle: "계속 사용")
        alert.addButton(withTitle: "종료")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        store.cancel()
        terminating = true
        Task { @MainActor in
            await store.waitForInstaller()
            await store.waitForExport()
            _ = try? await store.audio.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
