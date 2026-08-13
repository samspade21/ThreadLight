import Foundation

public enum SetupTransferKind: String, Equatable, Sendable {
    case administratorRequest
    case administratorResponse
}

public struct SetupTransferVerification: Sendable {
    public let kind: SetupTransferKind
    public let requestID: UUID
    public let signerKeyID: String

    public init(kind: SetupTransferKind, requestID: UUID, signerKeyID: String) {
        self.kind = kind
        self.requestID = requestID
        self.signerKeyID = signerKeyID
    }
}

public enum SetupTransferVerifier {
    public static func verify(packageURL: URL) throws -> SetupTransferVerification {
        let values = try packageURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ThreadLightError.invalidConfiguration("Choose a regular ThreadLight setup package directory.")
        }
        switch packageURL.pathExtension {
        case "threadlight-setup-request":
            return try verifyRequest(packageURL)
        case "threadlight-setup-response":
            return try verifyResponse(packageURL)
        default:
            throw ThreadLightError.invalidConfiguration("Choose a .threadlight-setup-request or .threadlight-setup-response package.")
        }
    }

    public static func request(at packageURL: URL) throws -> SetupHandoffPackage {
        _ = try verifyRequest(packageURL)
        return try CanonicalJSON.decoder.decode(
            SetupHandoffPackage.self,
            from: readRegularFile(packageURL.appending(path: "handoff.json"))
        )
    }

    public static func response(at packageURL: URL) throws -> SetupCompletionPackage {
        _ = try verifyResponse(packageURL)
        return try CanonicalJSON.decoder.decode(
            SetupCompletionPackage.self,
            from: readRegularFile(packageURL.appending(path: "completion.json"))
        )
    }

    private static func verifyRequest(_ root: URL) throws -> SetupTransferVerification {
        try requireExactFiles(
            root: root,
            expected: ["README.md", "slack-app-manifest.yaml", "handoff.json", "handoff.threadlight-signature.json"]
        )
        let data = try readRegularFile(root.appending(path: "handoff.json"))
        let envelope = try decodeEnvelope(root.appending(path: "handoff.threadlight-signature.json"))
        guard try SecureEnclaveSignatureProvider.verify(manifest: data, envelope: envelope) else {
            throw ThreadLightError.invalidConfiguration("The Legal request signature does not match its contents.")
        }
        let package = try CanonicalJSON.decoder.decode(SetupHandoffPackage.self, from: data)
        guard data == (try CanonicalJSON.encode(package)),
              package.schemaVersion == 2,
              package.redirectURI == SlackOAuth.redirectURI,
              package.requiredScope == "admin.legal_holds:read" else {
            throw ThreadLightError.invalidConfiguration("The Legal request format is unsupported or noncanonical.")
        }
        let manifest = try readRegularFile(root.appending(path: "slack-app-manifest.yaml"))
        guard manifest == Data(SlackAppManifest.template.utf8),
              package.appManifestSHA256 == SHA256Digest.data(manifest) else {
            throw ThreadLightError.invalidConfiguration("The Slack app manifest does not match the signed request.")
        }
        return .init(kind: .administratorRequest, requestID: package.requestID, signerKeyID: envelope.keyID)
    }

    private static func verifyResponse(_ root: URL) throws -> SetupTransferVerification {
        try requireExactFiles(
            root: root,
            expected: ["README.txt", "completion.json", "completion.threadlight-signature.json"]
        )
        let data = try readRegularFile(root.appending(path: "completion.json"))
        let envelope = try decodeEnvelope(root.appending(path: "completion.threadlight-signature.json"))
        guard try SecureEnclaveSignatureProvider.verify(manifest: data, envelope: envelope) else {
            throw ThreadLightError.invalidConfiguration("The Slack Admin handoff signature does not match its contents.")
        }
        let package = try CanonicalJSON.decoder.decode(SetupCompletionPackage.self, from: data)
        guard data == (try CanonicalJSON.encode(package)),
              package.schemaVersion == 2,
              package.redirectURI == SlackOAuth.redirectURI,
              package.requiredScope == "admin.legal_holds:read",
              package.legalOAuthRequired,
              package.tokenTransferProhibited,
              package.organizationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              package.enterpriseDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              package.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              Set(package.completedRequirements) == Set(SetupRequirementID.administratorRequirements) else {
            throw ThreadLightError.invalidConfiguration("The Slack Admin handoff format is incomplete or unsupported.")
        }
        return .init(kind: .administratorResponse, requestID: package.requestID, signerKeyID: envelope.keyID)
    }

    private static func decodeEnvelope(_ url: URL) throws -> SignatureEnvelope {
        let data = try readRegularFile(url)
        let envelope = try CanonicalJSON.decoder.decode(SignatureEnvelope.self, from: data)
        guard data == (try CanonicalJSON.encode(envelope)) else {
            throw ThreadLightError.invalidConfiguration("The setup signature file is not canonical ThreadLight JSON.")
        }
        return envelope
    }

    private static func requireExactFiles(root: URL, expected: Set<String>) throws {
        let urls = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        let actual = Set(urls.map(\.lastPathComponent))
        guard actual == expected else {
            let missing = expected.subtracting(actual).sorted()
            let unexpected = actual.subtracting(expected).sorted()
            let details = [
                missing.isEmpty ? nil : "missing: \(missing.joined(separator: ", "))",
                unexpected.isEmpty ? nil : "remove unexpected: \(unexpected.joined(separator: ", "))",
            ].compactMap { $0 }.joined(separator: "; ")
            throw ThreadLightError.invalidConfiguration("The setup package contents do not match (\(details)). Ask the sender to create a new untouched package if these files were not added by your transfer process.")
        }
        for url in urls { _ = try readRegularFile(url) }
    }

    private static func readRegularFile(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size <= 10 * 1_024 * 1_024 else {
            throw ThreadLightError.invalidConfiguration("The setup package contains an unsafe or oversized file: \(url.lastPathComponent)")
        }
        return try Data(contentsOf: url)
    }
}
