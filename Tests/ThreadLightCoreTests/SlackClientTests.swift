import Foundation
import Testing
@testable import ThreadLightCore

@Suite(.serialized)
struct SlackClientTests {
    @Test func oauthExchangeUsesPKCEWithoutClientSecretAndParsesRotatingTokens() async throws {
        let session = MockURLProtocol.session { request in
            #expect(request.url?.path == "/api/oauth.v2.user.access")
            let body = String(data: try Self.bodyData(for: request), encoding: .utf8) ?? ""
            #expect(body.contains("code_verifier=verifier"))
            #expect(!body.contains("client_secret"))
            return Self.response(
                for: request,
                json: #"{"ok":true,"access_token":"xoxp-test","refresh_token":"refresh-test","expires_in":3600,"authed_user":{"id":"U1","scope":"admin.legal_holds:read"},"enterprise":{"id":"E1"}}"#
            )
        }
        let tokens = try await SlackOAuthClient(session: session).exchange(code: "code", verifier: "verifier", clientID: "client")
        #expect(tokens.enterpriseID == "E1")
        #expect(tokens.refreshToken == "refresh-test")
        #expect(tokens.scope == "admin.legal_holds:read")
        #expect(tokens.hasExactLegalHoldsReadScope)
    }

    @Test func tokenWithUnexpectedScopeIsRejectedBeforeLegalHoldRequest() async {
        let session = MockURLProtocol.session { request in
            Issue.record("No Slack request should be made with an over-scoped token: \(request.url?.absoluteString ?? "unknown")")
            return Self.response(for: request, json: #"{"ok":true,"policies":[]}"#)
        }
        let client = RefreshingLegalHoldClient(
            tokens: .init(accessToken: "token", enterpriseID: "E1", scope: "admin.legal_holds:read,chat:write"),
            clientID: "client",
            apiSession: session
        )
        await #expect(throws: ThreadLightError.self) {
            _ = try await client.listPolicies(status: nil)
        }
    }

    @Test func legalHoldClientListsPoliciesAndCustodians() async throws {
        let session = MockURLProtocol.session { request in
            #expect(request.url?.path.contains("/admin.legalHold.") == true)
            if request.url?.path.hasSuffix("policies.list") == true {
                return Self.response(
                    for: request,
                    json: #"{"ok":true,"policies":[{"id":"H1","team_id":"E1","name":"Case","description":"Review","status":"ACTIVE","restrictions":["NO_RESTRICTION"],"date_created":1785542400,"date_updated":1785542500}],"response_metadata":{"next_cursor":""}}"#
                )
            }
            return Self.response(
                for: request,
                json: #"{"ok":true,"entities":[{"id":"He01RA72HZL7","team_id":"E1","policy_id":"H1","entity_type":"USER","entity_id":"U1","date_created":1785542400,"date_deleted":0}],"response_metadata":{"next_cursor":""}}"#
            )
        }
        let client = SlackLegalHoldClient(accessToken: "token", session: session)
        let holds = try await client.listPolicies(status: nil)
        #expect(holds.map(\.id) == ["H1"])
        let custodians = try await client.listCustodians(policyID: "H1")
        #expect(custodians.map(\.id) == ["U1"])
        #expect(custodians.map(\.displayName) == ["U1"])
    }

