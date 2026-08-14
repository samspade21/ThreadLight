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

@main
struct ThreadLightApplication: App {
    var body: some Scene {
        WindowGroup {
            WorkspaceWindow()
        }
        .defaultSize(width: 1_320, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            ThreadLightCommands()
        }

        WindowGroup("Conversation", for: ConversationWindowRequest.self) { request in
            WorkspaceWindow(initialConversation: request.wrappedValue)
        }
        .defaultSize(width: 1_140, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            ThreadLightCommands()
        }

        Settings {
            SettingsWorkspace()
        }
    }
}

private struct WorkspaceWindow: View {
    @State private var model = AppModel()
    let initialConversation: ConversationWindowRequest?

    init(initialConversation: ConversationWindowRequest? = nil) {
        self.initialConversation = initialConversation
    }

    var body: some View {
        RootView(initialConversation: initialConversation)
            .environment(model)
            .focusedSceneValue(\.threadLightModel, model)
            .frame(minWidth: 1_200, minHeight: 700)
            .safeAreaInset(edge: .top, spacing: 0) { DevelopmentBuildBanner() }
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
            Text("Development build — the evidence database key is stored unencrypted on disk. Not for real evidence.")
                .fontWeight(.semibold)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.red)
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Development build. The evidence database key is stored unencrypted on disk. Not for real evidence.")
        #else
        EmptyView()
        #endif
    }
}

private struct SettingsWorkspace: View {
    @State private var model = AppModel()

    var body: some View {
        SettingsView()
            .environment(model)
            .focusedSceneValue(\.threadLightModel, model)
            .frame(width: 760, height: 680)
            .task { await model.start() }
    }
}

private struct ThreadLightCommands: Commands {
    @FocusedValue(\.threadLightModel) private var model

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Divider()
            Button("Log Out of Slack") { Task { await model?.logOut() } }
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
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(900))
                guard !Task.isCancelled else { return }
                await model.refreshLegalHolds()
            }
        }
        .alert("ThreadLight", isPresented: $model.isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "Something went wrong. Please try again.")
        }
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
    @State private var isSigningIn = false
    @State private var pastedCallback = ""

    var body: some View {
        if model.pendingSignIn == nil {
            ContentUnavailableView {
                Label("Sign in to Slack", systemImage: "person.crop.circle.badge.checkmark")
            } description: {
                Text("Sign in to see the legal holds available to you.")
            } actions: {
                Button("Sign in to Slack") {
                    model.beginSlackSignIn()
                }
                .buttonStyle(.borderedProminent)
                .tint(ThreadLightTheme.violet)
            }
        } else {
            ContentUnavailableView {
                Label("Finish signing in", systemImage: "link.circle")
            } description: {
                Text("After you approve ThreadLight, the browser lands on a page that cannot be reached — that is expected and safe. Copy the entire address from the browser's address bar and paste it here.")
            } actions: {
                VStack(spacing: 10) {
                    TextField("https://callback.threadlight.invalid/oauth/callback?code=…", text: $pastedCallback)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: 460)
                    HStack {
                        Button(isSigningIn ? "Signing in…" : "Complete Sign-In") {
                            isSigningIn = true
                            Task {
                                await model.completeSlackSignIn(pastedCallback: pastedCallback)
                                if model.pendingSignIn == nil { pastedCallback = "" }
                                isSigningIn = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ThreadLightTheme.violet)
                        .disabled(pastedCallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSigningIn)
                        Button("Cancel") {
                            model.cancelSlackSignIn()
                            pastedCallback = ""
                        }
                        .disabled(isSigningIn)
                    }
                }
            }
        }
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
            Button("Log Out of Slack", role: .destructive) {
                Task { await model.logOut() }
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
