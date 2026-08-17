import Foundation
import Security

enum SupervisorPreferences {
    static let enabledKey = "supervisorEnabled"
    static let modelIDKey = "supervisorModelID"
    static let defaultModelID = "gpt-4.1-mini"
    static let independentEvaluatorEnabledKey = "independentEvaluatorEnabled"
    static let independentEvaluatorModelIDKey = "independentEvaluatorModelID"
    static let defaultIndependentEvaluatorModelID = "gpt-4.1"
}

struct SupervisorPrivatePromptPack {
    let completionReviewSystemPrompt: String
    let independentEvaluatorSystemPrompt: String

    static func load(bundle: Bundle = .module) -> SupervisorPrivatePromptPack? {
        guard let completionReviewSystemPrompt = loadPrompt(
            named: "private-completion-review-system-prompt",
            bundle: bundle
        ), let independentEvaluatorSystemPrompt = loadPrompt(
            named: "private-independent-evaluator-system-prompt",
            bundle: bundle
        ) else { return nil }
        return SupervisorPrivatePromptPack(
            completionReviewSystemPrompt: completionReviewSystemPrompt,
            independentEvaluatorSystemPrompt: independentEvaluatorSystemPrompt
        )
    }

    private static func loadPrompt(named name: String, bundle: Bundle) -> String? {
        guard let url = bundle.url(forResource: name, withExtension: "txt"),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= 8_192,
              let value = String(data: data, encoding: .utf8) else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

enum SupervisorAPIKeyStore {
    private static let service = "com.notchrelay.supervisor"
    private static let account = "openai-api-key"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    static func save(_ value: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            try delete()
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(normalized.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = query
            attributes.forEach { add[$0.key] = $0.value }
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError(status: updateStatus)
        }
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private struct KeychainError: LocalizedError {
        var status: OSStatus
        var errorDescription: String? { "钥匙串操作失败（\(status)）。" }
    }
}
