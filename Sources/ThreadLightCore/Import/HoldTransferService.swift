import CommonCrypto
import Compression
import CryptoKit
import Foundation

/// Naming for the encrypted transfer file.
///
/// ThreadLight writes `.threadlight` and opens either extension, so packages handed to a
/// recipient before the rename keep working. The format itself is identified by the magic
/// bytes, not the file name.
public enum HoldTransferFile {
    public static let pathExtension = "threadlight"
    public static let legacyPathExtension = "threadlight-hold"

    public static func isTransfer(_ url: URL) -> Bool {
        let found = url.pathExtension.lowercased()
        return found == pathExtension || found == legacyPathExtension
    }
}

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
    /// Version 3 deflates the canonical JSON before sealing it. Slack's own exports of this
    /// content compress about ten to one, and encrypted output cannot be compressed afterwards,
    /// so an uncompressed payload threw that away and pushed packages toward the size ceiling.
    private static let magic = Data("THREADLIGHT-HOLD-3\n".utf8)
    /// Version 2 is uncompressed and carries a schema 1 snapshot. Still readable so packages
    /// already handed to a recipient keep opening; never written.
    static let uncompressedMagic = Data("THREADLIGHT-HOLD-2\n".utf8)
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
        let compressed = try Self.deflate(cleartext)
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let secret = try Self.normalizedPassphrase(passphrase)
        let stretched = try secret.map { try Self.stretch(passphrase: $0, salt: salt) }
        let key = Self.key(hold: hold, custodians: custodians, salt: salt, stretchedPassphrase: stretched)
        guard let sealed = try AES.GCM.seal(compressed, using: key).combined else {
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
        guard header.starts(with: magic) || header.starts(with: uncompressedMagic) else {
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
        let isCompressed = data.starts(with: Self.magic)
        guard isCompressed || data.starts(with: Self.uncompressedMagic) else {
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
                let opened = try AES.GCM.open(
                    .init(combined: sealed),
                    using: Self.key(
                        hold: candidate.hold,
                        custodians: candidate.custodians,
                        salt: salt,
                        stretchedPassphrase: stretched
                    )
                )
                let cleartext = isCompressed
                    ? try Self.inflate(opened, limit: Self.maximumBytes)
                    : opened
                // Decoding must reproduce the sealed bytes exactly, so a package cannot carry
                // fields ThreadLight ignores or an ordering it did not write.
                let snapshot: HoldTransferSnapshot
                if isCompressed {
                    let decoded = try CanonicalJSON.decoder.decode(HoldTransferSnapshot.self, from: cleartext)
                    guard cleartext == (try CanonicalJSON.encode(decoded)) else { continue }
                    snapshot = decoded
                } else {
                    let decoded = try CanonicalJSON.decoder.decode(LegacyHoldTransferSnapshot.self, from: cleartext)
                    guard cleartext == (try CanonicalJSON.encode(decoded)), decoded.schemaVersion == 1 else { continue }
                    snapshot = decoded.modernized()
                }
                guard snapshot.schemaVersion == HoldTransferSnapshot.schemaVersion,
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
    static func key(
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

    private static func deflate(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return data }
        do { return try (data as NSData).compressed(using: .zlib) as Data }
        catch { throw ThreadLightError.export("Could not compress the hold transfer.") }
    }

    /// Inflates with a hard ceiling on what it will produce.
    ///
    /// A compressed payload can expand by orders of magnitude, so decompressing it whole and
    /// checking the size afterwards is already too late. Producing into a fixed buffer and
    /// stopping the moment the total passes `limit` bounds the work a malformed or hostile
    /// package can cause, even though reaching this point already required a key derived from
    /// the hold's own membership.
    private static func inflate(_ data: Data, limit: Int) throws -> Data {
        guard !data.isEmpty else { return data }
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else {
            throw ThreadLightError.archive("This hold transfer could not be decompressed.")
        }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = 1 << 20
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var output = Data()
        var status = COMPRESSION_STATUS_OK

        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw ThreadLightError.archive("This hold transfer could not be decompressed.")
            }
            stream.src_ptr = base
            stream.src_size = raw.count
            repeat {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                    throw ThreadLightError.archive("This hold transfer could not be decompressed.")
                }
                let produced = bufferSize - stream.dst_size
                if produced > 0 {
                    guard output.count + produced <= limit else {
                        throw ThreadLightError.archive("This hold transfer expands beyond the 2 GB transfer limit.")
                    }
                    output.append(buffer, count: produced)
                }
            } while status == COMPRESSION_STATUS_OK
        }
        return output
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

/// Messages are listed once and referenced by membership. Memberships are keyed per source
/// archive, so a message present in several custodians' exports has several memberships; the
/// earlier shape inlined the whole message into each one and serialized it that many times.
public struct HoldTransferSnapshot: Codable, Sendable {
    public static let schemaVersion = 2

    public let schemaVersion: Int
    public let createdAt: Date
    public let holdID: String
    public let organizationID: String
    public let holdFingerprint: String
    public let archives: [SourceArchive]
    public let messages: [EvidenceMessage]
    public let memberships: [HoldMembership]

    public init(
        schemaVersion: Int = HoldTransferSnapshot.schemaVersion,
        createdAt: Date,
        holdID: String,
        organizationID: String,
        holdFingerprint: String,
        archives: [SourceArchive],
        messages: [EvidenceMessage],
        memberships: [HoldMembership]
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.holdID = holdID
        self.organizationID = organizationID
        self.holdFingerprint = holdFingerprint
        self.archives = archives
        self.messages = messages
        self.memberships = memberships
    }
}

/// The schema 1 shape, read so packages written before messages were deduplicated still import.
/// ThreadLight never writes it again.
struct LegacyHoldTransferSnapshot: Codable, Sendable {
    let schemaVersion: Int
    let createdAt: Date
    let holdID: String
    let organizationID: String
    let holdFingerprint: String
    let archives: [SourceArchive]
    let records: [HoldTransferRecord]

    func modernized() -> HoldTransferSnapshot {
        var seen = Set<String>()
        var messages: [EvidenceMessage] = []
        for record in records where seen.insert(record.message.id).inserted {
            messages.append(record.message)
        }
        return HoldTransferSnapshot(
            schemaVersion: HoldTransferSnapshot.schemaVersion,
            createdAt: createdAt,
            holdID: holdID,
            organizationID: organizationID,
            holdFingerprint: holdFingerprint,
            archives: archives,
            messages: messages.sorted { $0.id < $1.id },
            memberships: records.map(\.membership)
        )
    }
}

public struct HoldTransferRecord: Codable, Sendable {
    public let message: EvidenceMessage
    public let membership: HoldMembership
}
