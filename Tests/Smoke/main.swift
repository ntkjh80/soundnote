import Foundation

// Command Line Tools에는 XCTest가 없을 수 있어, 핵심 연결 검사를 별도 실행 파일로도 제공합니다.
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw AppFailure(message: message) }
}

do {
    let config = AppSettings()
    try require(!config.allowRemote && !config.diarization, "기본 개인정보 설정 오류")
    try require(config.embedding.model == "google/embeddinggemma-2", "임베딩 기본값 오류")
    try require(config.asr.model == "mlx-community/whisper-large-v3-turbo" && config.summary.model == "gemma4:e4b", "기존 기본값 변경됨")
    let legacy = Data(#"{"asrModel":"custom/whisper","embedding":{"provider":"ollama","url":"http://127.0.0.1:11434","model":"embeddinggemma:300m"}}"#.utf8)
    let migrated = try JSONDecoder().decode(AppSettings.self, from: legacy)
    try require(migrated.embedding.model == "google/embeddinggemma-2" && migrated.asr.model == "custom/whisper", "기존 설정 이전 실패")
    let customized = Data(#"{"embedding":{"provider":"openai","url":"http://localhost:1234/v1","model":"my-model"},"qa":{"model":"my-chat"}}"#.utf8)
    let preserved = try JSONDecoder().decode(AppSettings.self, from: customized)
    try require(preserved.embedding.model == "my-model" && preserved.qa.model == "my-chat", "사용자 지정 모델 손실")
    var changed = config
    for stage in ModelStage.allCases {
        changed[stage] = ModelProfile(provider: "openai", url: "http://127.0.0.1:1234/v1", model: stage.rawValue + "-custom")
    }
    changed.audio.source = .both
    changed.audio.microphoneID = "test-device-uid"
    changed.audio.systemGain = 0.8
    try changed.validate()
    let persisted = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(changed))
    try require(persisted == changed, "단계별 모델 저장·복원 실패")
    changed.embedding = ModelProfile(model: "embeddinggemma:300m")
    let kept = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(changed))
    try require(kept.embedding.model == "embeddinggemma:300m", "버전 2 사용자 선택을 기본값으로 덮어씀")
    try require(config.audio.source == .microphone, "기존 녹음 기본값 변경됨")
    try require(migrated.audio == AudioSettings(), "예전 설정에 음성 기본값 추가 실패")
    let data = try JSONEncoder().encode(config)
    let encoded = String(decoding: data, as: UTF8.self)
    try require(!encoded.contains("Key") && !encoded.contains("Token"), "일반 설정에 인증 정보가 포함됨")
    try require(clockText(3661.9) == "01:01:01", "시간 표시 오류")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let request: [String: Any] = ["action": "create", "dataDir": folder.path,
                                 "title": "통합 검사", "text": "금요일까지 문서를 작성합니다."]
    let worker = WorkerClient()
    let response = try worker.execute(python: "/usr/bin/python3",
        request: JSONSerialization.data(withJSONObject: request), progress: { print($0) })
    let entry = try JSONDecoder().decode(Entry.self, from: response)
    try require(entry.title == "통합 검사", "Swift → Python → SQLite 연결 오류")
    let get = try WorkerClient().execute(python: "/usr/bin/python3",
        request: JSONSerialization.data(withJSONObject: ["action": "get", "id": entry.id, "dataDir": folder.path]),
        progress: { print($0) })
    let loaded = try JSONDecoder().decode(Entry.self, from: get)
    try require(loaded.text == entry.text, "저장한 원문을 다시 읽지 못함")
    let cancelled = WorkerClient()
    cancelled.cancel()
    do {
        _ = try cancelled.execute(python: "/usr/bin/python3", request: data, progress: { _ in })
        throw AppFailure(message: "실행 전 취소가 적용되지 않음")
    } catch is CancellationError { }
    print("Swift 단독 검사 통과: 개인정보 기본값, 설정 직렬화, 시간 표시, 워커 저장·조회, 실행 전 취소")
} catch {
    fputs("검사 실패: \(error.localizedDescription)\n", stderr)
    exit(1)
}
