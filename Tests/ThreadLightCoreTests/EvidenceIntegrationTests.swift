import AppKit
import Foundation
import PDFKit
import SQLCipher
import Testing
import ZIPFoundation
@testable import ThreadLightCore

@Test func encryptedStoreIndexesAndSearchesEvidence() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.seed()
    let results = try await fixture.store.search(holdID: fixture.hold.id, query: .init(text: "approval from:Alex"))
    #expect(results.map(\.id) == [fixture.message.id])
    #expect(try await fixture.store.memberships(messageID: fixture.message.id, holdID: fixture.hold.id).count == 1)
}

@Test func encryptedStoreListsAndFiltersConversations() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.seed()
    let directMessage = EvidenceMessage(
        id: "M-DM",
        conversationID: "D1",
        conversationName: "Alex Rivera, Morgan Lee",
        conversationKind: .groupDirectMessage,
        threadID: "M-DM",
        senderID: fixture.custodian.id,
        senderName: fixture.custodian.displayName,
        text: "private review",
        postedAt: fixture.message.postedAt.addingTimeInterval(1)
    )
    _ = try await fixture.store.insert(
        message: directMessage,
        membership: .init(
            holdID: fixture.hold.id,
            custodianID: fixture.custodian.id,
            messageID: directMessage.id,
            sourceArchiveID: fixture.archive.id
        )
    )

    let conversations = try await fixture.store.conversations(holdID: fixture.hold.id)
    #expect(Set(conversations.map(\.id)) == ["C1", "D1"])
    #expect(conversations.first(where: { $0.id == "D1" })?.kind == .groupDirectMessage)

    var filters = SearchFilters()
    filters.conversationID = "D1"
    let results = try await fixture.store.search(holdID: fixture.hold.id, query: .init(filters: filters))
    #expect(results.map(\.id) == [directMessage.id])
    let selected = try await fixture.store.messages(
        holdID: fixture.hold.id,
        messageIDs: [fixture.message.id, directMessage.id]
    )
    #expect(selected.map(\.id) == [fixture.message.id, directMessage.id])
}

@Test func encryptedStorePagesAndFiltersByPersonInvolvementAndDates() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.seed()
    let mentioned = EvidenceMessage(
        id: "M-MENTION",
        conversationID: "C1",
        conversationName: "general",
        conversationKind: .publicChannel,
        threadID: "M-MENTION",
        senderID: "U2",
        senderName: "Morgan Lee",
        text: "Please ask <@U1> to review this.",
        postedAt: fixture.message.postedAt.addingTimeInterval(60)
    )
    let unrelated = EvidenceMessage(
        id: "M-OTHER",
        conversationID: "C1",
        conversationName: "general",
        conversationKind: .publicChannel,
        threadID: "M-OTHER",
        senderID: "U2",
        senderName: "Morgan Lee",
        text: "No person selected here.",
        postedAt: fixture.message.postedAt.addingTimeInterval(120)
    )
    for message in [mentioned, unrelated] {
        _ = try await fixture.store.insert(
            message: message,
            membership: .init(
                holdID: fixture.hold.id,
                custodianID: fixture.custodian.id,
                messageID: message.id,
                sourceArchiveID: fixture.archive.id
            )
        )
    }

    var filters = SearchFilters()
    filters.personID = fixture.custodian.id
    filters.after = fixture.message.postedAt.addingTimeInterval(-1)
    filters.before = mentioned.postedAt.addingTimeInterval(1)
    let involved = try await fixture.store.search(holdID: fixture.hold.id, query: .init(filters: filters))
    #expect(involved.map(\.id) == [mentioned.id, fixture.message.id])

    let secondPage = try await fixture.store.search(
        holdID: fixture.hold.id,
        query: .init(filters: filters, limit: 1, offset: 1)
    )
    #expect(secondPage.map(\.id) == [fixture.message.id])
}

@Test func encryptedStoreExecutesAdvancedProximitySearch() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.seed()
    let results = try await fixture.store.search(
        holdID: fixture.hold.id,
        query: .init(text: #"approval NEAR/5 "legal hold""#, mode: .advanced)
    )
    #expect(results.map(\.id) == [fixture.message.id])
}

@Test func encryptedStoreExecutesUnaryNotAndQuotedFieldSearch() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.seed()
    let excluded = EvidenceMessage(
        id: "M2",
        conversationID: "C1",
        conversationName: "general",
        conversationKind: .publicChannel,
        threadID: "M2",
        senderID: "U2",
        senderName: "Morgan Lee",
        text: "This request contains fraud indicators.",
        postedAt: fixture.message.postedAt.addingTimeInterval(1)
    )
    _ = try await fixture.store.insert(
        message: excluded,
        membership: .init(
            holdID: fixture.hold.id,
            custodianID: fixture.custodian.id,
            messageID: excluded.id,
            sourceArchiveID: fixture.archive.id
        )
    )

    let notFraud = try await fixture.store.search(
        holdID: fixture.hold.id,
        query: .init(text: "NOT fraud", mode: .advanced)
    )
    #expect(notFraud.map(\.id) == [fixture.message.id])
    let named = try await fixture.store.search(
        holdID: fixture.hold.id,
        query: .init(text: #"from:"Alex Rivera" AND text:"legal hold""#, mode: .advanced)
    )
    #expect(named.map(\.id) == [fixture.message.id])
}

@Test func encryptedStoreSearchAndThreadContextEnforceActiveHoldScope() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let timestamp = fixture.message.postedAt
    var scopedHold = LegalHold(
        id: fixture.hold.id,
        organizationID: fixture.hold.organizationID,
        name: fixture.hold.name,
        status: .active,
        restrictions: [.onlyDMs],
        createdAt: fixture.hold.createdAt,
        updatedAt: fixture.hold.updatedAt,
        startAt: timestamp.addingTimeInterval(-10),
        endAt: timestamp.addingTimeInterval(10)
    )
    try await fixture.store.save(hold: scopedHold)
    try await fixture.store.replaceCustodians([fixture.custodian], holdID: scopedHold.id)
    try await fixture.store.beginImport(fixture.archive)

    let allowed = EvidenceMessage(
        id: "scope-allowed",
        conversationID: "D1",
        conversationName: "Alex Rivera",
        conversationKind: .directMessage,
        threadID: "scope-thread",
        senderID: fixture.custodian.id,
        senderName: fixture.custodian.displayName,
        text: "scope marker allowed",
        postedAt: timestamp
    )
    let publicMessage = EvidenceMessage(
        id: "scope-public",
        conversationID: "C1",
        conversationName: "general",
        conversationKind: .publicChannel,
        threadID: "scope-thread",
        senderID: fixture.custodian.id,
        senderName: fixture.custodian.displayName,
        text: "scope marker public",
        postedAt: timestamp
    )
    let lateMessage = EvidenceMessage(
        id: "scope-late",
        conversationID: "D1",
        conversationName: "Alex Rivera",
        conversationKind: .directMessage,
        threadID: "scope-thread",
        senderID: fixture.custodian.id,
        senderName: fixture.custodian.displayName,
        text: "scope marker late",
        postedAt: timestamp.addingTimeInterval(11)
    )
    for message in [allowed, publicMessage, lateMessage] {
        _ = try await fixture.store.insert(
            message: message,
            membership: .init(
                holdID: scopedHold.id,
                custodianID: fixture.custodian.id,
                messageID: message.id,
                sourceArchiveID: fixture.archive.id
            )
        )
    }
    try await fixture.store.completeImport(fixture.archive)

    #expect(try await fixture.store.search(holdID: scopedHold.id, query: .init(text: "scope marker")).map(\.id) == [allowed.id])
    #expect(try await fixture.store.thread(holdID: scopedHold.id, threadID: allowed.threadID).map(\.id) == [allowed.id])

    scopedHold.status = .released
    try await fixture.store.save(hold: scopedHold)
    #expect(try await fixture.store.search(holdID: scopedHold.id, query: .init()).isEmpty)
    #expect(try await fixture.store.thread(holdID: scopedHold.id, threadID: allowed.threadID).isEmpty)
}

