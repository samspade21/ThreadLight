import CryptoKit
import Foundation
import Security

public actor KeychainStore {
    public static let shared = KeychainStore()
    private let service: String
    private let useVolatileOAuthStorage: Bool
    #if THREADLIGHT_DEVELOPMENT
    private var volatileValues: [String: Data] = [:]
    #endif

    public init(
        service: String = "dev.threadlight.credentials",
        useVolatileOAuthStorage: Bool = false
    ) {
        self.service = service
        self.useVolatileOAuthStorage = useVolatileOAuthStorage
    }

    public func save(_ data: Data, account: String, accessControl: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) throws {
        #if THREADLIGHT_DEVELOPMENT
        if account.hasPrefix("slack.oauth."), useVolatileOAuthStorage {
            volatileValues[account] = data
            return
        }
        if !account.hasPrefix("slack.oauth.") {
            let url = try developmentURL(account: account)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return
        }
        #endif
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: accessControl,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError(status: updateStatus) }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    public func load(account: String) throws -> Data? {
        #if THREADLIGHT_DEVELOPMENT
        if account.hasPrefix("slack.oauth."), useVolatileOAuthStorage { return volatileValues[account] }
        if !account.hasPrefix("slack.oauth.") {
            let url = try developmentURL(account: account)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        }
        #endif
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return data
    }

    public func delete(account: String) throws {
        #if THREADLIGHT_DEVELOPMENT
        if account.hasPrefix("slack.oauth."), useVolatileOAuthStorage {
            volatileValues.removeValue(forKey: account)
            return
        }
        if !account.hasPrefix("slack.oauth.") {
            let url = try developmentURL(account: account)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        #endif
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    public func loadOrCreateRandomKey(account: String, count: Int = 32) throws -> Data {
        if let existing = try load(account: account) { return existing }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        let data = Data(bytes)
        try save(data, account: account)
        return data
    }

    #if THREADLIGHT_DEVELOPMENT
    private func developmentURL(account: String) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "ThreadLight/DevelopmentOnlyKeys", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let digest = SHA256.hash(data: Data("\(service):\(account)".utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: digest + ".key")
    }
    #endif
}

public struct KeychainError: LocalizedError, Sendable {
    public let status: OSStatus
    public var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}
