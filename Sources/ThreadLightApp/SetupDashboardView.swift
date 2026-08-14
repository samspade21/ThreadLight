import AppKit
import SwiftUI
import ThreadLightCore

struct SlackAppInstallationSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var copiedManifest = false
    @State private var isConnecting = false
    @State private var pastedCallback = ""

    var body: some View {
        @Bindable var setup = model.setup
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Install Slack App in Org", systemImage: "building.2.crop.circle.fill")
                    .font(.title2.bold())
                    .foregroundStyle(ThreadLightTheme.accentForeground)
                Text("One-time setup for your Slack organization. After this is complete, people only open ThreadLight and sign in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    setupSection(number: 1, title: "Create the ThreadLight app") {
                        Text("Use ThreadLight's single manifest to create the app in Slack.")
                            .foregroundStyle(.secondary)
                        Instruction(number: 1, text: "Copy the manifest below.")
                        Instruction(number: 2, text: "Open Slack apps and choose Create New App → From an app manifest.")
                        Instruction(number: 3, text: "Choose a workspace in your organization, select YAML, paste the manifest, then create the app.")
                        HStack {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(SlackAppManifest.template, forType: .string)
                                copiedManifest = true
                            } label: {
                                Label(copiedManifest ? "Manifest copied" : "Copy manifest", systemImage: copiedManifest ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(ThreadLightTheme.violet)
                            Button("Save YAML…", systemImage: "square.and.arrow.down") {
                                model.saveSlackAppManifest()
                            }
                            Link("Open Slack apps", destination: SlackAppManifest.createAppURL)
                        }
                        Text("The manifest already contains everything ThreadLight needs. Do not add a Client Secret or extra permissions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    setupSection(number: 2, title: "Enter the app details") {
                        Text("Find the Client ID under Basic Information → App Credentials in Slack.")
                            .foregroundStyle(.secondary)
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                            GridRow {
                                Text("Organization")
                                TextField("Example Corporation", text: $setup.organizationName)
                            }
                            GridRow {
                                Text("Slack address")
                                TextField("example.enterprise.slack.com", text: $setup.organizationDomain)
                            }
                            GridRow {
                                Text("Client ID")
                                TextField("Public Client ID", text: $setup.slackClientID)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        Text("The Client ID is safe to place in the managed settings profile. ThreadLight never needs the Client Secret.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    setupSection(number: 3, title: "Install and verify it") {
                        Text("This installation is done once for the organization.")
                            .foregroundStyle(.secondary)
                        Instruction(number: 1, text: "Open the ThreadLight app in Slack app management.")
                        Instruction(number: 2, text: "In the app's left sidebar, choose Settings → Install App.")
                        Instruction(number: 3, text: "Choose Install to Organization and select your organization.")
                        Instruction(number: 4, text: "Return here and sign in once to confirm ThreadLight can read the legal hold list.")

                        if setup.requiresAdministratorSignerConfirmation, let signer = setup.administratorSignerKeyID {
                            SignerConfirmation(signerKeyID: signer) {
                                setup.confirmAdministratorSignerKeyID()
                            }
                        }

                        HStack {
                            Link("Open Slack apps", destination: SlackAppManifest.createAppURL)
                            Button {
                                model.beginSlackSignIn()
                            } label: {
                                Label(connectionButtonTitle, systemImage: model.isConnected ? "checkmark.circle.fill" : "person.crop.circle.badge.checkmark")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(ThreadLightTheme.violet)
                            .disabled(
                                !hasAppDetails
                                    || isConnecting
                                    || model.isConnected
                                    || model.pendingSignIn != nil
                                    || setup.requiresAdministratorSignerConfirmation
                            )
                        }

                        if model.pendingSignIn != nil, !model.isConnected {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Finish signing in")
                                    .font(.headline)
                                Text("After you approve ThreadLight, the browser lands on a page that cannot be reached — that is expected and safe. Copy the entire address from the browser's address bar and paste it here.")
                                    .foregroundStyle(.secondary)
                                TextField("https://callback.threadlight.invalid/oauth/callback?code=…", text: $pastedCallback)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                                HStack {
                                    Button("Complete Sign-In") {
                                        isConnecting = true
                                        Task {
                                            await model.completeSlackSignIn(pastedCallback: pastedCallback)
                                            if model.pendingSignIn == nil { pastedCallback = "" }
                                            isConnecting = false
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(ThreadLightTheme.violet)
                                    .disabled(pastedCallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
                                    Button("Cancel") {
                                        model.cancelSlackSignIn()
                                        pastedCallback = ""
                                    }
                                    .disabled(isConnecting)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(ThreadLightTheme.violet.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        }

                        if model.isConnected {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Slack is verified", systemImage: "checkmark.seal.fill")
                                    .font(.headline)
                                    .foregroundStyle(ThreadLightTheme.successForeground)
                                Text("Next, save the MDM profile and add it to your MDM system.")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(ThreadLightTheme.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Managed settings profile")
                                .font(.headline)
                            Text("Save the profile, upload it to MDM, and assign it to the Macs that will use ThreadLight. After that, setup is complete.")
                                .foregroundStyle(.secondary)
                            Button("Save MDM Profile…", systemImage: "square.and.arrow.down") {
                                model.saveManagedConfigurationProfile()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(ThreadLightTheme.violet)
                            .controlSize(.large)
                            .disabled(!model.isConnected)
                            if !model.isConnected {
                                Text("This becomes available after Slack is verified above.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .accessibilityIdentifier("settings.slackAppInstallation")
        .onChange(of: setup.organizationName) { setup.save() }
        .onChange(of: setup.organizationDomain) { setup.save() }
        .onChange(of: setup.slackClientID) { setup.save() }
    }

    private var hasAppDetails: Bool {
        !model.setup.organizationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.setup.organizationDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.setup.slackClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var connectionButtonTitle: String {
        if isConnecting { return "Signing in…" }
        if model.isConnected { return "Slack verified" }
        if model.pendingSignIn != nil { return "Waiting for sign-in…" }
        return "Sign in and verify"
    }
}

/// Numbered, GroupBox-styled step used by the setup and package-preparation pages.
private func setupSection<Content: View>(
    number: Int,
    title: String,
    @ViewBuilder content: () -> Content
) -> some View {
    GroupBox {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    } label: {
        Label {
            Text("\(number). \(title)")
                .font(.headline)
        } icon: {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(ThreadLightTheme.accentForeground)
        }
    }
}

struct PackagePreparationSettingsView: View {
    private static let maxRangeDays = 180

    private static let scriptDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    @Environment(AppModel.self) private var model
    @State private var archiveURLs: [URL] = []
    @State private var isDropTargeted = false
    @State private var toDate = Date()
    @State private var fromDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var copiedScript = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Prepare Encrypted Packages", systemImage: "shippingbox.and.arrow.backward.fill")
                    .font(.title2.bold())
                    .foregroundStyle(ThreadLightTheme.accentForeground)
                Text("Run a Slack export for a legal hold's custodians, then attach the resulting ZIPs to one encrypted package for transfer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            if !model.isConnected {
                ContentUnavailableView {
                    Label("Slack is not connected", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text("Finish the one-time Slack app installation and sign in before preparing a package.")
                }
            } else if activeHolds.isEmpty {
                ContentUnavailableView {
                    Label("No active legal holds are available", systemImage: "lock.doc")
                } description: {
                    Text("Slack did not return any active legal holds for this account.")
                }
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            setupSection(number: 1, title: "Choose the legal hold") {
                                Text("Pick the hold this export script and package are for.")
                                    .foregroundStyle(.secondary)
                                Picker("Hold", selection: selectedHoldID) {
                                    ForEach(activeHolds) { hold in
                                        Text(hold.name).tag(hold.id)
                                    }
                                }
                                .disabled(model.isPackaging)
                            }

                            setupSection(number: 2, title: "Choose the date range") {
                                Text("Slack exports cover at most \(Self.maxRangeDays) days at a time.")
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 24) {
                                    DatePicker("From", selection: $fromDate, in: minFromDate...toDate, displayedComponents: .date)
                                    DatePicker("To", selection: $toDate, in: fromDate...Date(), displayedComponents: .date)
                                }
                                .datePickerStyle(.compact)
                                .frame(maxWidth: 420, alignment: .leading)
                            }

                            setupSection(number: 3, title: "Copy the export script") {
                                Text("This script exports every person on this hold for the dates above, then runs itself — nothing else to call by hand.")
                                    .foregroundStyle(.secondary)

                                if model.custodians.isEmpty {
                                    Text("No members were found for this hold yet, so there's nothing to generate a script for.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    HStack {
                                        Button {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(exportScriptText, forType: .string)
                                            copiedScript = true
                                        } label: {
                                            Label(copiedScript ? "Script copied" : "Copy script", systemImage: copiedScript ? "checkmark" : "doc.on.doc")
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(ThreadLightTheme.violet)
                                        Button("Save Script…", systemImage: "square.and.arrow.down") {
                                            model.saveSlackExportScript(exportScriptText)
                                        }
                                        Text("\(model.custodians.count) custodian(s)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Divider()

                                    Instruction(number: 1, text: "Open your organization's Slack exports page below, signed in as an Org Owner.")
                                    Group {
                                        if let exportsPageURL {
                                            Link(exportsPageURL.absoluteString, destination: exportsPageURL)
                                        } else {
                                            Text("https://app.slack.com/manage/YOUR_ORG_ID/security/exports")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .font(.system(.callout, design: .monospaced))
                                    .padding(.leading, 31)

                                    Instruction(number: 2, text: "Open the browser console — in Chrome, press ⌥⌘J (Option + Command + J).")
                                    Instruction(number: 3, text: "Paste the script (⌘V) and press Return.")
                                    Instruction(number: 4, text: "If it prints a reminder that it's waiting, click into the page (e.g. its search box) and leave the console open.")
                                    Instruction(number: 5, text: "There's a short pause between each person to avoid Slack's rate limits — larger holds take longer to finish.")
                                    Instruction(number: 6, text: "When it's done, the console prints THREADLIGHT EXPORT COMPLETE. Search the output for that line, and check the printed table for any ❌ rows to retry.")
                                }
                            }

                            setupSection(number: 4, title: "Download the exports") {
                                Text("Slack prepares each export in the background, on the same exports page.")
                                    .foregroundStyle(.secondary)
                                Instruction(number: 1, text: "Open the Downloads tab on that page.")
                                Instruction(number: 2, text: "Wait until every custodian's export shows as ready.")
                                Instruction(number: 3, text: "Download each one — they save as ZIP files.")
                                Instruction(number: 4, text: "Drag them all into the area below.")
                            }

                            setupSection(number: 5, title: "Add the export ZIPs") {
                                Text("Always available — drop files here any time, including ones from a previous run.")
                                    .foregroundStyle(.secondary)

                                VStack(spacing: 14) {
                                    Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "doc.zipper")
                                        .font(.system(size: 48))
                                        .foregroundStyle(ThreadLightTheme.accentForeground)
                                    Text("Drop Slack export ZIPs here")
                                        .font(.title3.bold())
                                    Text("Add one or more ZIP files for this legal hold.")
                                        .foregroundStyle(.secondary)
                                    Button("Choose ZIP files…", systemImage: "folder") {
                                        chooseArchives()
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(model.isPackaging)
                                }
                                .frame(maxWidth: .infinity, minHeight: 230)
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(ThreadLightTheme.violet.opacity(isDropTargeted ? 0.14 : 0.06))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(
                                            ThreadLightTheme.violet.opacity(isDropTargeted ? 0.9 : 0.35),
                                            style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [7])
                                        )
                                )
                                .dropDestination(for: URL.self) { urls, _ in
                                    add(urls)
                                } isTargeted: {
                                    isDropTargeted = $0
                                }

                                if !archiveURLs.isEmpty {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("ZIP files (\(archiveURLs.count))")
                                            .font(.headline)
                                        ForEach(archiveURLs, id: \.standardizedFileURL) { url in
                                            HStack {
                                                Image(systemName: "doc.zipper")
                                                    .foregroundStyle(ThreadLightTheme.accentForeground)
                                                Text(url.lastPathComponent)
                                                    .lineLimit(1)
                                                Spacer()
                                                Button("Remove", systemImage: "xmark") {
                                                    archiveURLs.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
                                                }
                                                .labelStyle(.iconOnly)
                                                .buttonStyle(.plain)
                                                .disabled(model.isPackaging)
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 9)
                                            .threadLightCard()
                                        }
                                    }
                                }

                                Text("ThreadLight normalizes the ZIPs locally. The encrypted package opens only while the same legal hold and member list are available in Slack.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(20)
                    }

                    Divider()

                    HStack(spacing: 12) {
                        Spacer()
                        if model.isPackaging {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button {
                            savePackage()
                        } label: {
                            Label(model.isPackaging ? "Creating encrypted package…" : "Save encrypted package…", systemImage: "lock.doc")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ThreadLightTheme.violet)
                        .controlSize(.large)
                        .disabled(archiveURLs.isEmpty || model.isPackaging)
                        Spacer()
                    }
                    .padding(16)
                    .background(.bar)
                }
            }
        }
        .onAppear {
            if let newest = activeHolds.first, model.selectedHold?.id != newest.id {
                model.sidebarSelection = .hold(newest.id)
            }
        }
        .onChange(of: model.selectedHold?.id) {
            archiveURLs.removeAll()
            copiedScript = false
        }
        .onChange(of: model.completedPackageCount) {
            archiveURLs.removeAll()
        }
        .onChange(of: toDate) {
            if fromDate > toDate { fromDate = toDate }
            if fromDate < minFromDate { fromDate = minFromDate }
            copiedScript = false
        }
        .onChange(of: fromDate) {
            if toDate < fromDate { toDate = fromDate }
            copiedScript = false
        }
    }

    private var activeHolds: [LegalHold] {
        model.holds
            .filter { $0.status == .active }
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.id < $1.id }
                return $0.createdAt > $1.createdAt
            }
    }

    private var selectedHoldID: Binding<String> {
        Binding(
            get: { model.selectedHold?.id ?? activeHolds.first?.id ?? "" },
            set: { model.sidebarSelection = .hold($0) }
        )
    }

    private var minFromDate: Date {
        Calendar.current.date(byAdding: .day, value: -Self.maxRangeDays, to: toDate) ?? toDate
    }

    private var exportsPageURL: URL? {
        guard let organizationID = model.selectedHold?.organizationID,
              !organizationID.isEmpty, organizationID != "unknown" else { return nil }
        return URL(string: "https://app.slack.com/manage/\(organizationID)/security/exports")
    }

    private var exportScriptText: String {
        SlackExportScript.build(
            custodianIDs: model.custodians.map(\.id),
            startDate: Self.scriptDateFormatter.string(from: fromDate),
            endDate: Self.scriptDateFormatter.string(from: toDate)
        )
    }

    private func chooseArchives() {
        let panel = NSOpenPanel()
        panel.title = "Choose Slack export ZIP files"
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            _ = add(panel.urls)
        }
    }

    @discardableResult
    private func add(_ urls: [URL]) -> Bool {
        var existing = Set(archiveURLs.map(\.standardizedFileURL))
        let zips = urls.filter { $0.pathExtension.lowercased() == "zip" }
        let additions = zips.filter { existing.insert($0.standardizedFileURL).inserted }
        archiveURLs.append(contentsOf: additions)
        return !additions.isEmpty
    }

    private func savePackage() {
        model.savePackage(archives: archiveURLs, operatorBinding: NSFullUserName())
    }
}

/// A handoff package carries the public key that verifies its own signature, so a valid
/// signature only proves the package is internally consistent — anyone who alters it can
/// re-sign with their own key. Comparing this ID out of band is what ties the imported
/// client ID to the real Slack Admin, so sign-in stays blocked until that happens.
private struct SignerConfirmation: View {
    let signerKeyID: String
    let confirm: () -> Void
    @State private var isConfirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Confirm who sent this handoff", systemImage: "exclamationmark.shield.fill")
                .font(.headline)
            Text("The signature on this handoff proves only that its contents are unaltered against the key inside it. Read the full signer ID below to the Slack Admin through your approved channel and confirm it matches theirs. Until then ThreadLight will not sign in with the client ID this handoff supplied.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(signerKeyID)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Toggle("I compared this signer ID with the Slack Admin out of band and it matches", isOn: $isConfirmed)
                .font(.callout)
            Button("Confirm signer") { confirm() }
                .buttonStyle(.borderedProminent)
                .tint(ThreadLightTheme.violet)
                .disabled(!isConfirmed)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.yellow, lineWidth: 1))
    }
}

private struct Instruction: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text(number.formatted())
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(ThreadLightTheme.violet, in: Circle())
            Text(text)
                .font(.callout)
        }
        .accessibilityElement(children: .combine)
    }
}
