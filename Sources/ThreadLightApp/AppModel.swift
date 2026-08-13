import AppKit
import AuthenticationServices
import Foundation
import Observation
import ThreadLightCore
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    enum SidebarSelection: Hashable {
        case setup
        case hold(String)
    }

    enum ExportSelectionScope: String, CaseIterable, Identifiable {
        case selectedMessages
        case completeThreads

        var id: String { rawValue }
        var title: String { self == .selectedMessages ? "Selected messages" : "Complete selected threads" }
    }

    let setup: SetupCoordinator
    var sidebarSelection: SidebarSelection = .setup {
        didSet {
            switch sidebarSelection {
            case .setup:
                selectedMessage = nil
                threadMessages = []
                selectedMessageIDs.removeAll()
            case let .hold(id):
                selectHold(id: id)
            }
        }
    }
    var holds: [LegalHold] = []
    var custodians: [Custodian] = []
    var importedCustodianIDs: Set<String> = []
    var messages: [EvidenceMessage] = []
    var threadMessages: [EvidenceMessage] = []
    var selectedHold: LegalHold?
    var selectedMessage: EvidenceMessage?
    var selectedMessageIDs: Set<String> = []
    var queryText = ""
    var searchMode: SearchMode = .basic
    var searchFilters = SearchFilters()
    var isSearching = false
    var isStarting = true
    var isDemoSession = false
    var isConnected = false
    var isShowingError = false
    var errorMessage: String?
    var statusMessage = "Complete setup to begin."
    var retentionDays: Int {
        didSet { UserDefaults.standard.set(retentionDays, forKey: Self.retentionDaysKey) }
    }
    var isShowingImport = false
    var isShowingImportReport = false
    var isShowingExportOptions = false
    var lastImportReport: ImportReport?
    var importProgress: ImportProgress?
    private(set) var currentOrganizationID: String?

    private var store: EvidenceStore?
    private var resourceVault: ResourceVault?
    private var legalHoldClient: (any LegalHoldClient)?
    private let authorization = SlackAuthorizationController()
    private let tokenVault = SlackTokenVault()
    private let quickLook = QuickLookPresenter()
    private var holdLoadTask: Task<Void, Never>?
    private var threadLoadTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var activeStorageNamespace: String?

    init() {
        #if THREADLIGHT_DEVELOPMENT
        if Self.demoMode != nil,
           let defaults = UserDefaults(suiteName: "dev.threadlight.sanitized-demo") {
            defaults.removePersistentDomain(forName: "dev.threadlight.sanitized-demo")
            setup = SetupCoordinator(persistence: .init(defaults: defaults, key: "demo.setup"))
        } else {
            setup = SetupCoordinator()
        }
        #else
        setup = SetupCoordinator()
        #endif
        let saved = UserDefaults.standard.integer(forKey: Self.retentionDaysKey)
        retentionDays = setup.managedRetentionDays ?? (saved > 0 ? saved : 30)
    }

    func start() async {
        defer { isStarting = false }
        var expiredProfiles = 0
        do {
            expiredProfiles = try await purgeExpiredStorageNamespaces()
#if THREADLIGHT_DEVELOPMENT
            if let demoMode = Self.demoMode {
                isDemoSession = true
                try await openStorage(organizationID: "E-DEMO", remember: false)
                try await seedDemoEvidence(complete: demoMode == .complete)
                return
            }
#endif
            let remembered = setup.expectedOrganizationID
                ?? UserDefaults.standard.string(forKey: Self.lastOrganizationIDKey)
                ?? "unconfigured"
            try await openStorage(organizationID: remembered)
            if expiredProfiles > 0 {
                statusMessage = "Purged local evidence from \(expiredProfiles) inactive organization profile(s)."
            }
        } catch {
            show(error)
            return
        }
        guard !setup.slackClientID.isEmpty else { return }
        do {
            guard let tokens = try await tokenVault.load(organizationID: "current") else { return }
            guard tokens.hasExactLegalHoldsReadScope else {
                throw ThreadLightError.authentication("Your saved Slack sign-in no longer has the access ThreadLight needs. Sign in again.")
            }
            let client = RefreshingLegalHoldClient(
                tokens: tokens,
                clientID: setup.slackClientID,
                tokenVault: tokenVault
            )
            let loadedHolds = try await client.listPolicies(status: nil)
            let organizationID = try verifiedOrganizationID(tokens: tokens, holds: loadedHolds)
            try setup.recordValidatedOrganizationID(organizationID)
            try await openStorage(organizationID: organizationID)
            legalHoldClient = client
            isConnected = true
            let currentHoldIDs = Set(loadedHolds.map(\.id))
            for oldHold in try await store?.holds() ?? [] where !currentHoldIDs.contains(oldHold.id) {
                _ = try await store?.purgeEvidence(holdID: oldHold.id)
            }
            holds = loadedHolds
            for hold in loadedHolds {
                try await store?.save(hold: hold)
                if hold.status == .active {
                    let currentCustodians = try await client.listCustodians(policyID: hold.id)
                    _ = try await reconcileCustodians(currentCustodians, for: hold)
                }
            }
            statusMessage = "Slack connection restored."
            if let first = loadedHolds.first { sidebarSelection = .hold(first.id) }
        } catch {
            isConnected = false
            statusMessage = "Slack must be reconnected. Local evidence remains available."
        }
    }

    func connectSlack() async {
        do {
            setup.save()
            let tokens = try await authorization.authorize(clientID: setup.slackClientID)
            guard tokens.hasExactLegalHoldsReadScope else {
                throw ThreadLightError.authentication("Slack did not grant exactly admin.legal_holds:read. Remove every other user scope and reconnect from ThreadLight. Keep the installation bot scope team:read.")
            }
            let validationClient = SlackLegalHoldClient(accessToken: tokens.accessToken)
            let loadedHolds = try await validationClient.listPolicies(status: nil)
            let organizationID = try verifiedOrganizationID(tokens: tokens, holds: loadedHolds)
            try setup.recordValidatedOrganizationID(organizationID)
            try await openStorage(organizationID: organizationID)
            try await tokenVault.save(tokens, organizationID: "current")
            let client = RefreshingLegalHoldClient(
                tokens: tokens,
                clientID: setup.slackClientID,
                tokenVault: tokenVault
            )
            legalHoldClient = client
            isConnected = true
            let currentHoldIDs = Set(loadedHolds.map(\.id))
            for oldHold in try await store?.holds() ?? [] where !currentHoldIDs.contains(oldHold.id) {
                _ = try await store?.purgeEvidence(holdID: oldHold.id)
            }
            holds = loadedHolds
            for hold in loadedHolds {
                try await store?.save(hold: hold)
                if hold.status == .active {
                    let currentCustodians = try await client.listCustodians(policyID: hold.id)
                    _ = try await reconcileCustodians(currentCustodians, for: hold)
                }
            }
            setup.update(.internalApp, state: .ready)
            setup.update(.pkce, state: .ready)
            setup.update(.readScope, state: .ready)
            setup.update(.enterpriseInstall, state: .ready, message: "Slack returned \(loadedHolds.count) legal hold policies.")
            statusMessage = "Signed in to Slack. Choose a legal hold or import its encrypted package."
            touchActivity()
            if let first = loadedHolds.first { sidebarSelection = .hold(first.id) }
        } catch {
            if case let ThreadLightError.slack(_, remediation) = error {
                setup.update(.enterpriseInstall, state: .blocked(reason: remediation))
            }
            show(error)
        }
    }

    func selectHold(id: String) {
        guard let hold = holds.first(where: { $0.id == id }) else { return }
        selectedHold = hold
        selectedMessage = nil
        threadMessages = []
        selectedMessageIDs.removeAll()
        importedCustodianIDs.removeAll()
        holdLoadTask?.cancel()
        holdLoadTask = Task {
            await loadCustodians(for: hold)
            guard !Task.isCancelled, selectedHold?.id == hold.id else { return }
            await search()
        }
    }

    func loadCustodians(for hold: LegalHold) async {
        do {
            let loaded: [Custodian]
            if hold.status != .active {
                loaded = try await store?.custodians(holdID: hold.id) ?? []
            } else if let legalHoldClient {
                loaded = try await legalHoldClient.listCustodians(policyID: hold.id)
                _ = try await reconcileCustodians(loaded, for: hold)
            } else {
                loaded = try await store?.custodians(holdID: hold.id) ?? []
            }
            guard !Task.isCancelled, selectedHold?.id == hold.id else { return }
            custodians = loaded
            try await refreshEvidenceReadiness(for: hold)
        } catch is CancellationError {
            return
        } catch { show(error) }
    }

    func search() async {
        searchGeneration += 1
        let generation = searchGeneration
        guard let hold = selectedHold, hold.status == .active, let store else {
            messages = []
            isSearching = false
            return
        }
        isSearching = true
        do {
            let query = SearchQuery(text: queryText, mode: searchMode, filters: searchFilters)
            let results = try await store.search(holdID: hold.id, query: query)
            guard generation == searchGeneration, selectedHold?.id == hold.id else { return }
            messages = results
            selectedMessageIDs.formIntersection(Set(results.map(\.id)))
            statusMessage = "\(messages.count) matching messages"
            touchActivity()
        } catch {
            if generation == searchGeneration { show(error) }
        }
        if generation == searchGeneration { isSearching = false }
    }

    func selectMessage(_ message: EvidenceMessage) {
        selectedMessage = message
        guard let hold = selectedHold, let store else { return }
        threadLoadTask?.cancel()
        threadLoadTask = Task {
            do {
                let loaded = try await store.thread(holdID: hold.id, threadID: message.threadID)
                guard !Task.isCancelled, selectedHold?.id == hold.id, selectedMessage?.id == message.id else { return }
                threadMessages = loaded
            }
            catch is CancellationError { return }
            catch { show(error) }
        }
    }

    func toggleEvidenceSelection(_ id: String) {
        if selectedMessageIDs.contains(id) { selectedMessageIDs.remove(id) }
        else { selectedMessageIDs.insert(id) }
    }

    func presentImportPanel() {
        guard selectedHold?.status == .active else { return }
        isShowingImport = true
    }

    func importHoldArchives(urls: [URL], operatorBinding: String) async {
        guard let hold = selectedHold, let store, !urls.isEmpty else { return }
        importProgress = nil
        defer { importProgress = nil }
        var imported = 0
        var messageCount = 0
        var warningCount = 0
        do {
            let importer = SlackExportImporter(store: store) { [weak self] progress in
                await MainActor.run { self?.importProgress = progress }
            }
            for url in urls {
                try Task.checkCancellation()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let report = try await importer.importHoldArchive(
                    url: url,
                    hold: hold,
                    operatorBinding: operatorBinding
                )
                imported += 1
                messageCount += report.messagesImported
                warningCount += report.warnings.count
                lastImportReport = report
            }
            isShowingImportReport = true
            setup.update(.exportAccess, state: .ready, message: "Slack export access produced a valid archive.")
            setup.update(.custodianExports, state: .ready, message: "\(imported) hold-wide Slack export ZIP(s) imported.")
            statusMessage = "Imported \(imported) ZIP file(s) and \(messageCount) normalized message(s)\(warningCount == 0 ? "." : " with \(warningCount) warning(s).")"
            touchActivity()
            await search()
        } catch is CancellationError {
            statusMessage = "Import stopped. Completed ZIP files remain available; an interrupted ZIP can be resumed."
        } catch { show(error) }
    }

    func chooseHoldTransferDestination() {
        guard selectedHold?.status == .active else { return }
        let panel = NSSavePanel()
        panel.title = "Save the encrypted legal hold package"
        panel.nameFieldStringValue = "ThreadLight-Hold-\(selectedHold?.name.fileSafePrefix ?? "Export").threadlight-hold"
        panel.allowedContentTypes = [UTType(filenameExtension: "threadlight-hold") ?? .data]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await exportHoldTransfer(to: url) }
    }

    func exportHoldTransfer(to destination: URL) async {
        guard let hold = selectedHold, let store, let legalHoldClient else { return }
        let access = destination.startAccessingSecurityScopedResource()
        defer { if access { destination.stopAccessingSecurityScopedResource() } }
        do {
            let currentHold = try await legalHoldClient.policy(id: hold.id)
            let currentCustodians = try await legalHoldClient.listCustodians(policyID: hold.id)
            _ = try await reconcileCustodians(currentCustodians, for: currentHold)
            guard currentHold.status == .active else {
                throw ThreadLightError.scope("Slack reports that this hold is no longer active.")
            }
            _ = try await HoldTransferService(store: store).export(
                hold: currentHold,
                custodians: currentCustodians,
                destination: destination
            )
            statusMessage = "Created encrypted package \(destination.lastPathComponent). Transfer it through your approved channel."
            touchActivity()
        } catch { show(error) }
    }

    func chooseHoldTransferImport() {
        guard isConnected else { return }
        let panel = NSOpenPanel()
        panel.title = "Import an encrypted legal hold package"
        panel.allowedContentTypes = [UTType(filenameExtension: "threadlight-hold") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importHoldTransfer(from: url) }
    }

    func importHoldTransfer(from url: URL) async {
        guard let store, let legalHoldClient else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let currentHolds = try await legalHoldClient.listPolicies(status: .active)
            var candidates: [HoldTransferCandidate] = []
            for hold in currentHolds {
                let currentCustodians = try await legalHoldClient.listCustodians(policyID: hold.id)
                _ = try await reconcileCustodians(currentCustodians, for: hold)
                candidates.append(.init(hold: hold, custodians: currentCustodians))
            }
            let result = try await HoldTransferService(store: store).importTransfer(
                url: url,
                candidates: candidates
            )
            holds = currentHolds
            sidebarSelection = .hold(result.hold.id)
            statusMessage = "Matched \(result.hold.name). Imported \(result.archivesImported) source ZIP(s) and \(result.messagesImported) message(s)."
            touchActivity()
        } catch { show(error) }
    }

    func refreshLegalHolds() async {
        guard let legalHoldClient, let store else { return }
        do {
            let refreshed = try await legalHoldClient.listPolicies(status: nil)
            var invalidated = 0
            let refreshedIDs = Set(refreshed.map(\.id))
            for oldHold in try await store.holds() where !refreshedIDs.contains(oldHold.id) {
                if try await store.purgeEvidence(holdID: oldHold.id) { invalidated += 1 }
            }
            for hold in refreshed {
                try await store.save(hold: hold)
                let currentCustodians = try await legalHoldClient.listCustodians(policyID: hold.id)
                if try await reconcileCustodians(currentCustodians, for: hold) { invalidated += 1 }
            }
            holds = refreshed
            if let selectedHold, let current = refreshed.first(where: { $0.id == selectedHold.id }) {
                self.selectedHold = current
                await loadCustodians(for: current)
            }
            statusMessage = invalidated == 0
                ? "Refreshed \(refreshed.count) legal hold(s) from Slack."
                : "A legal hold changed in Slack. ThreadLight removed its old local data because the encrypted package is no longer valid. Import a new package for that hold."
        } catch { show(error) }
    }

    func saveManagedConfigurationProfile() {
        guard isConnected else {
            show(ThreadLightError.invalidConfiguration("Sign in to Slack and verify the connection before saving the MDM profile."))
            return
        }
        guard let organizationID = setup.expectedOrganizationID ?? currentOrganizationID else {
            show(ThreadLightError.invalidConfiguration("ThreadLight could not identify the Slack organization. Sign in again, then save the MDM profile."))
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save the ThreadLight settings profile"
        panel.nameFieldStringValue = "ThreadLight.mobileconfig"
        panel.allowedContentTypes = [UTType(filenameExtension: "mobileconfig") ?? .data]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.prompt = "Save profile"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let access = destination.startAccessingSecurityScopedResource()
        defer { if access { destination.stopAccessingSecurityScopedResource() } }
        do {
            let configuration = try ManagedConfiguration(
                slackClientID: setup.slackClientID,
                organizationName: setup.organizationName,
                enterpriseDomain: setup.organizationDomain,
                expectedOrganizationID: organizationID,
                retentionDays: retentionDays
            )
            try configuration.profileData().write(to: destination, options: [.atomic, .completeFileProtection])
            statusMessage = "Saved the ThreadLight settings profile. Add it to MDM and assign it to the Macs that will use ThreadLight."
        } catch {
            show(error)
        }
    }

    func presentExportPanel() {
        guard !selectedMessageIDs.isEmpty else { return }
        isShowingExportOptions = true
    }

    func chooseExportDestination(selectionScope: ExportSelectionScope, formats: Set<EvidenceExportFormat>) {
        guard !selectedMessageIDs.isEmpty, !formats.isEmpty else { return }
        isShowingExportOptions = false
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        panel.title = "Choose an evidence export folder"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await exportEvidence(to: url, selectionScope: selectionScope, formats: formats) }
        }
    }

    func exportEvidence(
        to destination: URL,
        selectionScope: ExportSelectionScope = .selectedMessages,
        formats: Set<EvidenceExportFormat> = [.json, .pdf]
    ) async {
        guard let hold = selectedHold, let store else { return }
        let access = destination.startAccessingSecurityScopedResource()
        defer { if access { destination.stopAccessingSecurityScopedResource() } }
        var selected = messages.filter { selectedMessageIDs.contains($0.id) }
        do {
            guard let legalHoldClient else {
                throw ThreadLightError.scope("Reconnect Slack before exporting so ThreadLight can confirm the hold is still active.")
            }
            let currentHold = try await legalHoldClient.policy(id: hold.id)
            try await store.save(hold: currentHold)
            if let index = holds.firstIndex(where: { $0.id == currentHold.id }) { holds[index] = currentHold }
            selectedHold = currentHold
            guard currentHold.status == .active else {
                messages = []
                selectedMessageIDs.removeAll()
                throw ThreadLightError.scope("Slack reports that this hold is not active. Search and export are blocked.")
            }
            let currentCustodians = try await legalHoldClient.listCustodians(policyID: currentHold.id)
            try await store.replaceCustodians(currentCustodians, holdID: currentHold.id)
            custodians = currentCustodians
            try await refreshEvidenceReadiness(for: currentHold)
            if selectionScope == .completeThreads {
                var complete: [String: EvidenceMessage] = [:]
                for threadID in Set(selected.map(\.threadID)).sorted() {
                    for message in try await store.thread(holdID: currentHold.id, threadID: threadID) {
                        complete[message.id] = message
                    }
                }
                selected = complete.values.sorted { $0.postedAt < $1.postedAt }
            }
            let exporter = EvidenceExporter(store: store, resourceVault: resourceVault)
            let result = try await exporter.export(
                messages: selected,
                hold: currentHold,
                custodians: currentCustodians,
                destination: destination,
                formats: formats
            )
            statusMessage = "Created and verified \(result.packageURL.lastPathComponent). Signer key: \(result.keyID.prefix(12))…"
            touchActivity()
        } catch { show(error) }
    }

    func verifyEvidencePackage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Verify"
        panel.title = "Choose a ThreadLight evidence package"
        if panel.runModal() == .OK, let url = panel.url {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                guard try EvidenceExporter.verify(packageURL: url) else {
                    throw ThreadLightError.export("Signature or package hashes do not match.")
                }
                let envelopeURL = url.appending(path: "manifest.threadlight-signature.json")
                let envelope = try CanonicalJSON.decoder.decode(SignatureEnvelope.self, from: Data(contentsOf: envelopeURL))
                statusMessage = "Verified internally. Compare signer key \(envelope.keyID.prefix(12))… with your trusted record."
            } catch { show(error) }
        }
    }

    func importAttachment(_ file: EvidenceFile, for message: EvidenceMessage) {
        guard let store, let resourceVault else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose original bytes for \(file.name)"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let imported = try await resourceVault.importResource(url: url, replacing: file)
                    var updated = message
                    guard let index = updated.files.firstIndex(where: { $0.id == file.id }) else { return }
                    updated.files[index] = imported
                    try await store.update(message: updated)
                    selectedMessage = updated
                    if let hold = selectedHold { try await refreshEvidenceReadiness(for: hold) }
                    await search()
                    if let refreshed = messages.first(where: { $0.id == updated.id }) { selectedMessage = refreshed }
                    statusMessage = "Imported and indexed \(imported.name)."
                } catch { show(error) }
            }
        }
    }

    func previewAttachment(_ file: EvidenceFile) {
        guard let resourceVault else { return }
        Task {
            do {
                let data = try await resourceVault.cleartext(for: file)
                try quickLook.present(data: data, filename: file.name)
            } catch { show(error) }
        }
    }

    func purgeEvidence() async {
        do {
            holdLoadTask?.cancel()
            threadLoadTask?.cancel()
            let active = activeStorageNamespace
            let namespaces = knownStorageNamespaces().union(active.map { [$0] } ?? [])
            for namespace in namespaces.sorted() {
                if namespace == active {
                    try await store?.purge()
                    try await resourceVault?.purge()
                } else {
                    try await ResourceVault.removeDefault(organizationID: namespace)
                    try await EvidenceStore.removeDefault(organizationID: namespace)
                }
                UserDefaults.standard.removeObject(forKey: Self.lastActivityKeyPrefix + namespace)
            }
            holds.removeAll(); custodians.removeAll(); importedCustodianIDs.removeAll(); messages.removeAll(); selectedHold = nil
            selectedMessage = nil; selectedMessageIDs.removeAll(); threadMessages.removeAll()
            sidebarSelection = .setup
            setup.update(.custodianExports, state: .pending)
            setup.update(.attachments, state: .pending)
            statusMessage = "Purged local evidence from \(namespaces.count) organization profile(s)."
            touchActivity()
        } catch { show(error) }
    }

    func saveSlackAppManifest() {
        saveSlackManifest(
            SlackAppManifest.template,
            filename: SlackAppManifest.filename,
            title: "Save the Slack app manifest",
            status: "Saved the complete Slack app manifest."
        )
    }

    private func saveSlackManifest(_ contents: String, filename: String, title: String, status: String) {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = [.yaml]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.prompt = "Save manifest"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            let access = destination.startAccessingSecurityScopedResource()
            defer { if access { destination.stopAccessingSecurityScopedResource() } }
            try Data(contents.utf8).write(to: destination, options: .atomic)
            statusMessage = status
        } catch {
            show(error)
        }
    }

    func saveSlackAppIcon() {
        guard let source = Bundle.main.url(forResource: "SlackAppIcon", withExtension: "png") else {
            show(ThreadLightError.invalidConfiguration("The bundled Slack app icon is unavailable. Reinstall ThreadLight and try again."))
            return
        }

        let panel = NSSavePanel()
        panel.title = "Save the ThreadLight icon for Slack"
        panel.nameFieldStringValue = "ThreadLight-Slack-App-Icon.png"
        panel.allowedContentTypes = [.png]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.prompt = "Save icon"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            let access = destination.startAccessingSecurityScopedResource()
            defer { if access { destination.stopAccessingSecurityScopedResource() } }
            try Data(contentsOf: source).write(to: destination, options: .atomic)
            statusMessage = "Saved the Slack app icon. Upload it under Basic Information → Display Information in Slack app settings."
        } catch {
            show(error)
        }
    }

    func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    private func show(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        isShowingError = true
    }

    private func refreshEvidenceReadiness(for hold: LegalHold) async throws {
        guard let store else { return }
        let archives = try await store.archives(holdID: hold.id)
        importedCustodianIDs = []
        if archives.isEmpty { setup.update(.custodianExports, state: .pending) }
        else { setup.update(.custodianExports, state: .ready, message: "\(archives.count) hold-wide Slack export ZIP(s) imported.") }

        let attachments = try await store.attachmentAvailability(holdID: hold.id)
        if attachments.referenced == 0 {
            setup.update(.attachments, state: .notApplicable)
        } else if attachments.available == attachments.referenced {
            setup.update(.attachments, state: .ready, message: "All referenced attachment bytes are encrypted locally.")
        } else {
            setup.update(.attachments, state: .blocked(reason: "\(attachments.referenced - attachments.available) referenced attachment file(s) still need original bytes."))
        }
    }

    @discardableResult
    private func reconcileCustodians(_ loaded: [Custodian], for hold: LegalHold) async throws -> Bool {
        guard let store else { return false }
        let previous = try await store.custodians(holdID: hold.id)
        var invalidated = false
        if !previous.isEmpty,
           HoldAccessKey.fingerprint(hold: hold, custodians: previous)
            != HoldAccessKey.fingerprint(hold: hold, custodians: loaded),
           try await store.purgeEvidence(holdID: hold.id) {
            invalidated = true
            statusMessage = "The legal hold “\(hold.name)” changed in Slack. ThreadLight removed its old local data because that encrypted package is no longer valid. Import a new package."
            if selectedHold?.id == hold.id {
                messages = []
                selectedMessage = nil
                selectedMessageIDs.removeAll()
                threadMessages = []
            }
        }
        try await store.save(hold: hold)
        try await store.replaceCustodians(loaded, holdID: hold.id)
        return invalidated
    }

    private func touchActivity() {
        guard let activeStorageNamespace else { return }
        UserDefaults.standard.set(Date(), forKey: Self.lastActivityKeyPrefix + activeStorageNamespace)
    }

    private func knownStorageNamespaces() -> Set<String> {
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        return Set(defaults.keys.compactMap { key in
            guard key.hasPrefix(Self.lastActivityKeyPrefix) else { return nil }
            let namespace = String(key.dropFirst(Self.lastActivityKeyPrefix.count))
            return ThreadLightBuild.isValidStorageNamespace(namespace) ? namespace : nil
        })
    }

    private func purgeExpiredStorageNamespaces(now: Date = Date()) async throws -> Int {
        var purged = 0
        for namespace in knownStorageNamespaces().sorted() {
            let key = Self.lastActivityKeyPrefix + namespace
            guard let lastActivity = UserDefaults.standard.object(forKey: key) as? Date,
                  now.timeIntervalSince(lastActivity) >= Double(retentionDays) * 86_400 else { continue }
            try await ResourceVault.removeDefault(organizationID: namespace)
            try await EvidenceStore.removeDefault(organizationID: namespace)
            UserDefaults.standard.removeObject(forKey: key)
            if let remembered = UserDefaults.standard.string(forKey: Self.lastOrganizationIDKey),
               ThreadLightBuild.storageNamespace(organizationID: remembered) == namespace {
                UserDefaults.standard.removeObject(forKey: Self.lastOrganizationIDKey)
            }
            purged += 1
        }
        return purged
    }

    private func openStorage(organizationID: String, remember: Bool = true) async throws {
        let namespace = ThreadLightBuild.storageNamespace(organizationID: organizationID)
        guard namespace != activeStorageNamespace else {
            touchActivity()
            return
        }
        holdLoadTask?.cancel()
        threadLoadTask?.cancel()
        store = try await EvidenceStore.openDefault(organizationID: namespace)
        resourceVault = try await ResourceVault.openDefault(organizationID: namespace)
        currentOrganizationID = organizationID == "unconfigured" ? nil : organizationID
        activeStorageNamespace = namespace
        if remember, organizationID != "unconfigured" {
            UserDefaults.standard.set(organizationID, forKey: Self.lastOrganizationIDKey)
        }
        holds = try await store?.holds() ?? []
        if holds.isEmpty {
            setup.update(.custodianExports, state: .pending)
            setup.update(.attachments, state: .pending)
        }
        custodians = []
        importedCustodianIDs = []
        messages = []
        threadMessages = []
        selectedHold = nil
        selectedMessage = nil
        selectedMessageIDs = []
        sidebarSelection = holds.first.map { .hold($0.id) } ?? .setup
        touchActivity()
    }

