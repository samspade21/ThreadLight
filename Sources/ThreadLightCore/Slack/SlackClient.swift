import Foundation

public struct OAuthTokenSet: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let enterpriseID: String?
    public let authorizedUserID: String?
    public let scope: String

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        enterpriseID: String? = nil,
        authorizedUserID: String? = nil,
        scope: String
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.enterpriseID = enterpriseID
        self.authorizedUserID = authorizedUserID
        self.scope = scope
    }

    public var needsRefresh: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 120
    }

    public var hasExactThreadLightUserScopes: Bool {
        let scopes = Set(scope.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init))
        return scopes == SlackOAuth.requiredUserScopes
    }
}

public struct SlackUserProfile: Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let email: String?
    public let avatarURL: URL?

    public init(id: String, displayName: String, email: String? = nil, avatarURL: URL?) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.avatarURL = avatarURL
    }
}

public actor SlackTokenVault {
    private let keychain: KeychainStore

    public init(keychain: KeychainStore = .shared) {
        self.keychain = keychain
    }

    public func save(_ tokens: OAuthTokenSet, organizationID: String) async throws {
        let data = try JSONEncoder().encode(tokens)
        try await keychain.save(data, account: "slack.oauth.\(organizationID)")
    }

    public func load(organizationID: String) async throws -> OAuthTokenSet? {
        guard let data = try await keychain.load(account: "slack.oauth.\(organizationID)") else { return nil }
        return try JSONDecoder().decode(OAuthTokenSet.self, from: data)
    }

    public func remove(organizationID: String) async throws {
        try await keychain.delete(account: "slack.oauth.\(organizationID)")
    }
}

