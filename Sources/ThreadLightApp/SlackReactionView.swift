import AppKit
import SwiftUI
import ThreadLightCore

struct SlackReactionView: View {
    let reaction: EvidenceReaction
    let customEmojiURL: URL?
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 3 : 4) {
            SlackReactionGlyph(name: reaction.name, customEmojiURL: customEmojiURL, size: compact ? 14 : 17)
            Text(reaction.count.formatted())
                .font(compact ? .caption2.weight(.medium) : .caption.weight(.medium))
        }
        .padding(.horizontal, compact ? 7 : 8)
        .padding(.vertical, compact ? 3 : 4)
        .background(.secondary.opacity(0.09), in: Capsule())
        .help(reaction.userIDs.isEmpty ? "Reaction from Slack evidence" : "Slack user IDs: \(reaction.userIDs.joined(separator: ", "))")
        .accessibilityLabel("\(reaction.name), \(reaction.count) reactions")
    }
}

private struct SlackReactionGlyph: View {
    let name: String
    let customEmojiURL: URL?
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if let unicode = SlackEmoji.unicode(name) {
                Text(unicode)
                    .font(.system(size: size))
            } else {
                Text(":\(name):")
                    .font(.caption2)
            }
        }
        .frame(height: size)
        .task(id: customEmojiURL) {
            image = nil
            guard let customEmojiURL,
                  let data = await SlackImageCache.shared.data(for: customEmojiURL) else { return }
            image = NSImage(data: data)
        }
    }
}

private enum SlackEmoji {
    private static let values: [String: String] = [
        "+1": "👍", "thumbsup": "👍", "-1": "👎", "thumbsdown": "👎",
        "clap": "👏", "pray": "🙏", "muscle": "💪", "raised_hands": "🙌",
        "handshake": "🤝", "wave": "👋", "point_up": "☝️", "ok_hand": "👌",
        "heart": "❤️", "orange_heart": "🧡", "yellow_heart": "💛", "green_heart": "💚",
        "blue_heart": "💙", "purple_heart": "💜", "black_heart": "🖤", "broken_heart": "💔",
        "eyes": "👀", "eye": "👁️", "brain": "🧠", "thinking_face": "🤔",
        "smile": "😄", "grinning": "😀", "slightly_smiling_face": "🙂", "blush": "😊",
        "joy": "😂", "rofl": "🤣", "laughing": "😆", "sweat_smile": "😅",
        "wink": "😉", "heart_eyes": "😍", "star-struck": "🤩", "sunglasses": "😎",
        "neutral_face": "😐", "expressionless": "😑", "unamused": "😒", "grimacing": "😬",
        "disappointed": "😞", "cry": "😢", "sob": "😭", "angry": "😠",
        "rage": "😡", "scream": "😱", "flushed": "😳", "exploding_head": "🤯",
        "face_with_rolling_eyes": "🙄", "facepalm": "🤦", "shrug": "🤷",
        "white_check_mark": "✅", "heavy_check_mark": "✔️", "x": "❌",
        "warning": "⚠️", "question": "❓", "exclamation": "❗", "information_source": "ℹ️",
        "tada": "🎉", "confetti_ball": "🎊", "sparkles": "✨", "star": "⭐",
        "fire": "🔥", "boom": "💥", "100": "💯", "rocket": "🚀",
        "bulb": "💡", "bell": "🔔", "pushpin": "📌", "memo": "📝",
        "lock": "🔒", "unlock": "🔓", "key": "🔑", "mag": "🔍",
        "link": "🔗", "paperclip": "📎", "calendar": "📆", "hourglass": "⌛",
        "coffee": "☕", "beer": "🍺", "beers": "🍻", "cake": "🍰",
        "gift": "🎁", "medal": "🏅", "trophy": "🏆", "soccer": "⚽",
        "checkered_flag": "🏁", "construction": "🚧", "no_entry": "⛔", "red_circle": "🔴",
        "large_green_circle": "🟢", "large_blue_circle": "🔵"
    ]

    static func unicode(_ rawName: String) -> String? {
        let parts = rawName.components(separatedBy: "::skin-tone-")
        guard var value = values[parts[0]] else { return nil }
        if parts.count == 2, let tone = Int(parts[1]), let modifier = skinTone(tone) {
            value.append(modifier)
        }
        return value
    }

    private static func skinTone(_ value: Int) -> Character? {
        switch value {
        case 2: "🏻"
        case 3: "🏼"
        case 4: "🏽"
        case 5: "🏾"
        case 6: "🏿"
        default: nil
        }
    }
}
