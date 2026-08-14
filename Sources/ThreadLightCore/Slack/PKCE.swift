import CryptoKit
import Foundation
import Security

public struct PKCEPair: Equatable, Sendable {
    public let verifier: String
    public let challenge: String

    public static func generate(byteCount: Int = 48) throws -> PKCEPair {
        guard byteCount >= 32 && byteCount <= 96 else {
            throw ThreadLightError.invalidConfiguration("PKCE entropy must be between 32 and 96 bytes.")
        }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        let verifier = Data(bytes).base64URLEncodedString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        return .init(verifier: verifier, challenge: challenge)
    }
}

public extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum SlackOAuth {
    /// RFC 2606 reserves `.invalid`, so this host can never resolve or be registered by anyone.
    /// Slack classifies it as a web redirect — which its install path requires for the bot scope —
    /// while the authorization code can only ever land in the user's own browser address bar,
    /// where they copy it back into ThreadLight. The PKCE verifier never leaves this Mac,
    /// so the code is useless to anything that merely observes the URL.
    public static let redirectURI = "https://callback.threadlight.invalid/oauth/callback"
    public static let requiredUserScopes: Set<String> = ["admin.legal_holds:read", "users:read", "users:read.email", "reactions:read", "emoji:read"]
    public static let requestedUserScopes = "admin.legal_holds:read,users:read,users:read.email,reactions:read,emoji:read"
}

public struct OAuthAttempt: Sendable {
    public let pkce: PKCEPair
    public let state: String
    public let redirectURI: String
    public let authorizationURL: URL

    public static func make(clientID: String, redirectURI: String = SlackOAuth.redirectURI) throws -> OAuthAttempt {
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ThreadLightError.invalidConfiguration("Enter the client ID from your organization-owned Slack app.")
        }
        let pkce = try PKCEPair.generate()
        let statePair = try PKCEPair.generate(byteCount: 32)
        // Slack routes admin-scoped apps through its install path, which rejects the request
        // unless a bot scope is present (`no_bot_scopes_requested`). The bot token this issues
        // is ignored; ThreadLight only keeps the authed_user token.
        var components = URLComponents(string: "https://slack.com/oauth/v2/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "scope", value: "team:read"),
            .init(name: "user_scope", value: SlackOAuth.requestedUserScopes),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: statePair.verifier),
        ]
        guard let url = components.url else {
            throw ThreadLightError.invalidConfiguration("Could not create the Slack authorization URL.")
        }
        return .init(pkce: pkce, state: statePair.verifier, redirectURI: redirectURI, authorizationURL: url)
    }

    public func authorizationCode(from callbackURL: URL) throws -> String {
        guard let expected = URL(string: redirectURI),
              callbackURL.scheme?.lowercased() == expected.scheme?.lowercased(),
              callbackURL.host?.lowercased() == expected.host?.lowercased(),
              callbackURL.path == expected.path else {
            throw ThreadLightError.authentication("That address is not the Slack sign-in callback. Copy the entire address from the browser page that appears after you approve ThreadLight.")
        }
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw ThreadLightError.authentication("Slack returned an unreadable callback URL.")
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard values[item.name] == nil else {
                throw ThreadLightError.authentication("Slack returned a duplicate OAuth callback value. Close the browser and try again.")
            }
            values[item.name] = item.value ?? ""
        }
        guard values["state"] == state else {
            throw ThreadLightError.authentication("OAuth state did not match. Close the browser and try again.")
        }
        if let error = values["error"], !error.isEmpty {
            throw SlackErrorMapper.error(for: error)
        }
        guard let code = values["code"], !code.isEmpty else {
            throw ThreadLightError.authentication("Slack did not return an authorization code.")
        }
        return code
    }
}
