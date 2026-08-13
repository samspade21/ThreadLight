import AppKit
import SwiftUI
import ThreadLightCore
import UniformTypeIdentifiers

struct SearchWorkspaceView: View {
    @Environment(AppModel.self) private var model
    let hold: LegalHold
    @State private var isShowingFilters = false
    @State private var isShowingStatusExplanation = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HoldHeader(hold: hold)
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
            } else {
                SearchBar(isShowingFilters: $isShowingFilters)
                Divider()
                if model.messages.isEmpty && !model.isSearching {
                    EvidenceEmptyState(isSearchEmpty: !model.queryText.isEmpty)
                } else {
                    ResultsList()
                }
            }

            Divider()
            HStack {
                if model.isSearching { ProgressView().controlSize(.small) }
                Text(model.statusMessage).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !model.selectedMessageIDs.isEmpty {
                    Button("Export \(model.selectedMessageIDs.count) selected") { model.presentExportPanel() }
                        .buttonStyle(.borderedProminent).tint(ThreadLightTheme.violet)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle(hold.name)
        .background(AmbientBackdrop())
        .sheet(isPresented: $model.isShowingExportOptions) { ExportOptionsSheet() }
        .popover(isPresented: $isShowingFilters) { FilterPopover() }
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
}

private struct ExportOptionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectionScope: AppModel.ExportSelectionScope = .completeThreads
    @State private var fileChoice: FileChoice = .both

    private enum FileChoice: String, CaseIterable, Identifiable {
        case json
        case pdf
        case both

        var id: String { rawValue }
        var title: String {
            switch self { case .json: "JSON"; case .pdf: "PDF"; case .both: "JSON + PDF" }
        }
        var formats: Set<EvidenceExportFormat> {
            switch self { case .json: [.json]; case .pdf: [.pdf]; case .both: [.json, .pdf] }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Create evidence package", systemImage: "checkmark.seal.fill")
                    .font(.title2.bold())
                    .foregroundStyle(ThreadLightTheme.accentForeground)
                Text("ThreadLight rechecks the live hold and every record’s provenance before writing anything.")
                    .foregroundStyle(.secondary)
            }

            GroupBox("Evidence scope") {
                Picker("Scope", selection: $selectionScope) {
                    ForEach(AppModel.ExportSelectionScope.allCases) { scope in Text(scope.title).tag(scope) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(selectionScope == .completeThreads
                     ? "Includes every in-scope message in each selected thread, even if only one result was checked."
                     : "Includes only the checked messages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
            }

            GroupBox("Document format") {
                Picker("Format", selection: $fileChoice) {
                    ForEach(FileChoice.allCases) { choice in Text(choice.title).tag(choice) }
                }
                .pickerStyle(.segmented)
                Text("Available original attachments are included with either format. The signed manifest covers every file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }

            HStack {
                Text("\(model.selectedMessageIDs.count) message\(model.selectedMessageIDs.count == 1 ? "" : "s") selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Choose destination…") {
                    model.chooseExportDestination(selectionScope: selectionScope, formats: fileChoice.formats)
                }
                .buttonStyle(.borderedProminent)
                .tint(ThreadLightTheme.violet)
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
            Text(isSearchEmpty ? "No matches yet" : "Import an encrypted package")
                .font(.title2.bold())
            Text(isSearchEmpty
                 ? "Try fewer terms or adjust the filter chips above."
                 : "Import the encrypted package for this legal hold to make its messages and attachments searchable.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if !isSearchEmpty {
                ThreadPathGlyph()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct HoldHeader: View {
    @Environment(AppModel.self) private var model
    let hold: LegalHold

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(hold.name).font(.title2.bold())
                        Text(hold.status.rawValue)
                            .font(.caption.bold())
                            .foregroundStyle(hold.status == .active ? ThreadLightTheme.successForeground : .secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background((hold.status == .active ? ThreadLightTheme.teal : Color.secondary).opacity(0.10), in: Capsule())
                    }
                    if !hold.summary.isEmpty { Text(hold.summary).foregroundStyle(.secondary).lineLimit(2) }
                    Text(windowDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.chooseHoldTransferImport() } label: {
                    Label("Import encrypted package", systemImage: "lock.open")
                }
                .buttonStyle(.borderedProminent).tint(ThreadLightTheme.violet)
                .disabled(hold.status != .active)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.custodians) { custodian in
                        Label(custodian.displayName, systemImage: "person.crop.circle")
                            .font(.caption)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .foregroundStyle(ThreadLightTheme.accentForeground)
                            .background(ThreadLightTheme.violet.opacity(0.08), in: Capsule())
                    }
                }
            }
            if model.custodians.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(ThreadLightTheme.dangerForeground)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Custodian list unavailable").font(.callout.bold())
                        Text("Sign in to Slack again. ThreadLight needs the current member list to open an encrypted package for this hold.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(ThreadLightTheme.coral.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(16)
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
        let restriction = hold.restrictions.contains(.onlyDMs) ? "Direct messages only" : "All covered conversations"
        return "\(start) – \(end)  •  \(restriction)  •  \(model.custodians.count) custodians"
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
                Picker("Mode", selection: $model.searchMode) {
                    Text("Basic").tag(SearchMode.basic)
                    Text("Advanced").tag(SearchMode.advanced)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Search mode")
                .frame(width: 180)
                Button { isShowingFilters.toggle() } label: { Label("Filters", systemImage: "line.3.horizontal.decrease.circle") }
                Button("Search") { Task { await model.search() } }
                    .buttonStyle(.borderedProminent).tint(ThreadLightTheme.violet)
                    .accessibilityIdentifier("search.submit")
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
        if let custodianID = filters.custodianID,
           let custodian = model.custodians.first(where: { $0.id == custodianID }) { labels.append("Custodian: \(custodian.displayName)") }
        if let conversation = filters.conversation { labels.append("In: \(conversation)") }
        if let after = filters.after { labels.append("After: \(after.formatted(date: .numeric, time: .omitted))") }
        if let before = filters.before { labels.append("Before: \(before.formatted(date: .numeric, time: .omitted))") }
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
            ForEach(groupedThreads, id: \.key) { threadID, messages in
                Section {
                    ForEach(messages) { message in
                        ResultRow(message: message)
                            .tag(message.id)
                    }
                } header: {
                    Text(messages.first.map { "#\($0.conversationName) • \(messages.count) message\(messages.count == 1 ? "" : "s")" } ?? threadID)
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
                guard let id, let message = model.messages.first(where: { $0.id == id }) else { return }
                model.selectMessage(message)
            }
        )
    }

    private var groupedThreads: [(key: String, value: [EvidenceMessage])] {
        Dictionary(grouping: model.messages, by: \.threadID)
            .map { ($0.key, $0.value.sorted { $0.postedAt < $1.postedAt }) }
            .sorted { ($0.1.last?.postedAt ?? .distantPast) > ($1.1.last?.postedAt ?? .distantPast) }
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
            Circle()
                .fill(ThreadLightTheme.avatarColor(for: message.senderID).opacity(0.16))
                .frame(width: 34, height: 34)
                .overlay(Text(message.senderName.prefix(1).uppercased()).font(.headline).foregroundStyle(.primary))
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
    }
}

private struct HighlightedMessageText: View {
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
        let pattern = #"\"([^\"]+)\"|([^\s()]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = query as NSString
        return regex.matches(in: query, range: NSRange(location: 0, length: source.length)).compactMap { match in
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

private struct FilterPopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            TextField("Sender", text: Binding($model.searchFilters.sender, replacingNilWith: ""))
            Picker("Custodian", selection: $model.searchFilters.custodianID) {
                Text("Any").tag(String?.none)
                ForEach(model.custodians) { Text($0.displayName).tag(String?.some($0.id)) }
            }
            TextField("Channel or conversation", text: Binding($model.searchFilters.conversation, replacingNilWith: ""))
            Picker("Conversation type", selection: $model.searchFilters.kind) {
                Text("Any").tag(ConversationKind?.none)
                ForEach(ConversationKind.allCases, id: \.self) { Text($0.rawValue).tag(ConversationKind?.some($0)) }
            }
            Toggle("After date", isOn: optionalDateToggle($model.searchFilters.after))
            if model.searchFilters.after != nil {
                DatePicker("After", selection: optionalDateValue($model.searchFilters.after), displayedComponents: .date)
            }
            Toggle("Before date", isOn: optionalDateToggle($model.searchFilters.before))
            if model.searchFilters.before != nil {
                DatePicker("Before", selection: optionalDateValue($model.searchFilters.before), displayedComponents: .date)
            }
            Toggle("Has attachment", isOn: Binding($model.searchFilters.hasAttachment, replacingNilWith: false))
            TextField("File type (for example PDF)", text: Binding($model.searchFilters.fileType, replacingNilWith: ""))
            Toggle("Thread replies only", isOn: Binding($model.searchFilters.isThread, replacingNilWith: false))
            Toggle("Edited", isOn: Binding($model.searchFilters.isEdited, replacingNilWith: false))
            Toggle("Deleted", isOn: Binding($model.searchFilters.isDeleted, replacingNilWith: false))
            HStack {
                Button("Clear") { model.searchFilters = .init() }
                Spacer()
                Button("Apply") { Task { await model.search() } }.buttonStyle(.borderedProminent).tint(ThreadLightTheme.violet)
            }
        }
        .padding().frame(width: 360)
    }

    private func optionalDateToggle(_ date: Binding<Date?>) -> Binding<Bool> {
        Binding(
            get: { date.wrappedValue != nil },
            set: { date.wrappedValue = $0 ? Calendar.current.startOfDay(for: .now) : nil }
        )
    }

    private func optionalDateValue(_ date: Binding<Date?>) -> Binding<Date> {
        Binding(get: { date.wrappedValue ?? .now }, set: { date.wrappedValue = $0 })
    }
}

struct HoldArchiveIntakeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let hold: LegalHold
    @State private var archiveURLs: [URL] = []
    @State private var operatorBinding = NSFullUserName()
    @State private var importing = false
    @State private var importTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Attach Slack exports to this hold").font(.title2.bold())
            Text(hold.name).font(.headline)
            if !hold.summary.isEmpty {
                Text(hold.summary).foregroundStyle(.secondary)
            }
            GroupBox {
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 34))
                        .foregroundStyle(ThreadLightTheme.accentForeground)
                    Text("Drop one or more ZIP files here").font(.headline)
                    Text("or").font(.caption).foregroundStyle(.secondary)
                    Button("Choose ZIP files…", action: chooseArchives)
                }
                .frame(maxWidth: .infinity, minHeight: 125)
            }
            .dropDestination(for: URL.self) { urls, _ in
                add(urls)
                return !urls.isEmpty
            }
            if !archiveURLs.isEmpty {
                List(archiveURLs, id: \.path) { url in
                    HStack {
                        Image(systemName: "doc.zipper")
                        Text(url.lastPathComponent).lineLimit(1)
                        Spacer()
                        Button("Remove", systemImage: "xmark") {
                            archiveURLs.removeAll { $0 == url }
                        }
                        .labelStyle(.iconOnly)
                    }
                }
                .frame(height: min(CGFloat(archiveURLs.count * 32 + 8), 150))
            }
            TextField("Imported by", text: $operatorBinding)
            HStack {
                Button(importing ? "Cancel import" : "Cancel") {
                    importTask?.cancel()
                    if !importing { dismiss() }
                }
                Spacer()
                Button("Import \(archiveURLs.count) ZIP file(s)") {
                    importing = true
                    importTask = Task {
                        await model.importHoldArchives(urls: archiveURLs, operatorBinding: operatorBinding)
                        importing = false
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent).tint(ThreadLightTheme.violet)
                .disabled(archiveURLs.isEmpty || operatorBinding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || importing)
            }
            if importing {
                ProgressView("Validating, normalizing, and encrypting local evidence…")
            }
        }
        .padding(24)
        .frame(minWidth: 650, idealWidth: 650, maxWidth: 650, minHeight: 440)
        .onDisappear { importTask?.cancel() }
    }

    private func chooseArchives() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func add(_ urls: [URL]) {
        let zips = urls.filter { $0.pathExtension.lowercased() == "zip" }
        let existing = Set(archiveURLs.map(\.standardizedFileURL))
        archiveURLs.append(contentsOf: zips.filter { !existing.contains($0.standardizedFileURL) })
    }
}

private extension Binding where Value == String {
    init(_ source: Binding<String?>, replacingNilWith fallback: String) {
        self.init(get: { source.wrappedValue ?? fallback }, set: { source.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

private extension Binding where Value == Bool {
    init(_ source: Binding<Bool?>, replacingNilWith fallback: Bool) {
        self.init(get: { source.wrappedValue ?? fallback }, set: { source.wrappedValue = $0 })
    }
}
