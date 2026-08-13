import Foundation
import Testing
@testable import ThreadLightCore

@Test func pkceCreatesHighEntropyPair() throws {
    let pair = try PKCEPair.generate()
    #expect(pair.verifier.count >= 43)
    #expect(pair.challenge.count == 43)
    #expect(!pair.verifier.contains("="))
}

@Test func bundledSlackManifestEnablesPKCEForCustomCallback() {
    #expect(SlackAppManifest.filename == "threadlight-slack-app-manifest.yaml")
    #expect(SlackAppManifest.createAppURL.absoluteString == "https://api.slack.com/apps")
    #expect(SlackAppManifest.template.hasPrefix("_metadata:\n  major_version: 1\n"))
    #expect(SlackAppManifest.template.contains("threadlight://oauth/callback"))
    #expect(SlackAppManifest.template.contains("pkce_enabled: true"))
    #expect(SlackAppManifest.template.contains("admin.legal_holds:read"))
    #expect(SlackAppManifest.template.contains("bot:\n      - team:read"))
    #expect(SlackAppManifest.template.contains("bot_user:\n    display_name: ThreadLight\n    always_online: false"))
    #expect(!SlackAppManifest.template.contains("token_rotation_enabled"))
    #expect(!SlackAppManifest.template.contains("client_secret"))
    #expect(!SlackAppManifest.template.contains(":write"))
}

@Test func storageNamespacesAreStableAndOrganizationIsolated() {
    let first = ThreadLightBuild.storageNamespace(organizationID: "E123")
    #expect(first == ThreadLightBuild.storageNamespace(organizationID: "E123"))
    #expect(first != ThreadLightBuild.storageNamespace(organizationID: "E456"))
    #expect(!first.contains("/"))
    #expect(first.contains(ThreadLightBuild.isDevelopment ? "development" : "production"))
    #expect(ThreadLightBuild.isValidStorageNamespace(first))
    #expect(!ThreadLightBuild.isValidStorageNamespace("../../outside"))
    #expect(!ThreadLightBuild.isValidStorageNamespace(String(repeating: "a", count: 81)))
}

@Test func defaultStorageRemovalRejectsUnsafeNamespaces() async {
    await #expect(throws: ThreadLightError.self) {
        try await EvidenceStore.removeDefault(organizationID: "../../outside")
    }
    await #expect(throws: ThreadLightError.self) {
        try await ResourceVault.removeDefault(organizationID: "../outside")
    }
}

@Test func callbackRequiresMatchingStateAndRoute() throws {
    let attempt = try OAuthAttempt.make(clientID: "123.456")
    #expect(attempt.authorizationURL.path == "/oauth/v2_user/authorize")
    let authorizationItems = URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(authorizationItems.first(where: { $0.name == "scope" })?.value == "admin.legal_holds:read")
    #expect(authorizationItems.first(where: { $0.name == "user_scope" }) == nil)
    #expect(authorizationItems.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
    let good = URL(string: "threadlight://oauth/callback?code=abc&state=\(attempt.state)")!
    #expect(try attempt.authorizationCode(from: good) == "abc")
    let bad = URL(string: "threadlight://oauth/callback?code=abc&state=wrong")!
    #expect(throws: (any Error).self) { _ = try attempt.authorizationCode(from: bad) }
    let duplicate = URL(string: "threadlight://oauth/callback?code=abc&code=def&state=\(attempt.state)")!
    #expect(throws: (any Error).self) { _ = try attempt.authorizationCode(from: duplicate) }
    let denied = URL(string: "threadlight://oauth/callback?error=access_denied&state=\(attempt.state)")!
    do {
        _ = try attempt.authorizationCode(from: denied)
        Issue.record("Expected Slack denial")
    } catch let ThreadLightError.slack(message, remediation) {
        #expect(message.contains("not approved"))
        #expect(remediation.contains("allow ThreadLight to read legal holds"))
    }
}