@Test func encryptedStoreNormalizesUsersConversationsThreadsReactionsAndFiles() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.seed()
    var enriched = fixture.message
    enriched.reactions = [.init(name: "eyes", count: 1, userIDs: ["U2"])]
    enriched.files = [.init(
        id: "F1",
        name: "review.pdf",
        mimeType: "application/pdf",
        size: 42,
        remoteURL: URL(string: "https://files.slack.com/files-pri/F1/review.pdf")
    )]
    try await fixture.store.update(message: enriched)

    let counts = try await fixture.store.normalizedRecordCounts()
    #expect(counts.users == 2)
    #expect(counts.conversations == 1)
    #expect(counts.threads == 1)
    #expect(counts.reactions == 1)
    #expect(counts.files == 1)
}

@Test func schemaVersionOneDatabaseMigratesAndBackfillsNormalizedRecords() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ThreadLightMigration-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appending(path: "evidence.sqlite")
    let key = Data(repeating: 6, count: 32)
    let hold = LegalHold(id: "HM", organizationID: "EM", name: "Migration", status: .active, createdAt: .now, updatedAt: .now)
    let custodian = Custodian(id: "UM", holdID: hold.id, displayName: "Migration User")
    let archive = SourceArchive(
        holdID: hold.id,
        custodianID: custodian.id,
        originalFilename: "migration.zip",
        sha256: String(repeating: "b", count: 64),
        coverageStart: nil,
        coverageEnd: nil,
        operatorBinding: "Migration Test",
        isPerCustodian: true
    )
    let message = EvidenceMessage(
        id: "EM:CM:1.000001",
        conversationID: "CM",
        conversationName: "migration",
        conversationKind: .privateChannel,
        threadID: "EM:CM:1.000001",
        senderID: custodian.id,
        senderName: custodian.displayName,
        text: "migration marker",
        postedAt: Date(timeIntervalSince1970: 1),
        reactions: [.init(name: "white_check_mark", count: 1, userIDs: [custodian.id])],
        files: [.init(id: "FM", name: "migration.txt", mimeType: "text/plain")]
    )
    do {
        let original = try EvidenceStore(url: databaseURL, key: key)
        try await original.save(hold: hold)
        try await original.replaceCustodians([custodian], holdID: hold.id)
        try await original.beginImport(archive)
        _ = try await original.insert(
            message: message,
            membership: .init(holdID: hold.id, custodianID: custodian.id, messageID: message.id, sourceArchiveID: archive.id)
        )
        try await original.completeImport(archive)
    }
    await Task.yield()

    var rawDatabase: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &rawDatabase) == SQLITE_OK)
    let keyHex = key.map { String(format: "%02x", $0) }.joined()
    let downgradeSQL = """
    PRAGMA key = "x'\(keyHex)'";
    DROP TABLE import_checkpoints;
    DROP INDEX idx_source_archives_hash;
    DROP TABLE evidence_files;
    DROP TABLE reactions;
    DROP TABLE threads;
    DROP TABLE conversations;
    DROP TABLE users;
    ALTER TABLE memberships DROP COLUMN source_message_sha256;
    ALTER TABLE messages DROP COLUMN organization_id;
    ALTER TABLE source_archives DROP COLUMN sha256;
    PRAGMA user_version = 1;
    """
    #expect(sqlite3_exec(rawDatabase, downgradeSQL, nil, nil, nil) == SQLITE_OK)
    #expect(sqlite3_close(rawDatabase) == SQLITE_OK)

    let migrated = try EvidenceStore(url: databaseURL, key: key)
    let counts = try await migrated.normalizedRecordCounts()
    #expect(counts.users == 1)
    #expect(counts.conversations == 1)
    #expect(counts.threads == 1)
    #expect(counts.reactions == 1)
    #expect(counts.files == 1)
    #expect(try await migrated.search(holdID: hold.id, query: .init(text: "migration marker")).map(\.id) == [message.id])
}

@Test func wrongDatabaseKeyCannotReadEvidence() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.seed()
    #expect(throws: (any Error).self) {
        _ = try EvidenceStore(url: fixture.databaseURL, key: Data(repeating: 9, count: 32))
    }
}

@Test func importerReadsSlackMemberExportAndPreservesProvenance() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.store.save(hold: fixture.hold)
    try await fixture.store.replaceCustodians([fixture.custodian], holdID: fixture.hold.id)
    let zip = try fixture.makeSlackExport()
    let report = try await SlackExportImporter(store: fixture.store).importArchive(
        url: zip,
        hold: fixture.hold,
        custodian: fixture.custodian,
        operatorBinding: "Legal Reviewer",
        confirmedPerCustodian: true
    )
    #expect(report.messagesImported == 1)
    #expect(report.source.sha256.count == 64)
    let results = try await fixture.store.search(holdID: fixture.hold.id, query: .init(text: "approval"))
    #expect(results.count == 1)
    #expect(results[0].id == "E1:C1:1785542400.000100")
    #expect(results[0].threadID == results[0].id)
    #expect(results[0].senderAvatarURL == URL(string: "https://avatars.slack-edge.com/test.png"))
    let memberships = try await fixture.store.memberships(messageID: results[0].id, holdID: fixture.hold.id)
    #expect(memberships.first?.sourceMessageSHA256.count == 64)
}

