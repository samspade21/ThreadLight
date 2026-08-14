import Darwin
import Foundation
import Testing
import ZIPFoundation
@testable import ThreadLightCore

@Test func optInLargeSlackArchiveImportAndSearchPerformance() async throws {
    guard let rawCount = ProcessInfo.processInfo.environment["THREADLIGHT_PERFORMANCE_MESSAGES"],
          let messageCount = Int(rawCount),
          messageCount > 0 else { return }

    let persistentDatabase = ProcessInfo.processInfo.environment["THREADLIGHT_PERFORMANCE_DATABASE"].map(URL.init(fileURLWithPath:))
    let root = persistentDatabase?.deletingLastPathComponent()
        ?? FileManager.default.temporaryDirectory.appending(path: "ThreadLightPerformance-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let removeRootWhenFinished = persistentDatabase == nil
    defer { if removeRootWhenFinished { try? FileManager.default.removeItem(at: root) } }
    let databaseURL = persistentDatabase ?? root.appending(path: "performance.sqlite")
    let reuseDatabase = ProcessInfo.processInfo.environment["THREADLIGHT_PERFORMANCE_REUSE_DATABASE"] == "1"
        && FileManager.default.fileExists(atPath: databaseURL.path)
    let store = try EvidenceStore(url: databaseURL, key: Data(repeating: 8, count: 32))
    let hold = LegalHold(id: "H-PERF", organizationID: "E-PERF", name: "Performance", status: .active, createdAt: .now, updatedAt: .now)
    let custodian = Custodian(id: "U-PERF", holdID: hold.id, displayName: "Performance Custodian")
    if !reuseDatabase {
        try await store.save(hold: hold)
        try await store.replaceCustodians([custodian], holdID: hold.id)
    }

    var importSeconds = 0.0
    if !reuseDatabase {
        let zipURL: URL
        if let external = ProcessInfo.processInfo.environment["THREADLIGHT_PERFORMANCE_ARCHIVE"] {
            zipURL = URL(fileURLWithPath: external)
        } else {
            zipURL = root.appending(path: "performance-export-\(UUID()).zip")
            try makeArchive(at: zipURL, messageCount: messageCount)
        }
        let importStarted = Date()
        let report = try await SlackExportImporter(store: store).importArchive(
            url: zipURL,
            hold: hold,
            custodian: custodian,
            operatorBinding: "Performance Test",
            confirmedPerCustodian: true
        )
        importSeconds = Date().timeIntervalSince(importStarted)
        #expect(report.messagesImported == messageCount)
    }

    let holdOpenStarted = Date()
    let attachmentsStarted = Date()
    let attachmentAvailability = try await store.attachmentAvailability(holdID: hold.id)
    let attachmentSeconds = Date().timeIntervalSince(attachmentsStarted)
    let conversationsStarted = Date()
    let conversations = try await store.conversations(holdID: hold.id)
    let conversationSeconds = Date().timeIntervalSince(conversationsStarted)
    let initialMessagesStarted = Date()
    let initialMessages = try await store.search(holdID: hold.id, query: .init(limit: 501))
    let initialMessageSeconds = Date().timeIntervalSince(initialMessagesStarted)
    let holdOpenSeconds = Date().timeIntervalSince(holdOpenStarted)
    #expect(attachmentAvailability == (referenced: 0, available: 0))
    #expect(conversations.count == 1)
    #expect(initialMessages.count == min(501, messageCount))
    #expect(holdOpenSeconds < 2)

    let searchStarted = Date()
    let matches = try await store.search(holdID: hold.id, query: .init(text: "needle", limit: 10))
    let searchSeconds = Date().timeIntervalSince(searchStarted)
    #expect(!matches.isEmpty)
    #expect(searchSeconds < 2)
    var resourceUsage = rusage()
    #expect(getrusage(RUSAGE_SELF, &resourceUsage) == 0)
    let peakResidentBytes = Int64(resourceUsage.ru_maxrss)
    #expect(peakResidentBytes < 1_024 * 1_024 * 1_024)
    print("ThreadLight performance: \(messageCount) messages; import \(String(format: "%.2f", importSeconds))s; hold open \(String(format: "%.3f", holdOpenSeconds))s [attachments \(String(format: "%.3f", attachmentSeconds))s, conversations \(String(format: "%.3f", conversationSeconds))s, messages \(String(format: "%.3f", initialMessageSeconds))s]; search \(String(format: "%.3f", searchSeconds))s; peak RSS \(peakResidentBytes) bytes; swaps \(resourceUsage.ru_nswap)")
}

private func add(_ data: Data, path: String, to archive: Archive) throws {
    try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { offset, size in
        data.subdata(in: Int(offset)..<min(Int(offset) + size, data.count))
    }
}

private func makeArchive(at url: URL, messageCount: Int) throws {
    let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
    try add(Data(#"[{"id":"U-PERF","profile":{"real_name":"Performance Custodian"}}]"#.utf8), path: "users.json", to: archive)
    try add(Data(#"[{"id":"C-PERF","name":"performance"}]"#.utf8), path: "channels.json", to: archive)
    let messagesPerFile = 2_000
    for fileIndex in 0..<Int(ceil(Double(messageCount) / Double(messagesPerFile))) {
        var rows: [String] = []
        rows.reserveCapacity(messagesPerFile)
        let lower = fileIndex * messagesPerFile
        let upper = min(lower + messagesPerFile, messageCount)
        for index in lower..<upper {
            let marker = index.isMultiple(of: 25_000) ? " needle" : ""
            let timestamp = String(format: "%.6f", 1_700_000_000 + Double(index) / 1_000)
            rows.append(#"{"user":"U-PERF","text":"performance message \#(index)\#(marker)","ts":"\#(timestamp)"}"#)
        }
        let data = Data(("[" + rows.joined(separator: ",") + "]").utf8)
        let year = 2020 + fileIndex / (12 * 28)
        let month = (fileIndex / 28) % 12 + 1
        let day = fileIndex % 28 + 1
        guard year <= 9_999 else { throw ThreadLightError.archive("Performance fixture has too many dated Slack files.") }
        let date = String(format: "%04d-%02d-%02d", year, month, day)
        try add(data, path: "performance/\(date).json", to: archive)
    }
}
