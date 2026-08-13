import AppKit
import CryptoKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import ZIPFoundation

public actor ResourceVault {
    private let root: URL
    private let key: SymmetricKey

    public init(root: URL, keyData: Data) throws {
        self.root = root
        self.key = SymmetricKey(data: keyData)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public static func openDefault(organizationID: String, keychain: KeychainStore = .shared) async throws -> ResourceVault {
        guard ThreadLightBuild.isValidStorageNamespace(organizationID) else {
            throw ThreadLightError.archive("The local resource storage namespace is invalid.")
        }
        let key = try await keychain.loadOrCreateRandomKey(account: "evidence.resources.\(organizationID)")
        return try ResourceVault(root: defaultURL(organizationID: organizationID), keyData: key)
    }

    public static func removeDefault(organizationID: String, keychain: KeychainStore = .shared) async throws {
        guard ThreadLightBuild.isValidStorageNamespace(organizationID) else {
            throw ThreadLightError.archive("The local resource storage namespace is invalid.")
        }
        let url = try defaultURL(organizationID: organizationID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try await keychain.delete(account: "evidence.resources.\(organizationID)")
    }

    private static func defaultURL(organizationID: String) throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "ThreadLight/Resources/\(organizationID)", directoryHint: .isDirectory)
    }

    public func importResource(url: URL, fileID: String) throws -> EvidenceFile {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw ThreadLightError.archive("Choose a regular attachment file.") }
        guard let size = values.fileSize, size <= 500 * 1_024 * 1_024 else {
            throw ThreadLightError.archive("Attachment exceeds the 500 MB local import limit.")
        }
        let cleartext = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let sealed = try AES.GCM.seal(cleartext, using: key).combined else {
            throw ThreadLightError.archive("Could not encrypt the attachment.")
        }
        let storageID = SHA256Digest.data(Data(fileID.utf8))
        let relativePath = "\(storageID).resource.aesgcm"
        try sealed.write(to: root.appending(path: relativePath), options: [.atomic, .completeFileProtection])
        return .init(
            id: fileID,
            name: url.lastPathComponent,
            mimeType: values.contentType?.preferredMIMEType,
            size: Int64(size),
            localRelativePath: relativePath,
            sha256: SHA256Digest.data(cleartext),
            extractedText: try TextExtractor.extract(url: url, type: values.contentType)
        )
    }

    public func importResource(url: URL, replacing file: EvidenceFile) throws -> EvidenceFile {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let actualSize = values.fileSize else {
            throw ThreadLightError.archive("Choose a regular attachment file.")
        }
        if let expectedSize = file.size, expectedSize != Int64(actualSize) {
            throw ThreadLightError.archive(
                "The selected file is \(actualSize.formatted()) bytes, but Slack recorded \(expectedSize.formatted()) bytes. Choose the original file that matches Slack's metadata."
            )
        }
        var imported = try importResource(url: url, fileID: file.id)
        imported.name = file.name
        imported.mimeType = file.mimeType ?? imported.mimeType
        imported.size = file.size ?? imported.size
        imported.remoteURL = file.remoteURL
        return imported
    }

    public func cleartext(for file: EvidenceFile) throws -> Data {
        guard let path = file.localRelativePath else { throw ThreadLightError.archive("Original attachment bytes were not imported.") }
        guard path.utf8.count == 80,
              path.hasSuffix(".resource.aesgcm"),
              path.prefix(64).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ThreadLightError.archive("The stored attachment path is invalid.")
        }
        let url = root.appending(path: path)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let sealedSize = values.fileSize,
              sealedSize <= 500 * 1_024 * 1_024 + 64 else {
            throw ThreadLightError.archive("The encrypted attachment is unsafe or exceeds its size limit.")
        }
        let sealed = try Data(contentsOf: url)
        let cleartext = try AES.GCM.open(.init(combined: sealed), using: key)
        if let expectedSize = file.size, expectedSize != Int64(cleartext.count) {
            throw ThreadLightError.archive("The decrypted attachment size no longer matches Slack metadata.")
        }
        if let expectedHash = file.sha256, expectedHash != SHA256Digest.data(cleartext) {
            throw ThreadLightError.archive("The decrypted attachment no longer matches its stored SHA-256 hash.")
        }
        return cleartext
    }

    public func purge() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        for item in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: item)
        }
    }
}

public enum TextExtractor {
    public static func extract(url: URL, type: UTType? = nil) throws -> String? {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw ThreadLightError.archive("Choose a regular attachment file.") }
        guard (values.fileSize ?? 0) <= 64 * 1_024 * 1_024 else { return nil }
        let type = type ?? UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .pdf) == true { return PDFDocument(url: url)?.string }
        if type?.conforms(to: .plainText) == true || ["csv", "json"].contains(url.pathExtension.lowercased()) {
            return try String(contentsOf: url, encoding: .utf8)
        }
        if type?.conforms(to: .rtf) == true {
            let data = try Data(contentsOf: url)
            return try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
        }
        if ["docx", "xlsx", "pptx"].contains(url.pathExtension.lowercased()) {
            return try officeText(url: url)
        }
        return nil
    }

    private static func officeText(url: URL) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        let ext = url.pathExtension.lowercased()
        let relevant = archive.filter { entry in
            let path = entry.path.lowercased()
            guard entry.type == .file, path.hasSuffix(".xml"), entry.uncompressedSize <= 64 * 1_024 * 1_024 else { return false }
            switch ext {
            case "docx": return path == "word/document.xml" || path.hasPrefix("word/header") || path.hasPrefix("word/footer")
            case "pptx": return path.hasPrefix("ppt/slides/slide") || path.hasPrefix("ppt/notesSlides/notesSlide".lowercased())
            case "xlsx": return path == "xl/sharedstrings.xml" || path.hasPrefix("xl/worksheets/sheet")
            default: return false
            }
        }
        var result: [String] = []
        var expandedBytes: UInt64 = 0
        for entry in relevant.prefix(10_000) {
            let sum = expandedBytes.addingReportingOverflow(entry.uncompressedSize)
            guard !sum.overflow, sum.partialValue <= 64 * 1_024 * 1_024 else {
                throw ThreadLightError.archive("Office attachment text expands beyond the 64 MB extraction limit.")
            }
            expandedBytes = sum.partialValue
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            guard let xml = String(data: data, encoding: .utf8) else { continue }
            let withoutTags = xml.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            result.append(withoutTags.xmlEntityDecoded)
        }
        return result.joined(separator: "\n").replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
    }
}

private extension String {
    var xmlEntityDecoded: String {
        replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}