#if THREADLIGHT_DEVELOPMENT
    private func seedDemoEvidence(complete: Bool) async throws {
        guard let store else { return }
        try await store.purge()
        try await resourceVault?.purge()
        try setup.recordLegalRequesterSignerKeyID(String(repeating: "1", count: 64))
        try setup.recordAdministratorSignerKeyID(String(repeating: "2", count: 64))
        let now = Date()
        let active = LegalHold(
            id: "H-DEMO-ACTIVE",
            organizationID: "E-DEMO",
            name: "Northstar Preservation",
            summary: "Executive communications concerning the Northstar acquisition review.",
            status: .active,
            createdAt: now.addingTimeInterval(-30 * 86_400),
            updatedAt: now,
            startAt: now.addingTimeInterval(-14 * 86_400),
            endAt: now.addingTimeInterval(86_400)
        )
        let released = LegalHold(
            id: "H-DEMO-RELEASED",
            organizationID: "E-DEMO",
            name: "Atlas Matter",
            summary: "Released demonstration hold.",
            status: .released,
            createdAt: now.addingTimeInterval(-120 * 86_400),
            updatedAt: now.addingTimeInterval(-7 * 86_400)
        )
        let custodians = [
            Custodian(id: "U-DEMO-ALEX", holdID: active.id, displayName: "Alex Rivera", email: "alex@example.invalid"),
            Custodian(id: "U-DEMO-MORGAN", holdID: active.id, displayName: "Morgan Lee", email: "morgan@example.invalid"),
        ]
        try await store.save(hold: active)
        try await store.save(hold: released)
        try await store.replaceCustodians(custodians, holdID: active.id)
        let source = SourceArchive(
            holdID: active.id,
            custodianID: custodians[0].id,
            originalFilename: "alex-rivera-demo-export.zip",
            sha256: String(repeating: "d", count: 64),
            coverageStart: active.startAt,
            coverageEnd: now,
            operatorBinding: "Demo Legal Reviewer",
            isPerCustodian: true
        )
        try await store.beginImport(source)
        var attachment = EvidenceFile(
            id: "F-DEMO-MEMO",
            name: "Northstar approval memo.pdf",
            mimeType: "application/pdf",
            size: 248_100,
            remoteURL: URL(string: "https://files.slack.com/demo/Northstar-approval-memo.pdf")
        )
        if complete, let resourceVault {
            let bytes = Data("%PDF-1.4\n% ThreadLight sanitized demo attachment\n%%EOF\n".utf8)
            let temporaryURL = FileManager.default.temporaryDirectory.appending(path: "Northstar approval memo.pdf")
            try bytes.write(to: temporaryURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            attachment.size = Int64(bytes.count)
            attachment = try await resourceVault.importResource(url: temporaryURL, replacing: attachment)
        }
        let rootID = "E-DEMO:C-DEAL:\(now.addingTimeInterval(-3_600).timeIntervalSince1970)"
        let messages = [
            EvidenceMessage(
                id: rootID,
                conversationID: "C-DEAL",
                conversationName: "northstar-deal-team",
                conversationKind: .privateChannel,
                threadID: rootID,
                senderID: custodians[0].id,
                senderName: custodians[0].displayName,
                text: "Please preserve the final approval memo and the board timeline for legal review.",
                postedAt: now.addingTimeInterval(-3_600),
                reactions: [.init(name: "white_check_mark", count: 2, userIDs: custodians.map(\.id))],
                files: [attachment]
            ),
            EvidenceMessage(
                id: "E-DEMO:C-DEAL:\(now.addingTimeInterval(-3_300).timeIntervalSince1970)",
                conversationID: "C-DEAL",
                conversationName: "northstar-deal-team",
                conversationKind: .privateChannel,
                threadID: rootID,
                senderID: custodians[1].id,
                senderName: custodians[1].displayName,
                text: "I added the revised dates. The approval remains scheduled for Friday.",
                postedAt: now.addingTimeInterval(-3_300),
                editedAt: now.addingTimeInterval(-3_100)
            ),
            EvidenceMessage(
                id: "E-DEMO:C-DEAL:\(now.addingTimeInterval(-2_900).timeIntervalSince1970)",
                conversationID: "C-DEAL",
                conversationName: "northstar-deal-team",
                conversationKind: .privateChannel,
                threadID: rootID,
                senderID: custodians[0].id,
                senderName: custodians[0].displayName,
                text: "Thank you. Keep the source spreadsheet with the scoped conversation.",
                postedAt: now.addingTimeInterval(-2_900)
            ),
        ]
        for message in messages {
            _ = try await store.insert(
                message: message,
                membership: .init(
                    holdID: active.id,
                    custodianID: custodians[0].id,
                    messageID: message.id,
                    sourceArchiveID: source.id
                )
            )
        }
        try await store.completeImport(source)
        if complete {
            let secondSource = SourceArchive(
                holdID: active.id,
                custodianID: custodians[1].id,
                originalFilename: "morgan-lee-demo-export.zip",
                sha256: String(repeating: "e", count: 64),
                coverageStart: active.startAt,
                coverageEnd: now,
                operatorBinding: "Demo Legal Reviewer",
                isPerCustodian: true
            )
            try await store.beginImport(secondSource)
            for message in messages {
                _ = try await store.insert(
                    message: message,
                    membership: .init(
                        holdID: active.id,
                        custodianID: custodians[1].id,
                        messageID: message.id,
                        sourceArchiveID: secondSource.id
                    )
                )
            }
            try await store.completeImport(secondSource)
        }
        legalHoldClient = DemoLegalHoldClient(holds: [active, released], custodians: custodians)
        isConnected = true
        holds = [active, released]
        setup.update(.internalApp, state: .ready)
        setup.update(.pkce, state: .ready)
        setup.update(.readScope, state: .ready)
        setup.update(.enterpriseInstall, state: .ready)
        setup.update(.exportAccess, state: .ready, message: "Sanitized demo prerequisite validated.")
        setup.update(
            .custodianExports,
            state: complete ? .ready : .blocked(reason: "Missing export for Morgan Lee."),
            message: complete ? "Sanitized demo Slack exports are present." : nil
        )
        setup.update(
            .attachments,
            state: complete ? .ready : .blocked(reason: "1 referenced attachment still needs original bytes."),
            message: complete ? "Every sanitized demo attachment is present." : nil
        )
        statusMessage = "Sanitized development demo loaded. No Slack data or credentials are in use."
        sidebarSelection = .hold(active.id)
    }

    private enum DemoMode {
        case incomplete
        case complete
    }

    private static var demoMode: DemoMode? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--threadlight-demo-complete") { return .complete }
        if arguments.contains("--threadlight-demo") { return .incomplete }
        return nil
    }
