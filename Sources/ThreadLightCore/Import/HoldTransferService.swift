import CommonCrypto
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
    private static let magic = Data("THREADLIGHT-HOLD-2\n".utf8)
    private static let legacyMagic = Data("THREADLIGHT-HOLD-1\n".utf8)
    private static let saltCount = 32
    private static let maximumBytes = 2 * 1_024 * 1_024 * 1_024
    /// OWASP's PBKDF2-HMAC-SHA256 floor. Derived once per transfer, not once per candidate hold.
    private static let passphraseIterations: UInt32 = 600_000
    private let store: EvidenceStore

    public init(store: EvidenceStore) {
        self.store = store
    }

    public func export(
        hold: LegalHold,
        custodians: [Custodian],
        destination: URL,
        passphrase: String? = nil
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
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let secret = try Self.normalizedPassphrase(passphrase)
        let stretched = try secret.map { try Self.stretch(passphrase: $0, salt: salt) }
        let key = Self.key(hold: hold, custodians: custodians, salt: salt, stretchedPassphrase: stretched)
        guard let sealed = try AES.GCM.seal(cleartext, using: key).combined else {
            throw ThreadLightError.export("Could not encrypt the hold transfer.")
        }
        var output = Self.magic
        output.append(secret == nil ? 0 : 1)
        output.append(salt)
        output.append(sealed)
        try output.write(to: destination, options: [.atomic, .completeFileProtection])
        return destination
    }

    /// Reads only the package header so the app can ask for a passphrase before it imports.
    public static func requiresPassphrase(url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: magic.count + 1), header.count == magic.count + 1 else {
            throw ThreadLightError.archive("This is not a supported ThreadLight hold transfer.")
        }
        guard header.starts(with: magic) else {
            if header.starts(with: legacyMagic) {
                throw ThreadLightError.archive("This hold transfer was created by an older ThreadLight build. Ask the sender to create a new package.")
            }
            throw ThreadLightError.archive("This is not a supported ThreadLight hold transfer.")
        }
        return header[header.startIndex + magic.count] == 1
    }

    public func importTransfer(
        url: URL,
        candidates: [HoldTransferCandidate],
        passphrase: String? = nil
    ) async throws -> HoldTransferResult {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > Self.magic.count + 1 + Self.saltCount,
              size <= Self.maximumBytes + 1_024 else {
            throw ThreadLightError.archive("Choose a regular ThreadLight hold transfer no larger than 2 GB.")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.starts(with: Self.magic) else {
            if data.starts(with: Self.legacyMagic) {
                throw ThreadLightError.archive("This hold transfer was created by an older ThreadLight build. Ask the sender to create a new package.")
            }
            throw ThreadLightError.archive("This is not a supported ThreadLight hold transfer.")
        }
        let flagIndex = data.startIndex + Self.magic.count
        let requiresPassphrase = data[flagIndex] == 1
        guard data[flagIndex] <= 1 else {
            throw ThreadLightError.archive("This hold transfer declares an unsupported protection mode.")
        }
        let saltStart = flagIndex + 1
        let salt = data.subdata(in: saltStart..<(saltStart + Self.saltCount))
        let sealed = data.subdata(in: (saltStart + Self.saltCount)..<data.endIndex)

        let secret = try Self.normalizedPassphrase(passphrase)
        guard requiresPassphrase == (secret != nil) else {
            throw ThreadLightError.authentication(
                requiresPassphrase
                    ? "This hold transfer is protected by a passphrase. Enter the passphrase the sender shared through the approved channel."
                    : "This hold transfer was not created with a passphrase. Import it without one."
            )
        }
        // Stretching is keyed only by the passphrase and the file's salt, so it runs once
        // here rather than once per candidate hold.
        let stretched = try secret.map { try Self.stretch(passphrase: $0, salt: salt) }

        for candidate in candidates where candidate.hold.status == .active {
            do {
                let cleartext = try AES.GCM.open(
                    .init(combined: sealed),
                    using: Self.key(
                        hold: candidate.hold,
                        custodians: candidate.custodians,
                        salt: salt,
                        stretchedPassphrase: stretched
                    )
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
            requiresPassphrase
                ? "This encrypted package did not open. Either the passphrase is wrong, or it does not match any legal hold available to you. If the hold or its members changed, import a newly created package."
                : "This encrypted package does not match any legal hold available to you. If the hold or its members changed, import a newly created package."
        )
    }

    /// Key material is the hold fingerprint — organization, hold, and current member IDs —
    /// optionally combined with a stretched operator passphrase.
    ///
    /// Without a passphrase the fingerprint is the whole key, and every input to it is visible
    /// to anyone with Legal Holds access or Slack audit-log access. Such a person can rebuild
    /// the key and decrypt the package. Passing a passphrase, shared out of band, is what makes
    /// the file confidential against someone who already knows those identifiers.
    private static func key(
        hold: LegalHold,
        custodians: [Custodian],
        salt: Data,
        stretchedPassphrase: Data?
    ) -> SymmetricKey {
        var material = Data(HoldAccessKey.fingerprint(hold: hold, custodians: custodians).utf8)
        if let stretchedPassphrase { material.append(stretchedPassphrase) }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: material),
            salt: salt,
            info: Data("dev.threadlight.hold-transfer.v2".utf8),
            outputByteCount: 32
        )
    }

    private static func normalizedPassphrase(_ passphrase: String?) throws -> String? {
        guard let passphrase else { return nil }
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard trimmed.utf8.count >= 12 else {
            throw ThreadLightError.invalidConfiguration("A hold transfer passphrase must be at least 12 characters.")
        }
        return trimmed
    }

    private static func stretch(passphrase: String, salt: Data) throws -> Data {
        var derived = Data(count: 32)
        let status: Int32 = derived.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passphrase,
                    passphrase.utf8.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    passphraseIterations,
                    output.bindMemory(to: UInt8.self).baseAddress,
                    32
                )
            }
        }
        guard status == kCCSuccess else {
            throw ThreadLightError.export("Could not derive a key from the hold transfer passphrase.")
        }
        return derived
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
