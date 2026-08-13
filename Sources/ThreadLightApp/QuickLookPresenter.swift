import Foundation
import QuickLook
@preconcurrency import QuickLookUI
import ThreadLightCore

@MainActor
final class QuickLookPresenter: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var previewURL: URL?
    private let previewDirectory = FileManager.default.temporaryDirectory
        .appending(path: "ThreadLightQuickLook", directoryHint: .isDirectory)

    override init() {
        super.init()
        try? FileManager.default.removeItem(at: previewDirectory)
    }

    func present(data: Data, filename: String) throws {
        cleanup()
        try FileManager.default.createDirectory(
            at: previewDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let safeName = filename
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
            .prefix(120)
        let url = previewDirectory.appending(path: "\(UUID().uuidString)-\(safeName)")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        previewURL = url

        guard let panel = QLPreviewPanel.shared() else {
            cleanup()
            throw ThreadLightError.archive("Quick Look is unavailable on this Mac.")
        }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        previewURL! as NSURL
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? QLPreviewPanel != nil else { return }
        cleanup()
    }

    private func cleanup() {
        guard let previewURL else { return }
        try? FileManager.default.removeItem(at: previewURL)
        self.previewURL = nil
    }
}
