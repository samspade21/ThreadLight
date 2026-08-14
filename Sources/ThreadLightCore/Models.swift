import CryptoKit
import Foundation

public enum ThreadLightBuild {
    #if THREADLIGHT_DEVELOPMENT
    public static let isDevelopment = true
    #else
    public static let isDevelopment = false
    #endif

    public static var applicationIdentity: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info["CFBundleVersion"] as? String ?? "1"
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.threadlight.app"
        return "ThreadLight \(version) (\(build)); \(bundleID)" + (isDevelopment ? "; development" : "")
    }

    public static func storageNamespace(organizationID: String) -> String {
        let label = organizationID
            .replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let digest = SHA256.hash(data: Data(organizationID.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        let environment = isDevelopment ? "development" : "production"
        return "\(environment)-\(String((label.isEmpty ? "unknown" : label).prefix(32)))-\(digest)"
    }

    public static func isValidStorageNamespace(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

public enum UserRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case legal
    case slackAdministrator

    public var id: String { rawValue }
    public var title: String { self == .legal ? "Legal Role (Legal Holds admin)" : "IT Role" }
}

public enum SetupRequirementID: String, Codable, CaseIterable, Identifiable, Sendable {
    case internalApp
    case pkce
    case readScope
    case enterpriseInstall
    case exportAccess
    case custodianExports
    case attachments

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .internalApp: "Internal Slack app"
        case .pkce: "Secure OAuth callback"
        case .readScope: "Legal Holds read access"
        case .enterpriseInstall: "Enterprise installation"
        case .exportAccess: "Custom export access"
        case .custodianExports: "Slack export ZIPs"
        case .attachments: "Attachment files"
        }
    }

    public static let administratorRequirements: [SetupRequirementID] = [
        .internalApp, .pkce, .readScope, .enterpriseInstall, .exportAccess,
    ]
}

public enum SetupRequirementState: Codable, Equatable, Sendable {
    case pending
    case blocked(reason: String)
    case ready
    case notApplicable

    public var isReady: Bool {
        if case .ready = self { return true }
        if case .notApplicable = self { return true }
        return false
    }

    private enum CodingKeys: String, CodingKey { case kind, reason }
    private enum Kind: String, Codable { case pending, blocked, ready, notApplicable }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .pending: self = .pending
        case .blocked: self = .blocked(reason: try container.decode(String.self, forKey: .reason))
        case .ready: self = .ready
        case .notApplicable: self = .notApplicable
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pending: try container.encode(Kind.pending, forKey: .kind)
        case let .blocked(reason):
            try container.encode(Kind.blocked, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .ready: try container.encode(Kind.ready, forKey: .kind)
        case .notApplicable: try container.encode(Kind.notApplicable, forKey: .kind)
        }
    }
}

public struct SetupRequirement: Identifiable, Codable, Equatable, Sendable {
    public let id: SetupRequirementID
    public var state: SetupRequirementState
    public var detail: String
    public var why: String
    public var owner: UserRole
    public var actionURL: URL?

    public init(
        id: SetupRequirementID,
        state: SetupRequirementState = .pending,
        detail: String,
        why: String,
        owner: UserRole,
        actionURL: URL? = nil
    ) {
        self.id = id
        self.state = state
        self.detail = detail
        self.why = why
        self.owner = owner
        self.actionURL = actionURL
    }
}

public enum HoldStatus: String, Codable, CaseIterable, Sendable {
    case active = "ACTIVE"
    case released = "RELEASED"
    case unknown = "UNKNOWN"
}

public enum HoldRestriction: String, Codable, Sendable {
    case noRestriction = "NO_RESTRICTION"
    case onlyDMs = "ONLY_DMS"
}

public struct LegalHold: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let organizationID: String
    public var name: String
    public var summary: String
    public var status: HoldStatus
    public var restrictions: Set<HoldRestriction>
    public var createdAt: Date
    public var updatedAt: Date
    public var startAt: Date?
    public var endAt: Date?

    public init(
        id: String,
        organizationID: String,
        name: String,
        summary: String = "",
        status: HoldStatus,
        restrictions: Set<HoldRestriction> = [.noRestriction],
        createdAt: Date,
        updatedAt: Date,
        startAt: Date? = nil,
        endAt: Date? = nil
    ) {
        self.id = id
        self.organizationID = organizationID
        self.name = name
        self.summary = summary
        self.status = status
        self.restrictions = restrictions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startAt = startAt
        self.endAt = endAt
    }
}