#endif

    private func verifiedOrganizationID(tokens: OAuthTokenSet, holds: [LegalHold]) throws -> String {
        let identifier: String
        if let enterpriseID = tokens.enterpriseID, !enterpriseID.isEmpty {
            identifier = enterpriseID
        } else {
            let identifiers = Set(holds.map(\.organizationID).filter { !$0.isEmpty && $0 != "unknown" })
            guard identifiers.count == 1, let discovered = identifiers.first else {
                throw ThreadLightError.authentication("Slack could not identify your organization. Ask an organization owner to verify the ThreadLight app installation, then sign in again.")
            }
            identifier = discovered
        }
        if let expected = setup.expectedOrganizationID, expected != identifier {
            throw ThreadLightError.authentication("This Mac is set up for a different Slack organization. Sign out of Slack in your browser, choose the correct organization, and sign in again.")
        }
        return identifier
    }

    private static let retentionDaysKey = "threadlight.retentionDays.v1"
    private static let lastActivityKeyPrefix = "threadlight.lastActivity.v2."
    private static let lastOrganizationIDKey = "threadlight.lastOrganizationID.v1"
}

private extension String {
    var fileSafePrefix: String {
        let cleaned = replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((cleaned.isEmpty ? "Export" : cleaned).prefix(48))
    }
}

