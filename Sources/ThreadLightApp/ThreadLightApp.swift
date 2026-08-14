import SwiftUI
import ThreadLightCore

struct ConversationWindowRequest: Codable, Hashable {
    let holdID: String
    let conversationID: String
}

private struct FocusedAppModelKey: FocusedValueKey {
    typealias Value = AppModel
}

private extension FocusedValues {
    var threadLightModel: AppModel? {
        get { self[FocusedAppModelKey.self] }
        set { self[FocusedAppModelKey.self] = newValue }
    }
}

/// Holds app termination while an evidence-critical operation (import, packaging, purge) is
/// still running. exit() runs SQLCipher's atexit teardown, which frees its global state under
/// any statement still executing on another thread — quitting mid-purge crashed in the field
/// with a SIGSEGV inside the page codec.
@MainActor
final class TerminationGuard: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.criticalOperationCount > 0 else { return .terminateNow }
        model.statusMessage = "Finishing evidence work, then quitting…"
        Task { @MainActor in
            await model.awaitCriticalWorkCompletion()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct ThreadLightApplication: App {
    @NSApplicationDelegateAdaptor(TerminationGuard.self) private var terminationGuard
    /// One model for the whole app. Each scene used to build its own, which opened a second
    /// EvidenceStore on the same encrypted database and a second Slack session: work done in
    /// Settings was invisible to the main window, and errors raised there had no alert to
    /// surface them.
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            WorkspaceWindow(model: model)
                .onAppear { terminationGuard.model = model }
        }
        .defaultSize(width: 1_320, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            ThreadLightCommands()
        }

        WindowGroup("Conversation", for: ConversationWindowRequest.self) { request in
            WorkspaceWindow(model: model, initialConversation: request.wrappedValue)
        }
        .defaultSize(width: 1_140, height: 760)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsWorkspace(model: model)
                .onAppear { terminationGuard.model = model }
        }
    }
}

/// Presents whatever the model last failed at. Every scene that can start work needs this,
/// or that scene's failures are silent.
private struct ThreadLightErrorAlert: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content.alert("ThreadLight ran into a problem", isPresented: $model.isShowingError) {
            Button("Copy Error Report") { model.copyErrorReport() }
            Button("Report a Bug…") { model.openIssueReport() }
            Button("OK", role: .cancel) {}
        } message: {
            Text("""
            \(model.errorMessage ?? "Something went wrong. Please try again.")

            If this looks like a bug, choose Copy Error Report and open an issue at \
            github.com/samspade21/ThreadLight/issues so it can be fixed. Read the copied \
            report first and remove anything case related before posting it publicly.
            """)
        }
    }
}

private extension View {
    func threadLightErrorAlert(_ model: AppModel) -> some View {
        modifier(ThreadLightErrorAlert(model: model))
    }
}

private struct WorkspaceWindow: View {
    let model: AppModel
    let initialConversation: ConversationWindowRequest?

    init(model: AppModel, initialConversation: ConversationWindowRequest? = nil) {
        self.model = model
        self.initialConversation = initialConversation
    }

    var body: some View {
        VStack(spacing: 0) {
            RootView(initialConversation: initialConversation)
            DevelopmentBuildBanner()
        }
        .environment(model)
        .focusedSceneValue(\.threadLightModel, model)
        .frame(minWidth: 1_200, minHeight: 700)
    }
}

/// Debug and ad-hoc builds keep the evidence database key and the resource-vault key in
/// plaintext files under Application Support instead of the Keychain, so the encrypted
/// store offers no protection at rest. Production Developer ID builds compile this out.
struct DevelopmentBuildBanner: View {
    var body: some View {
        #if THREADLIGHT_DEVELOPMENT
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Development build — do not use real evidence. Local database keys are unencrypted.")
                .fontWeight(.semibold)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
        .background(Color.red.opacity(0.88))
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Development build. Do not use real evidence. Local database keys are unencrypted.")
        #else
        EmptyView()
        #endif
    }
}

