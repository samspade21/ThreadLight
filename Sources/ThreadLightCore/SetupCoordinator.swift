import Foundation
import Observation

@MainActor
@Observable
public final class SetupCoordinator {
    public private(set) var requirements: [SetupRequirement]
    public var selectedRole: UserRole
    public var organizationName: String
    public var organizationDomain: String
    public var slackClientID: String
    public var lastValidationMessage: String?
    public private(set) var activeRequest: SetupHandoffPackage?
    public private(set) var legalRequesterSignerKeyID: String?
    public private(set) var administratorSignerKeyID: String?
    /// The administrator signer key ID the operator confirmed out of band. A handoff package
    /// carries its own verifying public key, so its signature proves only internal consistency —
    /// this comparison is what actually ties the imported client ID to a known sender.
    public private(set) var confirmedAdministratorSignerKeyID: String?
    public private(set) var expectedOrganizationID: String?
    public private(set) var unmatchedAdministratorCompletionImported: Bool
    public private(set) var isManagedConfiguration: Bool

    @ObservationIgnored private let persistence: SetupPersistence
    @ObservationIgnored private let managedConfiguration: ManagedConfiguration?

    public init(
        persistence: SetupPersistence = .init(),
        managedConfiguration: ManagedConfiguration? = ManagedConfiguration.installed()
    ) {
        self.persistence = persistence
        self.managedConfiguration = managedConfiguration
        isManagedConfiguration = managedConfiguration != nil
        if let state = persistence.load() {
            requirements = state.requirements
            selectedRole = state.selectedRole
            organizationName = state.organizationName
            organizationDomain = state.organizationDomain
            slackClientID = state.slackClientID
            activeRequest = state.activeRequest
            legalRequesterSignerKeyID = state.legalRequesterSignerKeyID
            administratorSignerKeyID = state.administratorSignerKeyID
            confirmedAdministratorSignerKeyID = state.confirmedAdministratorSignerKeyID
            expectedOrganizationID = state.expectedOrganizationID
            unmatchedAdministratorCompletionImported = state.unmatchedAdministratorCompletionImported ?? false
        } else {
            requirements = Self.defaultRequirements
            selectedRole = .legal
            organizationName = ""
            organizationDomain = ""
            slackClientID = ""
            activeRequest = nil
            legalRequesterSignerKeyID = nil
            administratorSignerKeyID = nil
            confirmedAdministratorSignerKeyID = nil
            expectedOrganizationID = nil
            unmatchedAdministratorCompletionImported = false
        }
        applyManagedConfiguration()
    }

    public var managedRetentionDays: Int? { managedConfiguration?.retentionDays }

    public var relevantRequirements: [SetupRequirement] {
        requirements.filter { $0.owner == selectedRole }
    }

    public var readyCount: Int { requirements.filter(\.state.isReady).count }
    public var progress: Double { requirements.isEmpty ? 0 : Double(readyCount) / Double(requirements.count) }
    public var isReadyForReview: Bool { requirements.allSatisfy(\.state.isReady) }
    public var canCreateAdministratorCompletion: Bool {
        !organizationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !organizationDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !slackClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && expectedOrganizationID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && SetupRequirementID.administratorRequirements.allSatisfy { id in
                requirements.first(where: { $0.id == id })?.state.isReady == true
            }
    }

    /// True when a client ID arrived from a signed handoff package whose signer the operator
    /// has not yet confirmed. MDM-managed installs are exempt: their client ID comes from the
    /// configuration profile, not from a package that could have been altered in transit.
    public var requiresAdministratorSignerConfirmation: Bool {
        guard !isManagedConfiguration, let administratorSignerKeyID else { return false }
        return administratorSignerKeyID != confirmedAdministratorSignerKeyID
    }

    public func confirmAdministratorSignerKeyID() {
        guard let administratorSignerKeyID else { return }
        confirmedAdministratorSignerKeyID = administratorSignerKeyID
        lastValidationMessage = "Signer \(administratorSignerKeyID.prefix(12))… confirmed. You can now sign in to Slack."
        save()
    }

    public func update(_ id: SetupRequirementID, state: SetupRequirementState, message: String? = nil) {
        guard let index = requirements.firstIndex(where: { $0.id == id }) else { return }
        requirements[index].state = state
        lastValidationMessage = message
        save()
    }