@Test func importerAcceptsNestedHoldWideSlackMetadataWithNoMessages() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.store.save(hold: fixture.hold)
    try await fixture.store.replaceCustodians([fixture.custodian], holdID: fixture.hold.id)
    let zipURL = fixture.root.appending(path: "nested-empty.zip")
    let archive = try Archive(url: zipURL, accessMode: .create, pathEncoding: nil)
    for (path, data) in [
        ("teams/acme/users.json", Data(#"[{"id":"U1","profile":{"real_name":"Alex Rivera"}}]"#.utf8)),
        ("teams/acme/channels.json", Data("[]".utf8)),
        ("teams/acme/groups.json", Data("[]".utf8)),
    ] {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { offset, size in
            data.subdata(in: Int(offset)..<min(Int(offset) + size, data.count))
        }
    }
    let report = try await SlackExportImporter(store: fixture.store).importHoldArchive(
        url: zipURL,
        hold: fixture.hold,
        operatorBinding: "IT Operator"
    )
    #expect(report.messagesImported == 0)
    #expect(report.source.isPerCustodian == false)
    #expect(report.warnings.contains { $0.contains("metadata but no conversation messages") })
    #expect(try await fixture.store.archives(holdID: fixture.hold.id).count == 1)
}

@Test func optionalRealSlackExportFixtureImportsAsHoldWideData() async throws {
    guard let path = ProcessInfo.processInfo.environment["THREADLIGHT_SAMPLE_ZIP"] else { return }
    let root = FileManager.default.temporaryDirectory.appending(path: "ThreadLightRealFixture-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try EvidenceStore(url: root.appending(path: "evidence.sqlite"), key: Data(repeating: 4, count: 32))
    let hold = LegalHold(
        id: "H-REAL-FIXTURE",
        organizationID: "E-REAL-FIXTURE",
        name: "Real export fixture",
        status: .active,
        createdAt: .now,
        updatedAt: .now
    )
    try await store.save(hold: hold)
    let report = try await SlackExportImporter(store: store).importHoldArchive(
        url: URL(fileURLWithPath: path),
        hold: hold,
        operatorBinding: "Fixture Test"
    )
    #expect(report.source.isPerCustodian == false)
    #expect(report.messagesImported == 0)
    #expect(report.warnings.contains { $0.contains("metadata but no conversation messages") })
}

@Test func optionalRealSlackMessageExportFixtureImportsRootAndNestedLayouts() async throws {
    guard let path = ProcessInfo.processInfo.environment["THREADLIGHT_SAMPLE_ZIP_2"] else { return }
    let root = FileManager.default.temporaryDirectory.appending(path: "ThreadLightRealMessageFixture-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try EvidenceStore(url: root.appending(path: "evidence.sqlite"), key: Data(repeating: 5, count: 32))
    let hold = LegalHold(
        id: "H-REAL-MESSAGE-FIXTURE",
        organizationID: "E-REAL-MESSAGE-FIXTURE",
        name: "Real message export fixture",
        status: .active,
        createdAt: .now,
        updatedAt: .now
    )
    try await store.save(hold: hold)
    let report = try await SlackExportImporter(store: store).importHoldArchive(
        url: URL(fileURLWithPath: path),
        hold: hold,
        operatorBinding: "Fixture Test"
    )
    #expect(report.source.isPerCustodian == false)
    #expect(report.messagesImported > 0)
    #expect(try await store.search(holdID: hold.id, query: .init()).count > 0)
}

@Test func encryptedHoldTransferAutoMatchesAndImportsNormalizedEvidence() async throws {
    let source = try StoreFixture()
    defer { source.cleanup() }
    try await source.seed()
    let transferURL = source.root.appending(path: "case.threadlight-hold")
    _ = try await HoldTransferService(store: source.store).export(
        hold: source.hold,
        custodians: [source.custodian],
        destination: transferURL
    )
    let bytes = try Data(contentsOf: transferURL)
    #expect(bytes.range(of: Data(source.hold.id.utf8)) == nil)
    #expect(bytes.range(of: Data(source.custodian.id.utf8)) == nil)

    let destinationURL = source.root.appending(path: "legal.sqlite")
    let destination = try EvidenceStore(url: destinationURL, key: Data(repeating: 8, count: 32))
    let result = try await HoldTransferService(store: destination).importTransfer(
        url: transferURL,
        candidates: [.init(hold: source.hold, custodians: [source.custodian])]
    )
    #expect(result.hold.id == source.hold.id)
    #expect(result.archivesImported == 1)
    #expect(try await destination.search(holdID: source.hold.id, query: .init(text: "approval")).count == 1)

    let changed = Custodian(id: "different-member", holdID: source.hold.id, displayName: "Different")
    let otherDestination = try EvidenceStore(
        url: source.root.appending(path: "wrong.sqlite"),
        key: Data(repeating: 7, count: 32)
    )
    await #expect(throws: ThreadLightError.self) {
        _ = try await HoldTransferService(store: otherDestination).importTransfer(
            url: transferURL,
            candidates: [.init(hold: source.hold, custodians: [changed])]
        )
    }
}

@Test func passphraseProtectedHoldTransferResistsCorrectHoldIdentifiers() async throws {
    let source = try StoreFixture()
    defer { source.cleanup() }
    try await source.seed()
    let passphrase = "correct horse battery staple"
    let transferURL = source.root.appending(path: "protected.threadlight-hold")
    _ = try await HoldTransferService(store: source.store).export(
        hold: source.hold,
        custodians: [source.custodian],
        destination: transferURL,
        passphrase: passphrase
    )
    #expect(try HoldTransferService.requiresPassphrase(url: transferURL))

    let candidates = [HoldTransferCandidate(hold: source.hold, custodians: [source.custodian])]

    // The whole point: knowing the hold and member IDs is no longer enough.
    await #expect(throws: ThreadLightError.self) {
        _ = try await HoldTransferService(store: try EvidenceStore(
            url: source.root.appending(path: "nopass.sqlite"),
            key: Data(repeating: 5, count: 32)
        )).importTransfer(url: transferURL, candidates: candidates)
    }
    await #expect(throws: ThreadLightError.self) {
        _ = try await HoldTransferService(store: try EvidenceStore(
            url: source.root.appending(path: "wrongpass.sqlite"),
            key: Data(repeating: 6, count: 32)
        )).importTransfer(url: transferURL, candidates: candidates, passphrase: "wrong passphrase entirely")
    }

    let destination = try EvidenceStore(
        url: source.root.appending(path: "legal.sqlite"),
        key: Data(repeating: 8, count: 32)
    )
    let result = try await HoldTransferService(store: destination).importTransfer(
        url: transferURL,
        candidates: candidates,
        passphrase: passphrase
    )
    #expect(result.hold.id == source.hold.id)
    #expect(try await destination.search(holdID: source.hold.id, query: .init(text: "approval")).count == 1)
}

@Test func holdTransferRejectsShortPassphraseAndMismatchedProtectionMode() async throws {
    let source = try StoreFixture()
    defer { source.cleanup() }
    try await source.seed()
    let service = HoldTransferService(store: source.store)

    await #expect(throws: ThreadLightError.self) {
        _ = try await service.export(
            hold: source.hold,
            custodians: [source.custodian],
            destination: source.root.appending(path: "short.threadlight-hold"),
            passphrase: "tooshort"
        )
    }

    let openURL = source.root.appending(path: "open.threadlight-hold")
    _ = try await service.export(hold: source.hold, custodians: [source.custodian], destination: openURL)
    #expect(try HoldTransferService.requiresPassphrase(url: openURL) == false)

    // Supplying a passphrase for an unprotected package is a mistake worth naming, not ignoring.
    await #expect(throws: ThreadLightError.self) {
        _ = try await HoldTransferService(store: try EvidenceStore(
            url: source.root.appending(path: "surprise.sqlite"),
            key: Data(repeating: 9, count: 32)
        )).importTransfer(
            url: openURL,
            candidates: [.init(hold: source.hold, custodians: [source.custodian])],
            passphrase: "unexpected passphrase"
        )
    }
}

@Test func changedHoldMembershipPurgesLocalEvidence() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.seed()
    #expect(try await fixture.store.purgeEvidence(holdID: fixture.hold.id))
    #expect(try await fixture.store.archives(holdID: fixture.hold.id).isEmpty)
    #expect(try await fixture.store.search(holdID: fixture.hold.id, query: .init()).isEmpty)
}

@Test func importerAcceptsEnterpriseOrgUsersMetadata() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.store.save(hold: fixture.hold)
    try await fixture.store.replaceCustodians([fixture.custodian], holdID: fixture.hold.id)
    let zip = try fixture.makeEnterpriseSlackExport()
    let report = try await SlackExportImporter(store: fixture.store).importArchive(
        url: zip,
        hold: fixture.hold,
        custodian: fixture.custodian,
        operatorBinding: "Legal Reviewer",
        confirmedPerCustodian: true
    )
    #expect(report.messagesImported == 1)
    #expect(report.warnings.contains { $0.contains("outside conversations proven by Slack metadata") })
    let results = try await fixture.store.search(holdID: fixture.hold.id, query: .init(text: "enterprise"))
    #expect(results.count == 1)
    #expect(results[0].senderName == "Alex Rivera")
    #expect(results[0].files.first?.size == nil)
    #expect(try await fixture.store.search(holdID: fixture.hold.id, query: .init(text: "injected")).isEmpty)
    #expect(try await fixture.store.search(holdID: fixture.hold.id, query: .init(text: "invalid timestamp")).isEmpty)
}