@MainActor
@Test func setupCoordinatorPersistsAndGeneratesSafeHandoff() throws {
    let suite = try #require(UserDefaults(suiteName: "ThreadLightTests.\(UUID())"))
    defer { suite.removePersistentDomain(forName: suite.volatileDomainNames.first ?? "") }
    let setup = SetupCoordinator(persistence: .init(defaults: suite, key: "test"))
    setup.organizationName = "Example"
    setup.organizationDomain = "example.enterprise.slack.com"
    setup.slackClientID = "public-client-id"
    setup.update(.internalApp, state: .ready)
    let hold = LegalHold(id: "H1", organizationID: "E1", name: "Case", status: .active, createdAt: .now, updatedAt: .now)
    let handoff = setup.administratorHandoff(hold: hold, custodians: [])
    let package = setup.administratorHandoffPackage(hold: hold, custodians: [])
    #expect(handoff.contains("public-client-id") == false)
    #expect(handoff.contains("client secret") == true)
    #expect(package.clientID == "public-client-id")
    #expect(package.schemaVersion == 2)
    #expect(package.exportEnd != nil)
    #expect(!String(data: try CanonicalJSON.encode(package), encoding: .utf8)!.contains("message"))
    #expect(setup.readyCount == 1)

    setup.update(.enterpriseInstall, state: .blocked(reason: "Org Owner required"))
    setup.update(.attachments, state: .notApplicable)
    setup.selectedRole = .slackAdministrator
    setup.save()
    let restored = SetupCoordinator(persistence: .init(defaults: suite, key: "test"))
    #expect(restored.selectedRole == .slackAdministrator)
    #expect(restored.requirements.first(where: { $0.id == .enterpriseInstall })?.state == .blocked(reason: "Org Owner required"))
    #expect(restored.isReadyForReview == false)
    #expect(restored.relevantRequirements.allSatisfy { $0.owner == .slackAdministrator })
}

@MainActor
@Test func resettingDeletedSlackAppPreservesOrganizationAndExportAccess() throws {
    let suiteName = "ThreadLightTests.\(UUID())"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }
    let setup = SetupCoordinator(persistence: .init(defaults: suite, key: "test"))
    setup.organizationName = "Example"
    setup.organizationDomain = "example.enterprise.slack.com"
    setup.slackClientID = "deleted-client-id"
    for id in SetupRequirementID.administratorRequirements {
        setup.update(id, state: .ready)
    }

    setup.resetSlackAppConfiguration()

    #expect(setup.organizationName == "Example")
    #expect(setup.organizationDomain == "example.enterprise.slack.com")
    #expect(setup.slackClientID.isEmpty)
    #expect(setup.requirements.first(where: { $0.id == .exportAccess })?.state == .ready)
    for id in [SetupRequirementID.internalApp, .pkce, .readScope, .enterpriseInstall] {
        #expect(setup.requirements.first(where: { $0.id == id })?.state == .pending)
    }
}

