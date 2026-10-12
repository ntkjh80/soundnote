import SwiftUI

/// 선택한 단계의 설정만 보여 주되, 모든 단계의 변경을 한 번에 저장합니다.
struct SettingsView: View {
    @ObservedObject var store: AppStore
    var previewMode = false
    var previewEnvironment = false
    var previewIntervals = false
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @ViewState<AppSettings> private var draft = AppSettings()
    @ViewState<ModelStage> private var stage = .embedding
    @ViewState<[String: String]> private var keys: [String: String] = [:]
    @ViewState<[String: String]> private var originalKeys: [String: String] = [:]
    @ViewState<[String: ModelProfile]> private var alternatives: [String: ModelProfile] = [:]
    @ViewState<String> private var message = ""
    @ViewState<Bool> private var failed = false
    @ViewState<Bool> private var showEnvironment = false
    @ViewState<Bool> private var showSetup = false
    private let accent = Color(red: 0.76, green: 0.31, blue: 0.18)
    private var locked: Bool { store.busy || store.audio.recording }
    private var changed: Bool { draft != store.settings || keys != originalKeys }
    private var profile: Binding<ModelProfile> {
        Binding(get: { draft[stage] }, set: { draft[stage] = $0 })
    }
    private var isDirect: Bool { !["ollama", "openai"].contains(draft[stage].provider) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("모델 및 환경 설정").font(.title2.bold())
                    Text(changed ? "저장하면 다음 작업부터 기본값으로 사용합니다." : "각 단계에 맞는 모델을 선택하세요.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("설정 저장") { save() }.buttonStyle(.borderedProminent).disabled(locked)
                    .keyboardShortcut("s", modifiers: .command)
                Button { if let onClose { onClose() } else { dismiss() } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).padding(.leading, 8).help("설정 닫기 · 저장하지 않은 변경은 적용되지 않습니다")
            }.padding(24)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("처리 단계").font(.caption).foregroundStyle(.secondary).padding(10)
                    ForEach(ModelStage.allCases) { item in
                        Button { stage = item; showEnvironment = false } label: {
                            Label(item.title, systemImage: item.symbol).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(11).background(stage == item && !showEnvironment ? accent.opacity(0.10) : .clear,
                                                      in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                    Divider().padding(.vertical, 12)
                    Button { showEnvironment = true } label: {
                        Label("공통 환경", systemImage: "gearshape").padding(11)
                    }.buttonStyle(.plain)
                    Spacer()
                    Label(draft.allowRemote ? "외부 전송 허용" : "로컬 전용", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary).padding(10)
                }.padding(12).frame(width: 176)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if showEnvironment { environment } else { stageOptions }
                        if store.busy {
                            HStack { ProgressView().controlSize(.small); Text(store.progress).font(.callout)
                                Spacer(); Button("취소") { store.cancel() } }
                        }
                        if let notice = store.notice { Text(notice).font(.callout).foregroundStyle(.green) }
                        if let error = store.error { Text(error).font(.callout).foregroundStyle(.red) }
                    }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            HStack {
                Text(message.isEmpty ? (changed ? "저장하지 않은 변경 사항이 있습니다." : "API Key는 macOS 키체인에 안전하게 보관합니다.") : message)
                    .font(.caption).foregroundStyle(failed ? .red : .secondary)
                Spacer()
            }.padding(16)
        }
        .background(Color(red: 0.97, green: 0.96, blue: 0.93))
        .tint(accent).preferredColorScheme(.light)
        .frame(minWidth: 800, idealWidth: 850, minHeight: 680, idealHeight: 740)
        .onAppear {
            draft = store.settings
            if previewEnvironment { showEnvironment = true }
            if previewIntervals { stage = .summary }
            if !previewMode {
                // 읽기에 실패한 키는 사전에 넣지 않아 저장 시 기존 키를 지우지 않습니다.
                for name in Keychain.names {
                    do { keys[name] = try Keychain.read(name) }
                    catch { message = error.localizedDescription; failed = true }
                }
            }
            originalKeys = keys
        }
    }