@Test func streamingJSONArrayParserHandlesChunkBoundariesEscapesAndNesting() throws {
    let data = Data(#"[{"text":"brace } [ and quote \" and snowman ☃","nested":[{"ok":true}]},{"text":"second"}]"#.utf8)
    var parser = JSONArrayObjectParser(maximumObjectBytes: 1_024 * 1_024)
    var rows: [[String: Any]] = []
    var offset = 0
    while offset < data.count {
        let end = min(offset + 3, data.count)
        rows.append(contentsOf: try parser.consume(data.subdata(in: offset..<end), path: "chunked.json"))
        offset = end
    }
    try parser.finish(path: "chunked.json")
    #expect(rows.count == 2)
    #expect((rows[0]["text"] as? String)?.contains("snowman") == true)
    #expect((rows[1]["text"] as? String) == "second")
}

@Test func streamingJSONArrayParserRejectsMalformedAndOversizedObjects() throws {
    var malformed = JSONArrayObjectParser(maximumObjectBytes: 1_024)
    #expect(throws: (any Error).self) {
        _ = try malformed.consume(Data(#"[{"text":"one"},]"#.utf8), path: "malformed.json")
    }
    var oversized = JSONArrayObjectParser(maximumObjectBytes: 8)
    #expect(throws: (any Error).self) {
        _ = try oversized.consume(Data(#"[{"text":"too large"}]"#.utf8), path: "oversized.json")
    }
}

@Test func importerGroupsRepliesWhenRootHasClientMessageID() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.store.save(hold: fixture.hold)
    try await fixture.store.replaceCustodians([fixture.custodian], holdID: fixture.hold.id)
    let zip = try fixture.makeSlackThreadExport()
    _ = try await SlackExportImporter(store: fixture.store).importArchive(
        url: zip,
        hold: fixture.hold,
        custodian: fixture.custodian,
        operatorBinding: "Legal Reviewer",
        confirmedPerCustodian: true
    )

    let results = try await fixture.store.search(holdID: fixture.hold.id, query: .init(text: "thread"))
    #expect(results.count == 2)
    let root = try #require(results.first { $0.text == "thread root" })
    let reply = try #require(results.first { $0.text == "thread reply" })
    #expect(root.threadID == root.id)
    #expect(reply.threadID == root.id)
    #expect(try await fixture.store.thread(holdID: fixture.hold.id, threadID: root.id).count == 2)
    var threaded = SearchFilters()
    threaded.isThread = true
    #expect(try await fixture.store.search(holdID: fixture.hold.id, query: .init(filters: threaded)).map(\.id) == [reply.id])
}

@Test func importerRejectsDuplicateAndHostileArchives() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.store.save(hold: fixture.hold)
    try await fixture.store.replaceCustodians([fixture.custodian], holdID: fixture.hold.id)
    let zip = try fixture.makeSlackExport()
    let importer = SlackExportImporter(store: fixture.store)
    _ = try await importer.importArchive(
        url: zip,
        hold: fixture.hold,
        custodian: fixture.custodian,
        operatorBinding: "Legal Reviewer",
        confirmedPerCustodian: true
    )
    await #expect(throws: (any Error).self) {
        _ = try await importer.importArchive(
            url: zip,
            hold: fixture.hold,
            custodian: fixture.custodian,
            operatorBinding: "Legal Reviewer",
            confirmedPerCustodian: true
        )
    }

    let hostileURL = fixture.root.appending(path: "hostile.zip")
    let hostile = try Archive(url: hostileURL, accessMode: .create, pathEncoding: nil)
    let payload = Data("[]".utf8)
    for path in ["users.json", "channels.json"] {
        try hostile.addEntry(with: path, type: .file, uncompressedSize: Int64(payload.count)) { offset, size in
            payload.subdata(in: Int(offset)..<min(Int(offset) + size, payload.count))
        }
    }
    try hostile.addEntry(with: "../escape.json", type: .file, uncompressedSize: Int64(payload.count)) { offset, size in
        payload.subdata(in: Int(offset)..<min(Int(offset) + size, payload.count))
    }
    await #expect(throws: (any Error).self) {
        _ = try await importer.importArchive(
            url: hostileURL,
            hold: fixture.hold,
            custodian: fixture.custodian,
            operatorBinding: "Legal Reviewer",
            confirmedPerCustodian: true
        )
    }

    let collisionURL = fixture.root.appending(path: "case-collision.zip")
    let collision = try Archive(url: collisionURL, accessMode: .create, pathEncoding: nil)
    for path in ["users.json", "USERS.JSON", "channels.json", "general/2026-08-01.json"] {
        try collision.addEntry(with: path, type: .file, uncompressedSize: Int64(payload.count)) { offset, size in
            payload.subdata(in: Int(offset)..<min(Int(offset) + size, payload.count))
        }
    }
    await #expect(throws: (any Error).self) {
        _ = try await importer.importArchive(
            url: collisionURL,
            hold: fixture.hold,
            custodian: fixture.custodian,
            operatorBinding: "Legal Reviewer",
            confirmedPerCustodian: true
        )
    }

    let conflictingUsersURL = fixture.root.appending(path: "conflicting-users.zip")
    let conflictingUsers = try Archive(url: conflictingUsersURL, accessMode: .create, pathEncoding: nil)
    let conflictingPayloads: [(String, Data)] = [
        ("users.json", Data(#"[{"id":"U1","profile":{"real_name":"Alex"}},{"id":"U1","profile":{"real_name":"Mallory"}}]"#.utf8)),
        ("channels.json", Data(#"[{"id":"C1","name":"general"}]"#.utf8)),
        ("general/2026-08-01.json", Data(#"[{"user":"U1","text":"message","ts":"1785542400.000100"}]"#.utf8)),
    ]
    for (path, data) in conflictingPayloads {
        try conflictingUsers.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { offset, size in
            data.subdata(in: Int(offset)..<min(Int(offset) + size, data.count))
        }
    }
    await #expect(throws: ThreadLightError.self) {
        _ = try await importer.importArchive(
            url: conflictingUsersURL,
            hold: fixture.hold,
            custodian: fixture.custodian,
            operatorBinding: "Legal Reviewer",
            confirmedPerCustodian: true
        )
    }
}

@Test func importerRejectsMalformedSlackConversationJSON() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.store.save(hold: fixture.hold)
    try await fixture.store.replaceCustodians([fixture.custodian], holdID: fixture.hold.id)
    let zip = try fixture.makeMalformedSlackExport()
    await #expect(throws: (any Error).self) {
        _ = try await SlackExportImporter(store: fixture.store).importArchive(
            url: zip,
            hold: fixture.hold,
            custodian: fixture.custodian,
            operatorBinding: "Legal Reviewer",
            confirmedPerCustodian: true
        )
    }
    #expect(try await fixture.store.archives(holdID: fixture.hold.id).isEmpty)
}

@Test func importerEnforcesEntryExpandedJSONAndSymlinkLimits() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.store.save(hold: fixture.hold)
    try await fixture.store.replaceCustodians([fixture.custodian], holdID: fixture.hold.id)
    let zip = try fixture.makeSlackExport()

    for configure in [
        { (limits: inout SlackExportImporter.Limits) in limits.maximumEntries = 2 },
        { (limits: inout SlackExportImporter.Limits) in limits.maximumExpandedBytes = 1 },
        { (limits: inout SlackExportImporter.Limits) in limits.maximumJSONBytes = 1 },
    ] {
        var limits = SlackExportImporter.Limits()
        configure(&limits)
        await #expect(throws: (any Error).self) {
            _ = try await SlackExportImporter(store: fixture.store, limits: limits).importArchive(
                url: zip,
                hold: fixture.hold,
                custodian: fixture.custodian,
                operatorBinding: "Legal Reviewer",
                confirmedPerCustodian: true
            )
        }
    }

    let symlinkURL = fixture.root.appending(path: "symlink.zip")
    let symlinkArchive = try Archive(url: symlinkURL, accessMode: .create, pathEncoding: nil)
    let empty = Data("[]".utf8)
    for path in ["users.json", "channels.json", "general/2026-08-01.json"] {
        try symlinkArchive.addEntry(with: path, type: .file, uncompressedSize: Int64(empty.count)) { offset, size in
            empty.subdata(in: Int(offset)..<min(Int(offset) + size, empty.count))
        }
    }
    let target = Data("users.json".utf8)
    try symlinkArchive.addEntry(with: "unsafe-link", type: .symlink, uncompressedSize: Int64(target.count)) { offset, size in
        target.subdata(in: Int(offset)..<min(Int(offset) + size, target.count))
    }
    await #expect(throws: (any Error).self) {
        _ = try await SlackExportImporter(store: fixture.store).importArchive(
            url: symlinkURL,
            hold: fixture.hold,
            custodian: fixture.custodian,
            operatorBinding: "Legal Reviewer",
            confirmedPerCustodian: true
        )
    }
}

@Test func importerHonorsCancellationWithoutLeavingACompletedArchive() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.store.save(hold: fixture.hold)
    try await fixture.store.replaceCustodians([fixture.custodian], holdID: fixture.hold.id)
    let zip = try fixture.makeSlackExport()
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await SlackExportImporter(store: fixture.store).importArchive(
            url: zip,
            hold: fixture.hold,
            custodian: fixture.custodian,
            operatorBinding: "Legal Reviewer",
            confirmedPerCustodian: true
        )
    }
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(try await fixture.store.archives(holdID: fixture.hold.id).isEmpty)
}

