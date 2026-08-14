import AppKit
import SwiftUI
import ThreadLightCore
import UniformTypeIdentifiers

struct SearchWorkspaceView: View {
    @Environment(AppModel.self) private var model
    let hold: LegalHold
    let isLegalHoldListHidden: Bool
    let showLegalHolds: () -> Void
    let showsConversationSidebar: Bool
    @State private var isShowingFilters = false
    @State private var isShowingStatusExplanation = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HoldHeader(
                hold: hold,
                isLegalHoldListHidden: isLegalHoldListHidden,
                showLegalHolds: showLegalHolds
            )
            Divider()

            if hold.status != .active {
                ContentUnavailableView {
                    Label(hold.status == .released ? "Hold released" : "Hold status unavailable", systemImage: hold.status == .released ? "lock.open.fill" : "questionmark.diamond.fill")
                } description: {
                    Text(hold.status == .released
                         ? "Slack says this legal hold has been released, so its local data can no longer be used."
                         : "Slack could not confirm that this legal hold is active, so its local data cannot be used.")
                } actions: {
                    Button("Why is this blocked?") { isShowingStatusExplanation = true }
                }
            } else if !model.hasImportedPackage {
                PackageDropZone(hold: hold)
            } else if showsConversationSidebar {
                HSplitView {
                    ConversationSidebar()
                        .frame(minWidth: 150, idealWidth: 210, maxWidth: 420)
                    resultsPane
                        .frame(minWidth: 460)
                }
            } else {
                resultsPane
            }

            Divider()
            HStack {
                if model.isSearching { ProgressView().controlSize(.small) }
                Text(model.statusMessage).font(.caption).foregroundStyle(.secondary)
                if model.canLoadMoreMessages {
                    Button("Load More") { Task { await model.loadMoreMessages() } }
                        .disabled(model.isSearching)
                        .accessibilityIdentifier("search.load-more")
                }
                Spacer()
                if !model.selectedMessageIDs.isEmpty {
                    Button("Export \(model.selectedMessageIDs.count) selected") { model.presentExportPanel() }
                        .buttonStyle(.borderedProminent).tint(ThreadLightTheme.violet)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
        }
        .background(AmbientBackdrop())
        .sheet(isPresented: $model.isShowingExportOptions) { ExportOptionsSheet() }
        .alert("Slack exports imported", isPresented: $model.isShowingImportReport) {
            Button("OK", role: .cancel) {}
        } message: {
            if let report = model.lastImportReport {
                Text(importSummary(report))
            }
        }
        .alert("Why this hold is blocked", isPresented: $isShowingStatusExplanation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(hold.status == .released
                 ? "Slack reports that this legal hold was released. ThreadLight blocks its old local data so it cannot be searched or exported by mistake."
                 : "Slack did not return an active status for this legal hold. Sign in again, or ask your Slack administrator to check the hold.")
        }
    }

    private func importSummary(_ report: ImportReport) -> String {
        let summary = "\(report.messagesImported) messages imported; \(report.messagesDeduplicated) shared messages deduplicated; \(report.filesReferenced) files referenced."
        return report.warnings.isEmpty ? summary : summary + "\n\n" + report.warnings.joined(separator: "\n")
    }

    private var resultsPane: some View {
        VStack(spacing: 0) {
            SearchBar(isShowingFilters: $isShowingFilters)
            Divider()
            if model.messages.isEmpty && !model.isSearching {
                EvidenceEmptyState(isSearchEmpty: !model.queryText.isEmpty || model.searchFilters.conversationID != nil)
            } else {
                ResultsList()
            }
        }
    }
}

