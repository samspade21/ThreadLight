# Changelog

ThreadLight follows [Semantic Versioning](https://semver.org/). Published releases use tags such as `v0.3.0` and include GitHub-generated release notes.

## 0.5.0

### Breaking

- The local evidence database uses schema version 5 and there is no upgrade path. ThreadLight refuses an older database and says to delete it and re-import the untouched source ZIPs.
- The hold transfer format changed again and earlier `.threadlight` packages no longer open. The payload is now sealed as framed chunks whose order and end are authenticated, so a reordered or truncated package fails to open instead of decoding to something plausible. Export packages again from 0.5.0.

### Changed

- Importing a Slack export is more than twice as fast. The store caches prepared statements, commits under WAL with synchronous NORMAL, and no longer pays SQLCipher's per-allocation memory locking (`cipher_memory_security` is off: FileVault and macOS encrypted swap already cover plaintext at rest, and the setting doubled import time).
- Opening a hold is faster and stays fast on large holds. The conversation list aggregates over a covering index instead of decrypting every message row, and thread lookups have their own index.
- A message's raw Slack JSON is stored beside the message instead of inside its serialized form, so search and thread reads no longer decode it. JSON evidence exports still include it unchanged.
- Building an evidence export no longer re-reads the same source archives once per message, which large exports felt as minutes of manifest preparation.

## 0.4.1

### Fixed

- Slack sign-in no longer leaves the org/workspace picker to whatever happens to be active in the browser. The authorization URL now pins the org this Mac's MDM profile expects, so a non-admin approving in the wrong context can no longer get silently issued a workspace-scoped token that `admin.legalHold.*` then rejects.
- A custodian's or message sender's resolved name could be replaced by their Slack display name (often a nickname or handle) after a live profile refresh, even when their real name had already been resolved correctly. Every name resolution path now prefers Slack's real name first.

## 0.4.0

### Breaking

- The encrypted hold transfer file is now named `.threadlight` instead of `.threadlight-hold`. Export writes the new extension and import accepts only that one.
- The transfer package format changed and earlier packages no longer open. Anything created by 0.3.0 has to be exported again from 0.4.0. Import recognizes an older package and says so rather than reporting a corrupt file.

### Fixed

- A hold-wide export whose direct messages resolved to the same participant name was rejected whole, with the message that its conversation metadata was ambiguous. Conversations are keyed by the folder name Slack actually writes, so those exports import.
- Re-importing an export already held under a second file name failed the entire batch. That one file is now skipped and reported, and the rest of the batch continues.
- Saving an encrypted package could stop without writing a file and without saying why. Every path through packaging now reports its outcome.
- Each window built its own model, so work done in Settings was invisible to the main window and errors raised in Settings had no alert to present them. One model is now shared across the app.
- Purging local evidence emptied the legal hold list until the next refresh, which looked like being signed out. Holds are read back from Slack once the purge finishes. The Slack sign-in was never affected.
- Every use of the encrypted database is serialized. Transactions could previously interleave with other work on the same connection.

### Changed

- Transfer packages are compressed and no longer repeat a message once per source archive, which reduces a large hold's package by more than an order of magnitude and leaves far more headroom under the 2 GB transfer limit.
- Import and export write diagnostic logs under the `dev.threadlight.app` subsystem, recording stage transitions, counts, and error categories, and never message text, custodian identity, file names, or passphrases. Read a session back with `log show --predicate 'subsystem == "dev.threadlight.app"' --last 1h --info`.
- Error alerts offer to copy a diagnostic report and to open a GitHub issue. The report stays on the clipboard for review before anything is shared, because an error message can quote a path from inside a Slack export.

## 0.3.0

Initial open-source preview release. It includes local Slack legal-hold review, encrypted hold transfer, scoped search, PDF/JSON evidence export, optional evidence signing, current Slack profiles and reactions, managed configuration, and local retention controls.