public actor SlackOAuthClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func exchange(
        code: String,
        verifier: String,
        clientID: String,
        redirectURI: String = SlackOAuth.redirectURI
    ) async throws -> OAuthTokenSet {
        try await tokenRequest([
            "code": code,
            "client_id": clientID,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
        ])
    }

    public func refresh(refreshToken: String, clientID: String) async throws -> OAuthTokenSet {
        try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> OAuthTokenSet {
        var request = URLRequest(url: URL(string: "https://slack.com/api/oauth.v2.access")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormEncoding.encode(fields)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        try HTTPValidation.requireSuccess(response: response, data: data)

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let object, object["ok"] as? Bool == true else {
            let code = object?["error"] as? String ?? "unknown_error"
            throw SlackErrorMapper.error(for: code)
        }
        let user = object["authed_user"] as? [String: Any]
        guard let accessToken = (user?["access_token"] as? String) ?? (object["access_token"] as? String),
              !accessToken.isEmpty else {
            throw ThreadLightError.authentication("Slack did not issue a user access token.")
        }
        let expires = (user?["expires_in"] as? NSNumber)?.doubleValue ?? (object["expires_in"] as? NSNumber)?.doubleValue
        let enterprise = object["enterprise"] as? [String: Any]
        return .init(
            accessToken: accessToken,
            refreshToken: (user?["refresh_token"] as? String) ?? (object["refresh_token"] as? String),
            expiresAt: expires.map { Date().addingTimeInterval($0) },
            enterpriseID: enterprise?["id"] as? String,
            authorizedUserID: user?["id"] as? String,
            scope: (user?["scope"] as? String) ?? (object["scope"] as? String) ?? ""
        )
    }
}

public protocol LegalHoldClient: Sendable {
    func listPolicies(status: HoldStatus?) async throws -> [LegalHold]
    func policy(id: String) async throws -> LegalHold
    func listCustodians(policyID: String) async throws -> [Custodian]
    func userProfile(userID: String) async throws -> SlackUserProfile
    func reactions(conversationID: String, timestamp: String) async throws -> [EvidenceReaction]
    func emojiURLs() async throws -> [String: URL]
}

public actor RefreshingLegalHoldClient: LegalHoldClient {
    private var tokens: OAuthTokenSet
    private let clientID: String
    private let organizationID: String
    private let tokenVault: SlackTokenVault
    private let oauthClient: SlackOAuthClient
    private let apiSession: URLSession

    public init(
        tokens: OAuthTokenSet,
        clientID: String,
        organizationID: String = "current",
        tokenVault: SlackTokenVault = .init(),
        oauthClient: SlackOAuthClient = .init(),
        apiSession: URLSession = .shared
    ) {
        self.tokens = tokens
        self.clientID = clientID
        self.organizationID = organizationID
        self.tokenVault = tokenVault
        self.oauthClient = oauthClient
        self.apiSession = apiSession
    }

    public func listPolicies(status: HoldStatus?) async throws -> [LegalHold] {
        try await activeClient().listPolicies(status: status)
    }

    public func policy(id: String) async throws -> LegalHold {
        try await activeClient().policy(id: id)
    }

    public func listCustodians(policyID: String) async throws -> [Custodian] {
        try await activeClient().listCustodians(policyID: policyID)
    }

    public func userProfile(userID: String) async throws -> SlackUserProfile {
        try await activeClient().userProfile(userID: userID)
    }

    public func reactions(conversationID: String, timestamp: String) async throws -> [EvidenceReaction] {
        try await activeClient().reactions(conversationID: conversationID, timestamp: timestamp)
    }

    public func emojiURLs() async throws -> [String: URL] {
        try await activeClient().emojiURLs()
    }

    private func activeClient() async throws -> SlackLegalHoldClient {
        guard tokens.hasExactThreadLightUserScopes else { throw Self.invalidScope() }
        if tokens.needsRefresh {
            guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
                throw ThreadLightError.authentication("The Slack session expired and cannot rotate. Reconnect Slack.")
            }
            let refreshed = try await oauthClient.refresh(refreshToken: refreshToken, clientID: clientID)
            tokens = .init(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken ?? refreshToken,
                expiresAt: refreshed.expiresAt,
                enterpriseID: refreshed.enterpriseID ?? tokens.enterpriseID,
                authorizedUserID: refreshed.authorizedUserID ?? tokens.authorizedUserID,
                scope: refreshed.scope.isEmpty ? tokens.scope : refreshed.scope
            )
            guard tokens.hasExactThreadLightUserScopes else { throw Self.invalidScope() }
            try await tokenVault.save(tokens, organizationID: organizationID)
        }
        return SlackLegalHoldClient(accessToken: tokens.accessToken, session: apiSession)
    }

    private static func invalidScope() -> ThreadLightError {
        .authentication("Slack did not grant ThreadLight's five read-only user scopes. Update the Slack app manifest, then reconnect. Keep the installation bot scope team:read.")
    }
}