#if THREADLIGHT_DEVELOPMENT
private actor DemoLegalHoldClient: LegalHoldClient {
    let holds: [LegalHold]
    let custodians: [Custodian]

    init(holds: [LegalHold], custodians: [Custodian]) {
        self.holds = holds
        self.custodians = custodians
    }

    func listPolicies(status: HoldStatus?) async throws -> [LegalHold] {
        status.map { requested in holds.filter { $0.status == requested } } ?? holds
    }

    func policy(id: String) async throws -> LegalHold {
        guard let hold = holds.first(where: { $0.id == id }) else {
            throw ThreadLightError.slack("Demo hold not found.", remediation: "Reload the development demo.")
        }
        return hold
    }

    func listCustodians(policyID: String) async throws -> [Custodian] {
        custodians.filter { $0.holdID == policyID }
    }
}
#endif

@MainActor
private final class SlackAuthorizationController: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authorize(clientID: String) async throws -> OAuthTokenSet {
        let attempt = try OAuthAttempt.make(clientID: clientID)
        defer {
            session?.cancel()
            session = nil
        }
        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: attempt.authorizationURL, callbackURLScheme: "threadlight") { url, error in
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: ThreadLightError.authentication("Slack sign-in ended without a callback.")) }
            }
            session.presentationContextProvider = self
            self.session = session
            guard session.start() else {
                continuation.resume(throwing: ThreadLightError.authentication("Could not open the secure Slack sign-in window."))
                return
            }
        }
        let code = try attempt.authorizationCode(from: callbackURL)
        return try await SlackOAuthClient().exchange(code: code, verifier: attempt.pkce.verifier, clientID: clientID)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}
