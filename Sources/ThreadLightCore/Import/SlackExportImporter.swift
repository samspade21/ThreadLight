import CryptoKit
import Foundation
import ZIPFoundation

public struct SlackExportImporter: Sendable {
    public struct Limits: Sendable {
        public var maximumEntries = 100_000
        public var maximumExpandedBytes: UInt64 = 50 * 1_024 * 1_024 * 1_024
        public var maximumJSONBytes: UInt64 = 512 * 1_024 * 1_024
        public init() {}
    }

    private let store: EvidenceStore
    private let limits: Limits
    private let progressHandler: (@Sendable (ImportProgress) async -> Void)?

    public init(
        store: EvidenceStore,
        limits: Limits = .init(),
        progressHandler: (@Sendable (ImportProgress) async -> Void)? = nil
    ) {
        self.store = store
        self.limits = limits
        self.progressHandler = progressHandler
    }

    // Kept internal only to read pre-v1 test fixtures and validate migration behavior.
    func importArchive(
        url: URL,
        hold: LegalHold,
        custodian: Custodian,
        operatorBinding: String,
        confirmedPerCustodian: Bool
    ) async throws -> ImportReport {
        guard confirmedPerCustodian else {
            throw ThreadLightError.archive("Legacy per-member intake is no longer supported by the app.")
        }
        return try await importArchiveInternal(
            url: url,
            hold: hold,
            custodian: custodian,
            operatorBinding: operatorBinding,
            confirmedPerCustodian: confirmedPerCustodian
        )
    }

    public func importHoldArchive(
        url: URL,
        hold: LegalHold,
        operatorBinding: String
    ) async throws -> ImportReport {
        try await importArchiveInternal(
            url: url,
            hold: hold,
            custodian: Custodian(
                id: "threadlight:hold-wide",
                holdID: hold.id,
                displayName: "Hold-wide Slack compliance export"
            ),
            operatorBinding: operatorBinding,
            confirmedPerCustodian: false
        )
    }