@MainActor
@Test func setupHandoffRoundTripsBetweenLegalAndAdministratorComputers() async throws {
    let legalSuite = try #require(UserDefaults(suiteName: "ThreadLightLegalTests.\(UUID())"))
    let adminSuite = try #require(UserDefaults(suiteName: "ThreadLightAdminTests.\(UUID())"))
    let legal = SetupCoordinator(persistence: .init(defaults: legalSuite, key: "legal"))
    legal.organizationName = "Example"
    legal.organizationDomain = "example.enterprise.slack.com"
    let request = legal.administratorHandoffPackage(hold: nil, custodians: [])

    let administrator = SetupCoordinator(persistence: .init(defaults: adminSuite, key: "admin"))
    let legalSignerKeyID = String(repeating: "1", count: 64)
    try administrator.importAdministratorRequest(request, signerKeyID: legalSignerKeyID)
    #expect(administrator.selectedRole == .slackAdministrator)
    #expect(administrator.activeRequest?.requestID == request.requestID)
    #expect(administrator.legalRequesterSignerKeyID == legalSignerKeyID)
    #expect(SetupCoordinator(persistence: .init(defaults: adminSuite, key: "admin")).legalRequesterSignerKeyID == legalSignerKeyID)
    administrator.slackClientID = "123456789.987654321"
    try administrator.recordValidatedOrganizationID("E123")
    for id in [SetupRequirementID.internalApp, .pkce, .readScope, .enterpriseInstall, .exportAccess] {
        administrator.update(id, state: .ready)
    }
    let completion = try administrator.administratorCompletionPackage()
    #expect(completion.schemaVersion == 2)
    let completionData = try CanonicalJSON.encode(completion)
    let envelope = try await EphemeralSignatureProvider().sign(manifest: completionData)
    #expect(try SecureEnclaveSignatureProvider.verify(manifest: completionData, envelope: envelope))
    let encoded = try #require(String(data: completionData, encoding: .utf8))
    #expect(!encoded.localizedCaseInsensitiveContains("access_token"))
    #expect(!encoded.localizedCaseInsensitiveContains("refresh_token"))
    #expect(!encoded.localizedCaseInsensitiveContains("message"))
    #expect(!encoded.localizedCaseInsensitiveContains("policiesListed"))
    #expect(completion.legalOAuthRequired)

    try legal.importAdministratorCompletion(completion, signerKeyID: envelope.keyID)
    #expect(legal.selectedRole == .legal)
    #expect(legal.slackClientID == "123456789.987654321")
    #expect(SetupRequirementID.administratorRequirements.allSatisfy { id in
        legal.requirements.first(where: { $0.id == id })?.state.isReady == true
    })
    #expect(legal.lastValidationMessage?.localizedCaseInsensitiveContains("did not authenticate") == true)
    #expect(legal.administratorSignerKeyID == envelope.keyID)
    #expect(legal.expectedOrganizationID == nil)
    try legal.recordValidatedOrganizationID("E123")
    #expect(legal.expectedOrganizationID == "E123")
    #expect(throws: ThreadLightError.self) { try legal.recordValidatedOrganizationID("E456") }
    #expect(SetupCoordinator(persistence: .init(defaults: legalSuite, key: "legal")).expectedOrganizationID == "E123")
}

@MainActor
@Test func standaloneAdministratorHandoffImportsWithPersistentWarning() async throws {
    let adminSuite = try #require(UserDefaults(suiteName: "ThreadLightStandaloneAdminTests.\(UUID())"))
    let legalSuite = try #require(UserDefaults(suiteName: "ThreadLightStandaloneLegalTests.\(UUID())"))
    let administrator = SetupCoordinator(persistence: .init(defaults: adminSuite, key: "admin"))
    administrator.organizationName = "Example"
    administrator.organizationDomain = "example.enterprise.slack.com"
    administrator.slackClientID = "123456789.987654321"
    try administrator.recordValidatedOrganizationID("E123")
    for id in SetupRequirementID.administratorRequirements {
        administrator.update(id, state: .ready)
    }
    #expect(administrator.activeRequest == nil)
    #expect(administrator.canCreateAdministratorCompletion)

    let completion = try administrator.administratorCompletionPackage()
    let data = try CanonicalJSON.encode(completion)
    let envelope = try await EphemeralSignatureProvider().sign(manifest: data)
    let legal = SetupCoordinator(persistence: .init(defaults: legalSuite, key: "legal"))
    try legal.importAdministratorCompletion(completion, signerKeyID: envelope.keyID)

    #expect(legal.unmatchedAdministratorCompletionImported)
    #expect(legal.lastValidationMessage?.localizedCaseInsensitiveContains("not linked") == true)
    #expect(legal.slackClientID == completion.clientID)
    #expect(legal.administratorSignerKeyID == envelope.keyID)
    #expect(SetupCoordinator(persistence: .init(defaults: legalSuite, key: "legal")).unmatchedAdministratorCompletionImported)
}

