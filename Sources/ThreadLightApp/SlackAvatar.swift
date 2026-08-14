import AppKit
import SwiftUI

struct SlackAvatar: View {
    let name: String
    let userID: String
    let url: URL?
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let url, let data = await SlackImageCache.shared.data(for: url) else { return }
            image = NSImage(data: data)
        }
    }

    private var fallback: some View {
        Circle()
            .fill(ThreadLightTheme.avatarColor(for: userID).opacity(0.16))
            .overlay(
                Text(initials)
                    .font(.system(size: max(9, size * 0.36), weight: .semibold))
                    .foregroundStyle(.primary)
            )
    }

    private var initials: String {
        let parts = name.split(whereSeparator: { $0.isWhitespace })
        let letters = parts.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

actor SlackImageCache {
    static let shared = SlackImageCache()

    private let memory = NSCache<NSURL, NSData>()
    private let session: URLSession
    private var inFlight: [URL: Task<Data?, Never>] = [:]

    private init() {
        memory.countLimit = 500
        memory.totalCostLimit = 32 * 1_024 * 1_024
        let configuration = URLSessionConfiguration.default
        // Memory only. Custodian avatars identify the people on a legal hold, so they
        // must not land in a plaintext on-disk URLCache beside the encrypted store.
        configuration.urlCache = URLCache(memoryCapacity: 16 * 1_024 * 1_024, diskCapacity: 0)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)
    }

    func data(for url: URL) async -> Data? {
        if let cached = memory.object(forKey: url as NSURL) { return cached as Data }
        if let task = inFlight[url] { return await task.value }

        let session = session
        let task = Task<Data?, Never> {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            request.timeoutInterval = 20
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  data.count <= 10 * 1_024 * 1_024,
                  NSImage(data: data) != nil else { return nil }
            return data
        }
        inFlight[url] = task
        let data = await task.value
        inFlight[url] = nil
        guard let data else { return nil }
        memory.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        return data
    }
}
