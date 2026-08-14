# ThreadLight

**An open-source Slack legal hold and eDiscovery tool for macOS.** Apache License 2.0.

ThreadLight is a read-only Mac app for reviewing Slack Enterprise legal-hold exports. It lets a legal team collect, preserve, search, review, and produce Slack evidence without uploading it to ThreadLight, an AI service, an analytics service, or a hosted review system. The evidence never leaves the Macs handling the case, and the whole source is auditable — which matters when a review tool's behavior may itself have to be explained.

ThreadLight does not create legal holds or change Slack. Slack remains the system of record for the hold; ThreadLight is the local review tool.

Where it fits an eDiscovery workflow: Slack preserves the hold, an administrator turns approved exports into one encrypted package, and reviewers run identification, review, and production locally. It does not do processing analytics, predictive coding, redaction, privilege logging, or Bates numbering, and it is not a hosted review platform.

## Who uses it

- **A Slack administrator** creates the organization-owned Slack app, obtains approved Slack export ZIPs, and turns them into one encrypted ThreadLight package.
- **A lawyer or reviewer** signs in to Slack, opens that package on a managed Mac, searches the messages, reviews conversations and threads, and exports selected evidence as PDF or JSON.

## How it works

1. The Slack administrator installs ThreadLight's supplied app manifest for the Enterprise organization. The app has read-only permissions.
2. In **Settings → Prepare Packages**, the administrator chooses an active legal hold and drops in one or more untouched Slack export ZIP files.
3. ThreadLight reads and normalizes those ZIPs on that Mac, then creates one encrypted `.threadlight` file. A passphrase can be added for stronger transfer protection.
4. The administrator sends that encrypted file to Legal through the organization's approved transfer channel.
5. The reviewer signs in to Slack on their own Mac and drops the package into ThreadLight. The app only opens it when it matches a currently active hold and its current members.
6. The reviewer searches locally by words, person, conversation, attachment, or date. Channels and direct messages stay grouped like Slack.
7. Selected evidence can be saved as a PDF, JSON, or both. Evidence signing is optional and adds a manifest and signature for later tamper checking.

## Privacy and network use

Slack message evidence and attachments remain on the Macs handling the case. ThreadLight has no cloud service, telemetry service, hosted database, or developer-operated server. It does not upload the imported ZIPs, the encrypted hold package, search terms, messages, attachments, or evidence exports.

ThreadLight does connect directly to **Slack's** cloud for sign-in and for read-only checks that the hold is still active. It also requests current names, email addresses, avatars, reactions, and workspace emoji. Those images are cached locally. That Slack traffic is unavoidable because Slack is the authority for the hold; no message evidence is sent from ThreadLight back to Slack. A user can still choose a cloud-synced folder or cloud transfer service when saving or moving a file, so organizational handling rules still apply.

## Encryption in plain language

- A signed production build creates a separate random encryption key for each Slack organization and stores that key in the macOS Keychain on that Mac.
- Searchable message data is stored in an encrypted SQLCipher database. Imported attachment bytes are stored separately with AES-GCM encryption. The app decrypts data only when it needs to display or export it.
- The `.threadlight` transfer file is encrypted with AES-GCM. Its base key is derived from the Slack organization, the hold, and the hold's current member list. Those identifiers are not written in plaintext inside the package.
- That base key prevents ordinary accidental access, but Slack administrators who already know all those identifiers may be able to reconstruct it. For confidential transport, add a strong passphrase and share it through a separate approved channel. ThreadLight strengthens the passphrase with PBKDF2 before using it.
- If Slack reports that the hold disappeared or its member list changed, ThreadLight removes the old local evidence and requires a new package.
- Optional evidence signatures detect later changes. They do not prove who operated the Mac and are not a trusted timestamp; compare the displayed signer key ID through a separate trusted record.

Development builds deliberately use weaker local key storage and show a red warning. They must never be used with real evidence. Use only a Developer ID signed and Apple-notarized release for production data.

## Install a release