@MainActor
@Test func administratorCompletionRequiresValidatedOrganizationForMDM() throws {
    let suite = try #require(UserDefaults(suiteName: "ThreadLightAdminNoOAuthTests.\(UUID())"))
    defer { suite.removePersistentDomain(forName: suite.volatileDomainNames.first ?? "") }
    let administrator = SetupCoordinator(persistence: .init(defaults: suite, key: "admin"))
    _ = administrator.administratorHandoffPackage(hold: nil, custodians: [])
    for id in SetupRequirementID.administratorRequirements {
        administrator.update(id, state: .ready)
    }
    #expect(!administrator.canCreateAdministratorCompletion)
    #expect(throws: ThreadLightError.self) { try administrator.administratorCompletionPackage() }

    administrator.organizationName = "Example"
    administrator.organizationDomain = "example.enterprise.slack.com"
    administrator.slackClientID = "123456789.987654321"
    #expect(!administrator.canCreateAdministratorCompletion)
    #expect(throws: ThreadLightError.self) { try administrator.administratorCompletionPackage() }
    try administrator.recordValidatedOrganizationID("E123")
    #expect(administrator.canCreateAdministratorCompletion)
    let completion = try administrator.administratorCompletionPackage()
    #expect(completion.legalOAuthRequired)
    #expect(completion.completedRequirements.count == SetupRequirementID.administratorRequirements.count)
}

@MainActor
@Test func setupHandoffRejectsMismatchedOrIncompleteResponses() throws {
    let suite = try #require(UserDefaults(suiteName: "ThreadLightMismatchTests.\(UUID())"))
    let legal = SetupCoordinator(persistence: .init(defaults: suite, key: "legal"))
    _ = legal.administratorHandoffPackage(hold: nil, custodians: [])
    let response = SetupCompletionPackage(
        schemaVersion: 2,
        requestID: UUID(),
        requestSHA256: String(repeating: "b", count: 64),
        createdAt: .now,
        organizationName: "Example",
        enterpriseDomain: "example.enterprise.slack.com",
        clientID: "123.456",
        redirectURI: "threadlight://oauth/callback",
        requiredScope: "admin.legal_holds:read",
        completedRequirements: [.internalApp],
        administratorCompletedAt: .now,
        legalOAuthRequired: true,
        tokenTransferProhibited: true,
        legalNextStep: "Sign in locally."
    )
    #expect(throws: ThreadLightError.self) {
        try legal.importAdministratorCompletion(response, signerKeyID: String(repeating: "a", count: 64))
    }
}

@MainActor
@Test func setupTransferVerifierCoversManifestAndRejectsUnexpectedFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ThreadLightSetupTransfer-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = try #require(UserDefaults(suiteName: "ThreadLightTransferTests.\(UUID())"))
    let legal = SetupCoordinator(persistence: .init(defaults: suite, key: "legal"))
    legal.organizationName = "Example"
    let request = legal.administratorHandoffPackage(hold: nil, custodians: [])
    let requestData = try CanonicalJSON.encode(request)
    let envelope = try await EphemeralSignatureProvider().sign(manifest: requestData)
    let package = root.appending(path: "request.threadlight-setup-request", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
    try Data("Safe request".utf8).write(to: package.appending(path: "README.md"))
    try Data(SlackAppManifest.template.utf8).write(to: package.appending(path: "slack-app-manifest.yaml"))
    try requestData.write(to: package.appending(path: "handoff.json"))
    try CanonicalJSON.encode(envelope).write(to: package.appending(path: "handoff.threadlight-signature.json"))

    let result = try SetupTransferVerifier.verify(packageURL: package)
    #expect(result.kind == .administratorRequest)
    #expect(result.requestID == request.requestID)
    try Data("hidden unexpected content".utf8).write(to: package.appending(path: ".unexpected"))
    #expect(throws: ThreadLightError.self) { try SetupTransferVerifier.verify(packageURL: package) }
    try FileManager.default.removeItem(at: package.appending(path: ".unexpected"))
    try Data("unexpected".utf8).write(to: package.appending(path: "extra.txt"))
    #expect(throws: ThreadLightError.self) { try SetupTransferVerifier.verify(packageURL: package) }
    try FileManager.default.removeItem(at: package.appending(path: "extra.txt"))
    try Data("tampered manifest".utf8).write(to: package.appending(path: "slack-app-manifest.yaml"))
    #expect(throws: ThreadLightError.self) { try SetupTransferVerifier.verify(packageURL: package) }
}