private struct SettingsWorkspace: View {
    let model: AppModel

    var body: some View {
        SettingsView()
            .environment(model)
            .focusedSceneValue(\.threadLightModel, model)
            .frame(width: 760, height: 680)
            .task { await model.start() }
            .threadLightErrorAlert(model)
    }
}

private struct ThreadLightCommands: Commands {
    @FocusedValue(\.threadLightModel) private var model

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Divider()
            Button(role: .destructive) {
                Task { await model?.logOut() }
            } label: {
                Label("Log Out of Slack", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .disabled(model?.isConnected != true)
        }
        CommandGroup(after: .newItem) {
            Button("Refresh Legal Holds") { Task { await model?.refreshLegalHolds() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model?.isConnected != true)
            Button("Export selected evidence…") { model?.presentExportPanel() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model?.selectedMessageIDs.isEmpty != false)
        }
    }
}

private struct RootView: View {
    @Environment(AppModel.self) private var model
    let initialConversation: ConversationWindowRequest?

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isStarting {
                StartupView()
            } else if !model.setup.isManagedConfiguration && !model.isDemoSession {
                MissingConfigurationView()
            } else if !model.isConnected {
                SlackSignInView()
            } else if model.holds.isEmpty {
                NoLegalHoldsView()
            } else {
                LegalHoldWorkspace(isConversationWindow: initialConversation != nil)
            }
        }
        .task {
            await model.start()
            if let initialConversation {
                model.openConversation(
                    holdID: initialConversation.holdID,
                    conversationID: initialConversation.conversationID
                )
            }
            // Owned by the model so opening a second window does not start a second
            // refresh loop against the same shared state.
            model.beginPeriodicHoldRefresh()
        }
        .threadLightErrorAlert(model)
    }
}

private struct LegalHoldWorkspace: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    let isConversationWindow: Bool

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                BrandSidebarHeader()
                Divider()
                List(selection: $model.sidebarSelection) {
                    Section {
                        if model.visibleHolds.isEmpty {
                            Text("No \(model.holdListFilter.title.lowercased()) legal holds")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.visibleHolds) { hold in
                            HoldSidebarRow(hold: hold)
                                .tag(AppModel.SidebarSelection.hold(hold.id))
                        }
                    } header: {
                        HStack {
                            Text("Legal holds")
                            Spacer()
                            Picker("Legal hold status", selection: $model.holdListFilter) {
                                ForEach(AppModel.HoldListFilter.allCases) { filter in
                                    Text(filter.title).tag(filter)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .safeAreaInset(edge: .bottom) {
                ConnectionFooter()
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 245, max: 280)
        } content: {
            switch model.sidebarSelection {
            case .setup:
                ContentUnavailableView(
                    model.visibleHolds.isEmpty ? "No \(model.holdListFilter.title.lowercased()) legal holds" : "Choose a legal hold",
                    systemImage: "lock.doc"
                )
            case let .hold(id):
                if let hold = model.holds.first(where: { $0.id == id }) {
                    SearchWorkspaceView(
                        hold: hold,
                        isLegalHoldListHidden: !isConversationWindow && columnVisibility != .all,
                        showLegalHolds: { columnVisibility = .all },
                        showsConversationSidebar: !isConversationWindow
                    )
                        .navigationSplitViewColumnWidth(min: 570, ideal: 680)
                } else {
                    ContentUnavailableView("Choose a legal hold", systemImage: "lock.doc")
                }
            }
        } detail: {
            switch model.sidebarSelection {
            case .setup:
                ContentUnavailableView("Choose a message", systemImage: "text.bubble")
            case .hold:
                MessageDetailView(message: model.selectedMessage)
                    .navigationSplitViewColumnWidth(min: 340, ideal: 430)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .task(id: model.hasImportedPackage) {
            withAnimation {
                columnVisibility = model.hasImportedPackage ? .doubleColumn : .all
            }
        }
    }
}

private struct StartupView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Opening ThreadLight…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MissingConfigurationView: View {
    var body: some View {
        ContentUnavailableView {
            Label("ThreadLight isn't set up on this Mac", systemImage: "gearshape.badge.xmark")
        } description: {
            Text("Ask your administrator to install the ThreadLight settings profile, then reopen the app.")
        }
    }
}

private struct SlackSignInView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Sign in to Slack", systemImage: "person.crop.circle.badge.checkmark")
        } description: {
            Text("Sign in to see the legal holds available to you.")
        } actions: {
            Button(model.webSessionSignIn == nil ? "Sign in to Slack" : "Signing in…") {
                model.beginSlackWebSessionSignIn()
            }
            .buttonStyle(.borderedProminent)
            .tint(ThreadLightTheme.violet)
            .disabled(model.webSessionSignIn != nil)
        }
        .sheet(isPresented: webSessionSheetPresented) {
            if let signIn = model.webSessionSignIn {
                SlackWebSessionSheet(signIn: signIn) {
                    model.cancelSlackWebSessionSignIn()
                }
            }
        }
    }

    private var webSessionSheetPresented: Binding<Bool> {
        Binding(
            get: { model.webSessionSignIn?.isPresented ?? false },
            set: { newValue in
                if !newValue { model.cancelSlackWebSessionSignIn() }
            }
        )
    }
}

private struct NoLegalHoldsView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No legal holds are available", systemImage: "lock.doc")
        } description: {
            Text("Slack did not return any legal holds for your account. If you expected to see one, ask your Slack administrator to check your access.")
        }
    }
}

