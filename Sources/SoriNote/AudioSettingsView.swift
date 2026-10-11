import AVFoundation
import CoreGraphics
import SwiftUI

/// 녹음 설정은 모델 설정과 따로 저장할 수 있어, AI 서버 준비 없이도 입력을 바꿀 수 있습니다.
struct AudioSettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var audio: AudioController
    var previewMode = false
    @Environment(\.dismiss) private var dismiss
    @ViewState<AudioSettings> private var draft = AudioSettings()
    @ViewState<[MicrophoneDevice]> private var devices: [MicrophoneDevice] = []
    @ViewState<String> private var message = ""
    @ViewState<Bool> private var failed = false
    @ViewState<Bool> private var screenAllowed = false
    private let accent = Color(red: 0.76, green: 0.31, blue: 0.18)
    private var locked: Bool { store.busy || audio.recording }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("음성 설정").font(.title2.bold())
                    Text("어떤 소리를 기록할지 선택하세요.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("저장") { save() }.buttonStyle(.borderedProminent).disabled(locked)
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).padding(.leading, 8)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("녹음할 소리").font(.headline)
                        Picker("녹음 소스", selection: $draft.source) {
                            ForEach(RecordingSource.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().pickerStyle(.segmented)
                        Text(sourceDescription).font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                    if draft.source.usesMicrophone {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("마이크").font(.headline); Spacer()
                                Button("장치 새로고침") { refresh() }.buttonStyle(.borderless)
                            }
                            Picker("입력 장치", selection: $draft.microphoneID) {
                                Text("시스템 기본 마이크").tag("")
                                ForEach(devices) { Text($0.name).tag($0.id) }
                                if !draft.microphoneID.isEmpty && !devices.contains(where: { $0.id == draft.microphoneID }) {
                                    Text("연결되지 않은 마이크 · 다시 선택해 주세요").tag(draft.microphoneID)
                                }
                            }
                            volume("마이크 녹음 음량", value: $draft.microphoneGain)
                            Text("Teams에서 내 마이크를 음소거해도, 소리노트의 마이크 녹음은 계속됩니다. 내 목소리를 제외하려면 ‘시스템 오디오만’을 선택하세요.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if draft.source.usesSystem {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("시스템 오디오 · 스피커로 나가는 소리").font(.headline)
                            volume("시스템 녹음 음량", value: $draft.systemGain)
                            Text("스피커 음량을 0으로 내리거나 맥의 출력 음소거를 켜도, 앱이 재생하는 소리를 직접 캡처합니다. Teams 자체가 출력을 중단하면 해당 소리는 녹음되지 않습니다.")
                                .font(.callout).foregroundStyle(.secondary)
                            Text("시스템 전체 소리를 포함하므로 다른 앱의 음악·알림도 녹음될 수 있습니다. 화면 영상은 저장하지 않습니다.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Label(screenAllowed ? "시스템 캡처 권한 확인됨" : "첫 녹음 시 시스템 캡처 권한 필요",
                                      systemImage: screenAllowed ? "checkmark.shield" : "lock.shield").font(.caption)
                                Spacer()
                                Button("권한 설정 열기") {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                                }.buttonStyle(.borderless)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if draft.source == .both {
                        Text("스피커 소리가 마이크에 다시 들어오면 이중으로 들릴 수 있습니다. 이어폰을 사용하거나 맥 출력을 음소거하면 줄일 수 있습니다. 두 소리는 각각 절반 크기로 합쳐 과도한 음량을 줄입니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("설정은 다음 녹음부터 적용합니다. 녹음 중에는 바꿀 수 없습니다.").font(.caption).foregroundStyle(.secondary)
                }.padding(24).disabled(locked)
            }
            Divider()
            Text(message.isEmpty ? "현재 기본값: \(store.settings.audio.source.title)" : message)
                .font(.caption).foregroundStyle(failed ? .red : .secondary).padding(16)
        }
        .background(Color(red: 0.97, green: 0.96, blue: 0.93)).tint(accent).preferredColorScheme(.light)
        .onAppear {
            draft = store.settings.audio
            if !previewMode { refresh() }
        }
    }
    private var sourceDescription: String {
        switch draft.source {
        case .microphone: "대면 회의와 음성 메모에 사용합니다. 선택한 마이크의 소리만 녹음합니다."
        case .system: "Teams 등에서 들려오는 상대방 소리를 녹음합니다. 내 마이크는 사용하지 않습니다."
        case .both: "Teams 상대방의 소리와 선택한 마이크의 내 목소리를 한 파일에 녹음합니다."
        }
    }
    private func volume(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).font(.callout)
            Slider(value: value, in: 0...2).frame(maxWidth: 200)
            Text("\(Int(value.wrappedValue * 100))%").monospacedDigit().frame(width: 45, alignment: .trailing)
        }
    }
    private func refresh() {
        devices = MicrophoneDevices.list()
        screenAllowed = CGPreflightScreenCaptureAccess()
    }
    private func save() {
        do {
            try draft.validate()
            var settings = store.settings
            settings.audio = draft
            try settings.save()
            store.settings = settings
            failed = false; message = "저장했습니다. 다음 녹음부터 ‘\(draft.source.title)’을 사용합니다."
        } catch { failed = true; message = error.localizedDescription }
    }
}