    public func save() {
        persistence.save(
            .init(
                requirements: requirements,
                selectedRole: selectedRole,
                organizationName: organizationName,
                organizationDomain: organizationDomain,
                slackClientID: slackClientID,
                activeRequest: activeRequest,
                legalRequesterSignerKeyID: legalRequesterSignerKeyID,
                administratorSignerKeyID: administratorSignerKeyID,
                confirmedAdministratorSignerKeyID: confirmedAdministratorSignerKeyID,
                expectedOrganizationID: expectedOrganizationID,
                unmatchedAdministratorCompletionImported: unmatchedAdministratorCompletionImported
            )
        )
    }

    public func reset() {
        requirements = Self.defaultRequirements
        selectedRole = .legal
        organizationName = ""
        organizationDomain = ""
        slackClientID = ""
        lastValidationMessage = nil
        activeRequest = nil
        legalRequesterSignerKeyID = nil
        administratorSignerKeyID = nil
        confirmedAdministratorSignerKeyID = nil
        expectedOrganizationID = nil
        unmatchedAdministratorCompletionImported = false
        applyManagedConfiguration()
        save()
    }

    public func resetSlackAppConfiguration() {
        for id in [SetupRequirementID.internalApp, .pkce, .readScope, .enterpriseInstall] {
            guard let index = requirements.firstIndex(where: { $0.id == id }) else { continue }
            requirements[index].state = .pending
        }
        slackClientID = ""
        administratorSignerKeyID = nil
        confirmedAdministratorSignerKeyID = nil
        expectedOrganizationID = nil
        lastValidationMessage = "Starting with a new Slack app. Organization and export-access details were preserved."
        save()
    }

    public func administratorHandoff(hold: LegalHold?, custodians: [Custodian]) -> String {
        let dates: String
        if let hold {
            dates = "\(hold.startAt?.formatted(date: .numeric, time: .omitted) ?? "All history") through \((hold.endAt ?? Date()).formatted(date: .numeric, time: .omitted))"
        } else {
            dates = "Select the exact hold window in ThreadLight"
        }
        let people = custodians.isEmpty
            ? "- Import one custom export per hold custodian shown in ThreadLight."
            : custodians.map { "- \($0.displayName) (`\($0.id)`)" }.joined(separator: "\n")

        return """
        # ThreadLight Slack Admin Role setup handoff

        Request ID: \(activeRequest?.requestID.uuidString ?? "Create this package again from ThreadLight")
        Organization: \(organizationName.isEmpty ? "Not entered" : organizationName)
        Enterprise domain: \(organizationDomain.isEmpty ? "Not entered" : organizationDomain)
        Hold: \(hold?.name ?? "Not selected")
        Export coverage: \(dates)

        ## Internal app
        1. Create an organization-owned internal app from the single included `docs/slack-app-manifest.yaml`.
        2. Confirm bot scope `team:read`, user scopes `admin.legal_holds:read`, `users:read`, `users:read.email`, `reactions:read`, and `emoji:read`, PKCE, `https://callback.threadlight.invalid/oauth/callback`, and organization deployment.
        3. In that app's settings, open Install App and choose Install to Organization as an Org Owner. Select the Enterprise organization, not a workspace.
        4. Enter the public client ID in ThreadLight, then choose Connect IT Role to Slack. ThreadLight requests only the user scope and verifies it by listing Legal Hold policies.
        5. Create the signed Slack Admin handoff and return the entire response folder to the Legal Role.
        6. The Legal Role imports the response and signs in locally using an account Slack permits to read Legal Holds.

        IT and Legal authenticate locally. Never share a client secret or OAuth token. The response transfers only the public client ID and signed setup attestations.

        ## Slack exports
        Confirm approved Slack export access is enabled. In ThreadLight's IT Role, select this hold and attach one or more untouched JSON ZIPs. The current hold members are:
        \(people)

        ThreadLight normalizes the ZIPs and creates one encrypted `.threadlight` file. Deliver that file to Legal out of band. Standard exports may contain file links rather than original attachment bytes.

        ## Completion checklist
        - [ ] Internal app created
        - [ ] PKCE and callback configured
        - [ ] Legal Holds read scope granted
        - [ ] Installed at Enterprise organization level
        - [ ] Custom export access enabled
        - [ ] One untouched ZIP delivered per custodian
        - [ ] Signed completion response returned to Legal
        """
    }