@Test func importerResumesFromCheckpointWithoutExposingPartialEvidence() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.store.save(hold: fixture.hold)
    try await fixture.store.replaceCustodians([fixture.custodian], holdID: fixture.hold.id)
    let zip = try fixture.makeSlackThreadExport()
    let cancelling = SlackExportImporter(store: fixture.store) { _ in
        withUnsafeCurrentTask { $0?.cancel() }
    }
    let interrupted = Task {
        try await cancelling.importArchive(
            url: zip,
            hold: fixture.hold,
            custodian: fixture.custodian,
            operatorBinding: "Legal Reviewer",
            confirmedPerCustodian: true
        )
    }
    await #expect(throws: CancellationError.self) {
        _ = try await interrupted.value
    }
    #expect(try await fixture.store.archives(holdID: fixture.hold.id).isEmpty)
    #expect(try await fixture.store.search(holdID: fixture.hold.id, query: .init(text: "thread")).isEmpty)
    let digest = try SHA256Digest.file(url: zip)
    #expect(try await fixture.store.resumableImport(sha256: digest, holdID: fixture.hold.id) != nil)

    let report = try await SlackExportImporter(store: fixture.store).importArchive(
        url: zip,
        hold: fixture.hold,
        custodian: fixture.custodian,
        operatorBinding: "Legal Reviewer",
        confirmedPerCustodian: true
    )
    #expect(report.messagesImported == 2)
    #expect(try await fixture.store.archives(holdID: fixture.hold.id).count == 1)
    #expect(try await fixture.store.search(holdID: fixture.hold.id, query: .init(text: "thread")).count == 2)
    #expect(try await fixture.store.resumableImport(sha256: digest, holdID: fixture.hold.id) == nil)
}

@Test func importerRejectsSameArchiveBoundToDifferentCustodians() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let second = Custodian(id: "U2", holdID: fixture.hold.id, displayName: "Morgan Lee")
    try await fixture.store.save(hold: fixture.hold)
    try await fixture.store.replaceCustodians([fixture.custodian, second], holdID: fixture.hold.id)
    let zip = try fixture.makeSlackExport()
    let importer = SlackExportImporter(store: fixture.store)
    _ = try await importer.importArchive(
        url: zip,
        hold: fixture.hold,
        custodian: fixture.custodian,
        operatorBinding: "Legal Reviewer",
        confirmedPerCustodian: true
    )
    await #expect(throws: (any Error).self) {
        _ = try await importer.importArchive(
            url: zip,
            hold: fixture.hold,
            custodian: second,
            operatorBinding: "Legal Reviewer",
            confirmedPerCustodian: true
        )
    }
}

@Test func evidencePackageSignsAndVerifies() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.seed()
    let exporter = EvidenceExporter(store: fixture.store, signer: EphemeralSignatureProvider())
    let result = try await exporter.export(
        messages: [fixture.message],
        hold: fixture.hold,
        custodians: [fixture.custodian],
        destination: fixture.root
    )
    #expect(try EvidenceExporter.verify(packageURL: result.packageURL))
    #expect(FileManager.default.fileExists(atPath: result.packageURL.appending(path: "evidence.pdf").path))
    let linkedPackage = fixture.root.appending(path: "linked.threadlight-evidence")
    try FileManager.default.createSymbolicLink(at: linkedPackage, withDestinationURL: result.packageURL)
    #expect(try EvidenceExporter.verify(packageURL: linkedPackage) == false)
    let signatureURL = result.packageURL.appending(path: "manifest.threadlight-signature.json")
    let envelope = try CanonicalJSON.decoder.decode(SignatureEnvelope.self, from: Data(contentsOf: signatureURL))
    let changedTimestamp = SignatureEnvelope(
        schemaVersion: envelope.schemaVersion,
        algorithm: envelope.algorithm,
        keyID: envelope.keyID,
        publicKey: envelope.publicKey,
        manifestSHA256: envelope.manifestSHA256,
        signature: envelope.signature,
        signedAt: envelope.signedAt.addingTimeInterval(60)
    )
    try CanonicalJSON.encode(changedTimestamp).write(to: signatureURL, options: .atomic)
    #expect(try EvidenceExporter.verify(packageURL: result.packageURL) == false)
    try CanonicalJSON.encode(envelope).write(to: signatureURL, options: .atomic)
    #expect(try EvidenceExporter.verify(packageURL: result.packageURL))
    var noncanonicalEnvelope = try Data(contentsOf: signatureURL)
    noncanonicalEnvelope.append(0x0A)
    try noncanonicalEnvelope.write(to: signatureURL, options: .atomic)
    #expect(try EvidenceExporter.verify(packageURL: result.packageURL) == false)
    try CanonicalJSON.encode(envelope).write(to: signatureURL, options: .atomic)
    let unexpectedDirectory = result.packageURL.appending(path: "unexpected", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: unexpectedDirectory, withIntermediateDirectories: false)
    #expect(throws: ThreadLightError.self) { try EvidenceExporter.verify(packageURL: result.packageURL) }
    try FileManager.default.removeItem(at: unexpectedDirectory)
    try "undeclared".write(to: result.packageURL.appending(path: "extra.txt"), atomically: true, encoding: .utf8)
    #expect(try EvidenceExporter.verify(packageURL: result.packageURL) == false)
}

@Test func evidenceVerifierRejectsSignedUnsupportedAndInconsistentManifests() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.seed()
    let signer = EphemeralSignatureProvider()
    let result = try await EvidenceExporter(store: fixture.store, signer: signer).export(
        messages: [fixture.message],
        hold: fixture.hold,
        custodians: [fixture.custodian],
        destination: fixture.root,
        formats: [.json]
    )
    let original = try CanonicalJSON.decoder.decode(EvidenceManifest.self, from: Data(contentsOf: result.manifestURL))
    let signatureURL = result.packageURL.appending(path: "manifest.threadlight-signature.json")

    let unsupported = EvidenceManifest(
        schemaVersion: 2,
        exportID: original.exportID,
        createdAt: original.createdAt,
        application: original.application,
        hold: original.hold,
        items: original.items,
        sources: original.sources,
        files: original.files,
        warnings: original.warnings
    )
    let unsupportedData = try CanonicalJSON.encode(unsupported)
    try unsupportedData.write(to: result.manifestURL, options: .atomic)
    let unsupportedSignature = try await signer.sign(manifest: unsupportedData)
    try CanonicalJSON.encode(unsupportedSignature).write(to: signatureURL, options: .atomic)
    #expect(try EvidenceExporter.verify(packageURL: result.packageURL) == false)

    let item = try #require(original.items.first)
    let inconsistent = EvidenceManifest(
        schemaVersion: 1,
        exportID: original.exportID,
        createdAt: original.createdAt,
        application: original.application,
        hold: original.hold,
        items: [.init(
            messageID: item.messageID,
            conversationID: item.conversationID,
            threadID: item.threadID,
            postedAt: item.postedAt,
            sha256: item.sha256,
            sourceArchiveID: item.sourceArchiveID,
            custodianID: "different-custodian"
        )],
        sources: original.sources,
        files: original.files,
        warnings: original.warnings
    )
    let inconsistentData = try CanonicalJSON.encode(inconsistent)
    try inconsistentData.write(to: result.manifestURL, options: .atomic)
    let inconsistentSignature = try await signer.sign(manifest: inconsistentData)
    try CanonicalJSON.encode(inconsistentSignature).write(to: signatureURL, options: .atomic)
    #expect(try EvidenceExporter.verify(packageURL: result.packageURL) == false)

    let invalidHoldWideBinding = EvidenceManifest(
        schemaVersion: 1,
        exportID: original.exportID,
        createdAt: original.createdAt,
        application: original.application,
        hold: original.hold,
        items: original.items,
        sources: original.sources.map {
            SourceArchive(
                id: $0.id,
                holdID: $0.holdID,
                custodianID: $0.custodianID,
                originalFilename: $0.originalFilename,
                sha256: $0.sha256,
                importedAt: $0.importedAt,
                coverageStart: $0.coverageStart,
                coverageEnd: $0.coverageEnd,
                operatorBinding: $0.operatorBinding,
                isPerCustodian: false
            )
        },
        files: original.files,
        warnings: original.warnings
    )
    let invalidHoldWideData = try CanonicalJSON.encode(invalidHoldWideBinding)
    try invalidHoldWideData.write(to: result.manifestURL, options: .atomic)
    let invalidHoldWideSignature = try await signer.sign(manifest: invalidHoldWideData)
    try CanonicalJSON.encode(invalidHoldWideSignature).write(to: signatureURL, options: .atomic)
    #expect(try EvidenceExporter.verify(packageURL: result.packageURL) == false)
}

