# Release procedure

Production release is blocked until every gate below is complete.

## Version policy

ThreadLight follows Semantic Versioning and starts at `0.3.0`.

- Patch (`0.3.0` → `0.3.1`): compatible bug and security fixes.
- Minor (`0.3.0` → `0.4.0`): compatible features or meaningful workflow changes.
- Major (`0.x` → `1.0.0`, then `1.x` → `2.0.0`): a declared stable release or an incompatible evidence/package/workflow change.

`VERSION` is the release source of truth. The checked-in Info.plist must match it, and published tags use the same value with a `v` prefix. Bump and commit the version before releasing:

```sh
./scripts/bump-version.sh 0.3.1
git add VERSION Config/Info.plist CHANGELOG.md
git commit -m 'chore(release): bump version to 0.3.1'
```

## Required gates

- Enterprise Grid E2E: an Enterprise organization owner installs the customer-owned PKCE app; an account with Legal Holds access authorizes it; ThreadLight lists real policies and member entity IDs.
- Package-transfer E2E: multiple hold-wide ZIPs normalize, encrypt, auto-match, import, search, export, and verify successfully.
- Senior engineering review: SQLCipher schema v4, v1→v4 migration/backfill and rollback strategy, source-specific message provenance, checkpoint recovery, organization isolation, and retention behavior.
- AppSec review: OAuth, archive parsing, local encryption, evidence scope, dependency audit, and signing claims.
- Performance: representative million-message archive with bounded memory, cancellation, and interactive search.
- Legal/brand: third-party screenshot links and generated visual assets approved for distribution.

## Build and test

```sh
swift package resolve
swift test
./scripts/build-app.sh --development
codesign --verify --deep --strict --verbose=2 build/ThreadLight.app
./scripts/verify-reproducible-build.sh
./scripts/verify-evidence.sh /path/to/package.threadlight-evidence
./scripts/threadlight-ui.sh smoke-setup
./scripts/threadlight-ui.sh smoke
```

The UI smoke commands require macOS Accessibility and Screen Recording permission for the invoking terminal. `smoke-setup` verifies the one-time Slack app settings. `smoke` uses only sanitized development data for the review/export flow and writes output under `build/ui-smoke-*`.
The evidence verifier also requires canonical v1 manifest metadata and a canonical v2 signature envelope; valid cryptography alone does not permit unsupported or internally inconsistent package claims.

Run the opt-in real-ZIP benchmark separately from CI. Set the count to the release fixture size:

```sh
python3 scripts/generate-performance-fixture.py build/performance-2000000-valid.zip 2000000

THREADLIGHT_PERFORMANCE_MESSAGES=2000000 \
THREADLIGHT_PERFORMANCE_ARCHIVE="$PWD/build/performance-2000000-valid.zip" \
swift test --filter optInLargeSlackArchiveImportAndSearchPerformance
```

Current result on 2026-08-11 (Apple M2 Pro, 32 GB, macOS 26.6.1, Swift 6.3.3) using a Slack-shaped archive whose dated files all belong to the `performance` conversation declared in `channels.json`: 2,000,000 messages imported in 297.35 seconds, scoped FTS search in 0.056 seconds, 242,008,064-byte peak RSS, and zero swaps. The opt-in benchmark now fails at 1 GB peak RSS. The corresponding 200,000-message run imported in 28.46 seconds, searched in 0.005 seconds, used 96,534,528-byte peak RSS, and recorded zero swaps.

## Developer ID and notarization

Store the Developer ID identity and notary profile in the approved Apple/CI credential store. Never commit them.

Create the notary profile once per maintainer Mac:

```sh
xcrun notarytool store-credentials <profile> \
    --apple-id <apple-id> \
    --team-id <TEAMID> \
    --password <app-specific-password>
```

Then record the identity and profile in a gitignored `.signing.env` so release builds pick them up without re-exporting on every invocation. `--release` builds and `build-release.sh` source it; `--development` builds ignore it and stay ad-hoc signed. Environment variables already set always win, so GitHub Actions is unaffected.

```sh
cp .signing.env.example .signing.env
$EDITOR .signing.env

./scripts/build-app.sh --release
./scripts/verify-release-app.sh build/ThreadLight.app
```

Passing the values inline still works and overrides `.signing.env`:

```sh
CODE_SIGN_IDENTITY='Developer ID Application: Example Corp (TEAMID)' \
NOTARY_PROFILE='threadlight-notary' \
./scripts/build-app.sh --release
```

A Developer ID build now requires a notary profile and fails unless Apple's final status is `Accepted`. The release verifier independently requires the Developer ID authority and team, hardened runtime, production-only entitlements, same-team SQLCipher signature, no demo hooks, a valid stapled ticket, and Gatekeeper acceptance. ThreadLight does not emit a merely signed-but-unnotarized production app.

The ad-hoc build is for local testing only. It keeps OAuth tokens in macOS Keychain so sessions survive relaunches, while writing the database key to a plaintext local key file beside the database and signing evidence with ephemeral keys, which is why it must never hold real evidence. A rebuild may cause macOS to request Keychain authorization. It is not a distributable signed/notarized release and is not byte-for-byte comparable with a timestamped production signature.

The reproducibility check compares every file in two ad-hoc app bundles built from the same checkout, lockfile, and local Swift/Xcode toolchain. Developer ID signatures and notarization tickets contain external timestamps and are verified for trust, not byte equality.

## Publish from a maintainer Mac

Install and authenticate GitHub CLI, and configure the Apple notary profile in the login Keychain. The checkout must be clean and the target release must not already exist.

```sh
gh auth login
./scripts/release.sh 0.3.0
```

`release.sh` reads `.signing.env` through `build-release.sh`. Inline `CODE_SIGN_IDENTITY` and `NOTARY_PROFILE` still take precedence when set.

`release.sh` is the common local/CI entry point. It calls `build-release.sh`, which resolves dependencies, runs release tests, builds the production app, validates and notarizes it, creates `ThreadLight-0.3.0.dmg`, signs and notarizes the DMG, writes its SHA-256 checksum, and runs final Apple validation. It then uses `gh release create` to create tag `v0.3.0`, generate release notes, and upload both artifacts to `samspade21/ThreadLight`.

## Publish from GitHub Actions

The **Build and Release** workflow uses only `workflow_dispatch`; it never publishes on a push or pull request. Before using it, create a protected GitHub environment named `release` and add:

- `MACOS_CERTIFICATE_BASE64`: base64-encoded Developer ID Application `.p12`.
- `MACOS_CERTIFICATE_PASSWORD`: password for that `.p12`.
- `KEYCHAIN_PASSWORD`: throwaway password for the runner's temporary Keychain.
- `APPLE_API_KEY_BASE64`: base64-encoded App Store Connect API `.p8` key.
- `APPLE_API_KEY_ID`: App Store Connect API key ID.
- `APPLE_API_ISSUER_ID`: App Store Connect issuer ID.

From **Actions → Build and Release → Run workflow**, enter the exact version already committed in `VERSION`. The workflow imports credentials into an ephemeral Keychain, invokes the same `release.sh` used locally, and removes that Keychain afterward. GitHub's environment approval rules should require a maintainer before secrets are released to the job.
