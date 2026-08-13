import Darwin
import Foundation
import ThreadLightCore

@main
struct ThreadLightVerifierCommand {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("Usage: threadlight-verify /path/to/package.threadlight-{evidence,setup-request,setup-response}\n".utf8))
            exit(64)
        }
        let packageURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        do {
            if packageURL.pathExtension == "threadlight-setup-request" || packageURL.pathExtension == "threadlight-setup-response" {
                let result = try SetupTransferVerifier.verify(packageURL: packageURL)
                print("VALID: signed ThreadLight setup package matches its contents.")
                print("Kind: \(result.kind.rawValue)")
                print("Request ID: \(result.requestID.uuidString)")
                print("Signer key ID: \(result.signerKeyID)")
                print("Compare the signer key ID through the approved transfer channel; no OAuth token is contained in this package.")
                return
            }
            guard try EvidenceExporter.verify(packageURL: packageURL) else {
                FileHandle.standardError.write(Data("INVALID: signature, manifest, payload hashes, or package contents do not match.\n".utf8))
                exit(1)
            }
            let signatureURL = packageURL.appending(path: "manifest.threadlight-signature.json")
            let envelope = try CanonicalJSON.decoder.decode(SignatureEnvelope.self, from: Data(contentsOf: signatureURL))
            print("VALID: all declared files and the ES256 manifest signature match.")
            print("Signer key ID: \(envelope.keyID)")
            print("This is tamper evidence, not an independent timestamp or proof of operator identity.")
        } catch {
            FileHandle.standardError.write(Data("INVALID: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
