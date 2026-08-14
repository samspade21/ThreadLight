import Foundation
import SQLCipher

public actor EvidenceStore {
    nonisolated(unsafe) private var database: OpaquePointer?
    /// Serializes every use of the connection.
    ///
    /// The actor cannot do this. The handle and all of its helpers are nonisolated so `init`
    /// can open and migrate the database before any actor context exists, which leaves
    /// SQLite's own connection mutex as the only guard. That mutex makes a single call safe;
    /// it does not stop another task's statements from landing between this one's
    /// BEGIN IMMEDIATE and COMMIT, and it does not keep two tasks out of the cipher layer at
    /// once. Recursive so a transaction can run the statements nested inside it.
    nonisolated private let databaseLock = NSRecursiveLock()
    public let url: URL

    public init(url: URL, key: Data) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw ThreadLightError.database("Could not open the encrypted evidence database.")
        }
        database = handle
        do {
            try execute("PRAGMA key = \"x'\(key.hexString)'\"")
            try execute("PRAGMA cipher_memory_security = ON")
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try verifyCipher()
            try migrate()
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public static func openDefault(organizationID: String, keychain: KeychainStore = .shared) async throws -> EvidenceStore {
        guard ThreadLightBuild.isValidStorageNamespace(organizationID) else {
            throw ThreadLightError.database("The local evidence storage namespace is invalid.")
        }
        let key = try await keychain.loadOrCreateRandomKey(account: "evidence.database.\(organizationID)")
        return try EvidenceStore(url: defaultURL(organizationID: organizationID), key: key)
    }

    public static func removeDefault(organizationID: String, keychain: KeychainStore = .shared) async throws {
        guard ThreadLightBuild.isValidStorageNamespace(organizationID) else {
            throw ThreadLightError.database("The local evidence storage namespace is invalid.")
        }
        let url = try defaultURL(organizationID: organizationID)
        for candidate in [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")] {
            if FileManager.default.fileExists(atPath: candidate.path) {
                try FileManager.default.removeItem(at: candidate)
            }
        }
        try await keychain.delete(account: "evidence.database.\(organizationID)")
    }

    private static func defaultURL(organizationID: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "ThreadLight", directoryHint: .isDirectory)
        return base.appending(path: "\(organizationID).evidence.sqlite")
    }

    public func save(hold: LegalHold) throws {
        let data = try Self.encoder.encode(hold)
        try run(
            """
            INSERT INTO holds(id, organization_id, status, updated_at, json)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET organization_id=excluded.organization_id, status=excluded.status,
                updated_at=excluded.updated_at, json=excluded.json
            """,
            [.text(hold.id), .text(hold.organizationID), .text(hold.status.rawValue), .double(hold.updatedAt.timeIntervalSince1970), .blob(data)]
        )
    }

    public func holds() throws -> [LegalHold] {
        try rows("SELECT json FROM holds ORDER BY updated_at DESC") { statement in
            try Self.decoder.decode(LegalHold.self, from: columnData(statement, 0))
        }
    }

    public func replaceCustodians(_ custodians: [Custodian], holdID: String) throws {
        try transaction {
            try run("DELETE FROM custodians WHERE hold_id = ?", [.text(holdID)])
            for custodian in custodians {
                try run(
                    "INSERT INTO custodians(id, hold_id, current, json) VALUES(?, ?, ?, ?)",
                    [.text(custodian.id), .text(holdID), .int(custodian.isCurrent ? 1 : 0), .blob(try Self.encoder.encode(custodian))]
                )
            }
        }
    }

    public func custodians(holdID: String) throws -> [Custodian] {
        try rows("SELECT json FROM custodians WHERE hold_id = ? ORDER BY id", [.text(holdID)]) { statement in
            try Self.decoder.decode(Custodian.self, from: columnData(statement, 0))
        }
    }

    public func beginImport(_ source: SourceArchive) throws {
        try run(
            "INSERT INTO source_archives(id, hold_id, custodian_id, sha256, complete, imported_at, json) VALUES(?, ?, ?, ?, 0, ?, ?)",
            [.text(source.id.uuidString), .text(source.holdID), .text(source.custodianID), .text(source.sha256), .double(source.importedAt.timeIntervalSince1970), .blob(try Self.encoder.encode(source))]
        )
    }

    @discardableResult
    public func insert(message: EvidenceMessage, membership: HoldMembership) throws -> Bool {
        var inserted = false
        try transaction {
            inserted = try insertRecord(.init(message: message, membership: membership))
        }
        return inserted
    }

    public func insert(records: [EvidenceImportRecord]) throws -> (inserted: Int, deduplicated: Int) {
        var inserted = 0
        try transaction {
            var organizations: [String: String] = [:]
            var users = Set<String>()
            var conversations = Set<String>()
            for record in records {
                let holdID = record.membership.holdID
                let organizationID = try organizations[holdID] ?? {
                    let value = try holdOrganizationID(holdID: holdID)
                    organizations[holdID] = value
                    return value
                }()
                let userKey = organizationID + "\u{1F}" + record.message.senderID
                let conversationKey = organizationID + "\u{1F}" + record.message.conversationID
                if try insertRecord(
                    record,
                    organizationID: organizationID,
                    upsertSender: users.insert(userKey).inserted,
                    upsertConversation: conversations.insert(conversationKey).inserted
                ) {
                    inserted += 1
                }
            }
        }
        return (inserted, records.count - inserted)
    }

    public func update(message: EvidenceMessage) throws {
        let fileText = message.files.compactMap { [$0.name, $0.mimeType, $0.extractedText].compactMap { $0 }.joined(separator: " ") }.joined(separator: " ")
        try transaction {
            try run(
                """
                UPDATE messages SET conversation_id = ?, conversation_name = ?, conversation_kind = ?, thread_id = ?,
                    sender_id = ?, sender_name = ?, text = ?, posted_at = ?, edited_at = ?, deleted = ?,
                    has_attachment = ?, file_types = ?, json = ? WHERE id = ?
                """,
                [
                    .text(message.conversationID), .text(message.conversationName), .text(message.conversationKind.rawValue),
                    .text(message.threadID), .text(message.senderID), .text(message.senderName), .text(message.text),
                    .double(message.postedAt.timeIntervalSince1970), message.editedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                    .int(message.isDeleted ? 1 : 0), .int(message.files.isEmpty ? 0 : 1),
                    .text(message.files.compactMap(\.mimeType).joined(separator: " ")), .blob(try Self.encoder.encode(message)), .text(message.id),
                ]
            )
            guard sqlite3_changes(database) == 1 else { throw ThreadLightError.database("The message to update was not found.") }
            try run("DELETE FROM message_search WHERE message_id = ?", [.text(message.id)])
            try run(
                "INSERT INTO message_search(message_id, text, sender_name, conversation_name, file_text) VALUES(?, ?, ?, ?, ?)",
                [.text(message.id), .text(message.text), .text(message.senderName), .text(message.conversationName), .text(fileText)]
            )
            let organizationID = try messageOrganizationID(messageID: message.id)
            try upsertNormalized(message: message, organizationID: organizationID, incrementThreadCount: false)
        }
    }

    public func completeImport(_ source: SourceArchive) throws {
        try transaction {
            try run(
                "UPDATE source_archives SET complete = 1, json = ? WHERE id = ?",
                [.blob(try Self.encoder.encode(source)), .text(source.id.uuidString)]
            )
            try run("DELETE FROM import_checkpoints WHERE source_archive_id = ?", [.text(source.id.uuidString)])
        }
    }

    public func abandonImport(sourceID: UUID) throws {
        try transaction {
            try run("DELETE FROM source_archives WHERE id = ? AND complete = 0", [.text(sourceID.uuidString)])
            try execute("DELETE FROM message_search WHERE message_id IN (SELECT id FROM messages WHERE NOT EXISTS (SELECT 1 FROM memberships WHERE memberships.message_id = messages.id))")
            try execute("DELETE FROM messages WHERE NOT EXISTS (SELECT 1 FROM memberships WHERE memberships.message_id = messages.id)")
            try rebuildNormalizedTables()
        }
    }

    public func sourceArchive(id: UUID) throws -> SourceArchive? {
        try firstRow("SELECT json FROM source_archives WHERE id = ? AND complete = 1", [.text(id.uuidString)]) { statement in
            try Self.decoder.decode(SourceArchive.self, from: columnData(statement, 0))
        }
    }

    public func archives(holdID: String) throws -> [SourceArchive] {
        try rows("SELECT json FROM source_archives WHERE hold_id = ? AND complete = 1 ORDER BY imported_at DESC", [.text(holdID)]) { statement in
            try Self.decoder.decode(SourceArchive.self, from: columnData(statement, 0))
        }
    }

    public func sourceArchive(sha256: String, holdID: String) throws -> SourceArchive? {
        try firstRow(
            "SELECT json FROM source_archives WHERE hold_id = ? AND sha256 = ? AND complete = 1 LIMIT 1",
            [.text(holdID), .text(sha256)]
        ) { statement in
            try Self.decoder.decode(SourceArchive.self, from: columnData(statement, 0))
        }
    }

    func resumableImport(sha256: String, holdID: String) throws -> (SourceArchive, StoredImportCheckpoint)? {
        try firstRow(
            """
            SELECT a.json, c.json
            FROM source_archives a
            JOIN import_checkpoints c ON c.source_archive_id = a.id
            WHERE a.hold_id = ? AND a.sha256 = ? AND a.complete = 0
            LIMIT 1
            """,
            [.text(holdID), .text(sha256)]
        ) { statement in
            (
                try Self.decoder.decode(SourceArchive.self, from: columnData(statement, 0)),
                try Self.decoder.decode(StoredImportCheckpoint.self, from: columnData(statement, 1))
            )
        }
    }

    func saveImportCheckpoint(_ checkpoint: StoredImportCheckpoint) throws {
        try run(
            """
            INSERT INTO import_checkpoints(source_archive_id, updated_at, json) VALUES(?, ?, ?)
            ON CONFLICT(source_archive_id) DO UPDATE SET updated_at = excluded.updated_at, json = excluded.json
            """,
            [
                .text(checkpoint.sourceArchiveID.uuidString), .double(Date().timeIntervalSince1970),
                .blob(try Self.encoder.encode(checkpoint)),
            ]
        )
    }

    public func attachmentAvailability(holdID: String) throws -> (referenced: Int, available: Int) {
        let messages: [EvidenceMessage] = try rows(
            """
            SELECT DISTINCT m.json FROM messages m
            JOIN memberships hm ON hm.message_id = m.id
            JOIN source_archives a ON a.id = hm.source_archive_id AND a.complete = 1
            WHERE hm.hold_id = ?
            """,
            [.text(holdID)]
        ) { statement in
            try Self.decoder.decode(EvidenceMessage.self, from: columnData(statement, 0))
        }
        let files = messages.flatMap(\.files)
        return (files.count, files.filter(\.hasOriginalBytes).count)
    }

    public func conversations(holdID: String) throws -> [EvidenceConversation] {
        guard let hold = try storedHold(id: holdID), hold.status == .active else { return [] }
        var conditions = ["hm.hold_id = ?"]
        var values: [SQLiteValue] = [.text(holdID)]
        Self.appendHoldScope(hold, conditions: &conditions, values: &values)
        return try rows(
            """
            SELECT m.conversation_id, m.conversation_name, m.conversation_kind,
                   count(DISTINCT m.id), max(m.posted_at)
            FROM messages m
            JOIN memberships hm ON hm.message_id = m.id
            JOIN source_archives a ON a.id = hm.source_archive_id AND a.complete = 1
            WHERE \(conditions.joined(separator: " AND "))
            GROUP BY m.conversation_id, m.conversation_name, m.conversation_kind
            ORDER BY m.conversation_name COLLATE NOCASE, m.conversation_id
            """,
            values
        ) { statement in
            EvidenceConversation(
                id: columnText(statement, 0),
                name: columnText(statement, 1),
                kind: ConversationKind(rawValue: columnText(statement, 2)) ?? .unknown,
                messageCount: Int(sqlite3_column_int64(statement, 3)),
                lastPostedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            )
        }
    }

    public func messages(holdID: String, messageIDs: Set<String>) throws -> [EvidenceMessage] {
        guard !messageIDs.isEmpty,
              let hold = try storedHold(id: holdID),
              hold.status == .active else { return [] }
        let identifiers = messageIDs.sorted()
        var found: [String: EvidenceMessage] = [:]
        for offset in stride(from: 0, to: identifiers.count, by: 400) {
            let batch = Array(identifiers[offset..<min(offset + 400, identifiers.count)])
            var conditions = ["hm.hold_id = ?", "m.id IN (\(Array(repeating: "?", count: batch.count).joined(separator: ",")))"]
            var values: [SQLiteValue] = [.text(holdID)] + batch.map(SQLiteValue.text)
            Self.appendHoldScope(hold, conditions: &conditions, values: &values)
            let loaded: [EvidenceMessage] = try rows(
                """
                SELECT DISTINCT m.json
                FROM messages m
                JOIN memberships hm ON hm.message_id = m.id
                JOIN source_archives a ON a.id = hm.source_archive_id AND a.complete = 1
                WHERE \(conditions.joined(separator: " AND "))
                """,
                values
            ) { statement in
                try Self.decoder.decode(EvidenceMessage.self, from: columnData(statement, 0))
            }
            for message in loaded { found[message.id] = message }
        }
        return found.values.sorted { $0.postedAt < $1.postedAt }
    }

    public func search(holdID: String, query: SearchQuery) throws -> [EvidenceMessage] {
        guard let hold = try storedHold(id: holdID), hold.status == .active else { return [] }
        let parsed = try SearchParser.parse(query)
        let positiveExpression = parsed.expression.flatMap { $0.containsUnaryNot ? nil : $0 }
        var sql: String
        var conditions: [String]
        var values: [SQLiteValue]
        if let positiveExpression {
            // CROSS JOIN preserves the FTS-first loop order. Without it SQLite can choose to
            // scan every membership before applying a highly selective text match.
            sql = """
            SELECT DISTINCT m.json
            FROM message_search
            CROSS JOIN messages m ON m.id = message_search.message_id
            CROSS JOIN memberships hm INDEXED BY idx_memberships_hold ON hm.message_id = m.id
            CROSS JOIN source_archives a ON a.id = hm.source_archive_id AND a.complete = 1
            """
            conditions = ["message_search MATCH ?", "hm.hold_id = ?"]
            values = [.text(positiveExpression.fts5()), .text(holdID)]
        } else {
            sql = """
            SELECT DISTINCT m.json
            FROM messages m
            JOIN memberships hm ON hm.message_id = m.id
            JOIN source_archives a ON a.id = hm.source_archive_id AND a.complete = 1
            """
            conditions = ["hm.hold_id = ?"]
            values = [.text(holdID)]
            if let expression = parsed.expression {
                let predicate = SearchPredicateCompiler.compile(expression)
                conditions.append(predicate.sql)
                values.append(contentsOf: predicate.values)
            }
        }
        Self.appendHoldScope(hold, conditions: &conditions, values: &values)
        let filters = parsed.filters
        if let sender = filters.sender { conditions.append("m.sender_name LIKE ? ESCAPE '\\'"); values.append(.text("%\(sender.sqlLikeEscaped)%")) }
        if let personID = filters.personID {
            conditions.append("(m.sender_id = ? OR m.text LIKE ? ESCAPE '\\')")
            values.append(.text(personID))
            values.append(.text("%<@\(personID.sqlLikeEscaped)>%"))
        }
        if let custodianID = filters.custodianID { conditions.append("hm.custodian_id = ?"); values.append(.text(custodianID)) }
        if let conversationID = filters.conversationID { conditions.append("m.conversation_id = ?"); values.append(.text(conversationID)) }
        if let conversation = filters.conversation { conditions.append("m.conversation_name LIKE ? ESCAPE '\\'"); values.append(.text("%\(conversation.sqlLikeEscaped)%")) }
        if let after = filters.after { conditions.append("m.posted_at >= ?"); values.append(.double(after.timeIntervalSince1970)) }
        if let before = filters.before { conditions.append("m.posted_at < ?"); values.append(.double(before.timeIntervalSince1970)) }
        if let kind = filters.kind { conditions.append("m.conversation_kind = ?"); values.append(.text(kind.rawValue)) }
        if let value = filters.hasAttachment { conditions.append("m.has_attachment = ?"); values.append(.int(value ? 1 : 0)) }
        if let value = filters.fileType { conditions.append("m.file_types LIKE ? ESCAPE '\\'"); values.append(.text("%\(value.sqlLikeEscaped)%")) }
        if let value = filters.isThread { conditions.append(value ? "m.thread_id != m.id" : "m.thread_id = m.id") }
        if let value = filters.isEdited { conditions.append(value ? "m.edited_at IS NOT NULL" : "m.edited_at IS NULL") }
        if let value = filters.isDeleted { conditions.append("m.deleted = ?"); values.append(.int(value ? 1 : 0)) }
        sql += " WHERE " + conditions.joined(separator: " AND ") + " ORDER BY m.posted_at DESC, m.id DESC LIMIT ? OFFSET ?"
        values.append(.int(Int64(query.limit)))
        values.append(.int(Int64(query.offset)))
#if THREADLIGHT_DEVELOPMENT
        if ProcessInfo.processInfo.environment["THREADLIGHT_SEARCH_QUERY_PLAN"] == "1" {
            let plan: [String] = try rows("EXPLAIN QUERY PLAN \(sql)", values) { columnText($0, 3) }
            print("ThreadLight search query plan:\n\(plan.joined(separator: "\n"))")
            if let positiveExpression {
                let started = Date()
                let count: Int64? = try firstRow(
                    "SELECT count(*) FROM message_search WHERE message_search MATCH ?",
                    [.text(positiveExpression.fts5())]
                ) { sqlite3_column_int64($0, 0) }
                print("ThreadLight FTS-only diagnostic: \(count ?? 0) matches in \(Date().timeIntervalSince(started))s")
            }
        }
#endif
        return try rows(sql, values) { statement in
            try Self.decoder.decode(EvidenceMessage.self, from: columnData(statement, 0))
        }
    }

    public func thread(holdID: String, threadID: String) throws -> [EvidenceMessage] {
        guard let hold = try storedHold(id: holdID), hold.status == .active else { return [] }
        var conditions = ["hm.hold_id = ?", "m.thread_id = ?"]
        var values: [SQLiteValue] = [.text(holdID), .text(threadID)]
        Self.appendHoldScope(hold, conditions: &conditions, values: &values)
        return try rows(
            """
            SELECT DISTINCT m.json FROM messages m
            JOIN memberships hm ON hm.message_id = m.id
            JOIN source_archives a ON a.id = hm.source_archive_id AND a.complete = 1
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY m.posted_at ASC
            """,
            values
        ) { statement in
            try Self.decoder.decode(EvidenceMessage.self, from: columnData(statement, 0))
        }
    }

    public func membership(messageID: String, holdID: String) throws -> HoldMembership? {
        try firstRow(
            "SELECT hold_id, custodian_id, message_id, source_archive_id FROM memberships WHERE message_id = ? AND hold_id = ? LIMIT 1",
            [.text(messageID), .text(holdID)]
        ) { statement in
            guard let sourceID = UUID(uuidString: columnText(statement, 3)) else {
                throw ThreadLightError.database("Stored source archive ID is invalid.")
            }
            return .init(
                holdID: columnText(statement, 0),
                custodianID: columnText(statement, 1),
                messageID: columnText(statement, 2),
                sourceArchiveID: sourceID
            )
        }
    }

    public func memberships(messageID: String, holdID: String) throws -> [HoldMembership] {
        try rows(
            "SELECT hold_id, custodian_id, message_id, source_archive_id, source_message_sha256 FROM memberships WHERE message_id = ? AND hold_id = ?",
            [.text(messageID), .text(holdID)]
        ) { statement in
            guard let sourceID = UUID(uuidString: columnText(statement, 3)) else {
                throw ThreadLightError.database("Stored source archive ID is invalid.")
            }
            return .init(
                holdID: columnText(statement, 0),
                custodianID: columnText(statement, 1),
                messageID: columnText(statement, 2),
                sourceArchiveID: sourceID,
                sourceMessageSHA256: columnText(statement, 4)
            )
        }
    }

    public func transferSnapshot(
        hold: LegalHold,
        custodians: [Custodian],
        fingerprint: String
    ) throws -> HoldTransferSnapshot {
        let archives = try archives(holdID: hold.id)
        // Each message is serialized once here. Memberships are keyed per source archive, so a
        // message shared across custodians' exports repeats in the membership list only, which
        // costs a few identifiers instead of the whole message and its retained raw Slack JSON.
        let messages: [EvidenceMessage] = try rows(
            """
            SELECT m.json FROM messages m
            WHERE m.id IN (
                SELECT hm.message_id FROM memberships hm
                JOIN source_archives a ON a.id = hm.source_archive_id AND a.complete = 1
                WHERE hm.hold_id = ?
            )
            ORDER BY m.id
            """,
            [.text(hold.id)]
        ) { statement in
            try Self.decoder.decode(EvidenceMessage.self, from: columnData(statement, 0))
        }
        let memberships: [HoldMembership] = try rows(
            """
            SELECT hm.hold_id, hm.custodian_id, hm.message_id,
                   hm.source_archive_id, hm.source_message_sha256
            FROM memberships hm
            JOIN source_archives a ON a.id = hm.source_archive_id AND a.complete = 1
            WHERE hm.hold_id = ?
            ORDER BY hm.source_archive_id, hm.message_id, hm.custodian_id
            """,
            [.text(hold.id)]
        ) { statement in
            guard let sourceID = UUID(uuidString: columnText(statement, 3)) else {
                throw ThreadLightError.database("Stored source archive ID is invalid.")
            }
            return HoldMembership(
                holdID: columnText(statement, 0),
                custodianID: columnText(statement, 1),
                messageID: columnText(statement, 2),
                sourceArchiveID: sourceID,
                sourceMessageSHA256: columnText(statement, 4)
            )
        }
        return .init(
            createdAt: .now,
            holdID: hold.id,
            organizationID: hold.organizationID,
            holdFingerprint: fingerprint,
            archives: archives,
            messages: messages,
            memberships: memberships
        )
    }

    public func importTransferSnapshot(
        _ snapshot: HoldTransferSnapshot,
        hold: LegalHold,
        custodians: [Custodian]
    ) throws -> (archives: Int, messages: Int) {
        guard snapshot.schemaVersion == HoldTransferSnapshot.schemaVersion,
              snapshot.holdID == hold.id,
              snapshot.organizationID == hold.organizationID,
              snapshot.holdFingerprint == HoldAccessKey.fingerprint(hold: hold, custodians: custodians) else {
            throw ThreadLightError.archive("The transfer does not match the current legal hold membership.")
        }
        let sources = Dictionary(uniqueKeysWithValues: snapshot.archives.map { ($0.id, $0) })
        let messages = Dictionary(snapshot.messages.map { ($0.id, $0) }) { first, _ in first }
        guard sources.count == snapshot.archives.count,
              messages.count == snapshot.messages.count,
              snapshot.archives.allSatisfy({ $0.holdID == hold.id }),
              // Every membership must name a message the package actually carries, or the
              // transfer claims provenance for evidence it does not contain.
              snapshot.memberships.allSatisfy({
                  $0.holdID == hold.id
                    && messages[$0.messageID] != nil
                    && sources[$0.sourceArchiveID] != nil
              }) else {
            throw ThreadLightError.archive("The transfer contains inconsistent source provenance.")
        }
        try save(hold: hold)
        try replaceCustodians(custodians, holdID: hold.id)
        var importedArchives = 0
        var importedMessages = 0
        for archive in snapshot.archives {
            if try sourceArchive(sha256: archive.sha256, holdID: hold.id) != nil { continue }
            try beginImport(archive)
            let records = snapshot.memberships
                .filter { $0.sourceArchiveID == archive.id }
                .compactMap { membership in
                    messages[membership.messageID].map {
                        EvidenceImportRecord(message: $0, membership: membership)
                    }
                }
            let counts = try insert(records: records)
            importedMessages += counts.inserted
            try completeImport(archive)
            importedArchives += 1
        }
        return (importedArchives, importedMessages)
    }

    @discardableResult
    public func purgeEvidence(holdID: String) throws -> Bool {
        let existed: Int64 = try firstRow(
            "SELECT count(*) FROM source_archives WHERE hold_id = ?",
            [.text(holdID)]
        ) { sqlite3_column_int64($0, 0) } ?? 0
        guard existed > 0 else { return false }
        try transaction {
            try run("DELETE FROM source_archives WHERE hold_id = ?", [.text(holdID)])
            try execute("DELETE FROM message_search WHERE message_id IN (SELECT id FROM messages WHERE NOT EXISTS (SELECT 1 FROM memberships WHERE memberships.message_id = messages.id))")
            try execute("DELETE FROM messages WHERE NOT EXISTS (SELECT 1 FROM memberships WHERE memberships.message_id = messages.id)")
            try rebuildNormalizedTables()
        }
        return true
    }

    public func purge() throws {
        try transaction {
            try execute("DELETE FROM memberships")
            try execute("DELETE FROM message_search")
            try execute("DELETE FROM evidence_files")
            try execute("DELETE FROM reactions")
            try execute("DELETE FROM threads")
            try execute("DELETE FROM messages")
            try execute("DELETE FROM conversations")
            try execute("DELETE FROM users")
            try execute("DELETE FROM source_archives")
            try execute("DELETE FROM custodians")
            try execute("DELETE FROM holds")
        }
        try execute("VACUUM")
    }

    nonisolated private func verifyCipher() throws {
        let version: String? = try firstRow("PRAGMA cipher_version") { columnText($0, 0) }
        guard let version, !version.isEmpty else {
            throw ThreadLightError.database("SQLCipher is unavailable; ThreadLight will not create an unencrypted evidence store.")
        }
    }

    nonisolated private func storedHold(id: String) throws -> LegalHold? {
        try firstRow("SELECT json FROM holds WHERE id = ?", [.text(id)]) { statement in
            try Self.decoder.decode(LegalHold.self, from: columnData(statement, 0))
        }
    }

    private static func appendHoldScope(
        _ hold: LegalHold,
        conditions: inout [String],
        values: inout [SQLiteValue]
    ) {
        if let start = hold.startAt {
            conditions.append("m.posted_at >= ?")
            values.append(.double(start.timeIntervalSince1970))
        }
        if let end = hold.endAt {
            conditions.append("m.posted_at <= ?")
            values.append(.double(end.timeIntervalSince1970))
        }
        if hold.restrictions.contains(.onlyDMs) {
            conditions.append("m.conversation_kind IN (?, ?)")
            values.append(.text(ConversationKind.directMessage.rawValue))
            values.append(.text(ConversationKind.groupDirectMessage.rawValue))
        }
    }

    nonisolated private func insertRecord(
        _ record: EvidenceImportRecord,
        organizationID suppliedOrganizationID: String? = nil,
        upsertSender: Bool = true,
        upsertConversation: Bool = true
    ) throws -> Bool {
        let message = record.message
        let membership = record.membership
        let organizationID = try suppliedOrganizationID ?? holdOrganizationID(holdID: membership.holdID)
        let sourceMessage = message.rawJSON.isEmpty ? try CanonicalJSON.encode(message) : message.rawJSON
        let sourceMessageSHA256 = SHA256Digest.data(sourceMessage)
        let fileText = message.files.compactMap { [$0.name, $0.mimeType, $0.extractedText].compactMap { $0 }.joined(separator: " ") }.joined(separator: " ")
        try run(
            """
            INSERT OR IGNORE INTO messages(id, organization_id, conversation_id, conversation_name, conversation_kind, thread_id,
                sender_id, sender_name, text, posted_at, edited_at, deleted, has_attachment, file_types, json)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(message.id), .text(organizationID),
                .text(message.conversationID), .text(message.conversationName), .text(message.conversationKind.rawValue),
                .text(message.threadID), .text(message.senderID), .text(message.senderName), .text(message.text),
                .double(message.postedAt.timeIntervalSince1970), message.editedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .int(message.isDeleted ? 1 : 0), .int(message.files.isEmpty ? 0 : 1),
                .text(message.files.compactMap(\.mimeType).joined(separator: " ")), .blob(try Self.encoder.encode(message)),
            ]
        )
        let inserted = sqlite3_changes(database) > 0
        if inserted {
            try run(
                "INSERT INTO message_search(message_id, text, sender_name, conversation_name, file_text) VALUES(?, ?, ?, ?, ?)",
                [.text(message.id), .text(message.text), .text(message.senderName), .text(message.conversationName), .text(fileText)]
            )
            try upsertNormalized(
                message: message,
                organizationID: organizationID,
                incrementThreadCount: true,
                upsertSender: upsertSender,
                upsertConversation: upsertConversation
            )
        }
        try run(
            "INSERT OR IGNORE INTO memberships(hold_id, custodian_id, message_id, source_archive_id, source_message_sha256) VALUES(?, ?, ?, ?, ?)",
            [
                .text(membership.holdID), .text(membership.custodianID), .text(membership.messageID),
                .text(membership.sourceArchiveID.uuidString), .text(sourceMessageSHA256),
            ]
        )
        return inserted
    }

    nonisolated private func migrate() throws {
        let currentVersion: Int64 = try firstRow("PRAGMA user_version") { sqlite3_column_int64($0, 0) } ?? 0
        guard currentVersion <= 4 else {
            throw ThreadLightError.database("This evidence database was created by a newer ThreadLight schema version.")
        }
        try execute(
            """
            CREATE TABLE IF NOT EXISTS holds(
                id TEXT PRIMARY KEY, organization_id TEXT NOT NULL, status TEXT NOT NULL,
                updated_at REAL NOT NULL, json BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS custodians(
                id TEXT NOT NULL, hold_id TEXT NOT NULL, current INTEGER NOT NULL, json BLOB NOT NULL,
                PRIMARY KEY(id, hold_id), FOREIGN KEY(hold_id) REFERENCES holds(id) ON DELETE CASCADE
            );
            CREATE TABLE IF NOT EXISTS source_archives(
                id TEXT PRIMARY KEY, hold_id TEXT NOT NULL, custodian_id TEXT NOT NULL,
                complete INTEGER NOT NULL DEFAULT 0, imported_at REAL NOT NULL, json BLOB NOT NULL,
                FOREIGN KEY(hold_id) REFERENCES holds(id) ON DELETE CASCADE
            );
            CREATE TABLE IF NOT EXISTS messages(
                id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, conversation_name TEXT NOT NULL,
                conversation_kind TEXT NOT NULL, thread_id TEXT NOT NULL, sender_id TEXT NOT NULL,
                sender_name TEXT NOT NULL, text TEXT NOT NULL, posted_at REAL NOT NULL,
                edited_at REAL, deleted INTEGER NOT NULL, has_attachment INTEGER NOT NULL,
                file_types TEXT NOT NULL, json BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS memberships(
                hold_id TEXT NOT NULL, custodian_id TEXT NOT NULL, message_id TEXT NOT NULL,
                source_archive_id TEXT NOT NULL,
                PRIMARY KEY(hold_id, custodian_id, message_id, source_archive_id),
                FOREIGN KEY(message_id) REFERENCES messages(id) ON DELETE CASCADE,
                FOREIGN KEY(source_archive_id) REFERENCES source_archives(id) ON DELETE CASCADE
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5(
                message_id UNINDEXED, text, sender_name, conversation_name, file_text,
                tokenize='porter unicode61'
            );
            CREATE INDEX IF NOT EXISTS idx_memberships_hold ON memberships(hold_id, message_id);
            CREATE INDEX IF NOT EXISTS idx_messages_posted ON messages(posted_at DESC);
            """
        )
        var version = currentVersion
        if version < 1 {
            try execute("PRAGMA user_version = 1")
            version = 1
        }
        if version < 2 {
            try transaction {
                try execute("ALTER TABLE messages ADD COLUMN organization_id TEXT NOT NULL DEFAULT ''")
                try execute(
                    """
                    UPDATE messages
                    SET organization_id = COALESCE(
                        (SELECT h.organization_id
                         FROM memberships hm
                         JOIN holds h ON h.id = hm.hold_id
                         WHERE hm.message_id = messages.id
                         LIMIT 1),
                        'unknown'
                    )
                    WHERE organization_id = '';

                    CREATE TABLE users(
                        organization_id TEXT NOT NULL,
                        id TEXT NOT NULL,
                        display_name TEXT NOT NULL,
                        PRIMARY KEY(organization_id, id)
                    );
                    CREATE TABLE conversations(
                        organization_id TEXT NOT NULL,
                        id TEXT NOT NULL,
                        name TEXT NOT NULL,
                        kind TEXT NOT NULL,
                        PRIMARY KEY(organization_id, id)
                    );
                    CREATE TABLE threads(
                        id TEXT PRIMARY KEY,
                        organization_id TEXT NOT NULL,
                        conversation_id TEXT NOT NULL,
                        root_message_id TEXT NOT NULL,
                        first_posted_at REAL NOT NULL,
                        last_posted_at REAL NOT NULL,
                        message_count INTEGER NOT NULL
                    );
                    CREATE TABLE reactions(
                        message_id TEXT NOT NULL,
                        name TEXT NOT NULL,
                        count INTEGER NOT NULL,
                        user_ids_json BLOB NOT NULL,
                        PRIMARY KEY(message_id, name),
                        FOREIGN KEY(message_id) REFERENCES messages(id) ON DELETE CASCADE
                    );
                    CREATE TABLE evidence_files(
                        message_id TEXT NOT NULL,
                        id TEXT NOT NULL,
                        name TEXT NOT NULL,
                        mime_type TEXT,
                        byte_count INTEGER,
                        remote_url TEXT,
                        local_relative_path TEXT,
                        sha256 TEXT,
                        extracted_text TEXT,
                        PRIMARY KEY(message_id, id),
                        FOREIGN KEY(message_id) REFERENCES messages(id) ON DELETE CASCADE
                    );
                    CREATE INDEX idx_threads_conversation ON threads(organization_id, conversation_id, last_posted_at DESC);
                    CREATE INDEX idx_files_sha256 ON evidence_files(sha256) WHERE sha256 IS NOT NULL;
                    """
                )
                try rebuildNormalizedTables()
                try execute("PRAGMA user_version = 2")
            }
            version = 2
        }
        if version < 3 {
            try transaction {
                try execute("ALTER TABLE source_archives ADD COLUMN sha256 TEXT")
                let archives: [(String, SourceArchive)] = try rows("SELECT id, json FROM source_archives") { statement in
                    (columnText(statement, 0), try Self.decoder.decode(SourceArchive.self, from: columnData(statement, 1)))
                }
                for (id, archive) in archives {
                    try run("UPDATE source_archives SET sha256 = ? WHERE id = ?", [.text(archive.sha256), .text(id)])
                }
                try execute(
                    """
                    CREATE INDEX idx_source_archives_hash ON source_archives(hold_id, sha256, complete);
                    CREATE TABLE import_checkpoints(
                        source_archive_id TEXT PRIMARY KEY,
                        updated_at REAL NOT NULL,
                        json BLOB NOT NULL,
                        FOREIGN KEY(source_archive_id) REFERENCES source_archives(id) ON DELETE CASCADE
                    );
                    PRAGMA user_version = 3;
                    """
                )
            }
            version = 3
        }
        if version < 4 {
            try transaction {
                try execute("ALTER TABLE memberships ADD COLUMN source_message_sha256 TEXT NOT NULL DEFAULT ''")
                let stored: [(String, EvidenceMessage)] = try rows("SELECT id, json FROM messages") { statement in
                    (columnText(statement, 0), try Self.decoder.decode(EvidenceMessage.self, from: columnData(statement, 1)))
                }
                for (messageID, message) in stored {
                    let sourceMessage = message.rawJSON.isEmpty ? try CanonicalJSON.encode(message) : message.rawJSON
                    try run(
                        "UPDATE memberships SET source_message_sha256 = ? WHERE message_id = ?",
                        [.text(SHA256Digest.data(sourceMessage)), .text(messageID)]
                    )
                }
                try execute("PRAGMA user_version = 4")
            }
        }
    }

    nonisolated private func holdOrganizationID(holdID: String) throws -> String {
        guard let value: String = try firstRow(
            "SELECT organization_id FROM holds WHERE id = ?",
            [.text(holdID)],
            transform: { columnText($0, 0) }
        ), !value.isEmpty else {
            throw ThreadLightError.database("The message references a hold that is not stored locally.")
        }
        return value
    }

    nonisolated private func messageOrganizationID(messageID: String) throws -> String {
        guard let value: String = try firstRow(
            "SELECT organization_id FROM messages WHERE id = ?",
            [.text(messageID)],
            transform: { columnText($0, 0) }
        ), !value.isEmpty else {
            throw ThreadLightError.database("The message has no stored organization identity.")
        }
        return value
    }

    nonisolated private func rebuildNormalizedTables() throws {
        try execute("DELETE FROM evidence_files; DELETE FROM reactions; DELETE FROM threads; DELETE FROM conversations; DELETE FROM users;")
        let stored: [(String, EvidenceMessage)] = try rows("SELECT organization_id, json FROM messages") { statement in
            (
                columnText(statement, 0),
                try Self.decoder.decode(EvidenceMessage.self, from: columnData(statement, 1))
            )
        }
        var users = Set<String>()
        var conversations = Set<String>()
        for (organizationID, message) in stored {
            try upsertNormalized(
                message: message,
                organizationID: organizationID,
                incrementThreadCount: true,
                upsertSender: users.insert(organizationID + "\u{1F}" + message.senderID).inserted,
                upsertConversation: conversations.insert(organizationID + "\u{1F}" + message.conversationID).inserted
            )
        }
    }

    nonisolated private func upsertNormalized(
        message: EvidenceMessage,
        organizationID: String,
        incrementThreadCount: Bool,
        upsertSender: Bool = true,
        upsertConversation: Bool = true
    ) throws {
        if upsertSender {
            try run(
                """
                INSERT INTO users(organization_id, id, display_name) VALUES(?, ?, ?)
                ON CONFLICT(organization_id, id) DO UPDATE SET display_name = excluded.display_name
                WHERE display_name != excluded.display_name
                """,
                [.text(organizationID), .text(message.senderID), .text(message.senderName)]
            )
        }
        for userID in message.reactions?.flatMap(\.userIDs) ?? [] {
            try run(
                "INSERT OR IGNORE INTO users(organization_id, id, display_name) VALUES(?, ?, ?)",
                [.text(organizationID), .text(userID), .text(userID)]
            )
        }
        if upsertConversation {
            try run(
                """
                INSERT INTO conversations(organization_id, id, name, kind) VALUES(?, ?, ?, ?)
                ON CONFLICT(organization_id, id) DO UPDATE SET name = excluded.name, kind = excluded.kind
                WHERE name != excluded.name OR kind != excluded.kind
                """,
                [.text(organizationID), .text(message.conversationID), .text(message.conversationName), .text(message.conversationKind.rawValue)]
            )
        }
        if incrementThreadCount {
            try run(
                """
                INSERT INTO threads(id, organization_id, conversation_id, root_message_id, first_posted_at, last_posted_at, message_count)
                VALUES(?, ?, ?, ?, ?, ?, 1)
                ON CONFLICT(id) DO UPDATE SET
                    first_posted_at = min(first_posted_at, excluded.first_posted_at),
                    last_posted_at = max(last_posted_at, excluded.last_posted_at),
                    message_count = message_count + 1
                """,
                [
                    .text(message.threadID), .text(organizationID), .text(message.conversationID), .text(message.threadID),
                    .double(message.postedAt.timeIntervalSince1970), .double(message.postedAt.timeIntervalSince1970),
                ]
            )
        }
        if !incrementThreadCount {
            try run("DELETE FROM reactions WHERE message_id = ?", [.text(message.id)])
        }
        for reaction in message.reactions ?? [] {
            try run(
                "INSERT INTO reactions(message_id, name, count, user_ids_json) VALUES(?, ?, ?, ?)",
                [.text(message.id), .text(reaction.name), .int(Int64(reaction.count)), .blob(try Self.encoder.encode(reaction.userIDs))]
            )
        }
        if !incrementThreadCount {
            try run("DELETE FROM evidence_files WHERE message_id = ?", [.text(message.id)])
        }
        for file in message.files {
            try run(
                """
                INSERT INTO evidence_files(message_id, id, name, mime_type, byte_count, remote_url, local_relative_path, sha256, extracted_text)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(message.id), .text(file.id), .text(file.name), file.mimeType.map(SQLiteValue.text) ?? .null,
                    file.size.map(SQLiteValue.int) ?? .null, file.remoteURL.map { .text($0.absoluteString) } ?? .null,
                    file.localRelativePath.map(SQLiteValue.text) ?? .null, file.sha256.map(SQLiteValue.text) ?? .null,
                    file.extractedText.map(SQLiteValue.text) ?? .null,
                ]
            )
        }
    }

    func normalizedRecordCounts() throws -> (users: Int64, conversations: Int64, threads: Int64, reactions: Int64, files: Int64) {
        func count(_ table: String) throws -> Int64 {
            try firstRow("SELECT count(*) FROM \(table)") { sqlite3_column_int64($0, 0) } ?? 0
        }
        return (try count("users"), try count("conversations"), try count("threads"), try count("reactions"), try count("evidence_files"))
    }

    nonisolated private func transaction(_ body: () throws -> Void) throws {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    nonisolated private func execute(_ sql: String) throws {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        guard let database else { throw ThreadLightError.database("Evidence database is closed.") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &errorPointer)
        guard status == SQLITE_OK else {
            let detail = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorPointer)
            throw ThreadLightError.database("Database operation failed: \(detail)")
        }
    }

    nonisolated private func run(_ sql: String, _ values: [SQLiteValue] = []) throws {
        try withStatement(sql, values) { statement in
            let status = sqlite3_step(statement)
            guard status == SQLITE_DONE else { throw databaseError() }
        }
    }

    nonisolated private func rows<T>(_ sql: String, _ values: [SQLiteValue] = [], transform: (OpaquePointer) throws -> T) throws -> [T] {
        try withStatement(sql, values) { statement in
            var result: [T] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW: result.append(try transform(statement))
                case SQLITE_DONE: return result
                default: throw databaseError()
                }
            }
        }
    }

    nonisolated private func firstRow<T>(_ sql: String, _ values: [SQLiteValue] = [], transform: (OpaquePointer) throws -> T) throws -> T? {
        try withStatement(sql, values) { statement in
            switch sqlite3_step(statement) {
            case SQLITE_ROW: return try transform(statement)
            case SQLITE_DONE: return nil
            default: throw databaseError()
            }
        }
    }

    nonisolated private func withStatement<T>(_ sql: String, _ values: [SQLiteValue], body: (OpaquePointer) throws -> T) throws -> T {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        guard let database else { throw ThreadLightError.database("Evidence database is closed.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() { try bind(value, to: statement, index: Int32(offset + 1)) }
        return try body(statement)
    }

    nonisolated private func bind(_ value: SQLiteValue, to statement: OpaquePointer, index: Int32) throws {
        let destructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let status: Int32
        switch value {
        case .null: status = sqlite3_bind_null(statement, index)
        case let .int(value): status = sqlite3_bind_int64(statement, index, value)
        case let .double(value): status = sqlite3_bind_double(statement, index, value)
        case let .text(value): status = sqlite3_bind_text(statement, index, value, -1, destructor)
        case let .blob(data):
            status = data.withUnsafeBytes { buffer in sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), destructor) }
        }
        guard status == SQLITE_OK else { throw databaseError() }
    }

    nonisolated private func databaseError() -> ThreadLightError {
        guard let database else { return .database("Evidence database is closed.") }
        return .database("Database operation failed: \(String(cString: sqlite3_errmsg(database)))")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private enum SQLiteValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

struct StoredImportCheckpoint: Codable, Sendable {
    let sourceArchiveID: UUID
    var entryPath: String?
    var nextMessageIndex: Int
    var messagesProcessed: Int
    var messagesImported: Int
    var messagesDeduplicated: Int
    var filesReferenced: Int
    var coverageStart: Date?
    var coverageEnd: Date?

    init(sourceArchiveID: UUID) {
        self.sourceArchiveID = sourceArchiveID
        entryPath = nil
        nextMessageIndex = 0
        messagesProcessed = 0
        messagesImported = 0
        messagesDeduplicated = 0
        filesReferenced = 0
        coverageStart = nil
        coverageEnd = nil
    }
}

private enum SearchPredicateCompiler {
    struct Predicate {
        let sql: String
        let values: [SQLiteValue]
    }

    static func compile(_ expression: SearchExpression) -> Predicate {
        switch expression {
        case .term, .phrase, .near:
            return .init(
                sql: "m.id IN (SELECT message_id FROM message_search WHERE message_search MATCH ?)",
                values: [.text(expression.fts5())]
            )
        case let .and(lhs, rhs):
            return combine(lhs, rhs, operator: "AND")
        case let .or(lhs, rhs):
            return combine(lhs, rhs, operator: "OR")
        case let .not(value):
            let child = compile(value)
            return .init(sql: "NOT (\(child.sql))", values: child.values)
        }
    }

    private static func combine(_ lhs: SearchExpression, _ rhs: SearchExpression, operator: String) -> Predicate {
        let left = compile(lhs)
        let right = compile(rhs)
        return .init(sql: "(\(left.sql) \(`operator`) \(right.sql))", values: left.values + right.values)
    }
}

private extension SearchExpression {
    var containsUnaryNot: Bool {
        switch self {
        case .term, .phrase:
            false
        case let .near(lhs, rhs, _), let .and(lhs, rhs), let .or(lhs, rhs):
            lhs.containsUnaryNot || rhs.containsUnaryNot
        case .not:
            true
        }
    }
}

private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
    guard let pointer = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: pointer)
}

private func columnData(_ statement: OpaquePointer, _ index: Int32) -> Data {
    guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

private extension String {
    var sqlLikeEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