    public func administratorHandoffPackage(hold: LegalHold?, custodians: [Custodian]) -> SetupHandoffPackage {
        let package = SetupHandoffPackage(
            schemaVersion: 2,
            requestID: activeRequest?.requestID ?? UUID(),
            appManifestSHA256: SHA256Digest.data(Data(SlackAppManifest.template.utf8)),
            createdAt: Date(),
            organizationName: organizationName,
            enterpriseDomain: organizationDomain,
            requestedRole: "Slack Admin Role: Enterprise Org Owner and Export Admin",
            requestedActions: [
                "Create the organization-owned internal Slack app from the single included manifest.",
                "Keep bot scope team:read and ThreadLight's five read-only user scopes, PKCE, callback, and organization deployment unchanged.",
                "From that app's Settings → Install App page, install to the Enterprise organization as an Org Owner.",
                "Connect from ThreadLight to authorize and verify the user-only desktop flow.",
                "Enable approved custom/member JSON exports.",
                "Attach one or more approved Slack export ZIPs to the selected hold in ThreadLight.",
            ],
            clientID: slackClientID.isEmpty ? nil : slackClientID,
            clientIDInstruction: "Return only the Slack app client ID to Legal. Never send a client secret or OAuth token.",
            redirectURI: SlackOAuth.redirectURI,
            requiredScope: "admin.legal_holds:read",
            holdID: hold?.id,
            holdName: hold?.name,
            exportStart: hold?.startAt,
            exportEnd: hold.map { $0.endAt ?? Date() },
            custodians: custodians.map { .init(id: $0.id, displayName: $0.displayName) },
            checklist: [
                "Internal app created",
                "PKCE and callback configured",
                "Legal Holds read scope granted",
                "Installed at Enterprise organization level",
                "Custom export access enabled",
                "Slack export ZIPs attached to the selected hold",
            ]
        )
        activeRequest = package
        save()
        return package
    }

    public func importAdministratorRequest(_ package: SetupHandoffPackage, signerKeyID: String? = nil) throws {
        guard package.schemaVersion == 2,
              package.redirectURI == SlackOAuth.redirectURI,
              package.requiredScope == "admin.legal_holds:read",
              package.appManifestSHA256 == SHA256Digest.data(Data(SlackAppManifest.template.utf8)) else {
            throw ThreadLightError.invalidConfiguration("This is not a supported ThreadLight Slack Admin setup request.")
        }
        organizationName = package.organizationName
        organizationDomain = package.enterpriseDomain
        slackClientID = package.clientID ?? ""
        activeRequest = package
        legalRequesterSignerKeyID = nil
        administratorSignerKeyID = nil
        if let signerKeyID {
            guard Self.isValidSignerKeyID(signerKeyID) else {
                throw ThreadLightError.invalidConfiguration("The Legal request signer key ID is invalid.")
            }
            legalRequesterSignerKeyID = signerKeyID
        }
        expectedOrganizationID = nil
        selectedRole = .slackAdministrator
        for id in SetupRequirementID.administratorRequirements {
            update(id, state: .pending)
        }
        lastValidationMessage = "Imported Legal Role request \(package.requestID.uuidString.prefix(8)). Complete the five Slack Admin Role setup steps."
        save()
    }

