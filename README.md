# ThreadLight

ThreadLight is a local, read-only macOS application for reviewing Slack Enterprise legal-hold exports. On the packaging Mac, an administrator selects a hold, adds one or more Slack ZIPs, normalizes them locally, and saves one encrypted `.threadlight-hold` file. On a managed review Mac, ThreadLight automatically matches that file against the holds the signed-in person can currently read, then provides local search plus flat PDF/JSON export or an optional tamper-evident signed evidence package.

## Security boundary

- ThreadLight never writes to Slack.
- OAuth uses PKCE; no client secret is stored or shipped.
- Tokens and database keys live in macOS Keychain.
- OAuth tokens never cross computers. Each person signs in locally with an account allowed to read legal holds.
- Evidence is stored in a SQLCipher database.
- Each Slack Enterprise organization gets a distinct database key, encrypted database, resource vault, and retention clock. Startup purges every expired organization namespace, not only the last one opened; manual purge covers every known namespace.
- Large JSON files stream through protected temporary storage; cancelled imports retain an invisible checkpoint and resume only from the identical hashed ZIP and binding.
- Hold transfers use AES-GCM. The symmetric key is derived from the organization ID, hold ID, and sorted current member IDs; none of those identifiers appear in plaintext in the transfer.
- Hold ID and member IDs are authorization-derived material, not high-entropy secrets. This gates normal app access through Slack but is not equivalent to a user-held private key if those identifiers leak.
- Refreshing Slack invalidates and removes local evidence when a hold disappears or its current member set changes.
- A record is exportable only when a freshly checked active hold, time window, conversation restriction, and source provenance all match.
- Signatures prove that an export has not changed under the identified signing key. Record that key ID separately; signatures are not trusted timestamps or proof of operator identity.

## Build

Requirements: macOS 26, Apple Silicon, Xcode 26.6 or later with Swift 6.3.

```sh
swift package resolve
swift test
./scripts/build-app.sh
open build/ThreadLight.app
./scripts/verify-reproducible-build.sh
./scripts/verify-evidence.sh /path/to/package.threadlight-evidence
```

The build script accepts `CODE_SIGN_IDENTITY` and `NOTARY_PROFILE` environment variables. It performs an ad-hoc local signature when no Developer ID identity is supplied. A Developer ID build requires notarization and fails unless Apple accepts it, the ticket staples and validates, production entitlements pass, and Gatekeeper accepts the app. OAuth tokens use ThisDeviceOnly macOS Keychain storage in every build so sessions survive relaunches. Ad-hoc/debug builds still use separate file-protected development database keys and ephemeral evidence signatures, so they must not be used for production evidence. Developer ID builds use Keychain and Secure Enclave throughout. Never commit signing credentials.

The open-source `threadlight-verify` command checks package structure, every declared file hash, undeclared files, and the P-256 manifest signature. A valid result still requires comparing the reported signer key ID with a separately trusted record.

## Slack setup

Each organization owns its Slack app and creates it from the single [`docs/slack-app-manifest.yaml`](docs/slack-app-manifest.yaml). The manifest contains organization deployment, PKCE, the ThreadLight callback, bot scope `team:read`, and read-only user scopes `admin.legal_holds:read`, `users:read`, `users:read.email`, `reactions:read`, and `emoji:read`. These provide legal holds, current profiles, live reactions, and workspace emoji. Install from that app's **Settings → Install App → Install to Organization** page. ThreadLight never stores or uses the bot token and never transfers OAuth tokens.

After the connection is verified, ThreadLight generates a macOS `.mobileconfig` for MDM. It sets the public Client ID, organization identity, callback, required scope, and retention policy as forced preferences for `dev.threadlight.app`. On managed Macs, people launch ThreadLight and sign in to Slack; no setup-package import or manual Client ID entry is required. The profile contains no OAuth token, client secret, hold metadata, or evidence.

Slack sessions persist in a ThisDeviceOnly macOS Keychain item across app relaunches. **ThreadLight → Log Out of Slack** removes that item while leaving local evidence encrypted on the Mac.

Slack documents the Legal Holds API separately from ordinary Web API methods. ThreadLight follows the canonical scope table and singular `admin.legalHold.*` request URLs. See the [Slack app installation guide](docs/ADMIN_GUIDE.md).

## Evidence input

In **Settings → Prepare Packages**, select the legal hold and add one or more untouched Slack Enterprise JSON ZIPs. Root-level metadata and Enterprise layouts such as `teams/<workspace>/users.json` are supported. Metadata-only ZIPs are valid and import as zero messages. ThreadLight records each archive hash and operator binding and imports messages only from folders proven by conversation metadata. Save one encrypted package and transfer it through the approved channel. Review Macs import only that encrypted package, never the source ZIPs.

See [`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md), [`SECURITY.md`](SECURITY.md), [`docs/ADMIN_GUIDE.md`](docs/ADMIN_GUIDE.md), and [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

Third-party attribution is in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

For UI review without Slack credentials, an ad-hoc development build can launch a sanitized local case with `./scripts/threadlight-ui.sh launch-demo`. `launch-demo-complete` loads a fully eligible synthetic case. `./scripts/threadlight-ui.sh smoke-setup` verifies the one-time Slack app settings. `./scripts/threadlight-ui.sh smoke` drives selection, complete-thread JSON/PDF/resource export, independent verification, and in-app verification, then saves a ThreadLight-window-only capture. Demo modes are compiled out of production builds and must never be used for evidence.