@Test func evidenceExportFailsClosedWhenCustodianArchivesDisagreeOnMessageBytes() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.seed()
    let secondCustodian = Custodian(id: "U2", holdID: fixture.hold.id, displayName: "Morgan Lee")
    let secondArchive = SourceArchive(
        holdID: fixture.hold.id,
        custodianID: secondCustodian.id,
        originalFilename: "morgan.zip",
        sha256: String(repeating: "c", count: 64),
        coverageStart: nil,
        coverageEnd: nil,
        operatorBinding: "Reviewer",
        isPerCustodian: true
    )
    try await fixture.store.replaceCustodians([fixture.custodian, secondCustodian], holdID: fixture.hold.id)
    try await fixture.store.beginImport(secondArchive)
    var conflicting = fixture.message
    conflicting.text = "A later export contains different Slack message bytes."
    conflicting.rawJSON = Data(#"{"ts":"1785542400","text":"different"}"#.utf8)
    _ = try await fixture.store.insert(
        message: conflicting,
        membership: .init(
            holdID: fixture.hold.id,
            custodianID: secondCustodian.id,
            messageID: conflicting.id,
            sourceArchiveID: secondArchive.id
        )
    )
    try await fixture.store.completeImport(secondArchive)

    let memberships = try await fixture.store.memberships(messageID: fixture.message.id, holdID: fixture.hold.id)
    #expect(Set(memberships.map(\.sourceMessageSHA256)).count == 2)
    do {
        _ = try await EvidenceExporter(store: fixture.store, signer: EphemeralSignatureProvider()).export(
            messages: [fixture.message],
            hold: fixture.hold,
            custodians: [fixture.custodian, secondCustodian],
            destination: fixture.root
        )
        Issue.record("Expected conflicting source representations to block export")
    } catch let ThreadLightError.scope(message) {
        #expect(message.contains("differs across source ZIPs"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func evidenceExportHonorsFormatChoiceAndMatchesPublishedManifestSchema() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.seed()
    let exporter = EvidenceExporter(store: fixture.store, signer: EphemeralSignatureProvider())

    let jsonResult = try await exporter.export(
        messages: [fixture.message],
        hold: fixture.hold,
        custodians: [fixture.custodian],
        destination: fixture.root,
        formats: [.json]
    )
    #expect(FileManager.default.fileExists(atPath: jsonResult.packageURL.appending(path: "evidence.json").path))
    #expect(!FileManager.default.fileExists(atPath: jsonResult.packageURL.appending(path: "evidence.pdf").path))
    #expect(try EvidenceExporter.verify(packageURL: jsonResult.packageURL))

    let manifestObject = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: jsonResult.manifestURL)) as? [String: Any]
    )
    let schemaURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/ThreadLightCore/Resources/schemas/manifest.schema.json")
    let schema = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as? [String: Any])
    let properties = try #require(schema["properties"] as? [String: Any])
    let required = Set(try #require(schema["required"] as? [String]))
    #expect(Set(manifestObject.keys).isSubset(of: Set(properties.keys)))
    #expect(required.isSubset(of: Set(manifestObject.keys)))
    #expect((manifestObject["application"] as? String)?.contains("ThreadLight") == true)

    let pdfResult = try await exporter.export(
        messages: [fixture.message],
        hold: fixture.hold,
        custodians: [fixture.custodian],
        destination: fixture.root,
        formats: [.pdf]
    )
    #expect(FileManager.default.fileExists(atPath: pdfResult.packageURL.appending(path: "evidence.pdf").path))
    #expect(!FileManager.default.fileExists(atPath: pdfResult.packageURL.appending(path: "evidence.json").path))
    #expect(try EvidenceExporter.verify(packageURL: pdfResult.packageURL))
}

@Test func unsignedEvidenceExportWritesOnlyRequestedFlatFiles() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.seed()

    let result = try await EvidenceExporter(
        store: fixture.store,
        signer: EphemeralSignatureProvider()
    ).exportFiles(
        messages: [fixture.message],
        hold: fixture.hold,
        custodians: [fixture.custodian],
        destination: fixture.root,
        formats: [.pdf, .json]
    )

    #expect(result.fileURLs.map(\.pathExtension) == ["pdf", "json"])
    #expect(result.fileURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    #expect(try #require(PDFDocument(url: result.fileURLs[0])).pageCount > 0)
    let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result.fileURLs[1])) as? [String: Any])
    #expect(json["schemaVersion"] as? Int == 1)
    let contents = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: [.isDirectoryKey])
    #expect(!contents.contains { $0.pathExtension == "threadlight-evidence" })
    #expect(!contents.contains { $0.lastPathComponent == "manifest.json" || $0.lastPathComponent == "manifest.threadlight-signature.json" })
}

@Test func conversationPDFExportWritesTheExactSavePanelDestination() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.seed()
    let destination = fixture.root.appending(path: "chosen-conversation.pdf")

    let result = try await EvidenceExporter(
        store: fixture.store,
        signer: EphemeralSignatureProvider()
    ).exportPDF(
        messages: [fixture.message],
        hold: fixture.hold,
        custodians: [fixture.custodian],
        destination: destination
    )

    #expect(result == destination)
    #expect(try #require(PDFDocument(url: destination)).pageCount > 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "manifest.json").path))
}

@Test func jsonExportWritesTheExactSavePanelDestination() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.seed()
    let destination = fixture.root.appending(path: "chosen-evidence.json")

    let result = try await EvidenceExporter(
        store: fixture.store,
        signer: EphemeralSignatureProvider()
    ).exportJSON(
        messages: [fixture.message],
        hold: fixture.hold,
        custodians: [fixture.custodian],
        destination: destination
    )

    #expect(result == destination)
    let document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any])
    let messages = try #require(document["messages"] as? [[String: Any]])
    #expect(messages.compactMap { $0["id"] as? String } == [fixture.message.id])
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "manifest.json").path))
}

@Test func evidencePDFRemainsVisibleWhenRenderedFromDarkMode() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ThreadLightPDF-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "dark-mode.pdf")
    let hold = LegalHold(id: "H-DARK", organizationID: "E1", name: "Visible Hold", status: .active, createdAt: .now, updatedAt: .now)
    let message = EvidenceMessage(id: "M-DARK", conversationID: "C1", conversationName: "general", conversationKind: .publicChannel, threadID: "M-DARK", senderID: "U1", senderName: "Alex", text: "Visible evidence text", postedAt: .now)

    var renderError: Error?
    try #require(NSAppearance(named: .darkAqua)).performAsCurrentDrawingAppearance {
        do {
            try PDFRenderer.render(messages: [message], hold: hold, to: destination)
        } catch {
            renderError = error
        }
    }
    if let renderError { throw renderError }
    let pdf = try #require(PDFDocument(url: destination))
    let page = try #require(pdf.page(at: 0))
    let thumbnail = page.thumbnail(of: CGSize(width: 306, height: 396), for: .mediaBox)
    let bitmap = try #require(thumbnail.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
    var darkSamples = 0
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if color.alphaComponent > 0.5, color.brightnessComponent < 0.7 {
                darkSamples += 1
            }
        }
    }
    #expect(darkSamples > 50)
}

@Test func holdWideSlackPackageExportsMultipleMessagesAsVerifiedPDF() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.store.save(hold: fixture.hold)
    try await fixture.store.replaceCustodians([fixture.custodian], holdID: fixture.hold.id)
    _ = try await SlackExportImporter(store: fixture.store).importHoldArchive(
        url: fixture.makeSlackThreadExport(),
        hold: fixture.hold,
        operatorBinding: "Slack Administrator"
    )
    let messages = try await fixture.store.search(holdID: fixture.hold.id, query: .init(text: ""))
    #expect(messages.count == 2)

    let result = try await EvidenceExporter(
        store: fixture.store,
        signer: EphemeralSignatureProvider()
    ).export(
        messages: messages,
        hold: fixture.hold,
        custodians: [fixture.custodian],
        destination: fixture.root,
        formats: [.pdf]
    )
    let manifest = try CanonicalJSON.decoder.decode(EvidenceManifest.self, from: Data(contentsOf: result.manifestURL))
    #expect(manifest.sources.allSatisfy { !$0.isPerCustodian && $0.custodianID == "threadlight:hold-wide" })
    #expect(try EvidenceExporter.verify(packageURL: result.packageURL))
}

