import SwiftUI

/// 상단 버튼과 macOS 파일 메뉴가 같은 선택지와 활성화 조건을 사용합니다.
struct ExportMenuItems: View {
    @ObservedObject var store: AppStore

    var body: some View {
        ForEach([ExportFormat.bundle, .audio, .transcript], id: \.self) { format in
            Button(format.title) { store.export(format) }
                .disabled(store.busy || store.audio.recording || !format.isAvailable(for: store.selected))
        }
        Divider()
        Button(ExportFormat.markdown.title) { store.export(.markdown) }
            .keyboardShortcut("e")
            .disabled(store.selected == nil || store.busy || store.audio.recording)
    }
}
