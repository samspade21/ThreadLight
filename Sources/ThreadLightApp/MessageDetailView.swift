import AppKit
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
                        SlackAvatar(
                            name: message.senderName,
                            userID: message.senderID,
                            url: model.slackUserProfiles[message.senderID]?.avatarURL,
                            size: 42
                        )
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message.senderName).font(.headline)
                            Text(message.text.isEmpty ? "(No message text)" : message.text)
                                .textSelection(.enabled)
                        }
                    }
                    if !displayedReactions(for: message).isEmpty {
                        HStack(spacing: 7) {
                            ForEach(displayedReactions(for: message), id: \.self) { reaction in
                                SlackReactionView(
                                    reaction: reaction,
                                    customEmojiURL: model.slackEmojiURLs[reaction.name],
                                    compact: false
                                )
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
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(identifierText(for: message), forType: .string)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "fingerprint")
                            Text("Evidence identifiers")
                            Spacer()
                            Text("Click to copy")
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .help(identifierText(for: message))
                    .accessibilityLabel("Copy evidence identifiers")
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .task(id: message.id) {
                await model.refreshReactions(for: message)
            }
        } else {
            ContentUnavailableView("Select a message", systemImage: "text.bubble", description: Text("Choose a search result to inspect the complete message and resource provenance."))
        }
    }

    private func identifierText(for message: EvidenceMessage) -> String {
        var identifiers = [
            "Message ID: \(message.id)",
            "Thread ID: \(message.threadID)",
            "Conversation ID: \(message.conversationID)",
            "Sender ID: \(message.senderID)",
        ]
        if let holdID = model.selectedHold?.id {
            identifiers.insert("Legal hold ID: \(holdID)", at: 0)
        }
        return identifiers.joined(separator: "\n")
    }

    private func displayedReactions(for message: EvidenceMessage) -> [EvidenceReaction] {
        model.liveReactions[message.id] ?? message.reactions ?? []
    }
}