Download `ThreadLight-VERSION.dmg` and its `.sha256` file from [GitHub Releases](https://github.com/samspade21/ThreadLight/releases). Verify the checksum if your organization requires it, open the DMG, and drag ThreadLight into Applications. Production releases are signed with Apple Developer ID and notarized by Apple.

ThreadLight requires Apple Silicon and macOS 26 or later. Slack setup is completed once by the organization's Slack administrator; see the [Slack administrator guide](docs/ADMIN_GUIDE.md).

## Build for development

Requirements: macOS 26, Apple Silicon, Xcode 26.6 or later with Swift 6.3.

```sh
swift package resolve
swift test
./scripts/build-app.sh --development
open build/ThreadLight.app
./scripts/verify-reproducible-build.sh
./scripts/verify-evidence.sh /path/to/package.threadlight-evidence
```

Build mode is explicit. `--development` is the default and creates an ad-hoc test build. `--release` creates the real production build and requires `CODE_SIGN_IDENTITY` and `NOTARY_PROFILE`; it fails unless Apple accepts notarization, the ticket staples and validates, production entitlements pass, and Gatekeeper accepts the app. `THREADLIGHT_BUILD_MODE=release` can be used instead of the flag.

On a maintainer Mac, copy `.signing.env.example` to `.signing.env` and fill in the local Developer ID identity and notary profile. `.signing.env` is gitignored, is read only by `--release` builds, and never overrides values already exported in the environment, so CI keeps control.

```sh
cp .signing.env.example .signing.env
$EDITOR .signing.env
./scripts/build-app.sh --release
```

Without `.signing.env`, pass the values directly:

```sh
CODE_SIGN_IDENTITY='Developer ID Application: Example Corp (TEAMID)' \
NOTARY_PROFILE='threadlight-notary' \
./scripts/build-app.sh --release
```

OAuth tokens use ThisDeviceOnly macOS Keychain storage in every build so sessions survive relaunches. Development builds write the evidence database key and resource-vault key to plaintext key files under Application Support instead of the Keychain, and sign evidence with ephemeral keys. The key sits beside the database it unlocks, so the encrypted store gives no protection at rest and these builds must never hold real evidence. They show a compact warning at the bottom of the window. Release builds use Keychain and Secure Enclave throughout. Never commit signing credentials.

## Release maintainers

ThreadLight uses [Semantic Versioning](https://semver.org/) and tags releases as `vMAJOR.MINOR.PATCH`. `VERSION` and the app's Info.plist must agree. To prepare a later release:

```sh
./scripts/bump-version.sh 0.3.1
git add VERSION Config/Info.plist CHANGELOG.md
git commit -m 'chore(release): bump version to 0.3.1'
```

After the version commit is on `main`, a maintainer can publish from a configured Mac. This runs the tests, builds with Developer ID, notarizes the app and DMG, creates the checksum, creates the `v0.3.1` tag, and uploads both files with `gh`:

```sh
CODE_SIGN_IDENTITY='Developer ID Application: Example Corp (TEAMID)' \
NOTARY_PROFILE='threadlight-notary' \
./scripts/release.sh 0.3.1
```

The same `release.sh` is used by the manual **Build and Release** GitHub Action. The GitHub `release` environment needs these secrets: `MACOS_CERTIFICATE_BASE64`, `MACOS_CERTIFICATE_PASSWORD`, `KEYCHAIN_PASSWORD`, `APPLE_API_KEY_BASE64`, `APPLE_API_KEY_ID`, and `APPLE_API_ISSUER_ID`. The workflow refuses dirty, mismatched, unsigned, unnotarized, or duplicate releases. See [the full release procedure](docs/RELEASE.md).

The open-source `threadlight-verify` command checks package structure, every declared file hash, undeclared files, and the P-256 manifest signature. A valid result still requires comparing the reported signer key ID with a separately trusted record.

## Slack setup

Each organization owns its Slack app and creates it from the single [`docs/slack-app-manifest.yaml`](docs/slack-app-manifest.yaml). The manifest contains organization deployment, PKCE, the ThreadLight callback, bot scope `team:read`, and read-only user scopes `admin.legal_holds:read`, `users:read`, `users:read.email`, `reactions:read`, and `emoji:read`. These provide legal holds, current profiles, live reactions, and workspace emoji. Install from that app's **Settings → Install App → Install to Organization** page. ThreadLight never stores or uses the bot token and never transfers OAuth tokens.

After the connection is verified, ThreadLight generates a removable macOS `.mobileconfig` for MDM. It sets the public Client ID, organization identity, callback, required read-only scopes, and retention policy as forced preferences for `dev.threadlight.app`. On managed Macs, people launch ThreadLight and sign in to Slack; no setup-package import or manual Client ID entry is required. The profile contains no OAuth token, client secret, hold metadata, or evidence.

Slack sessions persist in a ThisDeviceOnly macOS Keychain item across app relaunches. **ThreadLight → Log Out of Slack** removes that item while leaving local evidence encrypted on the Mac.

Slack documents the Legal Holds API separately from ordinary Web API methods. ThreadLight follows the canonical scope table and singular `admin.legalHold.*` request URLs. See the [Slack app installation guide](docs/ADMIN_GUIDE.md).

## Evidence input

In **Settings → Prepare Packages**, select the legal hold and add one or more untouched Slack Enterprise JSON ZIPs. Root-level metadata and Enterprise layouts such as `teams/<workspace>/users.json` are supported. Metadata-only ZIPs are valid and import as zero messages. ThreadLight records each archive hash and operator binding and imports messages only from folders proven by conversation metadata. Save one encrypted package and transfer it through the approved channel. Review Macs import only that encrypted package, never the source ZIPs.

See [`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md), [`SECURITY.md`](SECURITY.md), [`docs/ADMIN_GUIDE.md`](docs/ADMIN_GUIDE.md), and [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

## License

ThreadLight is open source under the [Apache License 2.0](LICENSE). Contributions are welcome; see [`CONTRIBUTING.md`](CONTRIBUTING.md), which requires synthetic fixtures only — never real Slack exports, custodian names, or workspace identifiers.

Third-party attribution is in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

For UI review without Slack credentials, an ad-hoc development build can launch a sanitized local case with `./scripts/threadlight-ui.sh launch-demo`. `launch-demo-complete` loads a fully eligible synthetic case. `./scripts/threadlight-ui.sh smoke-setup` verifies the one-time Slack app settings. `./scripts/threadlight-ui.sh smoke` drives selection, complete-thread JSON/PDF/resource export, independent verification, and in-app verification, then saves a ThreadLight-window-only capture. Demo modes are compiled out of production builds and must never be used for evidence.
