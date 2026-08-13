# Release procedure

Production release is blocked until every gate below is complete.

## Required gates

- Dataminr E2E: an Enterprise organization owner installs the customer-owned PKCE app; an account with Legal Holds access authorizes it; ThreadLight lists real policies and member entity IDs.
- Package-transfer E2E: multiple hold-wide ZIPs normalize, encrypt, auto-match, import, search, export, and verify successfully.
- Senior engineering review: SQLCipher schema v4, v1→v4 migration/backfill and rollback strategy, source-specific message provenance, checkpoint recovery, organization isolation, and retention behavior.
- AppSec review: OAuth, archive parsing, local encryption, evidence scope, dependency audit, and signing claims.
- Performance: representative million-message archive with bounded memory, cancellation, and interactive search.
- Legal/brand: third-party screenshot links and generated visual assets approved for distribution.

## Build and test

```sh
swift package resolve
swift test
./scripts/build-app.sh
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

```sh
CODE_SIGN_IDENTITY='Developer ID Application: Example Corp (TEAMID)' \
NOTARY_PROFILE='threadlight-notary' \
./scripts/build-app.sh

./scripts/verify-release-app.sh build/ThreadLight.app
```

A Developer ID build now requires a notary profile and fails unless Apple's final status is `Accepted`. The release verifier independently requires the Developer ID authority and team, hardened runtime, production-only entitlements, same-team SQLCipher signature, no demo hooks, a valid stapled ticket, and Gatekeeper acceptance. ThreadLight does not emit a merely signed-but-unnotarized production app.

The ad-hoc build is for local testing only. It uses development-only local keys, session-only OAuth, and ephemeral evidence signatures so rebuilds do not trigger Keychain prompts. It is not a distributable signed/notarized release and is not byte-for-byte comparable with a timestamped production signature.

The reproducibility check compares every file in two ad-hoc app bundles built from the same checkout, lockfile, and local Swift/Xcode toolchain. Developer ID signatures and notarization tickets contain external timestamps and are verified for trust, not byte equality.
