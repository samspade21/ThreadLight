import AppKit
import CoreText
import Foundation

public struct EvidenceManifest: Codable, Sendable {
    public struct HoldSummary: Codable, Sendable {
        public let id: String
        public let name: String
        public let status: HoldStatus
        public let startAt: Date?
        public let endAt: Date?
        public let restrictions: [HoldRestriction]
    }

    public struct Item: Codable, Sendable {
        public let messageID: String
        public let conversationID: String
        public let threadID: String
        public let postedAt: Date
        public let sha256: String
        public let sourceArchiveID: UUID
        public let custodianID: String
    }

    public struct FileRecord: Codable, Sendable {
        public let path: String
        public let sha256: String
        public let byteCount: Int
    }

    public let schemaVersion: Int
    public let exportID: UUID
    public let createdAt: Date
    public let application: String
    public let hold: HoldSummary
    public let items: [Item]
    public let sources: [SourceArchive]
    public let files: [FileRecord]
    public let warnings: [String]
}

public struct EvidenceExportResult: Sendable {
    public let packageURL: URL
    public let manifestURL: URL
    public let signatureURL: URL
    public let keyID: String
}

public struct EvidenceExporter: Sendable {
    private let store: EvidenceStore
    private let signer: any SignatureProvider
    private let resourceVault: ResourceVault?

    public init(
        store: EvidenceStore,
        signer: (any SignatureProvider)? = nil,
        resourceVault: ResourceVault? = nil
    ) {
        self.store = store
        #if THREADLIGHT_DEVELOPMENT
        self.signer = signer ?? EphemeralSignatureProvider()
        #else
        self.signer = signer ?? SecureEnclaveSignatureProvider()
        #endif
        self.resourceVault = resourceVault
    }

