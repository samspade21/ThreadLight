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

public struct OAuthAttempt: Sendable {
    public let pkce: PKCEPair
    public let state: String
    public let authorizationURL: URL

    public static func make(clientID: String, redirectURI: String = "threadlight://oauth/callback") throws -> OAuthAttempt {
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ThreadLightError.invalidConfiguration("Enter the client ID from your organization-owned Slack app.")
        }
        let pkce = try PKCEPair.generate()
        let statePair = try PKCEPair.generate(byteCount: 32)
        var components = URLComponents(string: "https://slack.com/oauth/v2_user/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "scope", value: "admin.legal_holds:read"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: statePair.verifier),
        ]
        guard let url = components.url else {
            throw ThreadLightError.invalidConfiguration("Could not create the Slack authorization URL.")
        }
        return .init(pkce: pkce, state: statePair.verifier, authorizationURL: url)
    }

    public func authorizationCode(from callbackURL: URL) throws -> String {
        guard callbackURL.scheme?.lowercased() == "threadlight",
              callbackURL.host?.lowercased() == "oauth",
              callbackURL.path == "/callback" else {
            throw ThreadLightError.authentication("Slack returned to an unexpected callback URL.")
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