private struct ExportOptionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectionScope: AppModel.ExportSelectionScope = .completeThreads
    @State private var fileChoice: FileChoice = .pdf
    @State private var includeEvidenceSigning = false

    private enum FileChoice: String, CaseIterable, Identifiable {
        case pdf
        case json
        case both

        var id: String { rawValue }
        var title: String {
            switch self { case .pdf: "PDF"; case .json: "JSON"; case .both: "PDF + JSON" }
        }
        var formats: Set<EvidenceExportFormat> {
            switch self { case .json: [.json]; case .pdf: [.pdf]; case .both: [.json, .pdf] }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Export evidence", systemImage: "checkmark.seal.fill")
                    .font(.title2.bold())
                    .foregroundStyle(ThreadLightTheme.accentForeground)
                Text("ThreadLight rechecks the live hold and every record’s provenance before writing anything.")
                    .foregroundStyle(.secondary)
            }

            GroupBox("Evidence scope") {
                HStack(alignment: .top, spacing: 24) {
                    Picker("Scope", selection: $selectionScope) {
                        ForEach(AppModel.ExportSelectionScope.allCases) { scope in Text(scope.title).tag(scope) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .frame(width: 190, alignment: .leading)

                    Text(selectionScope == .completeThreads
                         ? "Includes every in-scope message in each selected thread, even if only one result was checked."
                         : "Includes only the checked messages.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)
                }
            }

            GroupBox("Document format") {
                Picker("Format", selection: $fileChoice) {
                    ForEach(FileChoice.allCases) { choice in Text(choice.title).tag(choice) }
                }
                .pickerStyle(.segmented)
                Text(includeEvidenceSigning
                     ? "Creates a signed evidence directory. Available original attachments, a manifest, and verification data are included."
                     : "Exports only the selected PDF or JSON files. Attachments, manifests, and signatures are not included.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .topLeading)
            }

            GroupBox("Evidence signing") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Toggle("", isOn: $includeEvidenceSigning)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .fixedSize()
                        Text("Include evidence signing")
                        Spacer(minLength: 0)
                    }
                    Text(includeEvidenceSigning
                         ? "ThreadLight will create the complete .threadlight-evidence directory."
                         : "Off by default. ThreadLight will write individual files directly into the chosen folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Text("\(model.selectedMessageIDs.count) message\(model.selectedMessageIDs.count == 1 ? "" : "s") selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export") {
                    model.chooseExportDestination(
                        selectionScope: selectionScope,
                        formats: fileChoice.formats,
                        includeEvidenceSigning: includeEvidenceSigning
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(ThreadLightTheme.violet)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

private struct EvidenceEmptyState: View {
    @Environment(AppModel.self) private var model
    let isSearchEmpty: Bool

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(ThreadLightTheme.violet.opacity(0.08))
                    .frame(width: 112, height: 112)
                Image(systemName: isSearchEmpty ? "magnifyingglass" : "tray.and.arrow.down.fill")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(ThreadLightTheme.threadGradient)
                if !isSearchEmpty {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.title2)
                        .foregroundStyle(ThreadLightTheme.successForeground)
                        .offset(x: 38, y: 36)
                }
            }
            Text(isSearchEmpty ? "No matches yet" : "No messages in this package")
                .font(.title2.bold())
            Text(isSearchEmpty
                 ? "Try fewer terms or adjust the filter chips above."
                 : "The imported package does not contain searchable messages.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct HoldHeader: View {
    @Environment(AppModel.self) private var model
    let hold: LegalHold
    let isLegalHoldListHidden: Bool
    let showLegalHolds: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if isLegalHoldListHidden {
                Button(action: showLegalHolds) {
                    Label("Legal holds", systemImage: "sidebar.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Show the legal hold list")
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(hold.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(hold.status.rawValue)
                        .font(.caption2.bold())
                        .foregroundStyle(hold.status == .active ? ThreadLightTheme.successForeground : .secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((hold.status == .active ? ThreadLightTheme.teal : Color.secondary).opacity(0.10), in: Capsule())
                }
                Text(windowDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help(hold.summary)

            Spacer(minLength: 8)

            if hold.status == .active {
                if model.custodians.isEmpty {
                    Label("Custodians unavailable", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(ThreadLightTheme.dangerForeground)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.custodians) { custodian in
                                if let name = resolvedName(for: custodian) {
                                    let profile = model.slackUserProfiles[custodian.id]
                                    let email = profile?.email ?? custodian.email
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        let identity = [name, "Slack ID: \(custodian.id)", email.map { "Email: \($0)" }]
                                            .compactMap { $0 }
                                            .joined(separator: "\n")
                                        NSPasteboard.general.setString(identity, forType: .string)
                                    } label: {
                                        HStack(spacing: 5) {
                                            SlackAvatar(
                                                name: name,
                                                userID: custodian.id,
                                                url: profile?.avatarURL ?? custodian.avatarURL,
                                                size: 18
                                            )
                                            Text(name)
                                        }
                                            .font(.caption2)
                                            .padding(.horizontal, 7).padding(.vertical, 3)
                                            .foregroundStyle(ThreadLightTheme.accentForeground)
                                            .background(ThreadLightTheme.violet.opacity(0.08), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .help([name, "Slack ID: \(custodian.id)", email.map { "Email: \($0)" }].compactMap { $0 }.joined(separator: "\n"))
                                    .accessibilityLabel("Copy \(name), Slack ID, and email")
                                }
                            }
                            if unresolvedCustodianCount > 0 {
                                HStack(spacing: 5) {
                                    ProgressView().controlSize(.mini)
                                    Text("Loading \(unresolvedCustodianCount) name\(unresolvedCustodianCount == 1 ? "" : "s")…")
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(minWidth: 120, maxWidth: 300, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            LinearGradient(
                colors: [ThreadLightTheme.aubergine.opacity(0.08), ThreadLightTheme.violet.opacity(0.035), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var windowDescription: String {
        let start = hold.startAt?.formatted(date: .abbreviated, time: .omitted) ?? "All history"
        let end = hold.endAt?.formatted(date: .abbreviated, time: .omitted) ?? "until release"
        let restriction = hold.restrictions.contains(.onlyDMs) ? "DMs only" : "All conversations"
        return "\(start) – \(end)  •  \(restriction)"
    }

    private var unresolvedCustodianCount: Int {
        model.custodians.count { resolvedName(for: $0) == nil }
    }

    private func resolvedName(for custodian: Custodian) -> String? {
        let candidates = [
            model.slackUserProfiles[custodian.id]?.displayName,
            custodian.displayName,
            model.messages.first(where: { $0.senderID == custodian.id })?.senderName,
        ]
        return candidates.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false && trimmed != custodian.id ? trimmed : nil
        }.first
    }
}

private struct PackageDropZone: View {
    @Environment(AppModel.self) private var model
    let hold: LegalHold
    @State private var isTargeted = false
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: isImporting ? "lock.rotation" : "shippingbox.and.arrow.backward.fill")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(ThreadLightTheme.threadGradient)
            Text(isImporting ? "Importing package…" : "Drag the legal hold package here")
                .font(.title2.bold())
            Text("Get the encrypted .threadlight package from your Slack administrator, then drag it anywhere into this area.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if isImporting {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(36)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(ThreadLightTheme.violet.opacity(isTargeted ? 0.10 : 0.035))
                .padding(24)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(
                    ThreadLightTheme.violet.opacity(isTargeted ? 0.70 : 0.20),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [8, 6])
                )
                .padding(24)
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard !isImporting,
                  let package = urls.first(where: { HoldTransferFile.isTransfer($0) }) else { return false }
            isImporting = true
            Task {
                await model.importHoldTransfer(from: package)
                isImporting = false
            }
            return true
        } isTargeted: { isTargeted = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop encrypted package for \(hold.name)")
    }
}

private struct ConversationSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        List {
            Button {
                model.selectConversation(id: nil)
            } label: {
            ConversationSidebarRow(
                title: "All messages",
                symbol: "tray.full.fill",
                count: model.conversations.reduce(0) { $0 + $1.messageCount },
                isSelected: model.searchFilters.conversationID == nil,
                avatarProfiles: []
                )
            }
            .buttonStyle(.plain)

            if !directMessages.isEmpty {
                Section("Direct messages") {
                    ForEach(directMessages) { conversation in
                        conversationButton(conversation)
                    }
                }
            }

            if !channels.isEmpty {
                Section("Channels") {
                    ForEach(channels) { conversation in
                        conversationButton(conversation)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("evidence.conversations")
    }

    @ViewBuilder
    private func conversationButton(_ conversation: EvidenceConversation) -> some View {
        Button {
            model.selectConversation(id: conversation.id)
        } label: {
            ConversationSidebarRow(
                title: conversation.name,
                symbol: symbol(for: conversation.kind),
                count: conversation.messageCount,
                isSelected: model.searchFilters.conversationID == conversation.id,
                avatarProfiles: conversation.kind.isDirect ? profiles(for: conversation) : []
            )
        }
        .buttonStyle(.plain)
        .help(helpText(for: conversation))
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard let holdID = model.selectedHold?.id else { return }
                openWindow(value: ConversationWindowRequest(holdID: holdID, conversationID: conversation.id))
            }
        )
        .contextMenu {
            Button("Select all messages") {
                Task { await model.setEvidenceSelection(for: conversation, selected: true) }
            }
            Button("Unselect all messages") {
                Task { await model.setEvidenceSelection(for: conversation, selected: false) }
            }
            Divider()
            Button("Export this conversation to PDF…") {
                model.chooseConversationPDFDestination(conversation)
            }
        }
    }

    private var directMessages: [EvidenceConversation] {
        model.conversations.filter { $0.kind.isDirect }.sorted(by: conversationSort)
    }

    private var channels: [EvidenceConversation] {
        model.conversations.filter { !$0.kind.isDirect }.sorted(by: conversationSort)
    }

    private func conversationSort(_ lhs: EvidenceConversation, _ rhs: EvidenceConversation) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func symbol(for kind: ConversationKind) -> String {
        switch kind {
        case .directMessage: "person.fill"
        case .groupDirectMessage: "person.2.fill"
        case .publicChannel: "number"
        case .privateChannel: "lock.fill"
        case .unknown: "bubble.left.fill"
        }
    }

    private func helpText(for conversation: EvidenceConversation) -> String {
        guard conversation.kind.isDirect else { return "Show messages in \(conversation.name)" }
        let details = participantNames(for: conversation).map { name in
            guard let profile = profile(named: name), let email = profile.email else { return name }
            return "\(name) — \(email)"
        }
        return details.isEmpty ? "Direct message" : "Participants:\n" + details.joined(separator: "\n")
    }

    private func profiles(for conversation: EvidenceConversation) -> [SlackUserProfile] {
        participantNames(for: conversation).compactMap(profile(named:))
    }

    private func participantNames(for conversation: EvidenceConversation) -> [String] {
        conversation.name
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func profile(named name: String) -> SlackUserProfile? {
        model.slackUserProfiles.values.first {
            $0.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }
}

private struct ConversationSidebarRow: View {
    let title: String
    let symbol: String
    let count: Int
    let isSelected: Bool
    let avatarProfiles: [SlackUserProfile]

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if avatarProfiles.isEmpty {
                    Image(systemName: symbol)
                } else {
                    HStack(spacing: -5) {
                        ForEach(avatarProfiles.prefix(2), id: \.id) { profile in
                            SlackAvatar(name: profile.displayName, userID: profile.id, url: profile.avatarURL, size: 18)
                                .overlay(Circle().stroke(.background, lineWidth: 1))
                        }
                    }
                }
            }
            .frame(width: 28)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(count.formatted())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(isSelected ? ThreadLightTheme.accentForeground : .primary)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(isSelected ? ThreadLightTheme.violet.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}

private struct SearchBar: View {
    @Environment(AppModel.self) private var model
    @Binding var isShowingFilters: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(ThreadLightTheme.accentForeground)
                TextField(model.searchMode == .basic ? "Search messages…" : "Boolean search…", text: $model.queryText)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await model.search() } }
                    .accessibilityLabel("Search messages")
                    .accessibilityIdentifier("search.query")
                Button("Search") { Task { await model.search() } }
                    .buttonStyle(.borderedProminent)
                    .tint(ThreadLightTheme.violet)
                    .accessibilityIdentifier("search.submit")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.secondary.opacity(0.18)))

            HStack(spacing: 8) {
                Picker("Mode", selection: $model.searchMode) {
                    Text("Basic").tag(SearchMode.basic)
                    Text("Advanced").tag(SearchMode.advanced)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Search mode")
                .frame(width: 115)
                Spacer()
                Menu {
                    ForEach(AppModel.MessageSort.allCases) { option in
                        Button {
                            model.messageSort = option
                        } label: {
                            if option == model.messageSort {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sort messages: \(model.messageSort.title)")
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { isShowingFilters.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Label("Filters", systemImage: "line.3.horizontal.decrease.circle.fill")
                        if !filterLabels.isEmpty {
                            Text(filterLabels.count.formatted())
                                .font(.caption2.bold())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.white.opacity(0.20), in: Capsule())
                        }
                        Image(systemName: isShowingFilters ? "chevron.up" : "chevron.down")
                            .font(.caption2.bold())
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(ThreadLightTheme.violet)
                .help(isShowingFilters ? "Hide search filters" : "Show search filters")
                .accessibilityIdentifier("search.filters")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isShowingFilters {
                FilterPanel {
                    withAnimation(.easeInOut(duration: 0.18)) { isShowingFilters = false }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if model.searchMode == .advanced {
                Text("Supports AND, OR, NOT, parentheses, quoted phrases, NEAR/1…50, and text:/from:/in:/file: fields.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !filterLabels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(filterLabels, id: \.self) { label in
                            Text(label).font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .foregroundStyle(ThreadLightTheme.accentForeground)
                                .background(ThreadLightTheme.violet.opacity(0.10), in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
    }

    private var filterLabels: [String] {
        let filters = model.searchFilters
        var labels: [String] = []
        if let sender = filters.sender { labels.append("From: \(sender)") }
        if let personID = filters.personID,
           let custodian = model.custodians.first(where: { $0.id == personID }) {
            labels.append("Person: \(model.slackUserProfiles[personID]?.displayName ?? custodian.displayName)")
        }
        if let custodianID = filters.custodianID,
           let custodian = model.custodians.first(where: { $0.id == custodianID }) { labels.append("Custodian: \(custodian.displayName)") }
        if let conversationID = filters.conversationID,
           let conversation = model.conversations.first(where: { $0.id == conversationID }) { labels.append("In: \(conversation.name)") }
        if let conversation = filters.conversation { labels.append("In: \(conversation)") }
        if let after = filters.after { labels.append("From date: \(after.formatted(date: .numeric, time: .omitted))") }
        if let before = filters.before { labels.append("Through date: \(before.addingTimeInterval(-1).formatted(date: .numeric, time: .omitted))") }
        if let kind = filters.kind { labels.append(kind.rawValue) }
        if filters.hasAttachment == true { labels.append("Has attachment") }
        if let fileType = filters.fileType { labels.append("File: \(fileType)") }
        if filters.isThread == true { labels.append("Thread replies") }
        if filters.isEdited == true { labels.append("Edited") }
        if filters.isDeleted == true { labels.append("Deleted") }
        return labels
    }
}

private struct ResultsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: selection) {
            ForEach(model.messageThreadGroups) { group in
                Section {
                    ForEach(group.messages) { message in
                        ResultRow(message: message)
                            .tag(message.id)
                    }
                } header: {
                    Text(group.messages.first.map { "#\($0.conversationName) • \(group.messages.count) message\(group.messages.count == 1 ? "" : "s")" } ?? group.id)
                }
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("search.results")
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedMessage?.id },
            set: { id in
                guard let id, let message = model.message(id: id) else { return }
                model.selectMessage(message)
            }
        )
    }
}

private struct ResultRow: View {
    @Environment(AppModel.self) private var model
    let message: EvidenceMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { model.toggleEvidenceSelection(message.id) } label: {
                Image(systemName: model.selectedMessageIDs.contains(message.id) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(model.selectedMessageIDs.contains(message.id) ? ThreadLightTheme.accentForeground : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.selectedMessageIDs.contains(message.id) ? "Remove message from evidence selection" : "Add message to evidence selection")
            SlackAvatar(
                name: message.senderName,
                userID: message.senderID,
                url: model.slackUserProfiles[message.senderID]?.avatarURL,
                size: 34
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(message.senderName).fontWeight(.semibold)
                    Text(message.postedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    if message.isDeleted { Text("DELETED").font(.caption2.bold()).foregroundStyle(.red) }
                    else if message.editedAt != nil { Text("edited").font(.caption).foregroundStyle(.secondary) }
                }
                HighlightedMessageText(
                    text: message.text.isEmpty ? "(No message text)" : message.text,
                    query: model.queryText
                )
                    .lineLimit(4)
                    .textSelection(.enabled)
                if !displayedReactions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(displayedReactions, id: \.self) { reaction in
                            SlackReactionView(
                                reaction: reaction,
                                customEmojiURL: model.slackEmojiURLs[reaction.name],
                                compact: true
                            )
                        }
                    }
                }
                if !message.files.isEmpty {
                    HStack {
                        ForEach(message.files.prefix(3)) { file in
                            Label(file.name, systemImage: file.hasOriginalBytes ? "doc.fill" : "link")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.senderName), \(message.postedAt.formatted()), \(message.text)")
        .task(id: message.id) {
            await model.refreshReactions(for: message)
        }
    }

    private var displayedReactions: [EvidenceReaction] {
        model.liveReactions[message.id] ?? message.reactions ?? []
    }
}

private struct HighlightedMessageText: View {
    private static let termRegex = try! NSRegularExpression(pattern: #"\"([^\"]+)\"|([^\s()]+)"#)

    let text: String
    let query: String

    var body: some View {
        Text(highlighted)
    }

    private var highlighted: AttributedString {
        var output = AttributedString(text)
        for term in highlightTerms where !term.isEmpty {
            var searchStart = output.startIndex
            while searchStart < output.endIndex,
                  let range = output[searchStart...].range(of: term, options: .caseInsensitive) {
                output[range].backgroundColor = ThreadLightTheme.violet.opacity(0.18)
                output[range].foregroundColor = ThreadLightTheme.accentForeground
                output[range].font = .body.bold()
                searchStart = range.upperBound
            }
        }
        return output
    }

    private var highlightTerms: [String] {
        let source = query as NSString
        return Self.termRegex.matches(in: query, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let quoted = match.range(at: 1)
            if quoted.location != NSNotFound { return source.substring(with: quoted) }
            var token = source.substring(with: match.range(at: 2))
            let upper = token.uppercased()
            if ["AND", "OR", "NOT"].contains(upper) || upper.hasPrefix("NEAR/") { return nil }
            if let separator = token.firstIndex(of: ":") {
                let field = String(token[..<separator]).lowercased()
                guard field == "text" else { return nil }
                token = String(token[token.index(after: separator)...])
            }
            return token
        }
    }
}

private struct FilterPanel: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("Filter messages", systemImage: "line.3.horizontal.decrease.circle.fill")
                    .font(.headline)
                    .foregroundStyle(ThreadLightTheme.accentForeground)
                if activeFilterCount > 0 {
                    Text("\(activeFilterCount) active")
                        .font(.caption2.bold())
                        .foregroundStyle(ThreadLightTheme.accentForeground)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(ThreadLightTheme.violet.opacity(0.11), in: Capsule())
                }
                Spacer()
                Button("Clear", systemImage: "xmark.circle") {
                    model.searchFilters = .init()
                    Task { await model.search() }
                }
                .disabled(activeFilterCount == 0 || model.isSearching)
                Button {
                    close()
                    Task { await model.search() }
                } label: {
                    if model.isSearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Apply Filters", systemImage: "checkmark")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(ThreadLightTheme.violet)
                .disabled(model.isSearching)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    filterField("Person involved", detail: "Author or @mention") {
                        Picker("Person involved", selection: $model.searchFilters.personID) {
                            Text("Any person").tag(String?.none)
                            ForEach(model.custodians) { custodian in
                                Text(model.slackUserProfiles[custodian.id]?.displayName ?? custodian.displayName)
                                    .tag(String?.some(custodian.id))
                            }
                        }
                        .labelsHidden()
                    }
                    filterField("Conversation type") {
                        Picker("Conversation type", selection: $model.searchFilters.kind) {
                            Text("Any type").tag(ConversationKind?.none)
                            ForEach(ConversationKind.allCases, id: \.self) {
                                Text($0.rawValue).tag(ConversationKind?.some($0))
                            }
                        }
                        .labelsHidden()
                    }
                }
                GridRow {
                    filterField("Sender name") {
                        TextField("Any sender", text: Binding($model.searchFilters.sender, replacingNilWith: ""))
                            .textFieldStyle(.roundedBorder)
                    }
                    filterField("Channel or conversation") {
                        TextField("Any conversation", text: Binding($model.searchFilters.conversation, replacingNilWith: ""))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                GridRow {
                    filterField("Evidence custodian") {
                        Picker("Evidence custodian", selection: $model.searchFilters.custodianID) {
                            Text("Any custodian").tag(String?.none)
                            ForEach(model.custodians) { Text($0.displayName).tag(String?.some($0.id)) }
                        }
                        .labelsHidden()
                    }
                    filterField("File type") {
                        TextField("For example, PDF", text: Binding($model.searchFilters.fileType, replacingNilWith: ""))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 9) {
                Toggle("Between specific days", isOn: dateRangeEnabled)
                    .toggleStyle(.switch)
                if model.searchFilters.after != nil, model.searchFilters.before != nil {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("From date")
                                .font(.caption.weight(.semibold))
                            DatePicker("From date", selection: fromDate, displayedComponents: .date)
                                .labelsHidden()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Through date")
                                .font(.caption.weight(.semibold))
                            DatePicker("Through date", selection: throughDate, displayedComponents: .date)
                                .labelsHidden()
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            HStack(spacing: 18) {
                Toggle("Has attachment", isOn: enabledFilter($model.searchFilters.hasAttachment))
                Toggle("Thread replies", isOn: enabledFilter($model.searchFilters.isThread))
                Toggle("Edited", isOn: enabledFilter($model.searchFilters.isEdited))
                Toggle("Deleted", isOn: enabledFilter($model.searchFilters.isDeleted))
                Spacer(minLength: 0)
            }
        }
        .font(.callout)
        .padding(14)
        .threadLightCard(emphasis: activeFilterCount > 0)
        .accessibilityIdentifier("search.filter-panel")
    }

    @ViewBuilder
    private func filterField<Content: View>(
        _ title: String,
        detail: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(title).font(.caption.weight(.semibold))
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activeFilterCount: Int {
        let filters = model.searchFilters
        return [
            filters.sender != nil,
            filters.personID != nil,
            filters.custodianID != nil,
            filters.conversationID != nil,
            filters.conversation != nil,
            filters.after != nil || filters.before != nil,
            filters.kind != nil,
            filters.hasAttachment == true,
            filters.fileType != nil,
            filters.isThread == true,
            filters.isEdited == true,
            filters.isDeleted == true,
        ].count(where: { $0 })
    }

    private func enabledFilter(_ value: Binding<Bool?>) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue == true },
            set: { value.wrappedValue = $0 ? true : nil }
        )
    }

    private var dateRangeEnabled: Binding<Bool> {
        Binding(
            get: { model.searchFilters.after != nil && model.searchFilters.before != nil },
            set: { enabled in
                if enabled {
                    let calendar = Calendar.current
                    let today = calendar.startOfDay(for: .now)
                    model.searchFilters.after = calendar.date(byAdding: .month, value: -1, to: today) ?? today
                    model.searchFilters.before = calendar.date(byAdding: .day, value: 1, to: today)
                } else {
                    model.searchFilters.after = nil
                    model.searchFilters.before = nil
                }
            }
        )
    }

    private var fromDate: Binding<Date> {
        Binding(
            get: { model.searchFilters.after ?? .now },
            set: { model.searchFilters.after = Calendar.current.startOfDay(for: $0) }
        )
    }

    private var throughDate: Binding<Date> {
        Binding(
            get: { (model.searchFilters.before ?? .now).addingTimeInterval(-1) },
            set: {
                let start = Calendar.current.startOfDay(for: $0)
                model.searchFilters.before = Calendar.current.date(byAdding: .day, value: 1, to: start)
            }
        )
    }
}

private extension Binding where Value == String {
    init(_ source: Binding<String?>, replacingNilWith fallback: String) {
        self.init(get: { source.wrappedValue ?? fallback }, set: { source.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}
