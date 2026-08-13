import SwiftUI
import ThreadLightCore

struct MessageDetailView: View {
    @Environment(AppModel.self) private var model
    let message: EvidenceMessage?

    var body: some View {
        if let message {
            ZStack {
                AmbientBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Image(systemName: "number")
                                .foregroundStyle(ThreadLightTheme.accentForeground)
                            Text(message.conversationName).font(.title2.bold())
                        }
                        Text(message.postedAt.formatted(date: .complete, time: .standard)).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        let avatarColor = ThreadLightTheme.avatarColor(for: message.senderID)
                        Circle().fill(avatarColor.opacity(0.16)).frame(width: 42, height: 42)
                            .overlay(Text(message.senderName.prefix(1).uppercased()).font(.title3.bold()).foregroundStyle(.primary))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message.senderName).font(.headline)
                            Text(message.text.isEmpty ? "(No message text)" : message.text)
                                .textSelection(.enabled)
                        }
                    }
                    if let reactions = message.reactions, !reactions.isEmpty {
                        HStack(spacing: 7) {
                            ForEach(reactions, id: \.self) { reaction in
                                Text(":\(reaction.name):  \(reaction.count)")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.secondary.opacity(0.09), in: Capsule())
                                    .help(reaction.userIDs.isEmpty ? "Reaction from Slack export" : "Slack user IDs: \(reaction.userIDs.joined(separator: ", "))")
                            }
                        }
                    }
                    if model.threadMessages.count > 1 {
                        Divider()
                        Text("Thread context").font(.headline)
                        ForEach(model.threadMessages) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.senderName).fontWeight(.semibold)
                                    Text(item.postedAt.formatted(date: .omitted, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(item.text.isEmpty ? "(No message text)" : item.text)
                                    .textSelection(.enabled)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(item.id == message.id ? ThreadLightTheme.violet.opacity(0.10) : .secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    if !message.files.isEmpty {
                        Divider()
                        Text("Resources").font(.headline)
                        ForEach(message.files) { file in
                            HStack {
                                Image(systemName: file.hasOriginalBytes ? "doc.fill" : "link.badge.plus")
                                    .foregroundStyle(file.hasOriginalBytes ? ThreadLightTheme.successForeground : ThreadLightTheme.dangerForeground)
                                VStack(alignment: .leading) {
                                    Text(file.name)
                                    Text(file.hasOriginalBytes ? "Original bytes imported" : "Metadata and Slack link only")
                                        .font(.caption).foregroundStyle(file.hasOriginalBytes ? ThreadLightTheme.successForeground : ThreadLightTheme.dangerForeground)
                                }
                                Spacer()
                                Text(file.mimeType ?? "Unknown type").font(.caption).foregroundStyle(.secondary)
                                if file.hasOriginalBytes {
                                    Button("Quick Look") { model.previewAttachment(file) }
                                        .help("Preview the decrypted attachment temporarily with macOS Quick Look")
                                } else {
                                    Button("Import original…") { model.importAttachment(file, for: message) }
                                        .help("Encrypt, extract, and bind operator-supplied original bytes to this Slack file record")
                                }
                            }
                            .padding(12).threadLightCard()
                        }
                    }
                    Divider()
                    Label("Evidence identifiers", systemImage: "fingerprint")
                        .font(.headline)
                        .foregroundStyle(ThreadLightTheme.accentForeground)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow { Text("Message ID").foregroundStyle(.secondary); Text(message.id).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        GridRow { Text("Thread ID").foregroundStyle(.secondary); Text(message.threadID).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        GridRow { Text("Conversation ID").foregroundStyle(.secondary); Text(message.conversationID).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    }
                    .padding(14)
                    .threadLightCard()
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("Message")
        } else {
            ContentUnavailableView("Select a message", systemImage: "text.bubble", description: Text("Choose a search result to inspect the complete message and resource provenance."))
        }
    }
}