    private var stageOptions: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(stage.title).font(.title3.bold())
                Spacer()
                Button("기본값 복원") { draft[stage] = stage.defaultProfile }.buttonStyle(.borderless).disabled(locked)
            }
            Text(description).font(.callout).foregroundStyle(.secondary)
            if stage == .summary { intervalOptions }
            if stage == .speaker {
                Toggle("화자 분리 사용", isOn: $draft.diarization).disabled(locked)
                Text("끄면 문자 변환만 진행하고 화자 모델은 불러오지 않습니다. 기존 화자 이름과 전사문은 유지됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if stage == .qa || stage == .embedding {
                Toggle("질문 답변 사용 · 검색용 임베딩 포함", isOn: $draft.qaEnabled).disabled(locked)
                Text("끄면 질문 답변과 임베딩 모델을 불러오지 않습니다. 요약 기능과 저장된 자료·색인은 유지됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 15) {
                Picker("실행 방식", selection: Binding(get: { draft[stage].provider }, set: switchProvider)) {
                    ForEach(stage.providers, id: \.self) { Text(providerName($0)).tag($0) }
                }
                labeled("모델 이름 또는 로컬 폴더") {
                    TextField("서버에 설치된 모델 ID를 입력하세요", text: profile.model).textFieldStyle(.roundedBorder)
                }
                if !isDirect {
                    labeled("서버 기본 주소") {
                        TextField("http://127.0.0.1:1234/v1", text: profile.url).textFieldStyle(.roundedBorder)
                    }
                    labeled("API Key · 인증이 없는 로컬 서버는 비워 두세요") {
                        SecureField("키를 입력하거나 지워서 변경", text: key(stage.keyName)).textFieldStyle(.roundedBorder)
                    }
                    Text(draft[stage].provider == "openai" ? "OpenAI 호환 주소에는 /v1까지 입력하세요. 각 단계의 API를 지원하는 서버가 필요합니다." : "Ollama 기본 주소: http://127.0.0.1:11434")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if stage == .asr {
                    Picker("음성 언어", selection: $draft.language) {
                        Text("한국어").tag("ko"); Text("자동 감지").tag(""); Text("영어").tag("en"); Text("일본어").tag("ja")
                    }
                    if !isDirect {
                        Picker("API 응답 형식", selection: profile.responseFormat) {
                            Text("verbose_json · 시각 포함").tag("verbose_json")
                            Text("json · 본문만 가능").tag("json")
                        }
                        Text("화자 분리에는 구간 시각이 필요합니다. json만 지원하는 모델은 전사·요약·검색에 사용할 수 있습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if stage == .speaker {
                    if isDirect {
                        Stepper(draft.speakerCount == 0 ? "화자 수: 자동" : "화자 수: \(draft.speakerCount)명", value: $draft.speakerCount, in: 0...30)
                    } else {
                        Text("/audio/transcriptions에서 diarized_json과 chunking_strategy=auto를 지원해야 합니다. API 방식의 화자 수는 서버가 판단합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if stage == .embedding {
                    if isDirect {
                        Picker("실행 장치", selection: profile.device) {
                            Text("자동 · Apple GPU 우선").tag("auto"); Text("CPU").tag("cpu"); Text("Apple GPU").tag("mps")
                        }
                    }
                    Picker("검색 입력 형식", selection: profile.promptStyle) {
                        Text("자동 · 모델 이름으로 판단").tag("auto")
                        Text("EmbeddingGemma 형식").tag("embeddinggemma")
                        Text("접두사 없음 · 서버에서 처리").tag("plain")
                    }
                    Text("서버에서 모델에 별칭을 붙였다면 입력 형식도 확인하세요. 모델·주소·입력 형식을 바꾸면 다음 검색에서 색인을 자동으로 다시 만듭니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(18).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                .disabled(locked || !draft.isEnabled(stage))
            Text("출고 기본값: \(stage.defaultProfile.model)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if !draft.isEnabled(stage) {
                Label("꺼진 기능은 모델 준비와 연결 확인에서 제외합니다.", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if isDirect || draft[stage].provider == "ollama" {
                HStack {
                    Button("모델 다운로드 / 준비") { if save() { store.prepare(role: stage.rawValue) } }
                    if stage == .speaker || stage == .embedding {
                        Button("다운로드 인증 설정") { showEnvironment = true }.buttonStyle(.borderless)
                    }
                }.disabled(locked)
                Text("현재 설정을 저장한 뒤 모델을 내려받습니다. 준비 후에는 인터넷 없이 실행합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("저장하고 연결 확인") { if save() { store.diagnostic() } }.disabled(locked)
            }
            if stage == .embedding && draft.qaEnabled {
                Button("검색 색인 비우고 다음 검색에서 재생성") { if save() { store.reindex() } }.disabled(locked)
            }
        }
    }

    private var intervalOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("자동 구간 요약", isOn: $draft.intervalSummaryEnabled).font(.headline)
            Text("녹음 중이나 기존 파일의 문자 변환 중에, 완료된 구간부터 전사문과 요약을 저장합니다.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("요약 간격")
                TextField("분", value: $draft.intervalMinutes, format: .number).frame(width: 48).textFieldStyle(.roundedBorder)
                Text("분")
                Stepper("간격 조정", value: $draft.intervalMinutes, in: 1...30).labelsHidden()
                Spacer()
                Text(draft.asr.provider == "openai" ? "API: 1~13분" : "1~30분").font(.caption).foregroundStyle(.secondary)
            }.disabled(!draft.intervalSummaryEnabled)
            Toggle("종료 후 전체 요약 만들기", isOn: $draft.intervalFinalSummary).disabled(!draft.intervalSummaryEnabled)
            Text("녹음 길이 기준이며 일시 정지 시간은 제외합니다. 전사 → 요약을 순서대로 실행하므로 결과 표시에는 처리 시간이 더 걸립니다. 질문 답변을 꺼도 사용할 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
            Text("아래 회의 요약 모델·서버·API Key를 함께 사용합니다. 화자 분리를 켰다면 전체 녹음 처리 후 한 번 실행합니다.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12)).disabled(locked)
    }

    private var environment: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("공통 환경").font(.title3.bold())
            VStack(alignment: .leading, spacing: 12) {
                Text("메모리에 맞춰 기능 선택").font(.headline)
                Toggle("화자 분리 사용", isOn: $draft.diarization)
                Toggle("질문 답변 사용 · 검색용 임베딩 포함", isOn: $draft.qaEnabled)
                Text("메모리가 부족하면 필요한 기능만 켜세요. 끈 기능은 다음 작업부터 모델을 불러오지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("화자 분리 약 4~8GB, 임베딩 약 3~5GB의 처리 단계를 생략할 수 있습니다. 요약을 사용하면 Gemma 약 8~12GB는 여전히 필요합니다. 수치는 추정치이며 화자 모델은 실측 전입니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12)).disabled(locked)
            if RuntimeInstaller.resources != nil {
                Button("자동 설치 / 복구…") {
                    if save() { store.error = nil; store.notice = nil; store.setupFinished = false; store.setupRuntimeReady = false; showSetup = true }
                }.disabled(locked)
                .sheet(isPresented: $showSetup) {
                    RuntimeSetupView(store: store) { showSetup = false; draft = store.settings }
                }
            }
            Toggle("외부 서버로 음성·텍스트 전송 허용", isOn: $draft.allowRemote)
            Text(draft.allowRemote ? "API 방식으로 선택한 단계는 설정한 서버에 음성 또는 텍스트를 보냅니다. 외부 서버 주소는 HTTPS만 허용합니다." : "루프백 주소와 직접 실행만 허용합니다. 별도 로컬 서버가 외부로 중계하는지는 그 서버의 설정을 확인하세요.")
                .font(.caption).foregroundStyle(draft.allowRemote ? .orange : .secondary)
            DownloadSettingsView(settings: $draft.runtime.network)
            labeled("Python 실행 파일의 절대 경로") { TextField("프로젝트/.venv/bin/python", text: $draft.pythonPath).textFieldStyle(.roundedBorder) }
            labeled("Hugging Face Token · 모델 다운로드 인증") { SecureField("읽기 토큰", text: key("hfToken")).textFieldStyle(.roundedBorder) }
            Text("접근 제한 모델은 해당 계정으로 이용 조건에 동의한 뒤 준비하세요. 직접 실행 모드에서는 이 토큰으로 회의 내용을 보내지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Link("EmbeddingGemma 2 이용 조건 ↗", destination: URL(string: "https://huggingface.co/google/embeddinggemma-2")!)
                Link("Community-1 이용 조건 ↗", destination: URL(string: "https://huggingface.co/pyannote/speaker-diarization-community-1")!)
            }.font(.caption)
            Button("저장하고 설치·연결 확인") { if save() { store.diagnostic() } }.disabled(locked)
            ForEach(store.checks) { check in
                Label { VStack(alignment: .leading, spacing: 3) {
                    Text(check.name).font(.callout.bold()); Text(check.detail).font(.caption).foregroundStyle(.secondary)
                } } icon: { Image(systemName: check.ok ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(check.ok ? .green : .orange) }
            }
            Divider()
            Text("데이터 보관").font(.headline)
            Text(AppSettings.directory.path).font(.caption.monospaced()).textSelection(.enabled)
            Button("데이터 폴더 열기") { NSWorkspace.shared.open(AppSettings.directory) }
        }
    }

    private var description: String {
        switch stage {
        case .asr: "녹음을 글로 바꿉니다. 기본 모델은 Apple Silicon에서 직접 실행합니다."
        case .speaker: "발언 시각을 비교해 화자를 나눕니다. 로컬 기본값은 CPU를 사용하며, 이 기능은 선택 사항입니다."
        case .summary: "전사문과 문서에서 핵심 내용, 결정 사항, 할 일을 정리합니다."
        case .embedding: "문서와 질문을 숫자 벡터로 바꿔 관련 내용을 찾습니다. EmbeddingGemma 2는 텍스트 부분만 직접 실행합니다."
        case .qa: "검색으로 찾은 원문을 읽고 출처를 붙여 답합니다. 요약과 다른 모델도 선택할 수 있습니다."
        }
    }
    private func providerName(_ value: String) -> String {
        switch value { case "mlx": "맥에서 직접 실행 · MLX Whisper"; case "pyannote": "맥에서 직접 실행 · pyannote"
        case "sentence_transformers": "맥에서 직접 실행 · Sentence Transformers"; case "ollama": "Ollama"; default: "OpenAI 호환 API" }
    }
    private func switchProvider(_ provider: String) {
        let old = draft[stage]
        alternatives[stage.rawValue + ":" + old.provider] = old
        draft[stage] = alternatives[stage.rawValue + ":" + provider] ?? stage.initialProfile(for: provider)
    }
    private func key(_ name: String) -> Binding<String> { Binding(get: { keys[name] ?? "" }, set: { keys[name] = $0 }) }
    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); content() }
    }
    @discardableResult private func save() -> Bool {
        do {
            // 별도 음성 설정 창에서 저장한 녹음 입력을 오래된 모델 편집본으로 덮어쓰지 않습니다.
            draft.audio = store.settings.audio
            try draft.validate()
            try draft.runtime.network.validate()
            for name in Keychain.names where keys[name] != originalKeys[name] {
                if let value = keys[name] { try Keychain.save(value, name: name) }
            }
            try draft.save()
            store.settings = draft; originalKeys = keys
            if !draft.qaEnabled { store.answer = nil }
            store.checks = []; store.error = nil; store.notice = nil
            failed = false; message = "저장했습니다. 다음 작업부터 선택한 모델을 기본값으로 사용합니다."
            return true
        } catch { failed = true; message = error.localizedDescription; return false }
    }
}
