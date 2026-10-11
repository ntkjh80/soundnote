import Foundation

/// 기능마다 실행 방식과 모델을 따로 보관합니다. 인증 정보는 이 구조에 넣지 않습니다.
struct ModelProfile: Codable, Equatable {
    var provider = "ollama"
    var url = "http://127.0.0.1:11434"
    var model = "gemma4:e4b"
    var responseFormat = "verbose_json"
    var device = "auto"
    var promptStyle = "auto"

    init(provider: String = "ollama", url: String = "http://127.0.0.1:11434", model: String = "gemma4:e4b",
         responseFormat: String = "verbose_json", device: String = "auto", promptStyle: String = "auto") {
        self.provider = provider; self.url = url; self.model = model
        self.responseFormat = responseFormat; self.device = device; self.promptStyle = promptStyle
    }
    enum CodingKeys: String, CodingKey { case provider, url, model, responseFormat, device, promptStyle }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? provider
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? url
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? model
        responseFormat = try c.decodeIfPresent(String.self, forKey: .responseFormat) ?? responseFormat
        device = try c.decodeIfPresent(String.self, forKey: .device) ?? device
        promptStyle = try c.decodeIfPresent(String.self, forKey: .promptStyle) ?? promptStyle
    }
}

enum ModelStage: String, CaseIterable, Identifiable {
    case asr, speaker, summary, embedding, qa
    var id: String { rawValue }
    var title: String {
        switch self { case .asr: "음성 인식"; case .speaker: "화자 분리"; case .summary: "회의 요약"
        case .embedding: "검색용 임베딩"; case .qa: "질문 답변" }
    }
    var symbol: String {
        switch self { case .asr: "waveform"; case .speaker: "person.2"; case .summary: "text.alignleft"
        case .embedding: "magnifyingglass"; case .qa: "bubble.left.and.text.bubble.right" }
    }
    var providers: [String] {
        switch self { case .asr: ["mlx", "openai"]; case .speaker: ["pyannote", "openai"]
        case .embedding: ["sentence_transformers", "ollama", "openai"]; default: ["ollama", "openai"] }
    }
    var defaultProfile: ModelProfile {
        switch self {
        case .asr: ModelProfile(provider: "mlx", url: "", model: "mlx-community/whisper-large-v3-turbo")
        case .speaker: ModelProfile(provider: "pyannote", url: "", model: "pyannote/speaker-diarization-community-1")
        case .embedding: ModelProfile(provider: "sentence_transformers", url: "", model: "google/embeddinggemma-2")
        default: ModelProfile()
        }
    }
    var keyName: String { rawValue + "Key" }
    func initialProfile(for provider: String) -> ModelProfile {
        if provider == defaultProfile.provider { return defaultProfile }
        if provider == "ollama" { return ModelProfile(model: "embeddinggemma:300m") }
        // 서버마다 모델 ID가 달라 호환 API의 이름은 사용자가 직접 지정합니다.
        return ModelProfile(provider: provider, url: "http://127.0.0.1:1234/v1", model: "")
    }
}

enum RecordingSource: String, Codable, CaseIterable, Identifiable {
    case microphone, system, both
    var id: String { rawValue }
    var title: String { switch self { case .microphone: "마이크만"; case .system: "시스템 오디오만"; case .both: "마이크 + 시스템 오디오" } }
    var usesMicrophone: Bool { self != .system }
    var usesSystem: Bool { self != .microphone }
}

/// 녹음 입력 설정입니다. 스피커의 출력 음량과 녹음 음량은 별도로 취급합니다.
struct AudioSettings: Codable, Equatable {
    var source: RecordingSource = .microphone
    var microphoneID = ""
    var microphoneGain: Double = 1
    var systemGain: Double = 1
    init() {}
    enum CodingKeys: String, CodingKey { case source, microphoneID, microphoneGain, systemGain }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(RecordingSource.self, forKey: .source) ?? source
        microphoneID = try c.decodeIfPresent(String.self, forKey: .microphoneID) ?? microphoneID
        microphoneGain = try c.decodeIfPresent(Double.self, forKey: .microphoneGain) ?? microphoneGain
        systemGain = try c.decodeIfPresent(Double.self, forKey: .systemGain) ?? systemGain
    }
    func validate() throws {
        guard [microphoneGain, systemGain].allSatisfy({ $0.isFinite && (0...2).contains($0) }) else {
            throw AppFailure(message: "녹음 음량은 0~200%로 설정하세요.")
        }
    }
}

struct AppSettings: Codable, Equatable {
    var settingsVersion = 2
    var audio = AudioSettings()
    var pythonPath = "/usr/bin/python3"
    var asr = ModelStage.asr.defaultProfile
    var speaker = ModelStage.speaker.defaultProfile
    var diarization = false
    var speakerCount = 0
    var language = "ko"
    var allowRemote = false
    var summary = ModelProfile()
    var qa = ModelProfile()
    var embedding = ModelStage.embedding.defaultProfile

