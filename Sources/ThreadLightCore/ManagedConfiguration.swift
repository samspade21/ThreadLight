import CryptoKit
import Foundation

public struct ManagedConfiguration: Equatable, Sendable {
    public static let applicationBundleID = "dev.threadlight.app"
    public static let configurationVersion = 3

    public enum Key {
        public static let version = "ThreadLightConfigurationVersion"
        public static let slackClientID = "ThreadLightSlackClientID"
        public static let organizationName = "ThreadLightOrganizationName"
        public static let enterpriseDomain = "ThreadLightEnterpriseDomain"
        public static let expectedOrganizationID = "ThreadLightExpectedOrganizationID"
        public static let redirectURI = "ThreadLightOAuthRedirectURI"
        public static let requiredUserScopes = "ThreadLightRequiredUserScopes"
        public static let retentionDays = "ThreadLightRetentionDays"
    }

    public let slackClientID: String
    public let organizationName: String
    public let enterpriseDomain: String
    public let expectedOrganizationID: String
    public let retentionDays: Int

    public init(
        slackClientID: String,
        organizationName: String,
        enterpriseDomain: String,
        expectedOrganizationID: String,
        retentionDays: Int
    ) throws {
        let clientID = slackClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = enterpriseDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        let organizationID = expectedOrganizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !name.isEmpty, !domain.isEmpty, !organizationID.isEmpty else {
            throw ThreadLightError.invalidConfiguration("The MDM profile requires the Slack client ID and complete Enterprise organization identity.")
        }
        guard (1...3650).contains(retentionDays) else {
            throw ThreadLightError.invalidConfiguration("MDM retention days must be between 1 and 3650.")
        }
        self.slackClientID = clientID
        self.organizationName = name
        self.enterpriseDomain = domain
        self.expectedOrganizationID = organizationID
        self.retentionDays = retentionDays
    }

    public static func installed(defaults: UserDefaults = .standard) -> ManagedConfiguration? {
        guard defaults.objectIsForced(forKey: Key.slackClientID),
              defaults.objectIsForced(forKey: Key.organizationName),
              defaults.objectIsForced(forKey: Key.enterpriseDomain),
              defaults.objectIsForced(forKey: Key.expectedOrganizationID),
              defaults.string(forKey: Key.redirectURI) == SlackOAuth.redirectURI,
              Set(defaults.stringArray(forKey: Key.requiredUserScopes) ?? []) == SlackOAuth.requiredUserScopes,
              defaults.integer(forKey: Key.version) == configurationVersion else { return nil }
        return try? .init(
            slackClientID: defaults.string(forKey: Key.slackClientID) ?? "",
            organizationName: defaults.string(forKey: Key.organizationName) ?? "",
            enterpriseDomain: defaults.string(forKey: Key.enterpriseDomain) ?? "",
            expectedOrganizationID: defaults.string(forKey: Key.expectedOrganizationID) ?? "",
            retentionDays: defaults.integer(forKey: Key.retentionDays)
        )
    }

    public func profileData() throws -> Data {
        var settings: [String: Any] = [
            Key.version: Self.configurationVersion,
            Key.slackClientID: slackClientID,
            Key.organizationName: organizationName,
            Key.enterpriseDomain: enterpriseDomain,
            Key.expectedOrganizationID: expectedOrganizationID,
            Key.redirectURI: SlackOAuth.redirectURI,
            Key.requiredUserScopes: SlackOAuth.requiredUserScopes.sorted(),
            Key.retentionDays: retentionDays,
        ]
        // Keep profile generation closed to accidental secret-bearing additions.
        settings = settings.filter { !$0.key.localizedCaseInsensitiveContains("secret") && !$0.key.localizedCaseInsensitiveContains("token") }

        let profileID = "dev.threadlight.app.mdm.\(stableSuffix)"
        let preferencePayload: [String: Any] = [
            "PayloadType": "com.apple.ManagedClient.preferences",
            "PayloadVersion": 1,
            "PayloadIdentifier": "\(profileID).preferences",
            "PayloadUUID": stableUUID(namespace: "preferences"),
            "PayloadDisplayName": "ThreadLight Managed Settings",
            "PayloadContent": [
                Self.applicationBundleID: [
                    "Forced": [["mcx_preference_settings": settings]],
                ],
            ],
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": profileID,
            "PayloadUUID": stableUUID(namespace: "profile"),
            "PayloadDisplayName": "ThreadLight Settings",
            "PayloadDescription": "Managed public settings for ThreadLight. Each person signs in to Slack on this Mac.",
            "PayloadOrganization": organizationName,
            "PayloadScope": "System",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [preferencePayload],
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    private var stableSuffix: String {
        SHA256.hash(data: Data(enterpriseDomain.lowercased().utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }

    private func stableUUID(namespace: String) -> String {
        let bytes = Array(SHA256.hash(data: Data("threadlight:\(namespace):\(enterpriseDomain.lowercased())".utf8)).prefix(16))
        return String(format: "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X", arguments: bytes.map { $0 })
    }
}
