# Troubleshooting

## Slack connection

| ThreadLight message | Cause | Fix |
|---|---|---|
| Your Slack account cannot read legal holds | The signed-in account lacks access. | Sign in with an account that can read Slack legal holds. |
| Only a Slack organization owner can complete this installation | The app was not installed by an organization owner. | Use the app's **Settings → Install App → Install to Organization** page. |
| ThreadLight is not installed for the Slack organization | The app was installed only in a workspace. | Keep organization deployment and bot scope `team:read`, then install it for the organization. |
| `no_bot_scopes_requested` | The Slack app lost its bot user or bot scope. | Restore the manifest's `bot_user` section and bot scope `team:read`, then sign in again. |
| Browser shows "site can't be reached" after approving | Expected — the callback host `callback.threadlight.invalid` never resolves by design. | Copy the entire address from the browser's address bar and paste it into ThreadLight's sign-in field. |
| Legal Holds read access is missing | The app lacks the required user scope. | Keep user scope `admin.legal_holds:read` and bot scope `team:read`, then sign in again. |
| Slack did not grant exactly the read scope | The user authorization has an additional scope or an incomplete grant. | Keep only user scope `admin.legal_holds:read`. The installation bot scope `team:read` remains expected. |
| PKCE is not enabled | The Slack app is not configured as a public PKCE client. | Enable PKCE, verify the callback, then start a new sign-in. |
| OAuth callback does not match | Slack and ThreadLight have different redirect values. | Use exactly `https://callback.threadlight.invalid/oauth/callback`. |
| Your Slack sign-in is no longer valid | The token was revoked, expired, or the account became inactive. | Sign in to Slack again. |

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
