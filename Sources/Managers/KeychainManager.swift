import Foundation
import Security

actor KeychainManager {
    private let service = "com.quantswarm.alphazero.credentials"
    private let account = "primary"

    func save(data: Data) throws {
        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryAny,
            &accessError
        ) else {
            let error = accessError?.takeRetainedValue()
            throw QuantSwarmError.persistence(error?.localizedDescription ?? "Access Control non disponibile")
        }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessControl as String: accessControl,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw QuantSwarmError.persistence("SecItemAdd: \(status)")
        }
    }

    func read(prompt: String = "Sblocca QuantSwarm con Face ID") throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseOperationPrompt as String: prompt
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else {
            throw QuantSwarmError.credentialsMissing
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw QuantSwarmError.persistence("SecItemCopyMatching: \(status)")
        }
        return data
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw QuantSwarmError.persistence("SecItemDelete: \(status)")
        }
    }
}