    private func importArchiveInternal(
        url: URL,
        hold: LegalHold,
        custodian: Custodian,
        operatorBinding: String,
        confirmedPerCustodian: Bool
    ) async throws -> ImportReport {
        guard hold.status == .active else { throw ThreadLightError.archive("Only a hold confirmed ACTIVE by Slack can accept new evidence.") }
        guard custodian.holdID == hold.id, custodian.isCurrent else {
            throw ThreadLightError.archive("Choose a current custodian from the selected hold.")
        }
        guard !operatorBinding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ThreadLightError.archive("Record who bound this Slack export to the custodian.")
        }
        guard url.pathExtension.lowercased() == "zip" else { throw ThreadLightError.archive("Choose an untouched Slack export ZIP.") }
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) }
        catch { throw ThreadLightError.archive("The selected file is not a readable ZIP archive.") }

        var entries: [Entry] = []
        entries.reserveCapacity(min(limits.maximumEntries, 4_096))
        for entry in archive {
            guard entries.count < limits.maximumEntries else {
                throw ThreadLightError.archive("Archive contains too many files.")
            }
            entries.append(entry)
        }
        try validate(entries: entries)
        let sha256 = try SHA256Digest.file(url: url)
        if let existing = try await store.sourceArchive(sha256: sha256, holdID: hold.id) {
            if existing.custodianID == custodian.id {
                throw ThreadLightError.archive("This exact ZIP is already bound to this custodian and hold.")
            }
            throw ThreadLightError.archive("This exact ZIP is already bound to another custodian on this hold. Choose that custodian's own untouched export.")
        }
        let users = try parseUsers(archive: archive, entries: entries)
        let conversations = try parseConversations(archive: archive, entries: entries, users: users)
        var source: SourceArchive
        var checkpoint: StoredImportCheckpoint
        if let resumed = try await store.resumableImport(sha256: sha256, holdID: hold.id) {
            guard resumed.0.custodianID == custodian.id else {
                throw ThreadLightError.archive("This ZIP has a paused import bound to another custodian on this hold.")
            }
            guard resumed.0.operatorBinding == operatorBinding else {
                throw ThreadLightError.archive("Resume this ZIP using the original operator binding: \(resumed.0.operatorBinding).")
            }
            source = resumed.0
            checkpoint = resumed.1
        } else {
            source = SourceArchive(
                holdID: hold.id,
                custodianID: custodian.id,
                originalFilename: url.lastPathComponent,
                sha256: sha256,
                coverageStart: nil,
                coverageEnd: nil,
                operatorBinding: operatorBinding,
                isPerCustodian: confirmedPerCustodian
            )
            checkpoint = StoredImportCheckpoint(sourceArchiveID: source.id)
            try await store.beginImport(source)
            try await store.saveImportCheckpoint(checkpoint)
        }

        var warnings: [String] = []
        do {
            let datedEntries = entries
                .filter {
                    $0.type == .file
                        && $0.path.contains("/")
                        && ($0.path as NSString).lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}\.json$"#, options: .regularExpression) != nil
                }
                .sorted { $0.path < $1.path }
            var messageEntries: [(entry: Entry, conversation: ConversationDescriptor)] = []
            for entry in datedEntries {
                let folder = entry.path.split(separator: "/").dropLast().joined(separator: "/")
                let leaf = folder.split(separator: "/").last.map(String.init) ?? ""
                if let conversation = conversations[folder] ?? conversations[leaf] {
                    messageEntries.append((entry, conversation))
                }
            }
            let ignoredDatedJSON = datedEntries.count - messageEntries.count
            if ignoredDatedJSON > 0 {
                warnings.append("Ignored \(ignoredDatedJSON) dated JSON file(s) outside conversations proven by Slack metadata.")
            }
            if messageEntries.isEmpty {
                warnings.append("The Slack export contains metadata but no conversation messages.")
            }
            if let checkpointPath = checkpoint.entryPath,
               !messageEntries.contains(where: { $0.entry.path == checkpointPath }) {
                throw ThreadLightError.archive("The saved import checkpoint no longer matches a proven Slack conversation in this ZIP.")
            }

            for item in messageEntries {
                let entry = item.entry
                if let checkpointPath = checkpoint.entryPath, entry.path < checkpointPath { continue }
                try Task.checkCancellation()
                let conversation = item.conversation
                let startIndex = entry.path == checkpoint.entryPath ? checkpoint.nextMessageIndex : 0
                var batch: [EvidenceImportRecord] = []
                var batchBytes = 0
                var parsedMessageIndex = 0
                let temporaryURL = try extractForStreaming(entry: entry, from: archive)
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                let handle = try FileHandle(forReadingFrom: temporaryURL)
                defer { try? handle.close() }
                var parser = JSONArrayObjectParser(maximumObjectBytes: min(limits.maximumJSONBytes, 32 * 1_024 * 1_024))
                while let chunk = try handle.read(upToCount: 256 * 1_024), !chunk.isEmpty {
                    try Task.checkCancellation()
                    let rows = try parser.consume(chunk, path: entry.path)
                    let parsed = try autoreleasepool {
                        try rows.compactMap { row in
                            try Self.parseMessage(
                                row,
                                organizationID: hold.organizationID,
                                conversation: conversation,
                                users: users
                            )
                        }
                    }
                    for message in parsed {
                        let index = parsedMessageIndex
                        parsedMessageIndex += 1
                        guard index >= startIndex else { continue }
                        checkpoint.coverageStart = min(checkpoint.coverageStart ?? message.postedAt, message.postedAt)
                        checkpoint.coverageEnd = max(checkpoint.coverageEnd ?? message.postedAt, message.postedAt)
                        let membership = HoldMembership(
                            holdID: hold.id,
                            custodianID: custodian.id,
                            messageID: message.id,
                            sourceArchiveID: source.id
                        )
                        batch.append(.init(message: message, membership: membership))
                        batchBytes += message.rawJSON.count
                        if batch.count == 500 || batchBytes >= 8 * 1_024 * 1_024 {
                            let counts = try await store.insert(records: batch)
                            checkpoint.messagesProcessed += batch.count
                            checkpoint.messagesImported += counts.inserted
                            checkpoint.messagesDeduplicated += counts.deduplicated
                            checkpoint.filesReferenced += batch.reduce(0) { $0 + $1.message.files.count }
                            checkpoint.entryPath = entry.path
                            checkpoint.nextMessageIndex = parsedMessageIndex
                            try await store.saveImportCheckpoint(checkpoint)
                            await reportProgress(checkpoint)
                            batch.removeAll(keepingCapacity: true)
                            batchBytes = 0
                            try Task.checkCancellation()
                        }
                    }
                }
                try parser.finish(path: entry.path)
                guard startIndex <= parsedMessageIndex else {
                    throw ThreadLightError.archive("The saved import checkpoint does not match this ZIP.")
                }
                if !batch.isEmpty {
                    let counts = try await store.insert(records: batch)
                    checkpoint.messagesProcessed += batch.count
                    checkpoint.messagesImported += counts.inserted
                    checkpoint.messagesDeduplicated += counts.deduplicated
                    checkpoint.filesReferenced += batch.reduce(0) { $0 + $1.message.files.count }
                }
                checkpoint.entryPath = entry.path
                checkpoint.nextMessageIndex = parsedMessageIndex
                try await store.saveImportCheckpoint(checkpoint)
                await reportProgress(checkpoint)
                try Task.checkCancellation()
            }
            source = SourceArchive(
                id: source.id,
                holdID: source.holdID,
                custodianID: source.custodianID,
                originalFilename: source.originalFilename,
                sha256: source.sha256,
                importedAt: source.importedAt,
                coverageStart: checkpoint.coverageStart,
                coverageEnd: checkpoint.coverageEnd,
                operatorBinding: source.operatorBinding,
                isPerCustodian: source.isPerCustodian
            )
            if let start = hold.startAt, let minimumDate = checkpoint.coverageStart, minimumDate > start {
                warnings.append("Archive begins after the hold start date; earlier content may be missing.")
            }
            if let end = hold.endAt, let maximumDate = checkpoint.coverageEnd, maximumDate < end {
                warnings.append("Archive ends before the hold end date; later content may be missing.")
            }
            try await store.completeImport(source)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? await store.abandonImport(sourceID: source.id)
            throw error
        }
        return .init(
            source: source,
            messagesImported: checkpoint.messagesImported,
            messagesDeduplicated: checkpoint.messagesDeduplicated,
            filesReferenced: checkpoint.filesReferenced,
            warnings: warnings
        )
    }

    private func reportProgress(_ checkpoint: StoredImportCheckpoint) async {
        await progressHandler?(.init(
            sourceArchiveID: checkpoint.sourceArchiveID,
            messagesProcessed: checkpoint.messagesProcessed,
            filesReferenced: checkpoint.filesReferenced
        ))
    }

    private func validate(entries: [Entry]) throws {
        guard entries.count <= limits.maximumEntries else { throw ThreadLightError.archive("Archive contains too many files.") }
        let lowercaseNames = Set(entries.map { ($0.path as NSString).lastPathComponent.lowercased() })
        guard !lowercaseNames.isDisjoint(with: ["users.json", "org_users.json"]),
              !lowercaseNames.isDisjoint(with: ["channels.json", "groups.json", "dms.json", "mpims.json"]) else {
            throw ThreadLightError.archive("The ZIP does not have the required Slack users (users.json or org_users.json) and conversation metadata files.")
        }
        var expanded: UInt64 = 0
        var uniquePaths = Set<String>()
        for entry in entries {
            var normalized = entry.path.replacingOccurrences(of: "\\", with: "/")
            if entry.type == .directory, normalized.hasSuffix("/") { normalized.removeLast() }
            let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
            guard !normalized.hasPrefix("/"),
                  !components.isEmpty,
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  entry.path.utf8.count <= 1_024 else {
                throw ThreadLightError.archive("Archive contains an unsafe path: \(entry.path.prefix(120))")
            }
            guard uniquePaths.insert(normalized.lowercased()).inserted else {
                throw ThreadLightError.archive("Archive contains a duplicate or case-colliding path: \(entry.path.prefix(120))")
            }
            guard entry.type != .symlink else { throw ThreadLightError.archive("Archive contains a symbolic link, which is not allowed.") }
            let sum = expanded.addingReportingOverflow(entry.uncompressedSize)
            guard !sum.overflow else { throw ThreadLightError.archive("Archive expanded size overflowed its safety limit.") }
            expanded = sum.partialValue
            guard expanded <= limits.maximumExpandedBytes else { throw ThreadLightError.archive("Archive expands beyond the 50 GB safety limit.") }
            if entry.path.lowercased().hasSuffix(".json"), entry.uncompressedSize > limits.maximumJSONBytes {
                throw ThreadLightError.archive("A JSON file exceeds the 512 MB safety limit: \(entry.path)")
            }
        }
    }

    private func parseUsers(archive: Archive, entries: [Entry]) throws -> [String: String] {
        let userEntries = entries.filter {
            let name = ($0.path as NSString).lastPathComponent.lowercased()
            return name == "users.json" || name == "org_users.json"
        }.sorted { $0.path < $1.path }
        var result: [String: String] = [:]
        for entry in userEntries {
            let data = try read(entry: entry, from: archive)
            let rows = try decodeRows(data, path: entry.path)
            for row in rows {
                guard let id = row["id"] as? String, !id.isEmpty else { continue }
                let profile = row["profile"] as? [String: Any]
                let name = (profile?["real_name"] as? String) ?? (profile?["display_name"] as? String) ?? (row["name"] as? String) ?? id
                if let existing = result[id], existing != name {
                    throw ThreadLightError.archive("Slack user metadata contains conflicting records for \(id).")
                }
                result[id] = name
            }
        }
        return result
    }

    private func parseConversations(archive: Archive, entries: [Entry], users: [String: String]) throws -> [String: ConversationDescriptor] {
        var result: [String: ConversationDescriptor] = [:]
        let files: [(String, ConversationKind)] = [
            ("channels.json", .publicChannel), ("groups.json", .privateChannel),
            ("dms.json", .directMessage), ("mpims.json", .groupDirectMessage),
        ]
        for (filename, kind) in files {
            let matches = entries.filter {
                ($0.path as NSString).lastPathComponent.lowercased() == filename
            }
            for entry in matches {
                let data = try read(entry: entry, from: archive)
                let rows = try decodeRows(data, path: entry.path)
                let base = entry.path.split(separator: "/").dropLast().joined(separator: "/")
                for row in rows {
                    guard let id = row["id"] as? String else { continue }
                    var name = (row["name"] as? String) ?? id
                    if kind.isDirect, let members = row["members"] as? [String] {
                        name = members.compactMap { users[$0] }.joined(separator: ", ")
                        if name.isEmpty { name = id }
                    }
                    let descriptor = ConversationDescriptor(id: id, name: name, kind: kind)
                    let localKeys = [name, id, row["name"] as? String].compactMap { $0 }
                    let keys = base.isEmpty ? localKeys : localKeys.map { base + "/" + $0 }
                    for key in keys {
                        if let existing = result[key],
                           (existing.id != descriptor.id || existing.kind != descriptor.kind) {
                            throw ThreadLightError.archive("Slack conversation metadata is ambiguous for \(key).")
                        }
                        result[key] = descriptor
                    }
                }
            }
        }
        return result
    }

    private func extractForStreaming(entry: Entry, from archive: Archive) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "ThreadLightImport", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = root.appending(path: UUID().uuidString + ".json")
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600, .protectionKey: FileProtectionType.complete]
        ) else {
            throw ThreadLightError.archive("Could not create protected temporary storage for streamed JSON.")
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            var extractedBytes: UInt64 = 0
            _ = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                let next = extractedBytes.addingReportingOverflow(UInt64(chunk.count))
                guard !next.overflow,
                      next.partialValue <= limits.maximumJSONBytes,
                      next.partialValue <= entry.uncompressedSize else {
                    throw ThreadLightError.archive("Archive entry expanded beyond its declared or safe size: \(entry.path)")
                }
                extractedBytes = next.partialValue
                try handle.write(contentsOf: chunk)
            }
            guard extractedBytes == entry.uncompressedSize else {
                throw ThreadLightError.archive("Archive entry size does not match its ZIP metadata: \(entry.path)")
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func read(entry: Entry, from archive: Archive) throws -> Data {
        var data = Data()
        data.reserveCapacity(Int(min(entry.uncompressedSize, 8 * 1_024 * 1_024)))
        _ = try archive.extract(entry) { chunk in
            try Task.checkCancellation()
            guard UInt64(data.count + chunk.count) <= limits.maximumJSONBytes else {
                throw ThreadLightError.archive("Archive entry exceeds its safe expanded size.")
            }
            data.append(chunk)
        }
        return data
    }

    private func decodeRows(_ data: Data, path: String) throws -> [[String: Any]] {
        do {
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ThreadLightError.archive("Slack JSON must contain a list of records: \(path)")
            }
            return rows
        } catch let error as ThreadLightError {
            throw error
        } catch {
            throw ThreadLightError.archive("Slack JSON is malformed: \(path)")
        }
    }

    private static func parseMessage(
        _ original: [String: Any],
        organizationID: String,
        conversation: ConversationDescriptor,
        users: [String: String]
    ) throws -> EvidenceMessage? {
        let row: [String: Any]
        let deleted: Bool
        if original["subtype"] as? String == "message_deleted", let previous = original["previous_message"] as? [String: Any] {
            row = previous
            deleted = true
        } else {
            row = original
            deleted = false
        }
        guard let timestamp = (row["ts"] as? String) ?? (original["deleted_ts"] as? String),
              let seconds = validEpochSeconds(timestamp) else { return nil }
        let senderID = (row["user"] as? String) ?? (row["bot_id"] as? String) ?? "unknown"
        let senderName = users[senderID] ?? (row["username"] as? String) ?? senderID
        let files = (row["files"] as? [[String: Any]] ?? []).compactMap { file -> EvidenceFile? in
            guard let id = file["id"] as? String else { return nil }
            let name = (file["name"] as? String) ?? (file["title"] as? String) ?? id
            let byteCount = (file["size"] as? NSNumber)?.int64Value
            return .init(
                id: id,
                name: name,
                mimeType: file["mimetype"] as? String,
                size: byteCount.flatMap { $0 >= 0 ? $0 : nil },
                remoteURL: ((file["url_private_download"] as? String) ?? (file["url_private"] as? String)).flatMap(URL.init(string:))
            )
        }
        let reactions = (row["reactions"] as? [[String: Any]] ?? []).compactMap { reaction -> EvidenceReaction? in
            guard let name = reaction["name"] as? String, !name.isEmpty else { return nil }
            let users = reaction["users"] as? [String] ?? []
            let count = max(0, (reaction["count"] as? NSNumber)?.intValue ?? users.count)
            return .init(name: name, count: count, userIDs: users)
        }
        let raw = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys, .withoutEscapingSlashes])
        let edited = (row["edited"] as? [String: Any])?["ts"] as? String
        let threadTimestamp = (row["thread_ts"] as? String) ?? timestamp
        // Slack's client_msg_id is optional and replies refer to their root by timestamp.
        // A workspace + conversation + timestamp key therefore keeps root/reply grouping
        // stable while still deduplicating the same message across custodian archives.
        let messageID = "\(organizationID):\(conversation.id):\(timestamp)"
        let threadID = "\(organizationID):\(conversation.id):\(threadTimestamp)"
        return .init(
            id: messageID,
            conversationID: conversation.id,
            conversationName: conversation.name,
            conversationKind: conversation.kind,
            threadID: threadID,
            senderID: senderID,
            senderName: senderName,
            text: (row["text"] as? String) ?? "",
            postedAt: Date(timeIntervalSince1970: seconds),
            editedAt: edited.flatMap(validEpochSeconds).map(Date.init(timeIntervalSince1970:)),
            isDeleted: deleted,
            reactions: reactions.isEmpty ? nil : reactions,
            files: files,
            rawJSON: raw
        )
    }

    private static func validEpochSeconds(_ value: String) -> TimeInterval? {
        guard value.utf8.count <= 64,
              let seconds = Double(value),
              seconds.isFinite,
              seconds >= 0,
              seconds <= 253_402_300_799 else { return nil }
        return seconds
    }
}