    public func administratorCompletionPackage(completedAt: Date = Date()) throws -> SetupCompletionPackage {
        let missing = SetupRequirementID.administratorRequirements.filter { id in
            requirements.first(where: { $0.id == id })?.state.isReady != true
        }
        guard missing.isEmpty else {
            throw ThreadLightError.invalidConfiguration("Complete every administrator step before creating the response: \(missing.map(\.title).joined(separator: ", ")).")
        }
        guard !organizationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !organizationDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !slackClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              expectedOrganizationID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ThreadLightError.invalidConfiguration("Enter the organization details and complete Slack validation before creating the Legal MDM configuration.")
        }
        return .init(
            schemaVersion: 2,
            requestID: activeRequest?.requestID ?? UUID(),
            requestSHA256: try activeRequest.map { SHA256Digest.data(try CanonicalJSON.encode($0)) }
                ?? SHA256Digest.data(Data("threadlight:standalone-it-completion:v1".utf8)),
            createdAt: Date(),
            organizationName: organizationName,
            enterpriseDomain: organizationDomain,
            clientID: slackClientID,
            redirectURI: SlackOAuth.redirectURI,
            requiredScope: "admin.legal_holds:read",
            completedRequirements: SetupRequirementID.administratorRequirements,
            administratorCompletedAt: completedAt,
            legalOAuthRequired: true,
            tokenTransferProhibited: true,
            legalNextStep: "Import this handoff in the Legal Role, then complete OAuth locally. That API check validates the scope and Enterprise installation; no token is transferred."
        )
    }

    public func importAdministratorCompletion(_ package: SetupCompletionPackage, signerKeyID: String) throws {
        guard package.schemaVersion == 2,
              package.redirectURI == SlackOAuth.redirectURI,
              package.requiredScope == "admin.legal_holds:read",
              package.legalOAuthRequired,
              package.tokenTransferProhibited,
              !package.organizationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !package.enterpriseDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !package.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.isValidSignerKeyID(signerKeyID) else {
            throw ThreadLightError.invalidConfiguration("This is not a supported ThreadLight Slack Admin handoff.")
        }
        if let request = activeRequest {
            guard request.requestID == package.requestID else {
                throw ThreadLightError.invalidConfiguration("This handoff does not match the Slack Admin setup request created by the Legal Role.")
            }
            guard package.requestSHA256 == SHA256Digest.data(try CanonicalJSON.encode(request)) else {
                throw ThreadLightError.invalidConfiguration("This response was created from different request contents.")
            }
            unmatchedAdministratorCompletionImported = false
        } else {
            unmatchedAdministratorCompletionImported = true
        }
        guard Set(package.completedRequirements) == Set(SetupRequirementID.administratorRequirements) else {
            throw ThreadLightError.invalidConfiguration("The Slack Admin handoff does not complete every required setup step.")
        }
        if !organizationName.isEmpty, organizationName != package.organizationName {
            throw ThreadLightError.invalidConfiguration("The Slack Admin handoff names a different organization.")
        }
        if !organizationDomain.isEmpty, organizationDomain != package.enterpriseDomain {
            throw ThreadLightError.invalidConfiguration("The Slack Admin handoff names a different Enterprise domain.")
        }
        organizationName = package.organizationName
        organizationDomain = package.enterpriseDomain
        slackClientID = package.clientID
        administratorSignerKeyID = signerKeyID
        // A new package means a new signer to confirm, even if one was confirmed before.
        confirmedAdministratorSignerKeyID = nil
        expectedOrganizationID = nil
        for id in SetupRequirementID.administratorRequirements {
            update(id, state: .ready)
        }
        selectedRole = .legal
        lastValidationMessage = unmatchedAdministratorCompletionImported
            ? "Standalone Slack Admin handoff imported. Its signature is valid, but it is not linked to a Legal Role request. Compare the full signer ID and organization details with the Slack Admin Role, then validate through Slack OAuth."
            : "Slack Admin handoff imported and signature verified. Compare signer \(signerKeyID.prefix(12))… through the approved channel, then sign in in the Legal Role with the Legal Holds administrator account. The Slack Admin Role did not authenticate to Legal Holds."
        save()
    }

    public func recordValidatedOrganizationID(_ organizationID: String) throws {
        let identifier = organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            throw ThreadLightError.authentication("Slack did not identify the Enterprise organization.")
        }
        if let expectedOrganizationID, expectedOrganizationID != identifier {
            throw ThreadLightError.authentication("Slack connected to organization \(identifier), but the Legal Role is already bound to \(expectedOrganizationID). Sign out of Slack in the browser and reconnect to the correct Enterprise organization.")
        }
        expectedOrganizationID = identifier
        save()
    }

    public func recordLegalRequesterSignerKeyID(_ keyID: String) throws {
        guard Self.isValidSignerKeyID(keyID) else {
            throw ThreadLightError.invalidConfiguration("The Legal request signer key ID is invalid.")
        }
        legalRequesterSignerKeyID = keyID
        save()
    }

    public func recordAdministratorSignerKeyID(_ keyID: String) throws {
        guard Self.isValidSignerKeyID(keyID) else {
            throw ThreadLightError.invalidConfiguration("The Slack Admin handoff signer key ID is invalid.")
        }
        administratorSignerKeyID = keyID
        save()
    }

    private static func isValidSignerKeyID(_ keyID: String) -> Bool {
        keyID.utf8.count == 64 && keyID.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private func applyManagedConfiguration() {
        guard let managedConfiguration else { return }
        selectedRole = .legal
        organizationName = managedConfiguration.organizationName
        organizationDomain = managedConfiguration.enterpriseDomain
        slackClientID = managedConfiguration.slackClientID
        expectedOrganizationID = managedConfiguration.expectedOrganizationID
        unmatchedAdministratorCompletionImported = false
        for id in SetupRequirementID.administratorRequirements {
            guard let index = requirements.firstIndex(where: { $0.id == id }) else { continue }
            requirements[index].state = .ready
        }
        lastValidationMessage = "ThreadLight configuration is managed by your organization. Authenticate with Slack to load your Legal Holds."
    }

    public static let defaultRequirements: [SetupRequirement] = [
        .init(
            id: .internalApp,
            detail: "Create an organization-owned Slack app from ThreadLight's manifest.",
            why: "A customer-owned app keeps credentials, approval, and lifecycle control inside your organization.",
            owner: .slackAdministrator,
            actionURL: URL(string: "https://api.slack.com/apps")
        ),
        .init(
            id: .pkce,
            detail: "Add https://callback.threadlight.invalid/oauth/callback and enable PKCE. Slack treats PKCE as a one-way app setting.",
            why: "PKCE lets a desktop app authenticate without embedding a client secret. Slack rejects custom app callbacks that do not use it.",
            owner: .slackAdministrator,
            actionURL: URL(string: "https://api.slack.com/apps")
        ),
        .init(
            id: .readScope,
            detail: "Configure bot scope team:read and user scopes admin.legal_holds:read, users:read, users:read.email, reactions:read, and emoji:read.",
            why: "Slack requires a bot scope for organization installation. The user scopes provide legal holds, current profiles, reactions, and workspace emoji; ThreadLight never stores or uses the bot token.",
            owner: .slackAdministrator,
            actionURL: URL(string: "https://api.slack.com/apps")
        ),
        .init(
            id: .enterpriseInstall,
            detail: "From the app's Settings → Install App page, install to the organization as an Org Owner, then verify from ThreadLight.",
            why: "That app-specific installer correctly requests the configured bot scope; ThreadLight's later desktop OAuth requests only its five read-only user scopes.",
            owner: .slackAdministrator,
            actionURL: URL(string: "https://docs.slack.dev/enterprise/organization-ready-apps/")
        ),
        .init(
            id: .exportAccess,
            detail: "Confirm custom exports by member are enabled.",
            why: "Slack's Legal Holds API does not expose preserved message contents. Approved exports supply the searchable evidence.",
            owner: .slackAdministrator,
            actionURL: URL(string: "https://slack.com/help/articles/201658943-Export-your-workspace-data")
        ),
        .init(
            id: .custodianExports,
            detail: "Attach one or more untouched Slack JSON ZIPs to the selected hold.",
            why: "IT normalizes all source ZIPs before creating one encrypted transfer for Legal.",
            owner: .slackAdministrator
        ),
        .init(
            id: .attachments,
            detail: "Import original attachment bytes when the evidence package requires them.",
            why: "Slack JSON exports often contain links rather than original file bytes.",
            owner: .legal
        ),
    ]
}