@Test func evidenceManifestCarriesCoverageAndMissingCustodianWarnings() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.seed()
    var boundedHold = fixture.hold
    boundedHold.startAt = fixture.message.postedAt.addingTimeInterval(-60)
    boundedHold.endAt = fixture.message.postedAt.addingTimeInterval(60)
    try await fixture.store.save(hold: boundedHold)
    let missing = Custodian(id: "U2", holdID: boundedHold.id, displayName: "Morgan Lee")
    var messageWithUnavailableFile = fixture.message
    messageWithUnavailableFile.files = [.init(
        id: "F-unavailable",
        name: "linked-only.pdf",
        mimeType: "application/pdf",
        remoteURL: URL(string: "https://files.slack.com/linked-only.pdf")
    )]
    try await fixture.store.update(message: messageWithUnavailableFile)

    let result = try await EvidenceExporter(
        store: fixture.store,
        signer: EphemeralSignatureProvider()
    ).export(
        messages: [messageWithUnavailableFile],
        hold: boundedHold,
        custodians: [fixture.custodian, missing],
        destination: fixture.root,
        formats: [.json]
    )
    let manifest = try CanonicalJSON.decoder.decode(EvidenceManifest.self, from: Data(contentsOf: result.manifestURL))
    #expect(!manifest.warnings.contains { $0.contains("Morgan Lee") })
    #expect(manifest.warnings.contains { $0.contains("no provable start-date coverage") })
    #expect(manifest.warnings.contains { $0.contains("no provable end-date coverage") })
    #expect(manifest.warnings.contains { $0.contains("Original bytes unavailable") })
    #expect(try EvidenceExporter.verify(packageURL: result.packageURL))
}

@Test func evidencePDFPaginatesWithoutClippingLongMessages() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.seed()
    var longMessage = fixture.message
    longMessage.text = (0..<1_500).map { "Evidence line \($0)" }.joined(separator: "\n") + "\nTAIL-MARKER-THREADLIGHT"
    try await fixture.store.update(message: longMessage)
    let result = try await EvidenceExporter(store: fixture.store, signer: EphemeralSignatureProvider()).export(
        messages: [longMessage],
        hold: fixture.hold,
        custodians: [fixture.custodian],
        destination: fixture.root
    )
    let pdf = try #require(PDFDocument(url: result.packageURL.appending(path: "evidence.pdf")))
    #expect(pdf.pageCount > 1)
    #expect(pdf.string?.contains("TAIL-MARKER-THREADLIGHT") == true)
}

@Test func importedAttachmentIsEncryptedIndexedAndIncludedInEvidence() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.seed()
    let originalURL = fixture.root.appending(path: "contract.txt")
    let original = Data("confidential attachment text".utf8)
    try original.write(to: originalURL)
    let vault = try ResourceVault(root: fixture.root.appending(path: "vault"), keyData: Data(repeating: 5, count: 32))
    let metadata = EvidenceFile(id: "F1", name: "contract.txt", mimeType: "text/plain")
    let imported = try await vault.importResource(url: originalURL, replacing: metadata)
    var message = fixture.message
    message.files = [imported]
    try await fixture.store.update(message: message)

    let search = try await fixture.store.search(holdID: fixture.hold.id, query: .init(text: "confidential"))
    #expect(search.map(\.id) == [message.id])
    let exporter = EvidenceExporter(store: fixture.store, signer: EphemeralSignatureProvider(), resourceVault: vault)
    let result = try await exporter.export(messages: [message], hold: fixture.hold, custodians: [fixture.custodian], destination: fixture.root)
    #expect(try EvidenceExporter.verify(packageURL: result.packageURL))
    let resources = try FileManager.default.contentsOfDirectory(at: result.packageURL.appending(path: "resources"), includingPropertiesForKeys: nil)
    #expect(resources.count == 1)
    #expect(try Data(contentsOf: resources[0]) == original)
}

@Test func importedAttachmentMustMatchSlackByteCountAndPreservesSlackMetadata() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let originalURL = fixture.root.appending(path: "operator-download.txt")
    let original = Data("original Slack attachment".utf8)
    try original.write(to: originalURL)
    let vault = try ResourceVault(root: fixture.root.appending(path: "attachment-vault"), keyData: Data(repeating: 9, count: 32))
    let remoteURL = URL(string: "https://files.slack.com/files-pri/T1-F1/original.txt")
    let metadata = EvidenceFile(
        id: "F1",
        name: "original-slack-name.txt",
        mimeType: "text/plain",
        size: Int64(original.count),
        remoteURL: remoteURL
    )
    let imported = try await vault.importResource(url: originalURL, replacing: metadata)
    #expect(imported.name == metadata.name)
    #expect(imported.mimeType == metadata.mimeType)
    #expect(imported.size == metadata.size)
    #expect(imported.remoteURL == remoteURL)
    #expect(imported.sha256 != nil)

    let mismatch = EvidenceFile(id: "F2", name: "wrong.txt", size: Int64(original.count + 1))
    await #expect(throws: ThreadLightError.self) {
        _ = try await vault.importResource(url: originalURL, replacing: mismatch)
    }
}

@Test func resourceVaultRejectsUnsafeStoredPaths() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let vault = try ResourceVault(root: fixture.root.appending(path: "safe-vault"), keyData: Data(repeating: 4, count: 32))
    let hostile = EvidenceFile(
        id: "F-hostile",
        name: "outside.txt",
        localRelativePath: "../outside.txt",
        sha256: String(repeating: "a", count: 64)
    )
    await #expect(throws: ThreadLightError.self) {
        _ = try await vault.cleartext(for: hostile)
    }
}