@MainActor
@Test func setupTransferVerifierCoversAdministratorResponseAndRejectsTampering() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ThreadLightSetupResponse-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = try #require(UserDefaults(suiteName: "ThreadLightResponseTests.\(UUID())"))
    let setup = SetupCoordinator(persistence: .init(defaults: suite, key: "admin"))
    setup.organizationName = "Example"
    setup.organizationDomain = "example.enterprise.slack.com"
    setup.slackClientID = "123.456"
    try setup.recordValidatedOrganizationID("E123")
    _ = setup.administratorHandoffPackage(hold: nil, custodians: [])
    for id in SetupRequirementID.administratorRequirements {
        setup.update(id, state: .ready)
    }
    let response = try setup.administratorCompletionPackage()
    let responseData = try CanonicalJSON.encode(response)
    let envelope = try await EphemeralSignatureProvider().sign(manifest: responseData)
    let package = root.appending(path: "response.threadlight-setup-response", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
    try Data("Safe response".utf8).write(to: package.appending(path: "README.txt"))
    try responseData.write(to: package.appending(path: "completion.json"))
    try CanonicalJSON.encode(envelope).write(to: package.appending(path: "completion.threadlight-signature.json"))

    let result = try SetupTransferVerifier.verify(packageURL: package)
    #expect(result.kind == .administratorResponse)
    #expect(result.requestID == response.requestID)
    #expect(try SetupTransferVerifier.response(at: package).clientID == "123.456")

    try Data("tampered response".utf8).write(to: package.appending(path: "completion.json"))
    #expect(throws: ThreadLightError.self) { try SetupTransferVerifier.verify(packageURL: package) }
}

@MainActor
@Test func managedProfileContainsOnlyPublicLegalConfigurationAndAppliesOnLaunch() throws {
    let managed = try ManagedConfiguration(
        slackClientID: "123.456",
        organizationName: "Example",
        enterpriseDomain: "example.enterprise.slack.com",
        expectedOrganizationID: "E123",
        retentionDays: 45
    )
    let data = try managed.profileData()
    let profile = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(profile["PayloadType"] as? String == "Configuration")
    #expect(profile["PayloadScope"] as? String == "System")
    let payloads = try #require(profile["PayloadContent"] as? [[String: Any]])
    let preferences = try #require(payloads.first?["PayloadContent"] as? [String: Any])
    let appDomain = try #require(preferences[ManagedConfiguration.applicationBundleID] as? [String: Any])
    let forced = try #require(appDomain["Forced"] as? [[String: Any]])
    let values = try #require(forced.first?["mcx_preference_settings"] as? [String: Any])
    #expect(values[ManagedConfiguration.Key.slackClientID] as? String == "123.456")
    #expect(values[ManagedConfiguration.Key.expectedOrganizationID] as? String == "E123")
    #expect(values["ThreadLightRole"] == nil)
    #expect(values[ManagedConfiguration.Key.retentionDays] as? Int == 45)
    #expect(!String(data: data, encoding: .utf8)!.localizedCaseInsensitiveContains("client_secret"))
    #expect(!String(data: data, encoding: .utf8)!.localizedCaseInsensitiveContains("access_token"))

    let suite = try #require(UserDefaults(suiteName: "ThreadLightManagedTests.\(UUID())"))
    let setup = SetupCoordinator(persistence: .init(defaults: suite, key: "managed"), managedConfiguration: managed)
    #expect(setup.isManagedConfiguration)
    #expect(setup.selectedRole == .legal)
    #expect(setup.slackClientID == "123.456")
    #expect(setup.expectedOrganizationID == "E123")
    #expect(setup.managedRetentionDays == 45)
    #expect(SetupRequirementID.administratorRequirements.allSatisfy { id in
        setup.requirements.first(where: { $0.id == id })?.state.isReady == true
    })
}

@Test func slackErrorsHaveActionableRemediation() {
    let error = SlackErrorMapper.error(for: "missing_scope")
    guard case let .slack(message, remediation) = error else { Issue.record("Expected Slack error"); return }
    #expect(message.contains("read access"))
    #expect(remediation.contains("reconnect"))
}

@Test func slackPKCEErrorsHaveActionableRemediation() {
    for code in ["pkce_not_allowed", "invalid_code_verifier"] {
        guard case let .slack(_, remediation) = SlackErrorMapper.error(for: code) else {
            Issue.record("Expected Slack error for \(code)")
            continue
        }
        #expect(remediation.localizedCaseInsensitiveContains("PKCE"))
    }
}
