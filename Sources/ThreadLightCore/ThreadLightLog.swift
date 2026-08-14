import Foundation
import os
import OSLog

/// Diagnostic logging for the long-running operations a user cannot otherwise observe.
///
/// ThreadLight handles legal evidence, so nothing here may record message text, custodian
/// identities, file names, passphrases, or anything else derived from a hold's contents.
/// Log stage transitions, counts, durations, and error categories only. Counts are marked
/// public so a support transcript is readable; every string stays private by default.
///
/// Anything needed to diagnose a run after the fact must be logged at `notice` or higher.
/// The unified log keeps `info` and `debug` in memory only and evicts them within minutes,
/// so per-archive progress recorded at `info` is already gone by the time someone asks what
/// happened. Reserve `info` for breadcrumbs that are worthless once the moment has passed.
///
/// Read a session back with:
///
///     log show --predicate 'subsystem == "dev.threadlight.app"' --last 1h --info
public enum ThreadLightLog {
    public static let subsystem = "dev.threadlight.app"

    /// Slack archive normalization into the encrypted store.
    public static let importer = Logger(subsystem: subsystem, category: "import")
    /// Encrypted hold-package export and import.
    public static let transfer = Logger(subsystem: subsystem, category: "transfer")
    /// Sign-in, hold refresh, and storage lifecycle, which can interrupt the two above.
    public static let session = Logger(subsystem: subsystem, category: "session")

    /// This process's own recent log entries, formatted for an error report. Reading the
    /// current-process store needs no special entitlement, and by this subsystem's logging
    /// policy the entries carry stages, counts, and categories — never evidence content.
    /// The report embedding them is still shown to the operator before anything is shared.
    public static func recentLogLines(minutes: Int = 30, limit: Int = 40) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let position = store.position(date: Date().addingTimeInterval(-Double(minutes) * 60))
        guard let entries = try? store.getEntries(at: position) else { return [] }
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        for entry in entries {
            guard let log = entry as? OSLogEntryLog, log.subsystem == subsystem else { continue }
            lines.append("\(formatter.string(from: log.date)) [\(log.category)] \(log.composedMessage)")
        }
        return Array(lines.suffix(limit))
    }

    /// Categorizes an error without emitting its message, which may quote evidence.
    public static func category(of error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard let threadLight = error as? ThreadLightError else {
            let nsError = error as NSError
            return "\(nsError.domain)#\(nsError.code)"
        }
        switch threadLight {
        case .archive: return "archive"
        case .duplicateArchive: return "duplicateArchive"
        case .authentication: return "authentication"
        case .database: return "database"
        case .export: return "export"
        case .invalidConfiguration: return "invalidConfiguration"
        case .scope: return "scope"
        case .slack: return "slack"
        }
    }
}