public struct Custodian: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let holdID: String
    public var displayName: String
    public var email: String?
    public var avatarURL: URL?
    public var isCurrent: Bool

    public init(
        id: String,
        holdID: String,
        displayName: String,
        email: String? = nil,
        avatarURL: URL? = nil,
        isCurrent: Bool = true
    ) {
        self.id = id
        self.holdID = holdID
        self.displayName = displayName
        self.email = email
        self.avatarURL = avatarURL
        self.isCurrent = isCurrent
    }
}

public enum ConversationKind: String, Codable, CaseIterable, Sendable {
    case publicChannel
    case privateChannel
    case directMessage
    case groupDirectMessage
    case unknown

    public var isDirect: Bool { self == .directMessage || self == .groupDirectMessage }
}

public struct EvidenceConversation: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: ConversationKind
    public let messageCount: Int
    public let lastPostedAt: Date

    public init(id: String, name: String, kind: ConversationKind, messageCount: Int, lastPostedAt: Date) {
        self.id = id
        self.name = name
        self.kind = kind
        self.messageCount = messageCount
        self.lastPostedAt = lastPostedAt
    }
}

public struct EvidenceFile: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var mimeType: String?
    public var size: Int64?
    public var remoteURL: URL?
    public var localRelativePath: String?
    public var sha256: String?
    public var extractedText: String?

    public init(
        id: String,
        name: String,
        mimeType: String? = nil,
        size: Int64? = nil,
        remoteURL: URL? = nil,
        localRelativePath: String? = nil,
        sha256: String? = nil,
        extractedText: String? = nil
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.remoteURL = remoteURL
        self.localRelativePath = localRelativePath
        self.sha256 = sha256
        self.extractedText = extractedText
    }

    public var hasOriginalBytes: Bool { localRelativePath != nil }
}

public struct EvidenceReaction: Codable, Hashable, Sendable {
    public let name: String
    public let count: Int
    public let userIDs: [String]

    public init(name: String, count: Int, userIDs: [String] = []) {
        self.name = name
        self.count = count
        self.userIDs = userIDs
    }
}

public struct EvidenceMessage: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var conversationID: String
    public var conversationName: String
    public var conversationKind: ConversationKind
    public var threadID: String
    public var senderID: String
    public var senderName: String
    public var senderAvatarURL: URL?
    public var text: String
    public var postedAt: Date
    public var editedAt: Date?
    public var isDeleted: Bool
    public var reactions: [EvidenceReaction]?
    public var files: [EvidenceFile]
    public var rawJSON: Data

    public init(
        id: String,
        conversationID: String,
        conversationName: String,
        conversationKind: ConversationKind,
        threadID: String,
        senderID: String,
        senderName: String,
        senderAvatarURL: URL? = nil,
        text: String,
        postedAt: Date,
        editedAt: Date? = nil,
        isDeleted: Bool = false,
        reactions: [EvidenceReaction]? = nil,
        files: [EvidenceFile] = [],
        rawJSON: Data = Data()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.conversationName = conversationName
        self.conversationKind = conversationKind
        self.threadID = threadID
        self.senderID = senderID
        self.senderName = senderName
        self.senderAvatarURL = senderAvatarURL
        self.text = text
        self.postedAt = postedAt
        self.editedAt = editedAt
        self.isDeleted = isDeleted
        self.reactions = reactions
        self.files = files
        self.rawJSON = rawJSON
    }
}

public struct SourceArchive: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let holdID: String
    public let custodianID: String
    public let originalFilename: String
    public let sha256: String
    public let importedAt: Date
    public let coverageStart: Date?
    public let coverageEnd: Date?
    public let operatorBinding: String
    public let isPerCustodian: Bool

    public init(
        id: UUID = UUID(),
        holdID: String,
        custodianID: String,
        originalFilename: String,
        sha256: String,
        importedAt: Date = Date(),
        coverageStart: Date?,
        coverageEnd: Date?,
        operatorBinding: String,
        isPerCustodian: Bool
    ) {
        self.id = id
        self.holdID = holdID
        self.custodianID = custodianID
        self.originalFilename = originalFilename
        self.sha256 = sha256
        self.importedAt = importedAt
        self.coverageStart = coverageStart
        self.coverageEnd = coverageEnd
        self.operatorBinding = operatorBinding
        self.isPerCustodian = isPerCustodian
    }
}

public struct HoldMembership: Codable, Hashable, Sendable {
    public let holdID: String
    public let custodianID: String
    public let messageID: String
    public let sourceArchiveID: UUID
    public let sourceMessageSHA256: String