    public func export(
        messages: [EvidenceMessage],
        hold: LegalHold,
        custodians: [Custodian],
        destination: URL,
        formats: Set<EvidenceExportFormat> = [.json, .pdf]
    ) async throws -> EvidenceExportResult {
        guard hold.status == .active else { throw ThreadLightError.export("Only a hold confirmed ACTIVE by Slack can be exported.") }
        guard !messages.isEmpty else { throw ThreadLightError.export("Select at least one message to export.") }
        guard messages.count <= 50_000 else { throw ThreadLightError.export("Split this review into evidence packages of 50,000 messages or fewer.") }
        guard !formats.isEmpty else { throw ThreadLightError.export("Choose JSON, PDF, or both evidence formats.") }

        var items: [EvidenceManifest.Item] = []
        var sources: [UUID: SourceArchive] = [:]
        var warnings: [String] = []
        for message in messages {
            let memberships = try await store.memberships(messageID: message.id, holdID: hold.id)
            var accepted: [(HoldMembership, SourceArchive)] = []
            var lastBlocked: ScopeDecision?
            for membership in memberships {
                let archive = try await store.sourceArchive(id: membership.sourceArchiveID)
                let custodian = custodians.first { $0.id == membership.custodianID && $0.holdID == hold.id }
                let decision = ScopeEvaluator.evaluate(message: message, hold: hold, custodian: custodian, archive: archive, membership: membership)
                if decision.canExport, let archive { accepted.append((membership, archive)) }
                else { lastBlocked = decision }
            }
            guard !accepted.isEmpty else {
                if case let .blocked(_, detail) = lastBlocked { throw ThreadLightError.scope("Message \(message.id) is not exportable: \(detail)") }
                throw ThreadLightError.scope("Message \(message.id) has no unambiguous hold membership.")
            }
            guard items.count + accepted.count <= 100_000 else {
                throw ThreadLightError.export("The selected messages have more than 100,000 custodian/source relationships. Split the evidence export into smaller packages.")
            }
            let consistency = ScopeEvaluator.evaluateSourceConsistency(accepted.map(\.0))
            guard consistency.canExport else {
                if case let .blocked(_, detail) = consistency {
                    throw ThreadLightError.scope("Message \(message.id) is not exportable: \(detail)")
                }
                throw ThreadLightError.scope("Message \(message.id) has conflicting source records.")
            }
            let fallbackRaw = message.rawJSON.isEmpty ? try CanonicalJSON.encode(message) : message.rawJSON
            for relation in accepted {
                sources[relation.1.id] = relation.1
                items.append(.init(
                    messageID: message.id,
                    conversationID: message.conversationID,
                    threadID: message.threadID,
                    postedAt: message.postedAt,
                    sha256: relation.0.sourceMessageSHA256.isEmpty
                        ? SHA256Digest.data(fallbackRaw)
                        : relation.0.sourceMessageSHA256,
                    sourceArchiveID: relation.0.sourceArchiveID,
                    custodianID: relation.0.custodianID
                ))
            }
            for file in message.files where !file.hasOriginalBytes {
                warnings.append("Original bytes unavailable for \(file.name) (Slack file \(file.id)); exported metadata only.")
            }
        }

        for source in sources.values {
            if let holdStart = hold.startAt {
                if let coverageStart = source.coverageStart {
                    if coverageStart > holdStart {
                        warnings.append("Source \(source.originalFilename) begins after the hold start; earlier content may be missing.")
                    }
                } else {
                    warnings.append("Source \(source.originalFilename) has no provable start-date coverage.")
                }
            }
            if let holdEnd = hold.endAt {
                if let coverageEnd = source.coverageEnd {
                    if coverageEnd < holdEnd {
                        warnings.append("Source \(source.originalFilename) ends before the hold end; later content may be missing.")
                    }
                } else {
                    warnings.append("Source \(source.originalFilename) has no provable end-date coverage.")
                }
            }
        }

        let exportID = UUID()
        let packageURL = destination.appending(path: "ThreadLight-\(Self.safeFilename(hold.name))-\(exportID.uuidString.prefix(8)).threadlight-evidence", directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: packageURL.path) else { throw ThreadLightError.export("Export destination already exists.") }
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: false)
        do {
            let readmeURL = packageURL.appending(path: "README.txt")
            try Self.packageReadme.write(to: readmeURL, atomically: true, encoding: .utf8)

            var payloadURLs = [readmeURL]
            if formats.contains(.json) {
                let jsonURL = packageURL.appending(path: "evidence.json")
                let evidence = EvidenceDocument(schemaVersion: 1, hold: hold, messages: messages)
                try CanonicalJSON.encode(evidence).write(to: jsonURL, options: [.atomic, .completeFileProtection])
                payloadURLs.append(jsonURL)
            }
            if formats.contains(.pdf) {
                let pdfURL = packageURL.appending(path: "evidence.pdf")
                try PDFRenderer.render(messages: messages, hold: hold, to: pdfURL)
                payloadURLs.append(pdfURL)
            }
            let filesWithBytes = messages.flatMap(\.files).filter(\.hasOriginalBytes)
            if !filesWithBytes.isEmpty {
                guard let resourceVault else {
                    throw ThreadLightError.export("Imported attachment bytes could not be opened from the encrypted resource vault.")
                }
                let resourcesURL = packageURL.appending(path: "resources", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: false)
                var copied = Set<String>()
                for file in filesWithBytes where copied.insert(file.id).inserted {
                    let data = try await resourceVault.cleartext(for: file)
                    if let expected = file.sha256, SHA256Digest.data(data) != expected {
                        throw ThreadLightError.export("Attachment \(file.name) failed its stored integrity check.")
                    }
                    let name = "\(Self.safeFilename(file.id))-\(Self.safeFilename(file.name))"
                    let url = resourcesURL.appending(path: name)
                    try data.write(to: url, options: [.atomic, .completeFileProtection])
                    payloadURLs.append(url)
                }
            }

            let payloadFiles = try payloadURLs.map { url -> EvidenceManifest.FileRecord in
                let path = url.deletingLastPathComponent() == packageURL ? url.lastPathComponent : "resources/\(url.lastPathComponent)"
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, let byteCount = values.fileSize else {
                    throw ThreadLightError.export("Evidence payload is not a regular file: \(path)")
                }
                return .init(path: path, sha256: try SHA256Digest.file(url: url), byteCount: byteCount)
            }
            let manifest = EvidenceManifest(
                schemaVersion: 1,
                exportID: exportID,
                createdAt: Date(),
                application: ThreadLightBuild.applicationIdentity,
                hold: .init(
                    id: hold.id,
                    name: hold.name,
                    status: hold.status,
                    startAt: hold.startAt,
                    endAt: hold.endAt,
                    restrictions: hold.restrictions.sorted { $0.rawValue < $1.rawValue }
                ),
                items: items.sorted { $0.messageID < $1.messageID },
                sources: sources.values.sorted { $0.id.uuidString < $1.id.uuidString },
                files: payloadFiles.sorted { $0.path < $1.path },
                warnings: Array(Set(warnings)).sorted()
            )
            let manifestData = try CanonicalJSON.encode(manifest)
            let manifestURL = packageURL.appending(path: "manifest.json")
            try manifestData.write(to: manifestURL, options: [.atomic, .completeFileProtection])
            let envelope = try await signer.sign(manifest: manifestData)
            guard try SecureEnclaveSignatureProvider.verify(manifest: manifestData, envelope: envelope) else {
                throw ThreadLightError.export("The new evidence signature did not verify.")
            }
            let signatureURL = packageURL.appending(path: "manifest.threadlight-signature.json")
            try CanonicalJSON.encode(envelope).write(to: signatureURL, options: [.atomic, .completeFileProtection])
            guard try Self.verify(packageURL: packageURL) else {
                throw ThreadLightError.export("The new evidence package failed its complete post-write verification.")
            }
            return .init(packageURL: packageURL, manifestURL: manifestURL, signatureURL: signatureURL, keyID: envelope.keyID)
        } catch {
            try? FileManager.default.removeItem(at: packageURL)
            throw error
        }
    }

    public static func verify(packageURL: URL) throws -> Bool {
        let packageValues = try packageURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard packageValues.isDirectory == true, packageValues.isSymbolicLink != true else { return false }
        let manifestURL = packageURL.appending(path: "manifest.json")
        let signatureURL = packageURL.appending(path: "manifest.threadlight-signature.json")
        let root = packageURL.standardizedFileURL
        guard try isRegularNonSymlink(manifestURL), try isRegularNonSymlink(signatureURL) else { return false }
        let manifestData = try readBoundedFile(manifestURL, maximumBytes: 32 * 1_024 * 1_024)
        let envelopeData = try readBoundedFile(signatureURL, maximumBytes: 1 * 1_024 * 1_024)
        let envelope = try CanonicalJSON.decoder.decode(SignatureEnvelope.self, from: envelopeData)
        guard envelopeData == (try CanonicalJSON.encode(envelope)) else { return false }
        guard try SecureEnclaveSignatureProvider.verify(manifest: manifestData, envelope: envelope) else { return false }
        let manifest = try CanonicalJSON.decoder.decode(EvidenceManifest.self, from: manifestData)
        guard manifestData == (try CanonicalJSON.encode(manifest)),
              validManifest(manifest) else { return false }
        let declaredPaths = manifest.files.map(\.path)
        guard Set(declaredPaths).count == declaredPaths.count else { return false }
        for file in manifest.files {
            guard safeRelativePath(file.path) else { return false }
            let url = packageURL.appending(path: file.path).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/"), try isRegularNonSymlink(url) else { return false }
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard values.fileSize == file.byteCount, try SHA256Digest.file(url: url) == file.sha256 else { return false }
        }
        var expected = Set(declaredPaths).union(["manifest.json", "manifest.threadlight-signature.json"])
        if declaredPaths.contains(where: { $0.hasPrefix("resources/") }) { expected.insert("resources/") }
        return try packageFilePaths(root: root) == expected
    }

    private static func validManifest(_ manifest: EvidenceManifest) -> Bool {
        guard manifest.schemaVersion == 1,
              !manifest.application.isEmpty,
              manifest.hold.status == .active,
              !manifest.items.isEmpty,
              manifest.items.count <= 100_000,
              manifest.sources.count <= 1_000,
              manifest.files.count <= 100_000,
              manifest.hold.startAt.map({ start in manifest.hold.endAt.map { start <= $0 } ?? true }) ?? true else {
            return false
        }

        let sourceIDs = manifest.sources.map(\.id)
        guard Set(sourceIDs).count == sourceIDs.count else { return false }
        let sources = Dictionary(uniqueKeysWithValues: manifest.sources.map { ($0.id, $0) })
        for source in manifest.sources {
            guard source.holdID == manifest.hold.id,
                  source.isPerCustodian,
                  !source.custodianID.isEmpty,
                  !source.operatorBinding.isEmpty,
                  validSHA256(source.sha256),
                  source.coverageStart.map({ start in source.coverageEnd.map { start <= $0 } ?? true }) ?? true else {
                return false
            }
        }

        var relationships = Set<String>()
        var referencedSources = Set<UUID>()
        for item in manifest.items {
            guard !item.messageID.isEmpty,
                  !item.conversationID.isEmpty,
                  !item.threadID.isEmpty,
                  !item.custodianID.isEmpty,
                  validSHA256(item.sha256),
                  let source = sources[item.sourceArchiveID],
                  source.custodianID == item.custodianID,
                  manifest.hold.startAt.map({ item.postedAt >= $0 }) ?? true,
                  manifest.hold.endAt.map({ item.postedAt <= $0 }) ?? true else {
                return false
            }
            let relationship = "\(item.messageID)\u{1F}\(item.sourceArchiveID.uuidString)\u{1F}\(item.custodianID)"
            guard relationships.insert(relationship).inserted else { return false }
            referencedSources.insert(item.sourceArchiveID)
        }
        guard referencedSources == Set(sourceIDs) else { return false }

        let paths = manifest.files.map(\.path)
        guard Set(paths).count == paths.count,
              paths.contains("README.txt"),
              paths.contains("evidence.json") || paths.contains("evidence.pdf") else { return false }
        return manifest.files.allSatisfy {
            $0.byteCount >= 0 && validSHA256($0.sha256) && validPayloadPath($0.path)
        }
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func validPayloadPath(_ path: String) -> Bool {
        if path == "README.txt" || path == "evidence.json" || path == "evidence.pdf" { return true }
        guard path.hasPrefix("resources/") else { return false }
        let name = String(path.dropFirst("resources/".count))
        guard !name.isEmpty, !name.contains("/") else { return false }
        return name.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func safeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\") else { return false }
        let components = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private static func isRegularNonSymlink(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func readBoundedFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size <= maximumBytes else {
            throw ThreadLightError.export("Evidence package metadata is unsafe or exceeds its size limit: \(url.lastPathComponent)")
        }
        return try Data(contentsOf: url)
    }

    private static func packageFilePaths(root: URL) throws -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return [] }
        var result = Set<String>()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw ThreadLightError.export("Evidence package contains a symbolic link.") }
            if values.isDirectory == true {
                let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
                guard relative == "resources" else {
                    throw ThreadLightError.export("Evidence package contains an unexpected directory: \(relative)")
                }
                result.insert("resources/")
                continue
            }
            guard values.isRegularFile == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            guard safeRelativePath(relative) else { throw ThreadLightError.export("Evidence package contains an unsafe path.") }
            result.insert(relative)
            guard result.count <= 100_003 else { throw ThreadLightError.export("Evidence package contains too many files.") }
        }
        return result
    }

    private static func safeFilename(_ value: String) -> String {
        let clean = value.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
        return String(clean.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static let packageReadme = """
    ThreadLight evidence package

    Verify this package in ThreadLight before relying on it. The ES256 signature proves that the manifest has not changed under the signing key identified in the signature envelope. Record and compare that key ID through a separate trusted process; a self-contained package cannot establish who controls a newly substituted key. It is not an independent timestamp, proof of operator identity, or Slack attestation. Operator-to-custodian archive binding is recorded provenance supplied during import.
    """
}

private struct EvidenceDocument: Codable {
    let schemaVersion: Int
    let hold: LegalHold
    let messages: [EvidenceMessage]
}

public enum CanonicalJSON {
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

enum PDFRenderer {
    private struct Page {
        let content: NSAttributedString
        let range: CFRange
    }

    static func render(messages: [EvidenceMessage], hold: LegalHold, to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ThreadLightError.export("Could not create the PDF evidence document.")
        }
        let contentRect = CGRect(x: 54, y: 58, width: 504, height: 680)
        var pages: [Page] = []
        for message in messages {
            let content = content(for: message, hold: hold)
            let framesetter = CTFramesetterCreateWithAttributedString(content)
            var location = 0
            while location < content.length {
                let requested = CFRange(location: location, length: content.length - location)
                let frame = CTFramesetterCreateFrame(framesetter, requested, CGPath(rect: contentRect, transform: nil), nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else {
                    context.closePDF()
                    throw ThreadLightError.export("A PDF page could not fit the selected evidence text.")
                }
                pages.append(.init(content: content, range: visible))
                location += visible.length
            }
        }

        for (index, page) in pages.enumerated() {
            context.beginPDFPage(nil)
            let framesetter = CTFramesetterCreateWithAttributedString(page.content)
            let frame = CTFramesetterCreateFrame(framesetter, page.range, CGPath(rect: contentRect, transform: nil), nil)
            CTFrameDraw(frame, context)
            let footer = NSAttributedString(string: "ThreadLight • Page \(index + 1) of \(pages.count)", attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.secondaryLabelColor])
            let footerSetter = CTFramesetterCreateWithAttributedString(footer)
            CTFrameDraw(CTFramesetterCreateFrame(footerSetter, CFRange(), CGPath(rect: CGRect(x: 54, y: 30, width: 504, height: 16), transform: nil), nil), context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func content(for message: EvidenceMessage, hold: LegalHold) -> NSAttributedString {
        let content = NSMutableAttributedString()
        content.append(.init(string: hold.name + "\n", attributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        content.append(.init(string: "#\(message.conversationName)  •  \(message.postedAt.formatted(date: .abbreviated, time: .standard))\n\n", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]))
        content.append(.init(string: message.senderName + "\n", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        content.append(.init(string: message.text + "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]))
        if let reactions = message.reactions, !reactions.isEmpty {
            content.append(.init(string: "Reactions: " + reactions.map { ":\($0.name): \($0.count)" }.joined(separator: "  ") + "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 9)]))
        }
        if !message.files.isEmpty {
            content.append(.init(string: "Attachments\n", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]))
            for file in message.files {
                content.append(.init(string: "• \(file.name) — \(file.mimeType ?? "unknown type") — \(file.hasOriginalBytes ? "included" : "metadata only")\n", attributes: [.font: NSFont.systemFont(ofSize: 9)]))
            }
        }
        content.append(.init(string: "\nMessage ID: \(message.id)\nThread ID: \(message.threadID)\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
        return content
    }
}
