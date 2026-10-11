import Foundation
import Security

/// API Key는 설정 파일에 쓰지 않고 macOS 키체인에 보관합니다.
enum Keychain {
    static let names = ["asrKey", "speakerKey", "summaryKey", "qaKey", "embeddingKey", "hfToken"]
    static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.sorinote.local", kSecAttrAccount as String: name]
    }

    static func read(_ name: String) throws -> String {
        var parameters = query(name)
        parameters[kSecReturnData as String] = true
        parameters[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(parameters as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AppFailure(message: "키체인에서 인증 정보를 읽지 못했습니다(\(status)). 접근 허용 상태를 확인하세요.")
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ value: String, name: String) throws {
        let parameters = query(name)
        if value.isEmpty {
            let status = SecItemDelete(parameters as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AppFailure(message: "키체인 항목을 삭제하지 못했습니다(\(status)).")
            }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(parameters as CFDictionary,
                                  [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var new = parameters
            new[kSecValueData as String] = data
            new[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(new as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw AppFailure(message: "키체인에 저장하지 못했습니다(\(status)).")
        }
    }
}
