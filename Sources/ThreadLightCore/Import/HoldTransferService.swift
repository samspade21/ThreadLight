import CommonCrypto
import Compression
import CryptoKit
import Foundation

/// Naming for the encrypted transfer file. The format itself is identified by the magic bytes,
/// not the file name.
public enum HoldTransferFile {
    public static let pathExtension = "threadlight"

    public static func isTransfer(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == pathExtension
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
    /// Version 4 splits the deflated canonical JSON into framed chunks, each sealed with its
    /// own AES-GCM box. The chunk index and a final-chunk flag are authenticated data, so a
    /// reordered, duplicated, or truncated frame sequence fails to open instead of decoding
    /// to something plausible. Framing also removes version 3's single 2 GB sealed buffer
    /// and its whole-payload decrypt copies.
    private static let magic = Data("THREADLIGHT-HOLD-4\n".utf8)
    private static let saltCount = 32
    private static let maximumBytes = 2 * 1_024 * 1_024 * 1_024
    private static let chunkBytes = 4 * 1_024 * 1_024
    private static let keyInfo = Data("dev.threadlight.hold-transfer.v4".utf8)
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
        var output = Self.magic
        output.append(secret == nil ? 0 : 1)
        output.append(salt)
        var chunkIndex: UInt64 = 0
        var offset = compressed.startIndex
        repeat {
            let end = min(offset + Self.chunkBytes, compressed.endIndex)
            let isFinal = end == compressed.endIndex
            guard let sealed = try AES.GCM.seal(
                compressed[offset..<end],
                using: key,
                authenticating: Self.chunkAAD(index: chunkIndex, isFinal: isFinal)
            ).combined else {
                throw ThreadLightError.export("Could not encrypt the hold transfer.")
            }
            withUnsafeBytes(of: UInt32(sealed.count).bigEndian) { output.append(contentsOf: $0) }
            output.append(sealed)
            offset = end
            chunkIndex += 1
        } while offset < compressed.endIndex
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
              size <= Self.maximumBytes + 1_048_576 else {
            throw ThreadLightError.archive("Choose a regular ThreadLight hold transfer no larger than 2 GB.")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.starts(with: Self.magic) else {
            throw ThreadLightError.archive("This is not a supported ThreadLight hold transfer.")
        }
        let flagIndex = data.startIndex + Self.magic.count
        let requiresPassphrase = data[flagIndex] == 1
        guard data[flagIndex] <= 1 else {
            throw ThreadLightError.archive("This hold transfer declares an unsupported protection mode.")
        }
        let saltStart = flagIndex + 1
        let salt = data.subdata(in: saltStart..<(saltStart + Self.saltCount))
        let frames = data[(saltStart + Self.saltCount)...]

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
                let opened = try Self.openChunks(
                    frames,
                    key: Self.key(
                        hold: candidate.hold,
                        custodians: candidate.custodians,
                        salt: salt,
                        stretchedPassphrase: stretched
                    )
                )
                let cleartext = try Self.inflate(opened, limit: Self.maximumBytes)
                // Decoding must reproduce the sealed bytes exactly, so a package cannot carry
                // fields ThreadLight ignores or an ordering it did not write.
                let snapshot = try CanonicalJSON.decoder.decode(HoldTransferSnapshot.self, from: cleartext)
                guard cleartext == (try CanonicalJSON.encode(snapshot)),
                      snapshot.schemaVersion == HoldTransferSnapshot.schemaVersion,
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
            info: keyInfo,
            outputByteCount: 32
        )
    }

    private static func chunkAAD(index: UInt64, isFinal: Bool) -> Data {
        var aad = keyInfo
        withUnsafeBytes(of: index.bigEndian) { aad.append(contentsOf: $0) }
        aad.append(isFinal ? 1 : 0)
        return aad
    }

    /// Opens the framed chunk sequence and returns the reassembled deflated payload.
    ///
    /// A wrong key fails on the first chunk's tag, so trying candidate holds stays cheap.
    /// Malformed framing throws a ThreadLightError, which the candidate loop does not
    /// swallow: a damaged file reports as damaged rather than as "no matching hold".
    private static func openChunks(_ frames: Data, key: SymmetricKey) throws -> Data {
        var compressed = Data()
        var offset = frames.startIndex
        var index: UInt64 = 0
        while offset < frames.endIndex {
            guard frames.endIndex - offset >= 4 else {
                throw ThreadLightError.archive("This hold transfer is truncated mid-frame.")
            }
            let sealedCount = frames[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            // AES-GCM overhead is a 12-byte nonce plus a 16-byte tag.
            guard sealedCount >= 28,
                  sealedCount <= chunkBytes + 28,
                  frames.endIndex - offset - 4 >= sealedCount else {
                throw ThreadLightError.archive("This hold transfer contains an invalid frame.")
            }
            let frameEnd = offset + 4 + sealedCount
            let opened = try AES.GCM.open(
                .init(combined: frames[(offset + 4)..<frameEnd]),
                using: key,
                authenticating: chunkAAD(index: index, isFinal: frameEnd == frames.endIndex)
            )
            guard compressed.count + opened.count <= maximumBytes else {
                throw ThreadLightError.archive("This hold transfer expands beyond the 2 GB transfer limit.")
            }
            compressed.append(opened)
            offset = frameEnd
            index += 1
        }
        return compressed
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

