import AppKit
import Foundation
import Observation
import ThreadLightCore
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    struct MessageThreadGroup: Identifiable {
        let id: String
        let messages: [EvidenceMessage]
    }

    enum SidebarSelection: Hashable {
        case setup
        case hold(String)
    }

    enum HoldListFilter: String, CaseIterable, Identifiable {
        case active
        case inactive
        case all

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum ExportSelectionScope: String, CaseIterable, Identifiable {
        case selectedMessages
        case completeThreads

        var id: String { rawValue }
        var title: String { self == .selectedMessages ? "Selected messages" : "Complete selected threads" }
    }

    enum MessageSort: String, CaseIterable, Identifiable {
        case newest
        case oldest
        case sender
        case conversation

        var id: String { rawValue }
        var title: String {
            switch self {
            case .newest: "Newest first"
            case .oldest: "Oldest first"
            case .sender: "Sender A–Z"
            case .conversation: "Conversation A–Z"
            }
        }
    }

    let setup: SetupCoordinator
    var sidebarSelection: SidebarSelection = .setup {
        didSet {
            switch sidebarSelection {
            case .setup:
                selectedHold = nil
                custodians = []
                slackUserProfiles = [:]
                conversations = []
                hasImportedPackage = false
                selectedMessage = nil
                threadMessages = []
                selectedMessageIDs.removeAll()
            case let .hold(id):
                selectHold(id: id)
            }
        }
    }
    var holds: [LegalHold] = []
    var holdListFilter: HoldListFilter = .active {
        didSet { selectDefaultHold() }
    }
    var custodians: [Custodian] = []
    var slackUserProfiles: [String: SlackUserProfile] = [:]
    var liveReactions: [String: [EvidenceReaction]] = [:]
    var slackEmojiURLs: [String: URL] = [:]
    var conversations: [EvidenceConversation] = []
    var importedCustodianIDs: Set<String> = []
    var hasImportedPackage = false
    var messages: [EvidenceMessage] = [] {
        didSet { rebuildMessageIndex() }
    }
    private(set) var messageThreadGroups: [MessageThreadGroup] = []
    private var messageByID: [String: EvidenceMessage] = [:]
    var threadMessages: [EvidenceMessage] = []
    var selectedHold: LegalHold?
    var selectedMessage: EvidenceMessage?
    var selectedMessageIDs: Set<String> = []
    var queryText = ""
    var searchMode: SearchMode = .basic
    var messageSort: MessageSort = .newest {
        didSet { rebuildMessageIndex() }
    }
    var searchFilters = SearchFilters()
    var isSearching = false
    private(set) var canLoadMoreMessages = false
    var isStarting = true
    var isDemoSession = false
    var isConnected = false
    var isShowingError = false
    var errorMessage: String?
    /// Full copyable diagnostics for the last error, and its type on its own for issue titles.
    private(set) var lastErrorReport = ""
    private(set) var lastErrorCategory = "unknown"
    var statusMessage = "Complete setup to begin." {
        didSet { recordActivity(statusMessage) }
    }
    /// Timestamped recent status messages, embedded in error reports so "what the app was
    /// doing" is answered by the app instead of left as a placeholder for the operator.
    private var recentActivity: [String] = []
    /// Evidence-critical operations in flight (imports, packaging, purges). Quitting the app
    /// waits for these: exit() during live SQLCipher work runs its atexit teardown under a
    /// running statement, which crashed in the field (SIGSEGV in sqlite3Codec).
    private(set) var criticalOperationCount = 0
    private var criticalWorkContinuations: [CheckedContinuation<Void, Never>] = []
    var retentionDays: Int {
        didSet { UserDefaults.standard.set(retentionDays, forKey: Self.retentionDaysKey) }
    }
    var isShowingImportReport = false
    var isShowingExportOptions = false
    var lastImportReport: ImportReport?
    var importProgress: ImportProgress?
    /// Packaging owns a multi-minute import plus an export, so the model holds the task.
    /// A transient sheet cannot outlive it, and its outcome is always reported.
    private(set) var isPackaging = false
    /// Increments only after a package is written, so the staged ZIP list clears exactly once.
    private(set) var completedPackageCount = 0
    private(set) var currentOrganizationID: String?
    private(set) var pendingSignIn: OAuthAttempt?
    private(set) var webSessionSignIn: SlackWebSessionSignIn?

    private var store: EvidenceStore?
    private var resourceVault: ResourceVault?
    private var legalHoldClient: (any LegalHoldClient)?
    private let tokenVault = SlackTokenVault()
    private let quickLook = QuickLookPresenter()
    private var holdLoadTask: Task<Void, Never>?
    private var threadLoadTask: Task<Void, Never>?
    private var packageTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var hasStarted = false
    private var searchGeneration = 0
    private var activeStorageNamespace: String?
    private var requestedConversation: (holdID: String, conversationID: String)?
    private var requestedSlackUserIDs: Set<String> = []
    private var requestedReactionMessageIDs: Set<String> = []
    private var custodianValidatedAt: [String: Date] = [:]

    var visibleHolds: [LegalHold] {
        let filtered = switch holdListFilter {
        case .active: holds.filter { $0.status == .active }
        case .inactive: holds.filter { $0.status != .active }
        case .all: holds
        }
        return filtered.sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt > $1.createdAt
        }
    }

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
        // Every scene calls this, and they now share one model. Opening a second store on the
        // same encrypted database is what made Settings work invisible to the main window.
        guard !hasStarted else { return }
        hasStarted = true
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
            guard tokens.hasExactThreadLightUserScopes else {
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
            Task { await refreshSlackEmojiCatalog() }
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
            ThreadLightLog.session.notice("slack session restored: holds=\(loadedHolds.count, privacy: .public)")
            setStatus("Slack connection restored.")
            selectDefaultHold()
        } catch {
            isConnected = false
            ThreadLightLog.session.error(
                "slack session restore failed: \(ThreadLightLog.category(of: error), privacy: .public)"
            )
            setStatus("Slack must be reconnected. Local evidence remains available.")
        }
    }

    func beginSlackSignIn() {
        do {
            guard !setup.requiresAdministratorSignerConfirmation else {
                throw ThreadLightError.invalidConfiguration(
                    "Confirm the Slack Admin handoff signer before signing in. The handoff carries its own verifying key, so its signature alone does not prove who sent it — compare the full signer ID with the Slack Admin through your approved channel, then confirm it in setup."
                )
            }
            setup.save()
            let attempt = try OAuthAttempt.make(clientID: setup.slackClientID, organizationID: setup.expectedOrganizationID)
            pendingSignIn = attempt
            NSWorkspace.shared.open(attempt.authorizationURL)
            statusMessage = "Approve ThreadLight in the browser, then paste the address of the final page below."
        } catch {
            show(error)
        }
    }

    func cancelSlackSignIn() {
        pendingSignIn = nil
        statusMessage = "Slack sign-in canceled."
    }

    /// For a signed-in person whose Slack role (e.g. Legal Holds Admin) can use Slack's own admin
    /// console but cannot complete OAuth for `admin.legal_holds:read` — Slack restricts that OAuth
    /// grant to Org Owners regardless of role. Reads the same data through that live web session
    /// instead. See `SlackWebSessionSignIn`.
    func beginSlackWebSessionSignIn() {
        guard let enterpriseID = setup.expectedOrganizationID, !enterpriseID.isEmpty else {
            show(ThreadLightError.invalidConfiguration("This Mac has no expected Slack organization yet. Complete setup first."))
            return
        }
        let signIn = SlackWebSessionSignIn()
        webSessionSignIn = signIn
        Task {
            do {
                try await signIn.beginSignIn(enterpriseID: enterpriseID)
                try await finishWebSessionConnection(signIn: signIn, organizationID: enterpriseID)
                ThreadLightLog.session.notice("web session sign-in: connected")
            } catch {
                if webSessionSignIn === signIn { webSessionSignIn = nil }
                if !(error is CancellationError) { show(error) }
                ThreadLightLog.session.error("web session sign-in: failed category=\(ThreadLightLog.category(of: error), privacy: .public)")
            }
        }
    }

    func cancelSlackWebSessionSignIn() {
        webSessionSignIn?.cancel()
        webSessionSignIn = nil
    }

    private func finishWebSessionConnection(signIn: SlackWebSessionSignIn, organizationID: String) async throws {
        let client = SlackLegalHoldClient(webSessionTransport: { method, fields in
            try await signIn.call(method: method, fields: fields)
        })
        let loadedHolds = try await client.listPolicies(status: nil)
        try setup.recordValidatedOrganizationID(organizationID)
        try await openStorage(organizationID: organizationID)
        legalHoldClient = client
        isConnected = true
        Task { await refreshSlackEmojiCatalog() }
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
        selectDefaultHold()
    }

    func logOut() async {
        do {
            try await tokenVault.remove(organizationID: "current")
            holdLoadTask?.cancel()
            threadLoadTask?.cancel()
            legalHoldClient = nil
            pendingSignIn = nil
            webSessionSignIn?.cancel()
            webSessionSignIn = nil
            isShowingImportReport = false
            isShowingExportOptions = false
            queryText = ""
            searchFilters = .init()
            messages = []
            canLoadMoreMessages = false
            conversations = []
            threadMessages = []
            slackUserProfiles = [:]
            liveReactions = [:]
            slackEmojiURLs = [:]
            requestedSlackUserIDs = []
            requestedReactionMessageIDs = []
            custodianValidatedAt = [:]
            selectedMessageIDs.removeAll()
            sidebarSelection = .setup
            statusMessage = "Logged out. Local evidence remains encrypted on this Mac."
            isConnected = false
        } catch {
            show(error)
        }
    }

    func completeSlackSignIn(pastedCallback: String) async {
        guard let attempt = pendingSignIn else { return }
        do {
            let trimmed = pastedCallback.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let callbackURL = URL(string: trimmed), callbackURL.host != nil else {
                throw ThreadLightError.authentication("That text is not a web address. Copy the entire address from the browser's address bar.")
            }
            let code = try attempt.authorizationCode(from: callbackURL)
            let tokens = try await SlackOAuthClient().exchange(code: code, verifier: attempt.pkce.verifier, clientID: setup.slackClientID)
            pendingSignIn = nil
            try await finishSlackConnection(tokens: tokens)
        } catch {
            if case let ThreadLightError.slack(_, remediation) = error {
                setup.update(.enterpriseInstall, state: .blocked(reason: remediation))
            }
            show(error)
        }
    }

    private func finishSlackConnection(tokens: OAuthTokenSet) async throws {
        guard tokens.hasExactThreadLightUserScopes else {
            throw ThreadLightError.authentication("Slack did not grant ThreadLight's five read-only user scopes. Update the Slack app manifest, then reconnect.")
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
        Task { await refreshSlackEmojiCatalog() }
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
        selectDefaultHold()
    }

    func selectHold(id: String) {
        guard let hold = holds.first(where: { $0.id == id }) else { return }
        if selectedHold?.id != id {
            cancelPackaging(reason: "the selected legal hold changed")
        }
        selectedHold = hold
        selectedMessage = nil
        threadMessages = []
        selectedMessageIDs.removeAll()
        importedCustodianIDs.removeAll()
        conversations = []
        searchFilters.conversationID = nil
        canLoadMoreMessages = false
        hasImportedPackage = false
        holdLoadTask?.cancel()
        holdLoadTask = Task {
            await loadCustodians(for: hold)
            guard !Task.isCancelled, selectedHold?.id == hold.id else { return }
            if hasImportedPackage {
                if requestedConversation?.holdID == hold.id {
                    searchFilters.conversationID = requestedConversation?.conversationID
                    requestedConversation = nil
                }
                await search()
                await loadConversations(for: hold)
            } else {
                messages = []
                isSearching = false
                statusMessage = "Waiting for the encrypted package for \(hold.name)."
            }
            await refreshCustodiansIfNeeded(for: hold)
        }
    }

    func loadCustodians(for hold: LegalHold) async {
        do {
            let loaded = try await store?.custodians(holdID: hold.id) ?? []
            guard !Task.isCancelled, selectedHold?.id == hold.id else { return }
            custodians = loaded
            try await refreshEvidenceReadiness(for: hold)
            Task { await refreshSlackUserProfiles(for: Set(loaded.map(\.id)), holdID: hold.id) }
        } catch is CancellationError {
            return
        } catch { show(error) }
    }

    private func refreshCustodiansIfNeeded(for hold: LegalHold) async {
        guard hold.status == .active, let legalHoldClient else { return }
        if let validatedAt = custodianValidatedAt[hold.id],
           Date().timeIntervalSince(validatedAt) < 300 {
            return
        }
        do {
            let loaded = try await legalHoldClient.listCustodians(policyID: hold.id)
            let invalidated = try await reconcileCustodians(loaded, for: hold)
            guard !Task.isCancelled, selectedHold?.id == hold.id else { return }
            if invalidated {
                try await refreshEvidenceReadiness(for: hold)
                return
            }
            let cached = try await store?.custodians(holdID: hold.id) ?? loaded
            guard !Task.isCancelled, selectedHold?.id == hold.id else { return }
            custodians = cached
            Task { await refreshSlackUserProfiles(for: Set(cached.map(\.id)), holdID: hold.id) }
        } catch is CancellationError {
            return
        } catch {
            show(error)
        }
    }

    /// Prefers a live-fetched Slack profile name, then the custodian's own stored name, then a
    /// name recovered from an already-loaded message they sent — falls back to nil (unresolved,
    /// e.g. still loading) rather than ever showing the raw Slack ID as a name.
    func resolvedCustodianName(for custodian: Custodian) -> String? {
        let candidates = [
            slackUserProfiles[custodian.id]?.displayName,
            custodian.displayName,
            messages.first(where: { $0.senderID == custodian.id })?.senderName,
        ]
        return candidates.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false && trimmed != custodian.id ? trimmed : nil
        }.first
    }

    func search(loadMore: Bool = false) async {
        searchGeneration += 1
        let generation = searchGeneration
        guard let hold = selectedHold, hold.status == .active, let store else {
            messages = []
            canLoadMoreMessages = false
            isSearching = false
            return
        }
        isSearching = true
        do {
            let pageSize = 500
            let offset = loadMore ? messages.count : 0
            let query = SearchQuery(
                text: queryText,
                mode: searchMode,
                filters: searchFilters,
                limit: pageSize + 1,
                offset: offset
            )
            let results = try await store.search(holdID: hold.id, query: query)
            guard generation == searchGeneration, selectedHold?.id == hold.id else { return }
            let page = Array(results.prefix(pageSize))
            if loadMore {
                let existingIDs = Set(messages.map(\.id))
                messages.append(contentsOf: page.filter { !existingIDs.contains($0.id) })
            } else {
                messages = page
            }
            canLoadMoreMessages = results.count > pageSize
            statusMessage = canLoadMoreMessages
                ? "\(messages.count) results loaded • More available"
                : "\(messages.count) matching message\(messages.count == 1 ? "" : "s")"
            touchActivity()
            Task { await refreshSlackUserProfiles(for: Set(page.map(\.senderID))) }
        } catch {
            if generation == searchGeneration { show(error) }
        }
        if generation == searchGeneration { isSearching = false }
    }

    func loadMoreMessages() async {
        guard canLoadMoreMessages, !isSearching else { return }
        await search(loadMore: true)
    }

    func selectConversation(id: String?) {
        searchFilters.conversationID = id
        selectedMessage = nil
        threadMessages = []
        selectedMessageIDs.removeAll()
        Task { await search() }
    }

    func openConversation(holdID: String, conversationID: String) {
        requestedConversation = (holdID, conversationID)
        holdListFilter = .all
        if sidebarSelection == .hold(holdID) {
            selectHold(id: holdID)
        } else {
            sidebarSelection = .hold(holdID)
        }
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
                Task { await refreshSlackUserProfiles(for: Set(loaded.map(\.senderID))) }
            }
            catch is CancellationError { return }
            catch { show(error) }
        }
    }

    func message(id: String) -> EvidenceMessage? {
        messageByID[id]
    }

    func toggleEvidenceSelection(_ id: String) {
        if selectedMessageIDs.contains(id) { selectedMessageIDs.remove(id) }
        else { selectedMessageIDs.insert(id) }
    }

    func refreshReactions(for message: EvidenceMessage) async {
        guard isConnected,
              let legalHoldClient,
              requestedReactionMessageIDs.insert(message.id).inserted,
              let timestamp = slackTimestamp(for: message) else { return }
        guard let reactions = try? await legalHoldClient.reactions(
            conversationID: message.conversationID,
            timestamp: timestamp
        ) else { return }
        liveReactions[message.id] = reactions
    }

    private func refreshSlackEmojiCatalog() async {
        guard isConnected, let legalHoldClient,
              let urls = try? await legalHoldClient.emojiURLs() else { return }
        slackEmojiURLs = urls
    }

    func setEvidenceSelection(for conversation: EvidenceConversation, selected: Bool) async {
        guard let hold = selectedHold, let store else { return }
        guard conversation.messageCount <= 50_000 else {
            show(ThreadLightError.export("This conversation has more than 50,000 messages. Narrow the search before selecting evidence."))
            return
        }
        do {
            var filters = SearchFilters()
            filters.conversationID = conversation.id
            let conversationMessages = try await store.search(
                holdID: hold.id,
                query: .init(filters: filters, limit: 50_000)
            )
            let ids = Set(conversationMessages.map(\.id))
            if selected {
                selectedMessageIDs.formUnion(ids)
                statusMessage = "Selected \(ids.count) messages from \(conversation.name)."
            } else {
                selectedMessageIDs.subtract(ids)
                statusMessage = "Unselected messages from \(conversation.name)."
            }
        } catch {
            show(error)
        }
    }

    func importHoldArchives(urls: [URL], operatorBinding: String, showReport: Bool = true) async -> Bool {
        guard let hold = selectedHold, let store, !urls.isEmpty else {
            ThreadLightLog.importer.error(
                """
                import refused: hold=\(self.selectedHold != nil, privacy: .public) \
                store=\(self.store != nil, privacy: .public) archives=\(urls.count, privacy: .public)
                """
            )
            if !urls.isEmpty {
                show(ThreadLightError.scope("Select an active legal hold before importing Slack export ZIPs."))
            }
            return false
        }
        importProgress = nil
        beginCriticalWork()
        defer {
            importProgress = nil
            endCriticalWork()
        }
        var imported = 0
        var skipped = 0
        var messageCount = 0
        var warningCount = 0
        ThreadLightLog.importer.notice("import started: archives=\(urls.count, privacy: .public)")
        do {
            // A fresh import for this hold should replace whatever is already there, not merge
            // with it — otherwise evidence dropped from a refreshed export (a revised scope, an
            // upstream redaction) would linger forever alongside the new archives. But a hold
            // left with an incomplete archive is mid-resume of a previously cancelled import,
            // not a fresh one, and purging here would throw away the completed archives that
            // resume is meant to leave alone.
            if try await !store.hasIncompleteImport(holdID: hold.id) {
                try await store.purgeEvidence(holdID: hold.id)
            }
            let importer = SlackExportImporter(store: store) { [weak self] progress in
                await MainActor.run { self?.importProgress = progress }
            }
            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                ThreadLightLog.importer.notice(
                    "archive \(index + 1, privacy: .public)/\(urls.count, privacy: .public) started, scoped=\(access, privacy: .public)"
                )
                let report: ImportReport
                do {
                    report = try await importer.importHoldArchive(
                        url: url,
                        hold: hold,
                        operatorBinding: operatorBinding
                    )
                } catch let error as ThreadLightError {
                    // The same export staged twice under two names is expected, not a failure.
                    // Its evidence is already in the store, so skip it and keep the batch going.
                    guard case .duplicateArchive = error else { throw error }
                    skipped += 1
                    ThreadLightLog.importer.notice(
                        """
                        archive \(index + 1, privacy: .public)/\(urls.count, privacy: .public) \
                        skipped: contents already imported for this hold
                        """
                    )
                    continue
                }
                imported += 1
                messageCount += report.messagesImported
                warningCount += report.warnings.count
                lastImportReport = report
                ThreadLightLog.importer.notice(
                    """
                    archive \(index + 1, privacy: .public)/\(urls.count, privacy: .public) done: \
                    messages=\(report.messagesImported, privacy: .public) \
                    deduplicated=\(report.messagesDeduplicated, privacy: .public) \
                    files=\(report.filesReferenced, privacy: .public) \
                    warnings=\(report.warnings.count, privacy: .public)
                    """
                )
            }
            isShowingImportReport = showReport
            // A skipped duplicate still means this hold holds that evidence.
            hasImportedPackage = imported + skipped > 0
            setup.update(.exportAccess, state: .ready, message: "Slack export access produced a valid archive.")
            setup.update(.custodianExports, state: .ready, message: "\(imported) hold-wide Slack export ZIP(s) imported.")
            let skippedNote = skipped == 0
                ? ""
                : " Skipped \(skipped) ZIP file(s) whose contents were already imported."
            statusMessage = "Imported \(imported) ZIP file(s) and \(messageCount) normalized message(s)"
                + (warningCount == 0 ? "." : " with \(warningCount) warning(s).")
                + skippedNote
            touchActivity()
            await loadConversations(for: hold)
            await search()
            ThreadLightLog.importer.notice(
                """
                import finished: archives=\(imported, privacy: .public) \
                skipped=\(skipped, privacy: .public) \
                messages=\(messageCount, privacy: .public) warnings=\(warningCount, privacy: .public)
                """
            )
            return true
        } catch is CancellationError {
            ThreadLightLog.importer.error(
                "import cancelled after \(imported, privacy: .public)/\(urls.count, privacy: .public) archives"
            )
            statusMessage = "Import stopped. Completed ZIP files remain available; an interrupted ZIP can be resumed."
            return false
        } catch {
            ThreadLightLog.importer.error(
                """
                import failed after \(imported, privacy: .public)/\(urls.count, privacy: .public) archives: \
                \(ThreadLightLog.category(of: error), privacy: .public)
                """
            )
            show(error)
            return false
        }
    }

    /// Refreshes holds from Slack every 15 minutes. Runs once for the whole app, however many
    /// windows are open.
    func beginPeriodicHoldRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(900))
                guard !Task.isCancelled, let self else { return }
                await self.refreshLegalHolds()
            }
        }
    }

    /// Imports the staged ZIPs and writes the encrypted package as one user-visible operation.
    /// Every exit path logs and leaves a status message; none of them can end in a stopped
    /// spinner with nothing said.
    func savePackage(archives: [URL], operatorBinding: String) {
        guard !isPackaging else { return }
        guard !archives.isEmpty else {
            show(ThreadLightError.export("Attach at least one Slack export ZIP before saving a package."))
            return
        }
        guard let destination = chooseHoldTransferDestination() else { return }
        isPackaging = true
        ThreadLightLog.transfer.notice("packaging started: archives=\(archives.count, privacy: .public)")
        packageTask = Task {
            defer {
                self.isPackaging = false
                self.packageTask = nil
            }
            let imported = await self.importHoldArchives(
                urls: archives,
                operatorBinding: operatorBinding,
                showReport: false
            )
            guard imported else {
                // importHoldArchives already logged the cause and set an error or status.
                ThreadLightLog.transfer.error("packaging stopped: the import did not complete")
                return
            }
            guard !Task.isCancelled else {
                ThreadLightLog.transfer.error("packaging cancelled between import and export")
                self.statusMessage = "Packaging stopped before the encrypted package was written. The imported ZIPs are still listed."
                return
            }
            if await self.exportHoldTransfer(to: destination) {
                self.completedPackageCount += 1
            }
        }
    }

    /// Cancels packaging when the work it depends on is about to be replaced. Silent
    /// cancellation is what made this failure invisible, so it always reports.
    private func cancelPackaging(reason: String) {
        guard isPackaging, let packageTask else { return }
        ThreadLightLog.transfer.error("packaging cancelled: \(reason, privacy: .public)")
        packageTask.cancel()
        self.packageTask = nil
        isPackaging = false
        statusMessage = "Packaging stopped because \(reason). No encrypted package was written."
    }

    /// Background status text that must never overwrite the outcome of an operation the
    /// user is waiting on. Terminal import/export messages assign `statusMessage` directly.
    private func setStatus(_ message: String) {
        guard !isPackaging else {
            ThreadLightLog.session.info("suppressed background status while packaging")
            return
        }
        statusMessage = message
    }

    func chooseHoldTransferDestination() -> URL? {
        guard selectedHold?.status == .active else {
            ThreadLightLog.transfer.error(
                "destination refused: hold=\(self.selectedHold != nil, privacy: .public) active=false"
            )
            show(ThreadLightError.scope("Select an active legal hold before creating an encrypted package."))
            return nil
        }
        let panel = NSSavePanel()
        panel.title = "Save the encrypted legal hold package"
        panel.nameFieldStringValue =
            "ThreadLight-\(selectedHold?.name.fileSafePrefix ?? "Export").\(HoldTransferFile.pathExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: HoldTransferFile.pathExtension) ?? .data]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Without a passphrase the package key comes only from the hold and member IDs, which
    /// anyone with Legal Holds or Slack audit-log access can read. Offer the passphrase first.
    private func promptForExportPassphrase() -> String?? {
        let alert = NSAlert()
        alert.messageText = "Protect this package with a passphrase?"
        alert.informativeText = """
        Without a passphrase, the package is encrypted with a key derived from the hold and member IDs alone. \
        Anyone with Legal Holds access or Slack audit-log access can rebuild that key and read the package.

        Share the passphrase with the recipient through a channel separate from the package itself.
        """
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "At least 12 characters"
        alert.accessoryView = field
        alert.addButton(withTitle: "Use passphrase")
        alert.addButton(withTitle: "Export without passphrase")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .some(field.stringValue)
        case .alertSecondButtonReturn: return .some(nil)
        default: return nil
        }
    }

    private func promptForImportPassphrase() -> String? {
        let alert = NSAlert()
        alert.messageText = "This package needs its passphrase"
        alert.informativeText = "Enter the passphrase the sender shared through the approved channel."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    func exportHoldTransfer(to destination: URL) async -> Bool {
        guard let hold = selectedHold, let store, let legalHoldClient else {
            ThreadLightLog.transfer.error(
                """
                export refused: hold=\(self.selectedHold != nil, privacy: .public) \
                store=\(self.store != nil, privacy: .public) slack=\(self.legalHoldClient != nil, privacy: .public)
                """
            )
            show(ThreadLightError.authentication(
                "ThreadLight lost its Slack connection before it could build the package. The imported ZIPs are still here — reconnect to Slack and choose Save encrypted package again."
            ))
            return false
        }
        ThreadLightLog.transfer.notice("export started")
        guard let passphrase = promptForExportPassphrase() else {
            ThreadLightLog.transfer.notice("export cancelled at the passphrase prompt")
            statusMessage = "Package cancelled at the passphrase prompt. The imported ZIPs are still listed."
            return false
        }
        let access = destination.startAccessingSecurityScopedResource()
        beginCriticalWork()
        defer {
            if access { destination.stopAccessingSecurityScopedResource() }
            endCriticalWork()
        }
        ThreadLightLog.transfer.notice(
            "destination scoped=\(access, privacy: .public) passphrase=\(passphrase != nil, privacy: .public)"
        )
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
                destination: destination,
                passphrase: passphrase
            )
            statusMessage = passphrase == nil
                ? "Created \(destination.lastPathComponent) without a passphrase. Its key is derived from the hold and member IDs, so anyone with Legal Holds or Slack audit-log access can read it. Transfer it through your approved channel."
                : "Created passphrase-protected package \(destination.lastPathComponent). Send the passphrase separately from the package."
            touchActivity()
            ThreadLightLog.transfer.notice("export finished")
            return true
        } catch {
            ThreadLightLog.transfer.error("export failed: \(ThreadLightLog.category(of: error), privacy: .public)")
            show(error)
            return false
        }
    }

    func importHoldTransfer(from url: URL) async {
        guard let store, let legalHoldClient else { return }
        let access = url.startAccessingSecurityScopedResource()
        beginCriticalWork()
        defer {
            if access { url.stopAccessingSecurityScopedResource() }
            endCriticalWork()
        }
        do {
            var passphrase: String?
            if try HoldTransferService.requiresPassphrase(url: url) {
                guard let entered = promptForImportPassphrase() else { return }
                passphrase = entered
            }
            let currentHolds = try await legalHoldClient.listPolicies(status: nil)
            var candidates: [HoldTransferCandidate] = []
            for hold in currentHolds where hold.status == .active {
                let currentCustodians = try await legalHoldClient.listCustodians(policyID: hold.id)
                _ = try await reconcileCustodians(currentCustodians, for: hold)
                candidates.append(.init(hold: hold, custodians: currentCustodians))
            }
            let result = try await HoldTransferService(store: store).importTransfer(
                url: url,
                candidates: candidates,
                passphrase: passphrase
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
                if hold.status == .active {
                    let currentCustodians = try await legalHoldClient.listCustodians(policyID: hold.id)
                    if try await reconcileCustodians(currentCustodians, for: hold) { invalidated += 1 }
                }
            }
            holds = refreshed
            selectDefaultHold()
            if let selectedHold, let current = refreshed.first(where: { $0.id == selectedHold.id }) {
                self.selectedHold = current
                await loadCustodians(for: current)
                if hasImportedPackage {
                    await loadConversations(for: current)
                    await search()
                }
            }
            setStatus(invalidated == 0
                ? "Refreshed \(refreshed.count) legal hold(s) from Slack."
                : "A legal hold changed in Slack. ThreadLight removed its old local data because the encrypted package is no longer valid. Import a new package for that hold.")
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

    func chooseExportDestination(
        selectionScope: ExportSelectionScope,
        formats: Set<EvidenceExportFormat>,
        includeEvidenceSigning: Bool
    ) {
        guard !selectedMessageIDs.isEmpty, !formats.isEmpty else { return }
        isShowingExportOptions = false
        if !includeEvidenceSigning, formats.count == 1, let format = formats.first {
            let panel = NSSavePanel()
            panel.title = "Export Evidence"
            panel.nameFieldStringValue = "ThreadLight-\(selectedHold?.name.fileSafePrefix ?? "Evidence").\(format.rawValue)"
            panel.allowedContentTypes = [format == .pdf ? .pdf : .json]
            panel.allowsOtherFileTypes = false
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.prompt = "Export"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            Task {
                await exportEvidence(
                    to: url,
                    selectionScope: selectionScope,
                    formats: formats,
                    includeEvidenceSigning: false,
                    exactFileFormat: format
                )
            }
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.title = "Export Evidence"
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await exportEvidence(
                    to: url,
                    selectionScope: selectionScope,
                    formats: formats,
                    includeEvidenceSigning: includeEvidenceSigning
                )
            }
        }
    }

    func chooseConversationPDFDestination(_ conversation: EvidenceConversation) {
        guard selectedHold?.status == .active else { return }
        let panel = NSSavePanel()
        panel.title = "Export this conversation to PDF"
        panel.nameFieldStringValue = "ThreadLight-\(selectedHold?.name.fileSafePrefix ?? "Hold")-\(conversation.name.fileSafePrefix).pdf"
        panel.allowedContentTypes = [.pdf]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { await exportConversationPDF(conversationID: conversation.id, to: destination) }
    }

    private func exportConversationPDF(conversationID: String, to destination: URL) async {
        guard let hold = selectedHold, let store else { return }
        let access = destination.startAccessingSecurityScopedResource()
        beginCriticalWork()
        defer {
            if access { destination.stopAccessingSecurityScopedResource() }
            endCriticalWork()
        }
        do {
            guard let legalHoldClient else {
                throw ThreadLightError.scope("Reconnect Slack before exporting so ThreadLight can confirm the hold is still active.")
            }
            let currentHold = try await legalHoldClient.policy(id: hold.id)
            guard currentHold.status == .active else {
                throw ThreadLightError.scope("Slack reports that this hold is not active. Export is blocked.")
            }
            let currentCustodians = try await legalHoldClient.listCustodians(policyID: currentHold.id)
            guard !(try await reconcileCustodians(currentCustodians, for: currentHold)) else {
                throw ThreadLightError.scope("The legal hold changed in Slack. Import a new encrypted package before exporting this conversation.")
            }
            if let index = holds.firstIndex(where: { $0.id == currentHold.id }) { holds[index] = currentHold }
            selectedHold = currentHold
            custodians = currentCustodians

            var filters = SearchFilters()
            filters.conversationID = conversationID
            let conversationMessages = try await store.search(
                holdID: currentHold.id,
                query: .init(filters: filters, limit: 50_000)
            )
            let url = try await EvidenceExporter(store: store, resourceVault: resourceVault).exportPDF(
                messages: conversationMessages,
                hold: currentHold,
                custodians: currentCustodians,
                destination: destination
            )
            statusMessage = "Created \(url.lastPathComponent)."
            touchActivity()
        } catch {
            show(error)
        }
    }

    func exportEvidence(
        to destination: URL,
        selectionScope: ExportSelectionScope = .selectedMessages,
        formats: Set<EvidenceExportFormat> = [.pdf],
        includeEvidenceSigning: Bool = false,
        exactFileFormat: EvidenceExportFormat? = nil
    ) async {
        guard let hold = selectedHold, let store else { return }
        let access = destination.startAccessingSecurityScopedResource()
        beginCriticalWork()
        defer {
            if access { destination.stopAccessingSecurityScopedResource() }
            endCriticalWork()
        }
        var selected: [EvidenceMessage] = []
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
            selected = try await store.messages(holdID: currentHold.id, messageIDs: selectedMessageIDs)
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
            if includeEvidenceSigning {
                let result = try await exporter.export(
                    messages: selected,
                    hold: currentHold,
                    custodians: currentCustodians,
                    destination: destination,
                    formats: formats
                )
                statusMessage = "Created and verified \(result.packageURL.lastPathComponent). Signer key: \(result.keyID.prefix(12))…"
            } else if let exactFileFormat {
                let url: URL
                switch exactFileFormat {
                case .pdf:
                    url = try await exporter.exportPDF(
                        messages: selected,
                        hold: currentHold,
                        custodians: currentCustodians,
                        destination: destination
                    )
                case .json:
                    url = try await exporter.exportJSON(
                        messages: selected,
                        hold: currentHold,
                        custodians: currentCustodians,
                        destination: destination
                    )
                }
                statusMessage = "Created \(url.lastPathComponent)."
            } else {
                let result = try await exporter.exportFiles(
                    messages: selected,
                    hold: currentHold,
                    custodians: currentCustodians,
                    destination: destination,
                    formats: formats
                )
                let names = result.fileURLs.map(\.lastPathComponent).joined(separator: ", ")
                statusMessage = "Created \(result.fileURLs.count) evidence file\(result.fileURLs.count == 1 ? "" : "s"): \(names)."
            }
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
        beginCriticalWork()
        defer { endCriticalWork() }
        statusMessage = "Purging local evidence…"
        do {
            holdLoadTask?.cancel()
            threadLoadTask?.cancel()
            let active = activeStorageNamespace
            let namespaces = knownStorageNamespaces().union(active.map { [$0] } ?? [])
            // Clear the in-memory/UI state before the slow on-disk purge below, not after —
            // deleting potentially large amounts of evidence from SQLite/the resource vault can
            // take a while, and every open window shares this same model, so leaving the old
            // rows in place until the disk work finished made purge look like it hadn't done
            // anything yet.
            holds.removeAll(); custodians.removeAll(); conversations.removeAll(); importedCustodianIDs.removeAll(); hasImportedPackage = false; messages.removeAll(); selectedHold = nil
            selectedMessage = nil; selectedMessageIDs.removeAll(); threadMessages.removeAll()
            sidebarSelection = .setup
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
            setup.update(.custodianExports, state: .pending)
            setup.update(.attachments, state: .pending)
            touchActivity()
            ThreadLightLog.session.notice(
                "purged local evidence from \(namespaces.count, privacy: .public) profile(s)"
            )
            // Legal holds belong to Slack, not to local evidence. Purging drops the cached hold
            // and custodian rows along with the messages, so they have to be read back from
            // Slack. Without this the sign-in is still valid but every hold list is empty,
            // which reads as being signed out.
            await refreshLegalHolds()
            statusMessage = "Purged local evidence from \(namespaces.count) organization profile(s). Slack sign-in and legal holds are unchanged."
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

    func saveSlackExportScript(_ contents: String) {
        let panel = NSSavePanel()
        panel.title = "Save the Slack export script"
        panel.nameFieldStringValue = "ThreadLight-Slack-Export-\(selectedHold?.name.fileSafePrefix ?? "Export").js"
        panel.allowedContentTypes = [.javaScript]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.prompt = "Save script"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            let access = destination.startAccessingSecurityScopedResource()
            defer { if access { destination.stopAccessingSecurityScopedResource() } }
            try Data(contents.utf8).write(to: destination, options: .atomic)
            statusMessage = "Saved the Slack export script."
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

    private func recordActivity(_ message: String) {
        recentActivity.append("\(ISO8601DateFormatter().string(from: Date())) \(message)")
        if recentActivity.count > 12 { recentActivity.removeFirst(recentActivity.count - 12) }
    }

    private func beginCriticalWork() { criticalOperationCount += 1 }

    private func endCriticalWork() {
        criticalOperationCount -= 1
        guard criticalOperationCount == 0 else { return }
        let waiters = criticalWorkContinuations
        criticalWorkContinuations = []
        for waiter in waiters { waiter.resume() }
    }

    /// Suspends until no evidence-critical operation is running. Used by the termination
    /// guard so quitting cannot tear SQLCipher down under a live statement.
    func awaitCriticalWorkCompletion() async {
        guard criticalOperationCount > 0 else { return }
        await withCheckedContinuation { criticalWorkContinuations.append($0) }
    }

    private func show(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let category = ThreadLightLog.category(of: error)
        errorMessage = message
        lastErrorCategory = category
        lastErrorReport = diagnosticReport(message: message, category: category, error: error)
        isShowingError = true
    }

    private func diagnosticReport(message: String, category: String, error: Error) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var details: [String] = []
        if !(error is ThreadLightError) {
            let nsError = error as NSError
            if let jsMessage = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String {
                details.append("JavaScript: \(jsMessage)")
            }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                details.append("Underlying: \(underlying.domain)#\(underlying.code) \(underlying.localizedDescription)")
            }
        }
        let logLines = ThreadLightLog.recentLogLines()
        return """
        ThreadLight error report

        What failed: \(message)
        Error type: \(category)\(details.isEmpty ? "" : "\nError detail: " + details.joined(separator: "; "))
        When: \(timestamp)
        App: \(ThreadLightBuild.applicationIdentity)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)

        Recent app activity:
        \(recentActivity.isEmpty ? "(none recorded)" : recentActivity.joined(separator: "\n"))

        Recent log lines:
        \(logLines.isEmpty
            ? "(none captured — run: log show --predicate 'subsystem == \"dev.threadlight.app\"' --last 30m --info)"
            : logLines.joined(separator: "\n"))

        Anything else you were doing:
        (add details here)

        Review before sharing: activity above can name holds or files from your case.
        """
    }

    /// Copies the report locally so the operator can read it before deciding what to share.
    /// "What failed" can quote a path from inside a Slack export, so ThreadLight never sends
    /// it anywhere on its own.
    func copyErrorReport() {
        guard !lastErrorReport.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastErrorReport, forType: .string)
        statusMessage = "Copied the error report. Review it for case details before pasting it into a public issue."
    }

    /// Opens a new GitHub issue prefilled with build and error type only. The operator pastes
    /// the copied report themselves, so nothing derived from a legal hold is published without
    /// them seeing it first.
    func openIssueReport() {
        var components = URLComponents(string: "https://github.com/samspade21/ThreadLight/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: "Error: \(lastErrorCategory)"),
            URLQueryItem(name: "body", value: """
            App: \(ThreadLightBuild.applicationIdentity)
            macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
            Error type: \(lastErrorCategory)

            Paste the copied error report here, after removing anything case related:
            """),
        ]
        guard let url = components?.url else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshEvidenceReadiness(for hold: LegalHold) async throws {
        guard let store else { return }
        let archives = try await store.archives(holdID: hold.id)
        if selectedHold?.id == hold.id { hasImportedPackage = !archives.isEmpty }
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

    private func loadConversations(for hold: LegalHold) async {
        guard let store else { return }
        do {
            let loaded = try await store.conversations(holdID: hold.id)
            guard !Task.isCancelled, selectedHold?.id == hold.id else { return }
            conversations = loaded
            if let selectedID = searchFilters.conversationID,
               !loaded.contains(where: { $0.id == selectedID }) {
                searchFilters.conversationID = nil
            }
        } catch is CancellationError {
            return
        } catch {
            show(error)
        }
    }

    private func refreshSlackUserProfiles(
        for userIDs: Set<String>,
        holdID expectedHoldID: String? = nil,
        retryFailures: Bool = true
    ) async {
        guard isConnected, let legalHoldClient else { return }
        let holdID = expectedHoldID ?? selectedHold?.id
        let missing = userIDs.subtracting(requestedSlackUserIDs)
        guard !missing.isEmpty else { return }
        requestedSlackUserIDs.formUnion(missing)
        let identifiers = missing.sorted()
        var failed: Set<String> = []
        let batchSize = retryFailures ? 4 : 1
        for start in stride(from: 0, to: identifiers.count, by: batchSize) {
            guard !Task.isCancelled else { return }
            let batch = identifiers[start..<min(start + batchSize, identifiers.count)]
            let results = await withTaskGroup(of: (String, SlackUserProfile?).self, returning: [(String, SlackUserProfile?)].self) { group in
                for userID in batch {
                    group.addTask { (userID, try? await legalHoldClient.userProfile(userID: userID)) }
                }
                var loaded: [(String, SlackUserProfile?)] = []
                for await result in group { loaded.append(result) }
                return loaded
            }
            for (userID, profile) in results {
                guard let profile else {
                    requestedSlackUserIDs.remove(userID)
                    failed.insert(userID)
                    continue
                }
                slackUserProfiles[profile.id] = profile
                guard selectedHold?.id == holdID else { continue }
                guard let index = custodians.firstIndex(where: { $0.id == profile.id }) else { continue }
                custodians[index].displayName = profile.displayName
                custodians[index].email = profile.email
                custodians[index].avatarURL = profile.avatarURL
            }
            if identifiers.count > batchSize {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        if !failed.isEmpty, retryFailures, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            await refreshSlackUserProfiles(for: failed, holdID: holdID, retryFailures: false)
        }
        if let holdID, selectedHold?.id == holdID, !custodians.isEmpty {
            try? await store?.replaceCustodians(custodians, holdID: holdID)
        }
    }

    private func slackTimestamp(for message: EvidenceMessage) -> String? {
        let prefix = "\(message.conversationID):"
        guard let range = message.id.range(of: prefix, options: .backwards) else { return nil }
        let timestamp = String(message.id[range.upperBound...])
        guard timestamp.contains("."), timestamp.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return timestamp
    }

    private func rebuildMessageIndex() {
        messageByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        let chronological = messages.sorted {
            if $0.postedAt == $1.postedAt { return $0.id < $1.id }
            return $0.postedAt < $1.postedAt
        }
        let grouped = Dictionary(grouping: chronological, by: \.threadID)
            .map { MessageThreadGroup(id: $0.key, messages: $0.value) }
        messageThreadGroups = grouped.sorted { lhs, rhs in
            switch messageSort {
            case .newest:
                return (lhs.messages.last?.postedAt ?? .distantPast) > (rhs.messages.last?.postedAt ?? .distantPast)
            case .oldest:
                return (lhs.messages.first?.postedAt ?? .distantFuture) < (rhs.messages.first?.postedAt ?? .distantFuture)
            case .sender:
                let comparison = (lhs.messages.first?.senderName ?? "").localizedCaseInsensitiveCompare(rhs.messages.first?.senderName ?? "")
                return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
            case .conversation:
                let comparison = (lhs.messages.first?.conversationName ?? "").localizedCaseInsensitiveCompare(rhs.messages.first?.conversationName ?? "")
                return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
            }
        }
    }

    @discardableResult
    private func reconcileCustodians(_ loaded: [Custodian], for hold: LegalHold) async throws -> Bool {
        guard let store else { return false }
        let previous = try await store.custodians(holdID: hold.id)
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let reconciled = loaded.map { custodian in
            guard let prior = previousByID[custodian.id] else { return custodian }
            var result = custodian
            if result.displayName == result.id, prior.displayName != prior.id {
                result.displayName = prior.displayName
            }
            result.email = result.email ?? prior.email
            result.avatarURL = result.avatarURL ?? prior.avatarURL
            return result
        }
        var invalidated = false
        if !previous.isEmpty,
           HoldAccessKey.fingerprint(hold: hold, custodians: previous)
            != HoldAccessKey.fingerprint(hold: hold, custodians: loaded),
           try await store.purgeEvidence(holdID: hold.id) {
            invalidated = true
            statusMessage = "The legal hold “\(hold.name)” changed in Slack. ThreadLight removed its old local data because that encrypted package is no longer valid. Import a new package."
            if selectedHold?.id == hold.id {
                messages = []
                conversations = []
                searchFilters.conversationID = nil
                selectedMessage = nil
                selectedMessageIDs.removeAll()
                threadMessages = []
            }
        }
        try await store.save(hold: hold)
        if Set(previous) != Set(reconciled) {
            try await store.replaceCustodians(reconciled, holdID: hold.id)
        }
        custodianValidatedAt[hold.id] = Date()
        return invalidated
    }

    private func touchActivity() {
        guard let activeStorageNamespace else { return }
        UserDefaults.standard.set(Date(), forKey: Self.lastActivityKeyPrefix + activeStorageNamespace)
    }

    private func selectDefaultHold() {
        if case let .hold(id) = sidebarSelection,
           visibleHolds.contains(where: { $0.id == id }) {
            return
        }
        sidebarSelection = visibleHolds.first.map { .hold($0.id) } ?? .setup
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
        // The store this replaces is the one a running package is writing into.
        cancelPackaging(reason: "ThreadLight switched to a different organization's local evidence")
        ThreadLightLog.session.notice(
            "storage opened: replacing=\(self.activeStorageNamespace != nil, privacy: .public)"
        )
        holdLoadTask?.cancel()
        threadLoadTask?.cancel()
        custodianValidatedAt = [:]
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
        conversations = []
        importedCustodianIDs = []
        hasImportedPackage = false
        messages = []
        threadMessages = []
        selectedHold = nil
        selectedMessage = nil
        selectedMessageIDs = []
        selectDefaultHold()
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

    func userProfile(userID: String) async throws -> SlackUserProfile {
        guard let custodian = custodians.first(where: { $0.id == userID }) else {
            return .init(id: userID, displayName: userID, avatarURL: nil)
        }
        return .init(id: userID, displayName: custodian.displayName, email: custodian.email, avatarURL: custodian.avatarURL)
    }

    func reactions(conversationID: String, timestamp: String) async throws -> [EvidenceReaction] {
        []
    }

    func emojiURLs() async throws -> [String: URL] {
        [:]
    }
}
#endif
