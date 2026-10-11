import SwiftUI

struct RuntimeSetupView: View {
    @ObservedObject var store: AppStore
    var onClose: () -> Void
    @ViewState<Bool> private var prepareModels = true
    private let accent = Color(red: 0.76, green: 0.31, blue: 0.18)
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Image(systemName: "arrow.down.app").font(.largeTitle).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("소리노트 사용 준비").font(.title2.bold())
                    Text("이 맥에서 회의를 처리할 실행 환경을 설치합니다.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                Label("전용 Python과 음성·검색 엔진 자동 설치", systemImage: "checkmark.circle")
                Label("요약용 Ollama 실행 도구 포함", systemImage: "checkmark.circle")
                Label("기존 회의 기록과 단계별 모델 설정 보존", systemImage: "checkmark.circle")
            }.font(.callout).padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            Toggle("현재 설정의 로컬 모델도 함께 다운로드", isOn: $prepareModels).disabled(store.busy)
            Text("기본 구성은 Whisper · EmbeddingGemma 2 · Gemma 4를 준비합니다. 화자 분리는 켜 둔 경우에만 준비합니다. API 방식은 건너뜁니다.").font(.callout).foregroundStyle(.secondary)
            Text("첫 설치에는 인터넷과 25GB 이상의 여유 공간을 권장합니다. 모델 이용 조건 동의나 인증이 필요하면 모델 및 환경 설정에서 입력한 뒤 다시 준비할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
            if store.busy { HStack { ProgressView().controlSize(.small); Text(store.progress).font(.callout) } }
            if let error = store.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let notice = store.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Text("모델은 위 선택을 끄고 나중에 준비할 수도 있습니다.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.busy { Button("취소") { store.cancel() } }
                else {
                    Button(store.setupFinished ? "사용 시작" : "나중에") { onClose() }
                    if !store.setupFinished {
                        Button("설치 시작") { store.installRuntime(prepareModels: prepareModels) }.buttonStyle(.borderedProminent)
                            .disabled(RuntimeInstaller.resources == nil)
                    }
                }
            }
        }.padding(26).frame(width: 660, height: 550)
            .background(Color(red: 0.97, green: 0.96, blue: 0.93)).tint(accent)
            .preferredColorScheme(.light).interactiveDismissDisabled(store.busy)
    }
}