@Test func textExtractorCoversEveryDocumentTypePromisedByTheUI() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ThreadLightExtraction-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let plainFiles: [(String, String, String)] = [
        ("sample.txt", "TXT extraction marker", "TXT extraction marker"),
        ("sample.csv", "column\nCSV extraction marker", "CSV extraction marker"),
        ("sample.json", #"{"value":"JSON extraction marker"}"#, "JSON extraction marker"),
        ("sample.rtf", #"{\rtf1\ansi RTF extraction marker}"#, "RTF extraction marker"),
    ]
    for (name, content, marker) in plainFiles {
        let url = root.appending(path: name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        #expect(try TextExtractor.extract(url: url)?.contains(marker) == true)
    }

    let officeFiles: [(String, String, String)] = [
        ("sample.docx", "word/document.xml", #"<w:document><w:body><w:p><w:r><w:t>DOCX extraction marker</w:t></w:r></w:p></w:body></w:document>"#),
        ("sample.xlsx", "xl/sharedStrings.xml", #"<sst><si><t>XLSX extraction marker</t></si></sst>"#),
        ("sample.pptx", "ppt/slides/slide1.xml", #"<p:sld><p:cSld><a:t>PPTX extraction marker</a:t></p:cSld></p:sld>"#),
    ]
    for (name, entryPath, xml) in officeFiles {
        let url = root.appending(path: name)
        let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        let data = Data(xml.utf8)
        try archive.addEntry(with: entryPath, type: .file, uncompressedSize: Int64(data.count)) { offset, size in
            data.subdata(in: Int(offset)..<min(Int(offset) + size, data.count))
        }
        let marker = name.split(separator: ".").last!.uppercased() + " extraction marker"
        #expect(try TextExtractor.extract(url: url)?.contains(marker) == true)
    }

    let pdfURL = root.appending(path: "sample.pdf")
    let hold = LegalHold(id: "H-PDF", organizationID: "E1", name: "PDF extraction", status: .active, createdAt: .now, updatedAt: .now)
    let message = EvidenceMessage(id: "M-PDF", conversationID: "C1", conversationName: "general", conversationKind: .publicChannel, threadID: "M-PDF", senderID: "U1", senderName: "Alex", text: "PDF extraction marker", postedAt: .now)
    try PDFRenderer.render(messages: [message], hold: hold, to: pdfURL)
    #expect(try TextExtractor.extract(url: pdfURL)?.contains("PDF extraction marker") == true)
}

@Test func fullLocalWorkflowImportsSearchesExportsAndDetectsTampering() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    try await fixture.store.save(hold: fixture.hold)
    try await fixture.store.replaceCustodians([fixture.custodian], holdID: fixture.hold.id)
    let report = try await SlackExportImporter(store: fixture.store).importArchive(
        url: fixture.makeSlackThreadExport(),
        hold: fixture.hold,
        custodian: fixture.custodian,
        operatorBinding: "Legal Reviewer",
        confirmedPerCustodian: true
    )
    #expect(report.messagesImported == 2)

    let root = try #require(try await fixture.store.search(
        holdID: fixture.hold.id,
        query: .init(text: #"text:"thread root" AND NOT text:reply"#, mode: .advanced)
    ).first)
    let attachmentURL = fixture.root.appending(path: "evidence-note.txt")
    try "local attachment search marker".write(to: attachmentURL, atomically: true, encoding: .utf8)
    let vault = try ResourceVault(root: fixture.root.appending(path: "workflow-vault"), keyData: Data(repeating: 3, count: 32))
    var enriched = root
    enriched.files = [try await vault.importResource(
        url: attachmentURL,
        replacing: .init(id: "F-workflow", name: "evidence-note.txt", mimeType: "text/plain")
    )]
    try await fixture.store.update(message: enriched)
    #expect(try await fixture.store.search(holdID: fixture.hold.id, query: .init(text: "marker")).map(\.id) == [enriched.id])

    let result = try await EvidenceExporter(
        store: fixture.store,
        signer: EphemeralSignatureProvider(),
        resourceVault: vault
    ).export(messages: [enriched], hold: fixture.hold, custodians: [fixture.custodian], destination: fixture.root)
    #expect(try EvidenceExporter.verify(packageURL: result.packageURL))
    let evidenceURL = result.packageURL.appending(path: "evidence.json")
    var tampered = try Data(contentsOf: evidenceURL)
    tampered.append(0x20)
    try tampered.write(to: evidenceURL)
    #expect(try EvidenceExporter.verify(packageURL: result.packageURL) == false)
}

private final class StoreFixture: @unchecked Sendable {
    let root: URL
    let databaseURL: URL
    let store: EvidenceStore
    let hold: LegalHold
    let custodian: Custodian
    let archive: SourceArchive
    let message: EvidenceMessage

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ThreadLightTests-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = root.appending(path: "evidence.sqlite")
        store = try EvidenceStore(url: databaseURL, key: Data(repeating: 7, count: 32))
        hold = .init(id: "H1", organizationID: "E1", name: "Investigation", status: .active, createdAt: .now, updatedAt: .now)
        custodian = .init(id: "U1", holdID: "H1", displayName: "Alex Rivera")
        archive = .init(holdID: "H1", custodianID: "U1", originalFilename: "alex.zip", sha256: String(repeating: "a", count: 64), coverageStart: nil, coverageEnd: nil, operatorBinding: "Reviewer", isPerCustodian: true)
        message = .init(id: "M1", conversationID: "C1", conversationName: "general", conversationKind: .publicChannel, threadID: "C1:1", senderID: "U1", senderName: "Alex Rivera", text: "Please provide approval for the legal hold.", postedAt: Date(timeIntervalSince1970: 1_785_542_400))
    }

    func seed() async throws {
        try await store.save(hold: hold)
        try await store.replaceCustodians([custodian], holdID: hold.id)
        try await store.beginImport(archive)
        _ = try await store.insert(message: message, membership: .init(holdID: hold.id, custodianID: custodian.id, messageID: message.id, sourceArchiveID: archive.id))
        try await store.completeImport(archive)
    }

    func makeSlackExport() throws -> URL {
        let source = root.appending(path: "slack", directoryHint: .isDirectory)
        let channel = source.appending(path: "general", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: channel, withIntermediateDirectories: true)
        try #"[{"id":"U1","name":"alex","profile":{"real_name":"Alex Rivera","image_72":"https://avatars.slack-edge.com/test.png"}}]"#.write(to: source.appending(path: "users.json"), atomically: true, encoding: .utf8)
        try #"[{"id":"C1","name":"general"}]"#.write(to: source.appending(path: "channels.json"), atomically: true, encoding: .utf8)
        try #"[{"client_msg_id":"M2","user":"U1","text":"approval recorded","ts":"1785542400.000100"}]"#.write(to: channel.appending(path: "2026-08-01.json"), atomically: true, encoding: .utf8)
        let zip = root.appending(path: "slack-export.zip")
        try FileManager.default.zipItem(at: source, to: zip, shouldKeepParent: false)
        return zip
    }

    func makeSlackThreadExport() throws -> URL {
        let source = root.appending(path: "slack-thread", directoryHint: .isDirectory)
        let channel = source.appending(path: "general", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: channel, withIntermediateDirectories: true)
        try #"[{"id":"U1","name":"alex","profile":{"real_name":"Alex Rivera"}}]"#.write(to: source.appending(path: "users.json"), atomically: true, encoding: .utf8)
        try #"[{"id":"C1","name":"general"}]"#.write(to: source.appending(path: "channels.json"), atomically: true, encoding: .utf8)
        try #"[{"client_msg_id":"root-client-id","user":"U1","text":"thread root","ts":"1785542400.000100"},{"client_msg_id":"reply-client-id","user":"U1","text":"thread reply","ts":"1785542401.000200","thread_ts":"1785542400.000100"}]"#.write(to: channel.appending(path: "2026-08-01.json"), atomically: true, encoding: .utf8)
        let zip = root.appending(path: "slack-thread-export.zip")
        try FileManager.default.zipItem(at: source, to: zip, shouldKeepParent: false)
        return zip
    }

    func makeEnterpriseSlackExport() throws -> URL {
        let source = root.appending(path: "slack-enterprise", directoryHint: .isDirectory)
        let channel = source.appending(path: "general", directoryHint: .isDirectory)
        let auxiliary = source.appending(path: "content_flags", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: channel, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: auxiliary, withIntermediateDirectories: true)
        try #"[{"id":"U1","team_id":"E1","profile":{"real_name":"Alex Rivera"}}]"#.write(to: source.appending(path: "org_users.json"), atomically: true, encoding: .utf8)
        try #"[{"id":"C1","name":"general"}]"#.write(to: source.appending(path: "channels.json"), atomically: true, encoding: .utf8)
        try #"[{"user":"U1","text":"enterprise export message","ts":"1785542400.000100","files":[{"id":"F1","name":"linked.txt","size":-1}]},{"user":"U1","text":"invalid timestamp","ts":"NaN"}]"#.write(to: channel.appending(path: "2026-08-01.json"), atomically: true, encoding: .utf8)
        try #"[{"user":"U1","text":"injected auxiliary record","ts":"1785542400.000200"}]"#.write(to: auxiliary.appending(path: "2026-08-01.json"), atomically: true, encoding: .utf8)
        let zip = root.appending(path: "slack-enterprise-export.zip")
        try FileManager.default.zipItem(at: source, to: zip, shouldKeepParent: false)
        return zip
    }

    func makeMalformedSlackExport() throws -> URL {
        let source = root.appending(path: "slack-malformed", directoryHint: .isDirectory)
        let channel = source.appending(path: "general", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: channel, withIntermediateDirectories: true)
        try #"[{"id":"U1","profile":{"real_name":"Alex Rivera"}}]"#.write(to: source.appending(path: "users.json"), atomically: true, encoding: .utf8)
        try #"[{"id":"C1","name":"general"}]"#.write(to: source.appending(path: "channels.json"), atomically: true, encoding: .utf8)
        try #"{"not":"an array"}"#.write(to: channel.appending(path: "2026-08-01.json"), atomically: true, encoding: .utf8)
        let zip = root.appending(path: "slack-malformed-export.zip")
        try FileManager.default.zipItem(at: source, to: zip, shouldKeepParent: false)
        return zip
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
