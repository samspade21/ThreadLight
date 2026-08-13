import CryptoKit
import Foundation
import Security

public struct SignatureEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let algorithm: String
    public let keyID: String
    public let publicKey: String
    public let manifestSHA256: String
    public let signature: String
    public let signedAt: Date

    public init(
        schemaVersion: Int = 2,
        algorithm: String = "ES256",
        keyID: String,
        publicKey: String,
        manifestSHA256: String,
        signature: String,
        signedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.algorithm = algorithm
        self.keyID = keyID
        self.publicKey = publicKey
        self.manifestSHA256 = manifestSHA256
        self.signature = signature
        self.signedAt = signedAt
    }
}

public protocol SignatureProvider: Sendable {
    func sign(manifest: Data) async throws -> SignatureEnvelope
}

private struct SignedEnvelopeClaims: Codable {
    let schemaVersion: Int
    let algorithm: String
    let keyID: String
    let publicKey: String
    let manifestSHA256: String
    let signedAt: Date
}

private func signedClaims(
    schemaVersion: Int = 2,
    algorithm: String = "ES256",
    keyID: String,
    publicKey: String,
    manifestSHA256: String,
    signedAt: Date
) throws -> Data {
    try CanonicalJSON.encode(SignedEnvelopeClaims(
        schemaVersion: schemaVersion,
        algorithm: algorithm,
        keyID: keyID,
        publicKey: publicKey,
        manifestSHA256: manifestSHA256,
        signedAt: signedAt
    ))
}

public actor SecureEnclaveSignatureProvider: SignatureProvider {
    private let keychain: KeychainStore
    private let keyAccount: String

    public init(keychain: KeychainStore = .shared, keyAccount: String = "evidence.signing.secureenclave.v1") {
        self.keychain = keychain
        self.keyAccount = keyAccount
    }

    public func sign(manifest: Data) async throws -> SignatureEnvelope {
        guard SecureEnclave.isAvailable else {
            throw ThreadLightError.export("Secure Enclave is unavailable. ThreadLight will not create a weaker evidence signature.")
        }
        let privateKey: SecureEnclave.P256.Signing.PrivateKey
        if let representation = try await keychain.load(account: keyAccount) {
            privateKey = try .init(dataRepresentation: representation)
        } else {
            var error: Unmanaged<CFError>?
            guard let control = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.privateKeyUsage],
                &error
            ) else {
                if let error { throw error.takeRetainedValue() }
                throw ThreadLightError.export("Could not create Secure Enclave access control.")
            }
            privateKey = try .init(accessControl: control)
            try await keychain.save(privateKey.dataRepresentation, account: keyAccount)
        }
        let publicKey = privateKey.publicKey.x963Representation
        let keyID = SHA256Digest.data(publicKey)
        let publicKeyString = publicKey.base64EncodedString()
        let manifestSHA256 = SHA256Digest.data(manifest)
        let signedAt = Date()
        let claims = try signedClaims(
            keyID: keyID,
            publicKey: publicKeyString,
            manifestSHA256: manifestSHA256,
            signedAt: signedAt
        )
        let signature = try privateKey.signature(for: claims)
        return .init(
            keyID: keyID,
            publicKey: publicKeyString,
            manifestSHA256: manifestSHA256,
            signature: signature.rawRepresentation.base64EncodedString(),
            signedAt: signedAt
        )
    }

    public static func verify(manifest: Data, envelope: SignatureEnvelope) throws -> Bool {
        guard envelope.schemaVersion == 2,
              envelope.algorithm == "ES256",
              envelope.manifestSHA256 == SHA256Digest.data(manifest),
              let publicKeyData = Data(base64Encoded: envelope.publicKey),
              envelope.keyID == SHA256Digest.data(publicKeyData),
              let signatureData = Data(base64Encoded: envelope.signature) else { return false }
        let key = try P256.Signing.PublicKey(x963Representation: publicKeyData)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        let claims = try signedClaims(
            schemaVersion: envelope.schemaVersion,
            algorithm: envelope.algorithm,
            keyID: envelope.keyID,
            publicKey: envelope.publicKey,
            manifestSHA256: envelope.manifestSHA256,
            signedAt: envelope.signedAt
        )
        return key.isValidSignature(signature, for: claims)
    }
}

public actor EphemeralSignatureProvider: SignatureProvider {
    private let key = P256.Signing.PrivateKey()

    public init() {}

    public func sign(manifest: Data) async throws -> SignatureEnvelope {
        let publicKey = key.publicKey.x963Representation
        let keyID = SHA256Digest.data(publicKey)
        let publicKeyString = publicKey.base64EncodedString()
        let manifestSHA256 = SHA256Digest.data(manifest)
        let signedAt = Date()
        let claims = try signedClaims(
            keyID: keyID,
            publicKey: publicKeyString,
            manifestSHA256: manifestSHA256,
            signedAt: signedAt
        )
        let signature = try key.signature(for: claims)
        return .init(
            keyID: keyID,
            publicKey: publicKeyString,
            manifestSHA256: manifestSHA256,
            signature: signature.rawRepresentation.base64EncodedString(),
            signedAt: signedAt
        )
    }
}