    public init(
        holdID: String,
        custodianID: String,
        messageID: String,
        sourceArchiveID: UUID,
        sourceMessageSHA256: String = ""
    ) {
        self.holdID = holdID
        self.custodianID = custodianID
        self.messageID = messageID
        self.sourceArchiveID = sourceArchiveID
        self.sourceMessageSHA256 = sourceMessageSHA256
    }
}

public struct EvidenceImportRecord: Sendable {
    public let message: EvidenceMessage
    public let membership: HoldMembership

    public init(message: EvidenceMessage, membership: HoldMembership) {
        self.message = message
        self.membership = membership
    }
}

public enum HoldAccessKey {
    public static func fingerprint(hold: LegalHold, custodians: [Custodian]) -> String {
        let memberIDs = custodians
            .filter { $0.holdID == hold.id && $0.isCurrent }
            .map(\.id)
            .sorted()
        let material = ([hold.organizationID, hold.id] + memberIDs).joined(separator: "\n")
        return SHA256Digest.data(Data(material.utf8))
    }
}

public enum SearchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case basic
    case advanced
    public var id: String { rawValue }
}

public struct SearchFilters: Codable, Equatable, Sendable {
    public var sender: String?
    public var personID: String?
    public var custodianID: String?
    public var conversationID: String?
    public var conversation: String?
    public var after: Date?
    public var before: Date?
    public var kind: ConversationKind?
    public var hasAttachment: Bool?
    public var fileType: String?
    public var isThread: Bool?
    public var isEdited: Bool?
    public var isDeleted: Bool?

    public init() {}
}

public struct SearchQuery: Codable, Equatable, Sendable {
    public var text: String
    public var mode: SearchMode
    public var filters: SearchFilters
    public var limit: Int
    public var offset: Int

    public init(text: String = "", mode: SearchMode = .basic, filters: SearchFilters = .init(), limit: Int = 500, offset: Int = 0) {
        self.text = text
        self.mode = mode
        self.filters = filters
        self.limit = min(max(limit, 1), 2_000)
        self.offset = max(offset, 0)
    }
}

public enum EvidenceExportFormat: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case json
    case pdf

    public var id: String { rawValue }
}

public enum ScopeBlockReason: String, Codable, Sendable {
    case releasedHold
    case holdStatusUnverified
    case missingCustodian
    case custodianNotCurrent
    case outsideDateRange
    case conversationRestricted
    case untrustedArchive
    case ambiguousMembership
    case conflictingSourceRecords
    case resourceUnavailable
}

public enum ScopeDecision: Codable, Equatable, Sendable {
    case eligible
    case blocked(reason: ScopeBlockReason, detail: String)

    public var canExport: Bool {
        if case .eligible = self { return true }
        return false
    }

    public var remediation: String? {
        guard case let .blocked(reason, _) = self else { return nil }
        return switch reason {
        case .releasedHold: "Select an active hold. Released holds cannot be reopened by ThreadLight."
        case .holdStatusUnverified: "Reconnect Slack. ThreadLight must receive an ACTIVE hold status before search or export."
        case .missingCustodian, .custodianNotCurrent: "Reconnect Slack and import an export for a current hold custodian."
        case .outsideDateRange: "Choose evidence whose timestamp falls inside the hold window."
        case .conversationRestricted: "Choose a conversation type covered by the hold."
        case .untrustedArchive: "Ask IT for a new encrypted transfer created from valid Slack export ZIPs."
        case .ambiguousMembership: "Re-import the source ZIP and bind it to the correct current custodian."
        case .conflictingSourceRecords: "Compare the untouched source ZIPs and resolve which Slack representation must be produced."
        case .resourceUnavailable: "Import the original attachment bytes or export message metadata with the warning."
        }
    }
}

public struct ImportReport: Codable, Sendable {
    public let source: SourceArchive
    public let messagesImported: Int
    public let messagesDeduplicated: Int
    public let filesReferenced: Int
    public let warnings: [String]
}

public struct ImportProgress: Sendable {
    public let sourceArchiveID: UUID
    public let messagesProcessed: Int
    public let filesReferenced: Int

    public init(sourceArchiveID: UUID, messagesProcessed: Int, filesReferenced: Int) {
        self.sourceArchiveID = sourceArchiveID
        self.messagesProcessed = messagesProcessed
        self.filesReferenced = filesReferenced
    }
}

public enum ThreadLightError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case authentication(String)
    case slack(String, remediation: String)
    case archive(String)
    case database(String)
    case scope(String)
    case export(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message), let .authentication(message), let .archive(message),
             let .database(message), let .scope(message), let .export(message): message
        case let .slack(message, _): message
        }
    }
}
