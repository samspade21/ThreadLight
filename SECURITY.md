# Security policy

## Reporting

Report security issues through [GitHub private vulnerability reporting](https://github.com/samspade21/ThreadLight/security/advisories/new). Do not open a public issue or pull request for an undisclosed vulnerability.

Even in a private report, **never attach or paste real data**. That means no Slack exports, OAuth tokens, evidence databases, signatures containing case metadata, custodian names or member IDs, or customer screenshots. Reproduce with synthetic fixtures — `Tests/ThreadLightCoreTests` shows the shape they take.

A good report names the affected file and line, states what an attacker gains, and gives the steps to reproduce.

## Scope

ThreadLight is a local macOS application. Findings that matter most:

- Evidence confidentiality at rest — SQLCipher storage, the AES-GCM resource vault, Keychain and Secure Enclave use.
- Slack OAuth — PKCE, scope enforcement, token handling and rotation.
- Untrusted input parsing — Slack export ZIPs, hold transfer packages, setup handoff packages, attachment text extraction.
- Evidence integrity — manifest hashing, ES256 signing, and what the signature does and does not prove.

Known and documented limitations are in [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md). Two worth reading before reporting, because both are deliberate:

- A hold transfer exported without a passphrase is encrypted with a key derived from the organization, hold, and member IDs. Anyone with Legal Holds access or Slack audit-log access can rebuild that key. Export with a passphrase when the transfer channel is not itself trusted.
- Evidence and setup-package signatures carry their own verifying public key. They prove the contents are unaltered against that key; they do not prove who produced the package. Signer key IDs must be compared out of band, which the app requires before it will sign in with a client ID that arrived in a handoff.

## Supported releases

The latest signed release only.

Ad-hoc and debug builds store the evidence database key in a plaintext file beside the database. They display a compact warning at the bottom of the window and must never hold real evidence. Issues that depend on a development build having weak key storage are working as documented, not vulnerabilities.

Production use requires human review of the database schema, Slack app configuration, dependency audit, and evidence policy.
