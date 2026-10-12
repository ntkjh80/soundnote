import SwiftUI

private let ink = Color(red: 0.14, green: 0.19, blue: 0.22)
private let accent = Color(red: 0.76, green: 0.31, blue: 0.18)
private let paper = Color(red: 0.97, green: 0.96, blue: 0.93)

struct ContentView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var audio: AudioController
    var previewMode = false
    @ViewState<String> private var section = "요약"
    @ViewState<Bool> private var editing = false
    @ViewState<Bool> private var configuring = false
    @ViewState<Bool> private var configuringAudio = false
    @ViewState<Bool> private var deleting = false
    @ViewState<Bool> private var retranscribing = false
    @ViewState<String> private var renameOld = ""
    @ViewState<String> private var renameNew = ""
    @ViewState<Bool> private var renaming = false
    @ViewState<String> private var question = ""
    @ViewState<Bool> private var allSources = true

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 244)
            VStack(spacing: 0) {
                topbar
                if audio.recording { recordingBar }
                if store.busy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(store.progress).font(.callout)
                        Spacer()
                        if !store.liveSummaryPaused {
                            Button(store.liveProcessing ? "자동 요약 중지" : "취소") { store.cancel() }.buttonStyle(.borderless)
                        }
                    }.padding(14).background(accent.opacity(0.08))
                }
                if let notice = store.notice {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(notice).font(.callout)
                        Spacer()
                        Button { store.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding(12).background(.green.opacity(0.07))
                }
                HStack(spacing: 0) {
                    if let entry = store.selected { detail(entry) }
                    else { welcome }
                    Divider()
                    questionPane.frame(width: 300)
                }
            }.background(paper)
        }
        .foregroundStyle(ink)
        .tint(accent)
        .preferredColorScheme(.light)
        .task {
            if !previewMode { store.launch() }
            else if !(store.selected?.interval_notes.isEmpty ?? true) { section = "구간 요약" }
        }
        .onChange(of: store.selected?.id) { _, _ in
            if let entry = store.selected, (!entry.interval_notes.isEmpty || entry.hasPendingIntervals), entry.summary.isEmpty { section = "구간 요약" }
        }
        .onChange(of: store.selected?.interval_notes.count ?? 0) { old, count in
            if old == 0 && count > 0 { section = "구간 요약" }
        }
        .alert("확인이 필요합니다", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("확인") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .alert("기록을 삭제할까요?", isPresented: $deleting) {
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) { store.deleteSelected() }
        } message: { Text("앱에 저장된 녹음 사본, 원문, 요약, 검색 색인을 삭제합니다. 가져오기 전 원본 파일은 유지됩니다.") }
        .alert("문자 변환을 다시 실행할까요?", isPresented: $retranscribing) {
            Button("취소", role: .cancel) {}
            Button("다시 변환") { store.processSelected("transcribe") }
        } message: { Text("현재 전사문과 화자 이름, 요약이 새 결과로 바뀝니다. 필요한 내용은 먼저 내보내 주세요.") }
        .alert("화자 이름 변경", isPresented: $renaming) {
            TextField("예: 김지민", text: $renameNew)
            Button("취소", role: .cancel) {}
            Button("변경") { store.renameSpeaker(old: renameOld, new: renameNew) }
        } message: { Text("이 회의의 ‘\(renameOld)’ 발언에 적용합니다. 기존 요약은 비워지므로 다시 요약해 주세요.") }
        .sheet(isPresented: $configuringAudio) { AudioSettingsView(store: store, audio: audio).frame(width: 660, height: 700) }
        .sheet(isPresented: $configuring) { SettingsView(store: store, onClose: { configuring = false }).frame(width: 850, height: 740) }
        .sheet(isPresented: $editing) { if let entry = store.selected { EditorView(store: store, entry: entry) } }
        .sheet(isPresented: $store.showingSetup) {
            RuntimeSetupView(store: store) { store.showingSetup = false; if !store.needsRuntimeSetup { store.launch() } }
        }
        .onChange(of: audio.recordingError) { _, value in if let value { store.error = value } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 11) {
                Image(systemName: "waveform").font(.title).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("소리노트").font(.title2.bold())
                    Text("나의 맥 안에, 회의의 모든 것").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.top, 16)
            Button { store.startRecording() } label: {
                Label("새 회의 녹음", systemImage: "mic.fill").frame(maxWidth: .infinity).padding(.vertical, 7)
            }.buttonStyle(.borderedProminent).disabled(store.busy || audio.recording)
            Button { configuringAudio = true } label: {
                Label(store.settings.audio.source.title, systemImage: "slider.horizontal.3")
                    .font(.caption).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
            TextField("기록 찾기", text: $store.search).textFieldStyle(.roundedBorder)
            HStack {
                Text("내 라이브러리").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Text("\(store.entries.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(store.filtered) { entry in
                        Button { store.select(entry.id) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: entry.kind == "meeting" ? "waveform" : "doc.text")
                                    .foregroundStyle(store.selectedID == entry.id ? accent : .secondary).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(entry.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                    Text(entry.created.prefix(10)).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if entry.summarized == 1 { Image(systemName: "sparkle").foregroundStyle(accent).font(.caption) }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(store.selectedID == entry.id ? accent.opacity(0.10) : .clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).disabled(store.busy)
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 12) {
                Button { store.importFiles() } label: { Label("녹음·문서 가져오기", systemImage: "square.and.arrow.down") }
                    .disabled(store.busy || audio.recording)
                Button { configuringAudio = true } label: { Label("음성 설정", systemImage: "waveform.badge.mic") }
                Button { configuring = true } label: { Label("모델 및 환경 설정", systemImage: "slider.horizontal.3") }
                Divider()
                Label(store.settings.allowRemote ? "외부 전송 허용됨" : "로컬 전용 모드",
                      systemImage: store.settings.allowRemote ? "network" : "lock.shield")
                    .font(.caption).foregroundStyle(store.settings.allowRemote ? accent : .secondary)
            }.buttonStyle(.plain).font(.callout)
        }.padding(20).background(Color.white.opacity(0.85))
    }

    private var topbar: some View {
        HStack {
            Text("WORKSPACE").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
            Text("/").foregroundStyle(.quaternary)
            Text(store.selected?.kind == "meeting" ? "회의 기록" : "기록과 문서").font(.callout)
            Spacer()
            if store.selected != nil {
                Button { editing = true } label: { Label("수정", systemImage: "square.and.pencil") }
                Menu { ExportMenuItems(store: store) } label: { Label("내보내기", systemImage: "square.and.arrow.up") }
                    .fixedSize().help("녹음 파일, 전사문, 요약을 원하는 위치에 저장")
                Button { deleting = true } label: { Image(systemName: "trash") }.help("이 기록 삭제")
            }
        }.buttonStyle(.borderless).disabled(store.busy || audio.recording)
            .padding(.horizontal, 26).frame(height: 58).background(.white.opacity(0.6))
    }

    private var recordingBar: some View {
        HStack(spacing: 15) {
            Circle().fill(accent).frame(width: 9, height: 9)
            Text(audio.paused ? "녹음 일시 정지" : audio.activeSource.title).fontWeight(.semibold)
            Text(clockText(audio.elapsed)).monospacedDigit()
            if audio.activeSource.usesMicrophone { inputMeter("마이크", level: audio.microphoneLevel) }
            if audio.activeSource.usesSystem { inputMeter("시스템", level: audio.systemLevel) }
            Spacer()
            Button(audio.paused ? "이어 녹음" : "일시 정지") { audio.pauseOrResume() }.disabled(store.busy && !store.liveProcessing)
            Button("녹음 완료") { store.stopRecording() }.buttonStyle(.borderedProminent).disabled(store.busy && !store.liveProcessing)
        }.padding(18).background(accent.opacity(0.08))
    }

    private func inputMeter(_ name: String, level: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            ProgressView(value: level).frame(width: 60).accessibilityLabel(name + " 입력 크기")
        }.help(audio.captureNotice ?? "입력이 없거나 무음인 동안에는 표시가 움직이지 않습니다.")
    }

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                Label("회의를 기록하는 새로운 습관", systemImage: "leaf").font(.caption).foregroundStyle(accent)
                Text("대화에 집중하세요.\n기록은 소리노트가.").font(.system(size: 36, weight: .semibold)).lineSpacing(5)
                Text("녹음부터 요약, 자료를 바탕으로 한 질문까지.\n당신의 맥에서 차근차근 정리합니다.")
                    .font(.body).foregroundStyle(.secondary).lineSpacing(5)
                HStack {
                    Button("첫 회의 녹음하기") { store.startRecording() }.buttonStyle(.borderedProminent)
                    Button("파일 가져오기") { store.importFiles() }.buttonStyle(.bordered)
                }.disabled(store.busy || audio.recording)
                Divider().padding(.vertical, 10)
                feature("01", "듣고, 기록하고", "마이크와 시스템 오디오를 녹음하고, 시간 정보가 있는 전사문으로 바꿉니다.", "waveform")
                feature("02", "누가 말했는지까지", "선택형 화자 분리로 대화 흐름을 읽고, 화자 이름을 직접 붙입니다.", "person.2")
                feature("03", "내 자료에서 찾는 답", "회의록과 문서를 검색해 답변과 함께 근거 문단을 보여 줍니다.", "text.magnifyingglass")
                Button("예시 기록으로 둘러보기 →") { store.demo() }.buttonStyle(.plain).foregroundStyle(accent)
                    .disabled(store.busy || audio.recording)
                Text("처음 사용한다면 설정에서 엔진과 모델 준비 상태를 확인하세요.\n음성 설정에서 마이크와 시스템 오디오를 선택할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(36).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func feature(_ number: String, _ title: String, _ caption: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 15) {
            Text(number).font(.system(size: 12, design: .monospaced)).foregroundStyle(accent).padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: icon).font(.headline)
                Text(caption).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func detail(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text(entry.kind == "meeting" ? "MEETING NOTE" : "DOCUMENT")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(accent)
                Text(entry.title).font(.system(size: 27, weight: .semibold)).textSelection(.enabled)
                HStack {
                    Label(String(entry.created.prefix(10)), systemImage: "calendar")
                    Text("·")
                    Text("\(entry.text.count.formatted())자")
                    if !entry.segments.isEmpty {
                        Text("·")
                        Text("\(Set(entry.segments.map(\.speaker)).count)개 화자 표시")
                    }
                }.font(.caption).foregroundStyle(.secondary)
                HStack {
                    if !entry.audio_path.isEmpty {
                        Button {
                            if entry.text.isEmpty { store.processSelected("transcribe") } else { retranscribing = true }
                        } label: { Label("문자 변환", systemImage: "waveform.badge.mic") }
                    }
                    if entry.hasPendingIntervals && !entry.audio_path.isEmpty {
                        Button("구간 처리 이어하기") { store.processSelected("continueIntervals"); section = "구간 요약" }
                    }
                    Button { store.processSelected("summarize"); section = "요약" } label: {
                        Label(entry.summary.isEmpty ? "AI 요약 만들기" : "다시 요약하기", systemImage: "sparkles")
                    }.buttonStyle(.borderedProminent).disabled(entry.text.isEmpty)
                }.disabled(store.busy || audio.recording)
            }
            if !entry.warning.isEmpty { Label(entry.warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(accent) }
            if !entry.audio_path.isEmpty {
                HStack {
                    Button {
                        do { try audio.play(entry.audio_path) } catch { store.error = error.localizedDescription }
                    } label: { Image(systemName: audio.playing ? "pause.fill" : "play.fill") }
                    Text(clockText(audio.playhead)).monospacedDigit()
                    ProgressView(value: audio.duration > 0 ? audio.playhead / audio.duration : 0)
                    Text(clockText(audio.duration)).monospacedDigit().foregroundStyle(.secondary)
                }.font(.caption).padding(14).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .disabled(audio.recording)
            }
            Picker("보기", selection: $section) {
                Text("요약").tag("요약")
                if !entry.interval_notes.isEmpty || entry.hasPendingIntervals { Text("구간 요약").tag("구간 요약") }
                Text("원문·화자").tag("원문·화자")
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if section == "구간 요약" {
                        Text("각 구간은 앞선 논의의 맥락을 참고해 정리합니다. 중간 요약의 결정이 이후에 바뀔 수 있으므로 마지막 요약과 원문도 확인하세요.")
                            .font(.caption).foregroundStyle(.secondary)
                        if entry.interval_notes.isEmpty {
                            emptyNote("첫 구간을 기다리고 있어요", "설정한 분량이 모이면 전사와 요약을 차례로 시작합니다.", "clock")
                        }
                        ForEach(entry.interval_notes) { note in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("\(clockText(note.start)) ~ \(clockText(note.end))").font(.caption.monospacedDigit().bold()).foregroundStyle(accent)
                                    Spacer()
                                    if note.status != "complete" { Text("전사 저장됨 · 요약 대기").font(.caption).foregroundStyle(.secondary) }
                                }
                                Text(.init(note.summary.isEmpty ? "이 구간의 전사문을 저장했습니다. 요약은 처리 중이거나 이어서 처리할 수 있습니다." : note.summary))
                                    .font(.body).lineSpacing(5).textSelection(.enabled)
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                        }
                    } else if section == "요약" {
                        if entry.summary.isEmpty {
                            emptyNote("핵심 내용만, 한눈에", "문자 변환이나 문서 가져오기를 마친 뒤\n‘AI 요약 만들기’를 눌러 보세요.", "sparkles")
                        } else {
                            Text(.init(entry.summary)).font(.body).lineSpacing(6).textSelection(.enabled)
                            Text("AI 요약은 틀릴 수 있습니다. 중요한 결정과 담당자는 원문에서 확인하세요.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if !entry.segments.isEmpty {
                        ForEach(entry.segments) { segment in
                            HStack(alignment: .top, spacing: 12) {
                                Button(clockText(segment.start)) {
                                    do { try audio.play(entry.audio_path, at: segment.start) } catch { store.error = error.localizedDescription }
                                }.font(.system(size: 10, design: .monospaced)).buttonStyle(.plain).foregroundStyle(accent)
                                    .disabled(audio.recording).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 6) {
                                    Button(segment.speaker) {
                                        renameOld = segment.speaker; renameNew = segment.speaker; renaming = true
                                    }.font(.caption.bold()).buttonStyle(.plain).disabled(store.busy || audio.recording)
                                    Text(segment.text).lineSpacing(5).textSelection(.enabled)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                    } else if !entry.text.isEmpty { Text(entry.text).lineSpacing(6).textSelection(.enabled) }
                    else { emptyNote("아직 전사문이 없어요", "‘문자 변환’을 누르면 로컬 모델이\n녹음을 읽고 문장으로 정리합니다.", "text.alignleft") }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
            }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func emptyNote(_ title: String, _ text: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: icon).font(.title).foregroundStyle(accent)
            Text(title).font(.title3.bold())
            Text(text).font(.callout).foregroundStyle(.secondary).lineSpacing(5)
        }.padding(.vertical, 30)
    }

    private var questionPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("내 기록에 질문하기", systemImage: "sparkle.magnifyingglass").font(.headline)
            if !store.settings.qaEnabled {
                Label("질문 답변 꺼짐", systemImage: "pause.circle").foregroundStyle(.secondary)
                Text("메모리 사용을 줄이기 위해 질문 답변과 검색용 임베딩을 사용하지 않습니다. 녹음·문자 변환·요약은 계속 사용할 수 있습니다.")
                    .font(.callout).foregroundStyle(.secondary).lineSpacing(4)
                Button("모델 및 환경 설정 열기") { configuring = true }
                Spacer()
            } else {
                Text("기록 속에서 답을 찾고,\n근거가 된 문단까지 확인하세요.").font(.callout).foregroundStyle(.secondary).lineSpacing(4)
                Picker("검색 범위", selection: $allSources) {
                    Text("모든 자료").tag(true); Text("선택한 자료").tag(false)
                }.pickerStyle(.segmented)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let answer = store.answer {
                            Text(.init(answer.answer)).font(.callout).lineSpacing(5).textSelection(.enabled)
                            Divider()
                            Text("검색된 근거 · 답변과 함께 확인하세요").font(.caption.bold())
                            ForEach(answer.sources) { source in
                                DisclosureGroup("[\(source.number)] \(source.title)") {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(source.text).font(.caption).lineSpacing(3).textSelection(.enabled)
                                        Button("원문 열기") { store.select(source.entry_id); section = "원문·화자" }
                                            .disabled(store.busy)
                                    }.padding(.top, 8)
                                }.font(.caption).padding(10).background(paper, in: RoundedRectangle(cornerRadius: 9))
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("이렇게 물어보세요").font(.caption).foregroundStyle(.secondary)
                                suggestion("이번 회의에서 결정한 내용은?")
                                suggestion("담당자별로 해야 할 일을 알려줘")
                                suggestion("아직 정하지 못한 일정이 있어?")
                            }.padding(.top, 20)
                        }
                    }
                }
                VStack(spacing: 10) {
                    TextField("자료에 대해 궁금한 내용을 적어 주세요", text: $question, axis: .vertical)
                        .lineLimit(3...6).textFieldStyle(.plain).padding(12)
                        .background(paper, in: RoundedRectangle(cornerRadius: 10))
                    Button {
                        store.ask(question, all: allSources)
                    } label: { Label("질문 보내기", systemImage: "arrow.up").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.busy || audio.recording || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || store.entries.isEmpty || (!allSources && store.selected == nil))
                    Text(store.settings.allowRemote ? "설정한 외부 서버로 텍스트가 전송될 수 있습니다." : "답변은 설정한 로컬 모델에서 생성합니다.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }.padding(20).frame(maxHeight: .infinity).background(.white.opacity(0.8))
    }

    private func suggestion(_ value: String) -> some View {
        Button { question = value } label: {
            HStack { Text(value).multilineTextAlignment(.leading); Spacer(minLength: 4); Image(systemName: "arrow.up.left") }
                .font(.caption).padding(12).frame(maxWidth: .infinity)
                .background(paper, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
}

struct EditorView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var title: String
    @ViewState<String> private var text: String

    init(store: AppStore, entry: Entry) {
        self.store = store; _title = ViewState(initialValue: entry.title); _text = ViewState(initialValue: entry.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("기록 수정").font(.title2.bold())
            TextField("제목", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $text).font(.body).border(.gray.opacity(0.2))
            Text("본문을 수정하면 이전 시각·화자 구간과 전체·구간 요약을 비웁니다. 화자 이름만 바꾸려면 원문 화면에서 이름을 누르세요.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer(); Button("취소") { dismiss() }
                Button("저장") { store.edit(title: title, text: text); dismiss() }.buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 720, height: 560)
    }
}