public actor SlackLegalHoldClient: LegalHoldClient {
    private var accessToken: String
    private let session: URLSession
    private let webSessionTransport: (@Sendable (String, [String: String]) async throws -> Data)?

    public init(accessToken: String, session: URLSession = .shared) {
        self.accessToken = accessToken
        self.session = session
        self.webSessionTransport = nil
    }

    /// Routes every call through a live, cookie-authenticated Slack web session instead of an
    /// OAuth bearer token — for a signed-in person whose own Slack role can use Slack's admin
    /// console (e.g. a Legal Holds Admin) but cannot complete OAuth for `admin.legal_holds:read`,
    /// which Slack restricts to Org Owners regardless of what that person's role otherwise permits.
    /// The transport returns raw JSON `Data` (not `[String: Any]`, which isn't `Sendable`) since it
    /// crosses from a `@MainActor`-isolated web view into this actor.
    public init(webSessionTransport: @Sendable @escaping (String, [String: String]) async throws -> Data) {
        self.accessToken = ""
        self.session = .shared
        self.webSessionTransport = webSessionTransport
    }

    public func replaceAccessToken(_ token: String) {
        accessToken = token
    }

    public func listPolicies(status: HoldStatus? = nil) async throws -> [LegalHold] {
        var cursor: String?
        var seenCursors = Set<String>()
        var pageCount = 0
        var policies: [LegalHold] = []
        repeat {
            pageCount += 1
            guard pageCount <= 10_000 else { throw Self.invalidPagination() }
            var fields = ["limit": "1000"]
            if let cursor, !cursor.isEmpty { fields["cursor"] = cursor }
            if let status { fields["status"] = status.rawValue }
            let object = try await call(method: "admin.legalHold.policies.list", fields: fields)
            let rows = object["policies"] as? [[String: Any]] ?? []
            policies.append(contentsOf: try rows.map(Self.parsePolicy))
            cursor = ((object["response_metadata"] as? [String: Any])?["next_cursor"] as? String)
            if let cursor, !cursor.isEmpty, !seenCursors.insert(cursor).inserted { throw Self.invalidPagination() }
        } while cursor?.isEmpty == false
        return policies.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func policy(id: String) async throws -> LegalHold {
        let object = try await call(method: "admin.legalHold.policies.info", fields: ["policy_id": id])
        guard let row = object["policy"] as? [String: Any] else {
            throw ThreadLightError.slack("Slack returned no policy details.", remediation: "Confirm the hold still exists and reconnect.")
        }
        return try Self.parsePolicy(row)
    }

    public func listCustodians(policyID: String) async throws -> [Custodian] {
        var cursor: String?
        var seenCursors = Set<String>()
        var pageCount = 0
        var custodians: [Custodian] = []
        repeat {
            pageCount += 1
            guard pageCount <= 10_000 else { throw Self.invalidPagination() }
            var fields = ["policy_id": policyID, "limit": "1000"]
            if let cursor, !cursor.isEmpty { fields["cursor"] = cursor }
            let object = try await call(method: "admin.legalHold.entities.list", fields: fields)
            let rows = object["entities"] as? [[String: Any]] ?? []
            custodians.append(contentsOf: rows.compactMap { row in
                guard (row["entity_type"] as? String)?.uppercased() == "USER",
                      let id = row["entity_id"] as? String else { return nil }
                let profile = row["profile"] as? [String: Any]
                let name = (profile?["real_name"] as? String)
                    ?? (profile?["display_name"] as? String)
                    ?? (row["name"] as? String)
                    ?? id
                let avatarURL = ["image_72", "image_192", "image_512", "image_48"]
                    .compactMap { profile?[$0] as? String }
                    .compactMap(URL.init(string:))
                    .first(where: Self.isSlackAvatarURL)
                let deletedAt = (row["date_deleted"] as? NSNumber)?.doubleValue ?? 0
                return Custodian(
                    id: id,
                    holdID: policyID,
                    displayName: name,
                    email: profile?["email"] as? String,
                    avatarURL: avatarURL,
                    isCurrent: deletedAt <= 0
                )
            })
            cursor = ((object["response_metadata"] as? [String: Any])?["next_cursor"] as? String)
            if let cursor, !cursor.isEmpty, !seenCursors.insert(cursor).inserted { throw Self.invalidPagination() }
        } while cursor?.isEmpty == false
        return custodians.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public func userProfile(userID: String) async throws -> SlackUserProfile {
        let object = try await call(method: "users.info", fields: ["user": userID])
        guard let user = object["user"] as? [String: Any],
              let id = user["id"] as? String,
              id == userID else {
            throw ThreadLightError.slack("Slack returned no profile for this user.", remediation: "The user may no longer be visible to the signed-in Slack account.")
        }
        let profile = user["profile"] as? [String: Any]
        let displayName = [profile?["real_name"] as? String, user["real_name"] as? String, profile?["display_name"] as? String, user["name"] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? id
        let avatarURL = ["image_512", "image_192", "image_72", "image_48"]
            .compactMap { profile?[$0] as? String }
            .compactMap(URL.init(string:))
            .first(where: Self.isSlackAvatarURL)
        let email = (profile?["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(id: id, displayName: displayName, email: email?.isEmpty == false ? email : nil, avatarURL: avatarURL)
    }

    public func reactions(conversationID: String, timestamp: String) async throws -> [EvidenceReaction] {
        let object = try await call(
            method: "reactions.get",
            fields: ["channel": conversationID, "timestamp": timestamp, "full": "true"]
        )
        let message = object["message"] as? [String: Any]
        return (message?["reactions"] as? [[String: Any]] ?? []).compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            let users = row["users"] as? [String] ?? []
            let count = max(0, (row["count"] as? NSNumber)?.intValue ?? users.count)
            return .init(name: name, count: count, userIDs: users)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func emojiURLs() async throws -> [String: URL] {
        let object = try await call(method: "emoji.list", fields: ["include_categories": "false"])
        let entries = object["emoji"] as? [String: String] ?? [:]
        var result: [String: URL] = [:]
        for name in entries.keys {
            var visited: Set<String> = []
            if let url = Self.resolveEmojiURL(name: name, entries: entries, visited: &visited) {
                result[name] = url
            }
        }
        return result
    }

    private static func resolveEmojiURL(name: String, entries: [String: String], visited: inout Set<String>) -> URL? {
        guard visited.insert(name).inserted, let value = entries[name] else { return nil }
        if value.hasPrefix("alias:") {
            return resolveEmojiURL(name: String(value.dropFirst("alias:".count)), entries: entries, visited: &visited)
        }
        guard let url = URL(string: value), isSlackImageURL(url) else { return nil }
        return url
    }

    private static func isSlackAvatarURL(_ url: URL) -> Bool {
        isSlackImageURL(url)
    }

    private static func isSlackImageURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "secure.gravatar.com" || host.hasSuffix(".slack-edge.com")
    }

    private func call(method: String, fields: [String: String]) async throws -> [String: Any] {
        let data = try await fetchData(method: method, fields: fields)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ThreadLightError.slack("Slack returned an unreadable response.", remediation: "Try again. If this continues, give sanitized diagnostics to the Slack Admin Role.")
        }
        guard object["ok"] as? Bool == true else {
            throw SlackErrorMapper.error(for: object["error"] as? String ?? "unknown_error")
        }
        return object
    }

    private func fetchData(method: String, fields: [String: String]) async throws -> Data {
        if let webSessionTransport {
            return try await webSessionTransport(method, fields)
        }
        var request = URLRequest(url: URL(string: "https://slack.com/api/\(method)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormEncoding.encode(fields)
        request.timeoutInterval = 45

        var attempt = 0
        while true {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 429, attempt < 3 {
                let retryAfter = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "1") ?? 1
                attempt += 1
                try await Task.sleep(for: .seconds(min(max(retryAfter, 1), 30)))
                continue
            }
            try HTTPValidation.requireSuccess(response: response, data: data)
            return data
        }
    }

    private static func parsePolicy(_ row: [String: Any]) throws -> LegalHold {
        guard let id = row["id"] as? String else {
            throw ThreadLightError.slack("Slack returned a hold without an ID.", remediation: "Contact Slack Support with sanitized diagnostics.")
        }
        let status = HoldStatus(rawValue: (row["status"] as? String) ?? "") ?? .unknown
        let restrictions = Set((row["restrictions"] as? [String] ?? ["NO_RESTRICTION"]).compactMap(HoldRestriction.init(rawValue:)))
        let created = epoch(row["date_created"]) ?? .distantPast
        return LegalHold(
            id: id,
            organizationID: (row["team_id"] as? String) ?? "unknown",
            name: (row["name"] as? String) ?? "Unnamed hold",
            summary: (row["description"] as? String) ?? "",
            status: status,
            restrictions: restrictions.isEmpty ? [.noRestriction] : restrictions,
            createdAt: created,
            updatedAt: epoch(row["date_updated"]) ?? created,
            startAt: positiveEpoch(row["date_policy_start"]),
            endAt: positiveEpoch(row["date_policy_end"])
        )
    }

    private static func epoch(_ value: Any?) -> Date? {
        guard let seconds = (value as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func positiveEpoch(_ value: Any?) -> Date? {
        guard let date = epoch(value), date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }

    private static func invalidPagination() -> ThreadLightError {
        .slack(
            "Slack returned invalid Legal Holds pagination.",
            remediation: "Try again. If this repeats, provide sanitized diagnostics to the Slack Admin Role or Slack Support; ThreadLight stopped to avoid an incomplete or endless result set."
        )
    }
}

enum FormEncoding {
    static func encode(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return fields.sorted(by: { $0.key < $1.key }).map { key, value in
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(escapedKey)=\(escapedValue)"
        }.joined(separator: "&").data(using: .utf8) ?? Data()
    }
}

enum HTTPValidation {
    static func requireSuccess(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ThreadLightError.slack(
                "Slack returned HTTP \(status).",
                remediation: status == 403 ? "Your Slack account cannot read legal holds. Ask a Slack administrator to check your access and the ThreadLight app installation." : "Try again after checking Slack status."
            )
        }
    }
}

public enum SlackErrorMapper {
    public static func error(for code: String) -> ThreadLightError {
        switch code {
        case "oauth_authorization_url_mismatch", "cannot_install_an_org_installed_app":
            .slack("Slack rejected the authorization request shape.", remediation: "Update ThreadLight and sign in again from Settings.")
        case "no_bot_scopes_requested":
            .slack("The Slack app is missing the bot scope required for authorization.", remediation: "Restore the app manifest's bot_user section and bot scope team:read, save it in Slack app settings, then sign in again.")
        case "missing_scope", "unknown_method":
            .slack("Required Slack read access is missing.", remediation: "Use ThreadLight's manifest with admin.legal_holds:read, users:read, users:read.email, reactions:read, and emoji:read, then reconnect.")
        case "legal_hold_not_found":
            .slack("The legal hold no longer exists or is unavailable.", remediation: "Confirm the hold in Slack using Legal's Legal Holds administrator account. ThreadLight will not search or export it without a live match.")
        case "not_an_admin":
            .slack("Your Slack account cannot read legal holds.", remediation: "Sign in with an account that has access to Slack legal holds.")
        case "not_an_owner":
            .slack("Only a Slack organization owner can complete this installation.", remediation: "Ask an organization owner to install ThreadLight, then try again.")
        case "not_allowed_token_type":
            .slack("Slack rejected this authorization type for Legal Holds.", remediation: "Confirm the internal app is installed at Enterprise level and Legal is using the Legal Holds administrator account. If Slack still rejects it, the Phase 0 authorization gate has failed.")
        case "enterprise_is_restricted", "team_access_not_granted", "invalid_team_for_non_distributed_app":
            .slack("ThreadLight is not installed for the Slack organization.", remediation: "Open the app's Settings → Install App page and choose Install to Organization.")
        case "token_revoked", "invalid_auth", "account_inactive":
            .slack("Your Slack sign-in is no longer valid.", remediation: "Sign in to Slack again with an account that can read legal holds.")
        case "access_denied", "user_scope_not_granted":
            .slack("Slack sign-in was not approved.", remediation: "Try again and allow ThreadLight to read legal holds.")
        case "bad_redirect_uri":
            .slack("The OAuth callback does not match.", remediation: "Set the Slack app redirect URL to \(SlackOAuth.redirectURI). ThreadLight supplies PKCE automatically.")
        case "pkce_not_allowed":
            .slack("PKCE is not enabled for this Slack app.", remediation: "Open OAuth & Permissions for the organization-owned app, enable PKCE, confirm \(SlackOAuth.redirectURI), and try again.")
        case "invalid_code_verifier":
            .slack("Slack rejected the secure sign-in proof.", remediation: "Start a new sign-in from ThreadLight. If it repeats, confirm PKCE is enabled for the Slack app.")
        case "ratelimited":
            .slack("Slack is temporarily rate limiting requests.", remediation: "Wait a minute and try again.")
        default:
            .slack("Slack could not complete the request (\(code)).", remediation: "Open setup readiness and verify every administrator step.")
        }
    }
}
