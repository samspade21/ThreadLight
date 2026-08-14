# Troubleshooting

## Slack connection

| ThreadLight message | Cause | Fix |
|---|---|---|
| Your Slack account cannot read legal holds | Applies to the Org Owner install/OAuth path only. For everyday sign-in (embedded browser), this instead means the account genuinely cannot view legal holds in Slack's own admin console. | For the OAuth path, sign in with an Org Owner account. Otherwise, confirm the account has the Legal Holds Admin role (or equivalent) in Slack, by checking whether they can open `/manage/<enterprise-id>/security/legal-holds` in a normal browser. |
| Only a Slack organization owner can complete this installation | This is Slack's own OAuth restriction on the `admin.legal_holds:read` scope — it applies no matter what role the signing-in account otherwise has, and only ever affects the OAuth/org-install path (the "Installing the app to the organization for the first time?" section). | If this person is meant to be a reviewer, not the org installer, they should use the regular **Sign in and verify** button instead — that opens an embedded browser to Slack's own site and does not go through OAuth, so this restriction doesn't apply. |
| ThreadLight is not installed for the Slack organization | The app was installed only in a workspace. | Keep organization deployment and bot scope `team:read`, then install it for the organization. |
| `no_bot_scopes_requested` | The Slack app lost its bot user or bot scope. | Restore the manifest's `bot_user` section and bot scope `team:read`, then sign in again. |
| Browser shows "site can't be reached" after approving | Expected — the callback host `callback.threadlight.invalid` never resolves by design. | Copy the entire address from the browser's address bar and paste it into ThreadLight's sign-in field. |
| Required Slack read access is missing | The app lacks a required user scope. | Use ThreadLight's manifest with its five read-only user scopes plus bot scope `team:read`, then sign in again. |
| Slack did not grant exactly the read scopes | The user authorization has an additional scope or an incomplete grant. | Keep only the five ThreadLight user scopes. The installation bot scope `team:read` remains expected. |
| PKCE is not enabled | The Slack app is not configured as a public PKCE client. | Enable PKCE, verify the callback, then start a new sign-in. |
| OAuth callback does not match | Slack and ThreadLight have different redirect values. | Use exactly `https://callback.threadlight.invalid/oauth/callback`. |
| Your Slack sign-in is no longer valid | The token was revoked, expired, or the account became inactive. | Sign in to Slack again. |
| Embedded sign-in browser shows Slack's own "your browser is not supported" page | Slack's server-side minimum browser version increased past what ThreadLight currently presents. Not a real compatibility issue — ThreadLight presents as a current desktop Safari, but that claimed version can go stale as Slack raises its bar. | Check `https://slack.com/help/articles/115002037526-Minimum-requirements-for-using-Slack` for the current minimum Safari version and report it — the presented version needs updating to match. |
| Embedded sign-in browser is blank/white after Okta or another SSO provider | Usually the SSO page itself failing to render, unrelated to Slack. Check that provider's own sign-in logs first. | If their logs show nothing (the request never arrived), it's likely being blocked client-side rather than rejected server-side — report what's shown in the embedded browser's own console (Safari's Develop menu can attach to it in a development build). |
| Embedded sign-in never finishes even though the person is clearly signed in and on the legal holds page | The page hasn't actually finished loading yet by ThreadLight's own check, or Slack's site navigated there via an in-page route change ThreadLight didn't observe. | Try again — if it persists, note whether the browser window still shows any loading indicator. |

If Slack rejects the internal app or scope despite correct setup, stop. Do not substitute ordinary search scopes or a shared Marketplace credential.

## Managed settings

| Symptom | Fix |
|---|---|
| ThreadLight says it is not set up on this Mac | Confirm MDM installed the generated `.mobileconfig` as forced preferences for `dev.threadlight.app`, then reopen ThreadLight. |
| ThreadLight opens with no Client ID | Confirm the installed profile contains `ThreadLightSlackClientID`. No setup-package fallback exists. |
| ThreadLight connects to a different organization | Verify the profile's organization, sign out of Slack in the browser, select the correct organization, and sign in again. |
| No legal holds are available | Confirm the signed-in account can view legal holds in Slack. |

## Import

| Symptom | Fix |
|---|---|
| ZIP is rejected as non-Slack | Use an untouched Slack JSON ZIP containing `users.json` or `org_users.json` plus conversation metadata. Root and `teams/<workspace>/` layouts are accepted. |
| ZIP already imported | Remove the duplicate. ThreadLight identifies every source by SHA-256 within the selected hold. |
| Coverage warning | Re-export the missing date range. A warning does not expand export eligibility. |
| Missing original attachment | Import the original from the message detail pane. Slack links alone do not prove bytes were preserved. |
| Attachment byte count does not match | Choose the original file whose size matches Slack's JSON metadata. |
| Import paused | Select the identical untouched ZIP and use the same importer name. ThreadLight resumes from its encrypted checkpoint. |
| Encrypted package does not match | If the hold or current member list changed, the old package is intentionally invalid. Create and transfer a new package. |

## Search and export

- Released holds show metadata only; search, import, and export are blocked.
- `NOT` and quoted field phrases require Advanced mode, for example `fraud AND NOT text:"test transaction"`.
- Export requires a live check that the hold remains active and its member fingerprint is unchanged.
- If Secure Enclave signing fails, ThreadLight does not fall back to a weaker software key.
- Independently verify an evidence package with `./scripts/verify-evidence.sh /path/to/package.threadlight-evidence`.

## Safe diagnostics

Never attach real exports, tokens, databases, or customer screenshots to an issue. Reproduce with synthetic data and report the ThreadLight version, macOS version, failing stage, and sanitized error text.
