import AppKit
import SwiftUI
import ThreadLightCore

struct SlackAppInstallationSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var copiedManifest = false
    @State private var isConnecting = false

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

                        HStack {
                            Link("Open Slack apps", destination: SlackAppManifest.createAppURL)
                            Button {
                                isConnecting = true
                                Task {
                                    await model.connectSlack()
                                    isConnecting = false
                                }
                            } label: {
                                Label(connectionButtonTitle, systemImage: model.isConnected ? "checkmark.circle.fill" : "person.crop.circle.badge.checkmark")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(ThreadLightTheme.violet)
                            .disabled(!hasAppDetails || isConnecting || model.isConnected)
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
        return "Sign in and verify"
    }

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
}

struct PackagePreparationSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Prepare Encrypted Packages", systemImage: "shippingbox.and.arrow.backward.fill")
                    .font(.title2.bold())
                    .foregroundStyle(ThreadLightTheme.accentForeground)
                Text("Attach one or more Slack export ZIPs to a legal hold, then save one encrypted package for transfer.")
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
                Form {
                    Section("Legal hold") {
                        Picker("Hold", selection: selectedHoldID) {
                            ForEach(activeHolds) { hold in
                                Text(hold.name).tag(hold.id)
                            }
                        }
                        if let hold = model.selectedHold, !hold.summary.isEmpty {
                            Text(hold.summary)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Create package") {
                        Button("Add Slack export ZIPs…", systemImage: "doc.zipper") {
                            model.presentImportPanel()
                        }
                        Button("Save encrypted package…", systemImage: "lock.doc") {
                            model.chooseHoldTransferDestination()
                        }
                        Text("ThreadLight normalizes the ZIPs locally. The encrypted package opens only while the same legal hold and member list are available in Slack.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .onAppear {
            if model.selectedHold?.status != .active, let first = activeHolds.first {
                model.sidebarSelection = .hold(first.id)
            }
        }
        .sheet(isPresented: $model.isShowingImport) {
            if let hold = model.selectedHold {
                HoldArchiveIntakeSheet(hold: hold)
            }
        }
        .alert("Slack exports imported", isPresented: $model.isShowingImportReport) {
            Button("OK", role: .cancel) {}
        } message: {
            if let report = model.lastImportReport {
                Text("Imported \(report.messagesImported) messages and found \(report.filesReferenced) file references.")
            }
        }
    }

    private var activeHolds: [LegalHold] {
        model.holds.filter { $0.status == .active }
    }

    private var selectedHoldID: Binding<String> {
        Binding(
            get: { model.selectedHold?.id ?? activeHolds.first?.id ?? "" },
            set: { model.sidebarSelection = .hold($0) }
        )
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