private struct BrandSidebarHeader: View {
    var body: some View {
        HStack(spacing: 11) {
            ThreadLightAppIcon(size: 46)
            VStack(alignment: .leading, spacing: 1) {
                Text("ThreadLight")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                Text("Legal-hold review")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct HoldSidebarRow: View {
    let hold: LegalHold

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol)
                .foregroundStyle(hold.status == .active ? ThreadLightTheme.accentForeground : .secondary)
                .frame(width: 28, height: 28)
                .background((hold.status == .active ? ThreadLightTheme.violet : Color.secondary).opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(hold.name).lineLimit(1)
                Text(hold.status.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusSymbol: String {
        switch hold.status {
        case .active: "lock.fill"
        case .released: "lock.open"
        case .unknown: "questionmark.diamond"
        }
    }
}

private struct ConnectionFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button(role: .destructive) {
                Task { await model.logOut() }
            } label: {
                Label("Log Out of Slack", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .disabled(!model.isConnected)
        } label: {
            HStack {
                StatusOrb(color: model.isConnected ? ThreadLightTheme.teal : .secondary, size: 8)
                Text(model.isConnected ? "Signed in to Slack" : "Not signed in")
                    .font(.caption)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .padding(12)
        .background(.ultraThinMaterial)
    }
}

private struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            SlackAppInstallationSettingsView()
                .tabItem { Label("Install Slack App in Org", systemImage: "building.2") }
            PackagePreparationSettingsView()
                .tabItem { Label("Prepare Packages", systemImage: "shippingbox.and.arrow.backward") }
        }
        .padding(.top, 8)
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirmingPurge = false

    var body: some View {
        Form {
            Section("Local evidence") {
                Stepper("Purge after \(model.retentionDays) inactive days", value: Bindable(model).retentionDays, in: 1...365)
                Button("Purge all local evidence…", role: .destructive) { isConfirmingPurge = true }
            }
            Section {
                Text("ThreadLight has no telemetry and never writes to Slack.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog(
            "Purge local evidence from every organization?",
            isPresented: $isConfirmingPurge,
            titleVisibility: .visible
        ) {
            Button("Purge all evidence", role: .destructive) { Task { await model.purgeEvidence() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes imported messages, indexes, attachments, and source provenance from every ThreadLight organization profile on this Mac. Setup details and Slack authorization remain.")
        }
    }
}