    @Test func revokedTokenBecomesActionableError() async {
        let session = MockURLProtocol.session { request in
            Self.response(for: request, json: #"{"ok":false,"error":"token_revoked"}"#)
        }
        do {
            _ = try await SlackLegalHoldClient(accessToken: "revoked", session: session).listPolicies(status: nil)
            Issue.record("Expected token_revoked to fail")
        } catch let ThreadLightError.slack(message, remediation) {
            #expect(message.contains("no longer valid"))
            #expect(remediation.contains("Sign in to Slack again"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func repeatedPaginationCursorFailsClosed() async {
        let session = MockURLProtocol.session { request in
            Self.response(
                for: request,
                json: #"{"ok":true,"policies":[],"response_metadata":{"next_cursor":"same-cursor"}}"#
            )
        }
        do {
            _ = try await SlackLegalHoldClient(accessToken: "token", session: session).listPolicies(status: nil)
            Issue.record("Expected repeated cursor to fail")
        } catch let ThreadLightError.slack(message, remediation) {
            #expect(message.contains("pagination"))
            #expect(remediation.contains("stopped"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func accessAndOrganizationInstallErrorsUsePlainEnglish() {
        guard case let .slack(adminMessage, adminRemediation) = SlackErrorMapper.error(for: "not_an_admin") else {
            Issue.record("Expected Legal Holds administrator error")
            return
        }
        #expect(adminMessage.contains("cannot read legal holds"))
        #expect(adminRemediation.contains("account that has access"))
        guard case let .slack(ownerMessage, ownerRemediation) = SlackErrorMapper.error(for: "not_an_owner") else {
            Issue.record("Expected Org Owner installation error")
            return
        }
        #expect(ownerMessage.contains("organization owner"))
        #expect(ownerRemediation.contains("install ThreadLight"))
        guard case let .slack(message, remediation) = SlackErrorMapper.error(for: "enterprise_is_restricted") else {
            Issue.record("Expected enterprise install error")
            return
        }
        #expect(message.contains("not installed"))
        #expect(remediation.contains("Install to Organization"))
    }

    @Test func legalHoldSpecificErrorsFailClosedWithGuidance() {
        for code in ["missing_scope", "unknown_method"] {
            guard case let .slack(message, remediation) = SlackErrorMapper.error(for: code) else {
                Issue.record("Expected missing Legal Holds access error")
                continue
            }
            #expect(message.contains("read access"))
            #expect(remediation.contains("reconnect"))
        }
        guard case let .slack(message, remediation) = SlackErrorMapper.error(for: "legal_hold_not_found") else {
            Issue.record("Expected missing hold error")
            return
        }
        #expect(message.contains("no longer exists"))
        #expect(remediation.contains("will not search or export"))
    }

    @Test func organizationInstallMissingBotScopeHasExactFix() {
        guard case let .slack(message, remediation) = SlackErrorMapper.error(for: "no_bot_scopes_requested") else {
            Issue.record("Expected organization install scope error")
            return
        }
        #expect(message.contains("bot scope"))
        #expect(remediation.contains("Settings → Install App"))
        #expect(remediation.contains("Install to Organization"))
    }

    @Test func longRunningClientRotatesExpiredTokenBeforeLegalHoldRequest() async throws {
        let session = MockURLProtocol.session { request in
            if request.url?.path == "/api/oauth.v2.user.access" {
                let body = String(data: try Self.bodyData(for: request), encoding: .utf8) ?? ""
                #expect(body.contains("grant_type=refresh_token"))
                #expect(body.contains("refresh_token=refresh-old"))
                return Self.response(
                    for: request,
                    json: #"{"ok":true,"access_token":"xoxp-new","refresh_token":"refresh-new","expires_in":3600,"authed_user":{"id":"U1","scope":"admin.legal_holds:read"},"enterprise":{"id":"E1"}}"#
                )
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer xoxp-new")
            return Self.response(for: request, json: #"{"ok":true,"policies":[],"response_metadata":{"next_cursor":""}}"#)
        }
        let vault = SlackTokenVault(keychain: KeychainStore(service: "dev.threadlight.tests.\(UUID())"))
        let client = RefreshingLegalHoldClient(
            tokens: .init(
                accessToken: "xoxp-old",
                refreshToken: "refresh-old",
                expiresAt: Date().addingTimeInterval(-60),
                enterpriseID: "E1",
                authorizedUserID: "U1",
                scope: "admin.legal_holds:read"
            ),
            clientID: "client",
            tokenVault: vault,
            oauthClient: SlackOAuthClient(session: session),
            apiSession: session
        )

        #expect(try await client.listPolicies(status: nil).isEmpty)
        let stored = try #require(try await vault.load(organizationID: "current"))
        #expect(stored.accessToken == "xoxp-new")
        #expect(stored.refreshToken == "refresh-new")
    }

    private static func response(for request: URLRequest, json: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (response, Data(json.utf8))
    }

    private static func bodyData(for request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    private nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func session(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
        self.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