private struct ConversationDescriptor {
    let id: String
    let name: String
    let kind: ConversationKind
}

struct JSONArrayObjectParser {
    private let maximumObjectBytes: UInt64
    private var started = false
    private var finished = false
    private var expectingSeparator = false
    private var afterComma = false
    private var depth = 0
    private var insideString = false
    private var escaped = false
    private var object = Data()

    init(maximumObjectBytes: UInt64) {
        self.maximumObjectBytes = maximumObjectBytes
    }

    mutating func consume(_ data: Data, path: String) throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for byte in data {
            if finished {
                guard Self.isWhitespace(byte) else { throw malformed(path) }
                continue
            }
            if !started {
                if Self.isWhitespace(byte) { continue }
                guard byte == 0x5B else { throw malformed(path) } // [
                started = true
                continue
            }
            if depth == 0 {
                if Self.isWhitespace(byte) { continue }
                if expectingSeparator {
                    if byte == 0x2C { // ,
                        expectingSeparator = false
                        afterComma = true
                        continue
                    }
                    if byte == 0x5D { // ]
                        finished = true
                        continue
                    }
                    throw malformed(path)
                }
                if byte == 0x5D { // ]
                    guard !afterComma else { throw malformed(path) }
                    finished = true
                    continue
                }
                guard byte == 0x7B else { throw malformed(path) } // {
                object.removeAll(keepingCapacity: true)
                object.append(byte)
                depth = 1
                insideString = false
                escaped = false
                afterComma = false
                continue
            }

            object.append(byte)
            guard UInt64(object.count) <= maximumObjectBytes else {
                throw ThreadLightError.archive("A Slack message object exceeds the safe streaming limit: \(path)")
            }
            if insideString {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true } // \
                else if byte == 0x22 { insideString = false } // "
                continue
            }
            switch byte {
            case 0x22: insideString = true
            case 0x7B, 0x5B: depth += 1 // { [
            case 0x7D, 0x5D: // } ]
                depth -= 1
                guard depth >= 0 else { throw malformed(path) }
                if depth == 0 {
                    guard let row = try JSONSerialization.jsonObject(with: object) as? [String: Any] else {
                        throw malformed(path)
                    }
                    rows.append(row)
                    expectingSeparator = true
                }
            default: break
            }
        }
        return rows
    }

    func finish(path: String) throws {
        guard started, finished, depth == 0, !insideString else { throw malformed(path) }
    }

    private func malformed(_ path: String) -> ThreadLightError {
        .archive("Slack JSON is malformed: \(path)")
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}

enum SHA256Digest {
    static func file(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func data(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