public struct SetupHandoffPackage: Codable, Sendable {
    public struct CustodianRecord: Codable, Sendable {
        public let id: String
        public let displayName: String

        public init(id: String, displayName: String) {
            self.id = id
            self.displayName = displayName
        }
    }

    public let schemaVersion: Int
    public let requestID: UUID
    public let appManifestSHA256: String
    public let createdAt: Date
    public let organizationName: String
    public let enterpriseDomain: String
    public let requestedRole: String
    public let requestedActions: [String]
    public let clientID: String?
    public let clientIDInstruction: String
    public let redirectURI: String
    public let requiredScope: String
    public let holdID: String?
    public let holdName: String?
    public let exportStart: Date?
    public let exportEnd: Date?
    public let custodians: [CustodianRecord]
    public let checklist: [String]
}

public struct SetupCompletionPackage: Codable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let requestSHA256: String
    public let createdAt: Date
    public let organizationName: String
    public let enterpriseDomain: String
    public let clientID: String
    public let redirectURI: String
    public let requiredScope: String
    public let completedRequirements: [SetupRequirementID]
    public let administratorCompletedAt: Date
    public let legalOAuthRequired: Bool
    public let tokenTransferProhibited: Bool
    public let legalNextStep: String
}

public struct SetupState: Codable, Sendable {
    public var requirements: [SetupRequirement]
    public var selectedRole: UserRole
    public var organizationName: String
    public var organizationDomain: String
    public var slackClientID: String
    public var activeRequest: SetupHandoffPackage?
    public var legalRequesterSignerKeyID: String?
    public var administratorSignerKeyID: String?
    public var confirmedAdministratorSignerKeyID: String?
    public var expectedOrganizationID: String?
    public var unmatchedAdministratorCompletionImported: Bool?
}

public struct SetupPersistence {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "threadlight.setup.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> SetupState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SetupState.self, from: data)
    }

    public func save(_ state: SetupState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
