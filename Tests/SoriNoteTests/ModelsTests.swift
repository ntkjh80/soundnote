import XCTest
@testable import SoriNote

final class ModelsTests: XCTestCase {
    func testDefaultPrivacyBoundary() throws {
        let settings = AppSettings()
        XCTAssertFalse(settings.allowRemote)
        XCTAssertFalse(settings.diarization)
        let data = try JSONEncoder().encode(settings)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(encoded.contains("Token"))
        XCTAssertFalse(encoded.contains("Key"))
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data).summary.model, "gemma4:e4b")
    }

    func testModelMigrationAndRoundTrip() throws {
        let old = Data(#"{"asrModel":"custom/whisper","embedding":{"provider":"ollama","url":"http://127.0.0.1:11434","model":"embeddinggemma:300m"}}"#.utf8)
        let migrated = try JSONDecoder().decode(AppSettings.self, from: old)
        XCTAssertEqual(migrated.embedding.model, "google/embeddinggemma-2")
        XCTAssertEqual(migrated.asr.model, "custom/whisper")
        var value = AppSettings()
        for stage in ModelStage.allCases {
            value[stage] = ModelProfile(provider: "openai", url: "http://localhost:1234/v1", model: stage.rawValue)
        }
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(value)), value)
        value.embedding = ModelProfile(model: "embeddinggemma:300m")
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(value)).embedding, value.embedding)
    }

    func testTimeFormatting() {
        XCTAssertEqual(clockText(-10), "00:00:00")
        XCTAssertEqual(clockText(3661.9), "01:01:01")
    }

    func testWorkerProtocolPersistence() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let request: [String: Any] = ["action": "create", "dataDir": folder.path,
            "title": "테스트 회의", "text": "금요일까지 초안을 작성합니다."]
        let result = try WorkerClient().execute(python: "/usr/bin/python3",
            request: JSONSerialization.data(withJSONObject: request), progress: { _ in })
        let entry = try JSONDecoder().decode(Entry.self, from: result)
        XCTAssertEqual(entry.title, "테스트 회의")
        let listing = try WorkerClient().execute(python: "/usr/bin/python3",
            request: JSONSerialization.data(withJSONObject: ["action": "list", "dataDir": folder.path]), progress: { _ in })
        struct Listing: Decodable { let entries: [EntryPreview] }
        XCTAssertEqual(try JSONDecoder().decode(Listing.self, from: listing).entries.first?.id, entry.id)
    }
}
