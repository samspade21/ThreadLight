# Threat model

## Protected assets

Slack OAuth tokens, imported message content, attachments, hold/custodian metadata, source archive provenance, local database keys, and export signing keys.

## Trust boundaries

- Slack OAuth and Web API over TLS.
- User-selected Slack export archives and resources, treated as hostile input.
- macOS Keychain and Secure Enclave.
- User-selected export destination, which may not be encrypted.

## Primary threats and controls

- **Over-broad Slack access:** customer-owned app, organization install, exact single documented read scope enforced on returned and rotated tokens, no write methods.
- **OAuth interception:** PKCE S256 with the verifier never leaving the Mac, high-entropy state, and an RFC 2606 `.invalid` callback host that can never resolve or be registered — the authorization code only ever appears in the user's own browser address bar, where they paste it back into ThreadLight. An intercepted code is useless without the local verifier.
- **Token theft:** ThisDeviceOnly Keychain items; tokens never logged or stored in preferences/database.
- **Archive attacks:** reject absolute paths, traversal, symlinks, excessive file count, excessive expanded size, malformed JSON, and unsupported layouts.
- **Evidence leakage:** SQLCipher database; AES-GCM resource vault; owner-only decrypted Quick Look files removed when preview closes and stale previews removed at next launch; no evidence-content application logging; no telemetry.
- **Cross-organization mixing:** MDM supplies the expected Enterprise ID as a forced preference; Legal OAuth must return the same ID. Enterprise-ID-derived namespaces isolate keys, databases, resources, retention timestamps, and offline reopening. The signed Slack Admin handoff remains an audit artifact.
- **Interrupted import ambiguity:** checkpoints are stored in the encrypted database and tied to the source SHA-256, hold, custodian, and operator binding; incomplete sources cannot satisfy search/export joins.
- **Large JSON exhaustion:** conversation JSON is decompressed to a protected, randomly named temporary file and parsed incrementally with per-entry and per-object limits; temporary files are deleted after each entry.
- **Incorrect hold scope:** hold-wide source provenance and centralized fail-closed ScopeDecision. Export re-fetches policy status and current members from Slack immediately before evaluation; unknown status blocks distinctly.
- **IT-to-Legal transfer disclosure:** AES-GCM encrypts normalized payloads. The file exposes only a format marker, random salt, nonce, ciphertext, and authentication tag. Legal tries keys derived from its live accessible hold/member combinations. This is access-derived symmetric encryption, not asymmetric encryption and not protection against an attacker who already knows the hold and member IDs.
- **Stale hold access:** refresh compares the organization/hold/current-member fingerprint. A mismatch or missing hold purges local evidence and requires a new IT transfer.
- **Evidence modification:** SHA-256 source/resource hashes and a Secure Enclave-backed ES256 signature bind the manifest hash, public key, key ID, algorithm, and claimed signing time. Each custodian/source membership also retains its source-specific message hash; differing representations of the same Slack message fail evidence export closed. Verification requires canonical versioned metadata and rejects signed manifests with unsupported schemas, invalid paths, or inconsistent hold/source/custodian relationships. A verifier must compare the signer key ID with a previously recorded trusted value; an entirely self-contained package cannot prevent key substitution, and the bound signing time is not an independent timestamp.
- **False chain-of-custody claims:** export states that operator binding and local time are not independent attestations.

OWASP API Security Top 10 controls apply to the Slack client, especially broken authorization, resource consumption, unsafe consumption, and security misconfiguration.

Development builds deliberately replace Keychain/Secure Enclave persistence with file-protected local keys, session-only OAuth, and ephemeral signatures. They are visibly marked DEV, use separate storage namespaces, and are not valid production evidence tools.