    init() {}
    enum CodingKeys: String, CodingKey {
        case audio, settingsVersion, pythonPath, asr, speaker, diarization, speakerCount, language, allowRemote, summary, qa, embedding
    }
    enum LegacyKeys: String, CodingKey { case asrModel, diarizationModel }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let old = try decoder.container(keyedBy: LegacyKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .settingsVersion) ?? 1
        audio = try c.decodeIfPresent(AudioSettings.self, forKey: .audio) ?? audio
        pythonPath = try c.decodeIfPresent(String.self, forKey: .pythonPath) ?? pythonPath
        asr = try c.decodeIfPresent(ModelProfile.self, forKey: .asr) ?? asr
        speaker = try c.decodeIfPresent(ModelProfile.self, forKey: .speaker) ?? speaker
        if !c.contains(.asr), let name = try old.decodeIfPresent(String.self, forKey: .asrModel) { asr.model = name }
        if !c.contains(.speaker), let name = try old.decodeIfPresent(String.self, forKey: .diarizationModel) { speaker.model = name }
        diarization = try c.decodeIfPresent(Bool.self, forKey: .diarization) ?? diarization
        speakerCount = try c.decodeIfPresent(Int.self, forKey: .speakerCount) ?? speakerCount
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? language
        allowRemote = try c.decodeIfPresent(Bool.self, forKey: .allowRemote) ?? allowRemote
        summary = try c.decodeIfPresent(ModelProfile.self, forKey: .summary) ?? summary
        qa = try c.decodeIfPresent(ModelProfile.self, forKey: .qa) ?? qa
        if let previous = try c.decodeIfPresent(ModelProfile.self, forKey: .embedding) {
            // 0.1의 출고 기본값만 이전합니다. 사용자가 지정한 모델·서버는 그대로 둡니다.
            if version >= 2 || previous != ModelProfile(model: "embeddinggemma:300m") { embedding = previous }
        }
    }

    subscript(stage: ModelStage) -> ModelProfile {
        get { switch stage { case .asr: asr; case .speaker: speaker; case .summary: summary; case .embedding: embedding; case .qa: qa } }
        set { switch stage { case .asr: asr = newValue; case .speaker: speaker = newValue; case .summary: summary = newValue
            case .embedding: embedding = newValue; case .qa: qa = newValue } }
    }

    func validate() throws {
        try audio.validate()
        guard pythonPath.hasPrefix("/") else { throw AppFailure(message: "Python 실행 파일의 절대 경로를 입력하세요.") }
        for stage in ModelStage.allCases {
            let profile = self[stage]
            guard stage.providers.contains(profile.provider), !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppFailure(message: "\(stage.title): 실행 방식과 모델 이름을 확인하세요.")
            }
            if ["ollama", "openai"].contains(profile.provider) {
                guard let url = URLComponents(string: profile.url), ["http", "https"].contains(url.scheme ?? ""),
                      let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                    throw AppFailure(message: "\(stage.title): 올바른 서버 기본 주소를 입력하세요. API Key는 별도 칸에 넣습니다.")
                }
            }
        }
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoriNote", isDirectory: true)
    }
    static func load() -> AppSettings {
        let url = directory.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: url), var value = try? JSONDecoder().decode(Self.self, from: data) {
            if !FileManager.default.isExecutableFile(atPath: value.pythonPath), let managed = managedPython() { value.pythonPath = managed }
            return value
        }
        var value = Self()
        if let managed = managedPython() { value.pythonPath = managed; return value }
        if let resource = Bundle.main.url(forResource: "runtime", withExtension: "json"),
           let data = try? Data(contentsOf: resource),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let path = json["pythonPath"], FileManager.default.isExecutableFile(atPath: path) { value.pythonPath = path }
        return value
    }
    func save() throws {
        try validate()
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let url = Self.directory.appendingPathComponent("settings.json")
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func managedPython(in directory: URL = Self.directory) -> String? {
        let runtime = directory.appendingPathComponent("runtime", isDirectory: true)
        guard let data = try? Data(contentsOf: runtime.appendingPathComponent("runtime.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let path = json["pythonPath"],
              URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(runtime.standardizedFileURL.path + "/engines/"),
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}

struct EntryPreview: Codable, Identifiable {
    let id: String
    let title: String
    let kind: String
    let created: String
    let preview: String
    let summarized: Int
    let audio_path: String
}

struct Segment: Codable, Identifiable {
    var id: String { "\(start)-\(end)" }
    let start: Double
    let end: Double
    var speaker: String
    var text: String
}

struct Entry: Codable, Identifiable {
    let id: String
    var title: String
    let kind: String
    let created: String
    var text: String
    var segments: [Segment]
    var summary: String
    let audio_path: String
    let warning: String
}

struct Source: Codable, Identifiable {
    var id: Int { number }
    let number: Int
    let entry_id: String
    let title: String
    let text: String
    let ordinal: Int
    let score: Double
}

struct Answer: Codable {
    let answer: String
    let sources: [Source]
}

struct Check: Codable, Identifiable {
    var id: String { name }
    let name: String
    let ok: Bool
    let detail: String
}

struct AppFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func clockText(_ seconds: Double) -> String {
    let value = max(0, Int(seconds))
    return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
}
