# Contributing

ThreadLight handles legal hold evidence. The rules below exist because a mistake here leaks someone's real messages, not just a build.

## Never commit real data

Use synthetic fixtures for everything. No Slack exports, evidence databases, OAuth tokens, `.threadlight-hold` packages, screenshots of real conversations, custodian names, member IDs, workspace IDs, or enterprise domains — in code, tests, docs, commit messages, issues, or pull requests.

`Tests/ThreadLightCoreTests` shows the fixture style: invented names like `Alex Rivera`, IDs like `U1`, and placeholder orgs like `acme`. Follow it. `.gitignore` already excludes evidence artifacts, exports, `tmp/`, and signing material, but treat that as a backstop, not a review step.

CI runs a `gitleaks` scan on every pull request. It catches credential shapes, not identifiers — you are the check for those.

## Build and test

```bash
swift build -Xswiftc -DTHREADLIGHT_DEVELOPMENT
```

```bash
swift test
```

`./scripts/build-app.sh` produces a runnable `.app`. Without `CODE_SIGN_IDENTITY` it makes an ad-hoc development build, which stores the evidence database key in a plaintext file beside the database and shows a permanent red banner. That build is for development only — never point it at real evidence.

## Changes that need extra care

Say so explicitly in the pull request when you touch:

- **Crypto or key handling** — `Security/KeychainStore.swift`, `Export/SignatureService.swift`, `Import/HoldTransferService.swift`, `Import/ResourceVault.swift`. Explain what the change means for the threat model and update [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) in the same pull request.
- **Untrusted input parsing** — Slack export ZIPs, hold transfers, setup packages, attachment text extraction. Add a test for the malformed case, not just the happy path.
- **The evidence schema or manifest format** — include the migration path.
- **Anything that weakens a documented guarantee.** Change the docs in the same commit. A guarantee the code no longer provides is worse than one it never claimed.

## Style

Match the surrounding code. Comments explain why a constraint exists, not what the line does — the existing comments in `SlackExportImporter.validate` and `PKCE.swift` are the model. Prefer the direct implementation over the abstraction.

## Pull requests

One concern per pull request. State what you changed, why, and how you verified it. If you could not verify something, say that too.
