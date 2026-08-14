import Foundation
import os

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
