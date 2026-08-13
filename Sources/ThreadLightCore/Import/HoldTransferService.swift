import CryptoKit
import Foundation

public struct HoldTransferCandidate: Sendable {
    public let hold: LegalHold
    public let custodians: [Custodian]

    public init(hold: LegalHold, custodians: [Custodian]) {
        self.hold = hold
        self.custodians = custodians
    }
}

public struct HoldTransferResult: Sendable {
    public let hold: LegalHold
    public let archivesImported: Int
    public let messagesImported: Int
}

public struct HoldTransferService: Sendable {
    private static let magic = Data("THREADLIGHT-HOLD-1\n".utf8)
    private static let maximumBytes = 2 * 1_024 * 1_024 * 1_024
    private let store: EvidenceStore

    public init(store: EvidenceStore) {
        self.store = store
    }

    public func export(
        hold: LegalHold,
        custodians: [Custodian],
        destination: URL
    ) async throws -> URL {
        guard hold.status == .active else {
            throw ThreadLightError.export("Only an active legal hold can be transferred.")
        }
        let snapshot = try await store.transferSnapshot(
            hold: hold,
            custodians: custodians,
            fingerprint: HoldAccessKey.fingerprint(hold: hold, custodians: custodians)
        )
        let cleartext = try CanonicalJSON.encode(snapshot)
        guard cleartext.count <= Self.maximumBytes else {
            throw ThreadLightError.export("The normalized hold payload exceeds the 2 GB transfer limit.")
        }
        let salt = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let key = Self.key(hold: hold, custodians: custodians, salt: salt)
        guard let sealed = try AES.GCM.seal(cleartext, using: key).combined else {
            throw ThreadLightError.export("Could not encrypt the hold transfer.")
        }
        var output = Self.magic
        output.append(salt)
        output.append(sealed)
        try output.write(to: destination, options: [.atomic, .completeFileProtection])
        return destination
    }

    public func importTransfer(
        url: URL,
        candidates: [HoldTransferCandidate]
    ) async throws -> HoldTransferResult {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > Self.magic.count + 32,
              size <= Self.maximumBytes + 1_024 else {
            throw ThreadLightError.archive("Choose a regular ThreadLight hold transfer no larger than 2 GB.")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.starts(with: Self.magic) else {
            throw ThreadLightError.archive("This is not a supported ThreadLight hold transfer.")
        }
        let saltStart = Self.magic.count
        let salt = data.subdata(in: saltStart..<(saltStart + 32))
        let sealed = data.subdata(in: (saltStart + 32)..<data.count)

        for candidate in candidates where candidate.hold.status == .active {
            do {
                let cleartext = try AES.GCM.open(
                    .init(combined: sealed),
                    using: Self.key(hold: candidate.hold, custodians: candidate.custodians, salt: salt)
                )
                let snapshot = try CanonicalJSON.decoder.decode(HoldTransferSnapshot.self, from: cleartext)
                guard cleartext == (try CanonicalJSON.encode(snapshot)),
                      snapshot.schemaVersion == 1,
                      snapshot.holdID == candidate.hold.id,
                      snapshot.organizationID == candidate.hold.organizationID,
                      snapshot.holdFingerprint == HoldAccessKey.fingerprint(
                        hold: candidate.hold,
                        custodians: candidate.custodians
                      ) else {
                    continue
                }
                let counts = try await store.importTransferSnapshot(
                    snapshot,
                    hold: candidate.hold,
                    custodians: candidate.custodians
                )
                return .init(
                    hold: candidate.hold,
                    archivesImported: counts.archives,
                    messagesImported: counts.messages
                )
            } catch is CryptoKitError {
                continue
            }
        }
        throw ThreadLightError.authentication(
            "This encrypted package does not match any legal hold available to you. If the hold or its members changed, import a newly created package."
        )
    }

    private static func key(hold: LegalHold, custodians: [Custodian], salt: Data) -> SymmetricKey {
        let fingerprint = HoldAccessKey.fingerprint(hold: hold, custodians: custodians)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(fingerprint.utf8)),
            salt: salt,
            info: Data("dev.threadlight.hold-transfer.v1".utf8),
            outputByteCount: 32
        )
    }
}

public struct HoldTransferSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let createdAt: Date
    public let holdID: String
    public let organizationID: String
    public let holdFingerprint: String
    public let archives: [SourceArchive]
    public let records: [HoldTransferRecord]
}

public struct HoldTransferRecord: Codable, Sendable {
    public let message: EvidenceMessage
    public let membership: HoldMembership
}
