import SwiftUI
import AppKit

/// 자주 쓰는 선택만 먼저 보여 주고, 회사 네트워크 설정은 필요한 경우 펼칩니다.
struct DownloadSettingsView: View {
    @Binding var settings: DownloadSettings
    var initiallyExpanded = false
    @ViewState<Bool> private var expanded = false
    var body: some View {
        DisclosureGroup("회사 네트워크 · 인증서 · 오프라인 설치", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("macOS가 신뢰하는 인증서 사용", isOn: $settings.useSystemCertificates)
                field("CA 인증서 묶음 · PEM 파일", hint: "비워 두면 시스템/환경 변수 설정 사용", text: $settings.caBundlePath)
                field("프록시 주소", hint: "http://proxy.company:8080", text: $settings.proxyURL)
                field("Python 다운로드 미러", hint: "https://… 또는 file:///…", text: $settings.pythonMirrorURL)
                field("Python 패키지 저장소", hint: "https://…/simple · 비워 두면 uv 설정 사용", text: $settings.packageIndexURL)
                field("오프라인 패키지 폴더", hint: "/절대/경로/wheels · 지정하면 인덱스 조회 안 함", text: $settings.wheelhousePath)
                Toggle("오프라인 준비 · Python·패키지·모델 다운로드 안 함", isOn: $settings.offline)
                Text("주소에 비밀번호나 토큰을 넣지 마세요. 인증이 필요한 프록시는 회사에서 제공한 환경 변수·uv 설정을 사용하세요. 터미널의 설정은 앱 바이너리를 직접 실행해야 전달됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("인증서 검증은 기본적으로 유지합니다. 이미 실행 중인 Ollama 서버에는 이 설정이 전달되지 않으므로 해당 서버에도 별도로 설정해야 합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 10)
        }.onAppear { expanded = initiallyExpanded }
    }
    private func field(_ title: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(hint, text: text).textFieldStyle(.roundedBorder)
        }
    }
}

struct RuntimeSetupView: View {
    @ObservedObject var store: AppStore
    var onClose: () -> Void
    var previewNetwork = false
    @ViewState<Bool> private var prepareModels = true
    @ViewState<RuntimeSettings> private var options = RuntimeSettings()
    private let accent = Color(red: 0.76, green: 0.31, blue: 0.18)
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "arrow.down.app").font(.largeTitle).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("소리노트 사용 준비").font(.title2.bold())
                    Text("설치된 Python을 활용하거나 전용 환경을 만들 수 있습니다.").foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("실행 환경", selection: $options.mode) {
                            ForEach(RuntimeMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                        if [.localPython, .existingVenv].contains(options.mode) {
                            HStack {
                                TextField("Python 3.12의 절대 경로 · venv/bin/python", text: $options.sourcePython).textFieldStyle(.roundedBorder)
                                Button("선택…", action: choosePython)
                            }
                        }
                        if options.mode == .automatic {
                            Toggle("호환되는 Python이 없으면 다운로드", isOn: $options.allowPythonDownload)
                            Text("앱의 전용 환경, 저장된 Python, 활성화된 venv, 설치된 Python 3.12 순서로 확인합니다.").font(.caption).foregroundStyle(.secondary)
                        } else if options.mode == .existingVenv {
                            Toggle("선택한 venv에 필수 패키지 설치 · 버전 조정 허용", isOn: $options.installMissingPackages)
                            Text("기본값은 검사 후 연결만 합니다. 위 선택을 켜면 해당 venv의 패키지가 변경되며 중간 실패 시 일부 변경이 남을 수 있습니다. 다른 프로젝트와 공유하지 않는 환경을 권장합니다.").font(.caption).foregroundStyle(.secondary)
                        } else if options.mode == .localPython {
                            Text("선택한 Python으로 소리노트 전용 venv를 만듭니다. Python 자체는 다운로드하지 않으며 패키지 설치는 별도로 진행합니다.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("ARM64 Python \(RuntimeInstaller.pythonVersion)을 사용자 폴더에 설치합니다. 시스템 Python은 바꾸지 않습니다.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(16).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                        .disabled(store.busy || store.setupRuntimeReady)
                    DownloadSettingsView(settings: $options.network, initiallyExpanded: previewNetwork).disabled(store.busy)
                    Divider()
                    Toggle("현재 설정의 로컬 모델도 함께 준비", isOn: $prepareModels).disabled(store.busy || store.setupRuntimeReady)
                    Text("기본 구성은 Whisper · EmbeddingGemma 2 · Gemma 4입니다. 화자 분리와 질문 답변·임베딩은 해당 기능을 켠 경우만 준비하며, API 방식은 건너뜁니다. 전체 구성은 25GB 이상의 여유 공간을 권장합니다.").font(.callout).foregroundStyle(.secondary)
                    if store.setupRuntimeReady {
                        Label("실행 환경 준비 완료 · 모델은 따로 다시 준비할 수 있습니다.", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                    }
                    if store.busy { HStack { ProgressView().controlSize(.small); Text(store.progress).font(.callout) } }
                    if let error = store.error {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                            Button("진단 내용 복사") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(error, forType: .string) }
                        }
                    }
                    if let notice = store.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
                }.padding(.trailing, 8)
            }
            Divider()
            HStack {
                Text("기존 기록과 모델·API 설정은 유지됩니다.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.busy { Button("취소") { store.cancel() } }
                else {
                    Button(store.setupRuntimeReady || store.setupFinished ? "사용 시작" : "나중에") { close() }
                    if store.setupRuntimeReady && !store.setupFinished {
                        Button("모델 준비 다시 시도") { store.retrySetupModels(options: options) }.buttonStyle(.borderedProminent)
                    } else if !store.setupFinished {
                        Button("준비 시작") { store.installRuntime(options: options, prepareModels: prepareModels) }.buttonStyle(.borderedProminent)
                            .disabled(RuntimeInstaller.resources == nil)
                    }
                }
            }
        }.padding(26).frame(width: 730, height: 700)
            .background(Color(red: 0.97, green: 0.96, blue: 0.93)).tint(accent)
            .preferredColorScheme(.light).interactiveDismissDisabled(store.busy)
            .onAppear { options = store.settings.runtime }
    }
    private func close() {
        do { try store.saveRuntimeOptions(options); onClose() }
        catch { store.error = error.localizedDescription }
    }
    private func choosePython() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true; panel.message = "Python 3.12 또는 가상 환경의 bin/python 파일을 선택하세요."
        if panel.runModal() == .OK, let url = panel.url { options.sourcePython = url.path }
    }
}
