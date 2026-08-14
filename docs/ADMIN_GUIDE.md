# Slack app installation and deployment

Install the ThreadLight Slack app once for the organization. Then distribute the generated settings profile through MDM. Each person signs in to Slack locally; no OAuth token, Client Secret, or setup package is transferred.

Slack restricts OAuth for the `admin.legal_holds:read` scope to Org Owners, regardless of what a person's own Slack role otherwise permits — this is a Slack platform restriction, not something ThreadLight's setup can grant around. Because of that, sign-in works differently depending on who's signing in:

- **A Slack Org Owner** can use either sign-in button (Slack's OAuth requirements are satisfied either way).
- **Everyone else** (for example, a Legal Holds Admin who is not an Org Owner) signs in through **Sign in and verify**, which opens an embedded browser to Slack's own site. They log in exactly as they would anywhere else — nothing technical, no DevTools, no token ever leaves Slack's session. ThreadLight reads legal hold data through that same signed-in session instead of through OAuth, because Slack's own admin console already respects that person's real Legal Holds Admin role, even though its OAuth API does not.

## Before you begin

You need:

- a Slack Enterprise organization;
- a Slack organization owner for the one-time organization-wide installation;
- for each additional reviewer, a Slack account with permission to view legal holds in Slack's own admin console (Enterprise Grid → Legal Holds) — this does not need to be an Org Owner;
- MDM access for the Macs that will use ThreadLight.

## 1. Create the app

1. Open **ThreadLight → Settings → Install Slack App in Org**.
2. Choose **Copy manifest**.
3. Open [Slack app management](https://api.slack.com/apps).
4. Choose **Create New App → From an app manifest**.
5. Choose a workspace in the target organization, select **YAML**, paste the manifest, and create the app.

Use the manifest unchanged. It contains organization deployment, PKCE, `https://callback.threadlight.invalid/oauth/callback`, bot scope `team:read`, and read-only user scopes `admin.legal_holds:read`, `users:read`, `users:read.email`, `reactions:read`, and `emoji:read`. These supply legal holds, current profiles, live reactions, and workspace emoji. ThreadLight never needs the Client Secret.

## 2. Enter the app details

In Slack, open **Basic Information → App Credentials**. Copy the public Client ID into ThreadLight. Enter the organization name and Slack address. Do not copy the Client Secret.

## 3. Install and verify

1. Open the ThreadLight app in Slack app management.
2. In the app's left sidebar, choose **Settings → Install App**. The URL ends in `/install-on-team`.
3. Choose **Install to Organization** and select the Enterprise organization.
4. Return to ThreadLight and choose **Sign in and verify**. This opens an embedded browser to Slack's own site — sign in as you normally would.
5. When ThreadLight confirms that Slack returned the legal hold list, choose **Save MDM profile…**.
6. Add the `.mobileconfig` to MDM and assign it to the managed Macs that will use ThreadLight.

The same MDM profile works for every Mac, whether the person signing in on it is the Org Owner or a Legal Holds Admin reviewer — nothing in the profile differs by role, since the reviewer sign-in only needs the organization ID the profile already carries (`ThreadLightExpectedOrganizationID`), not the Slack Client ID or OAuth settings. Those OAuth-only fields stay in the profile for the one-time organization install; reviewer Macs simply don't use them.

If a step-4 sign-in shows Slack's own "browser is not supported" page, that's Slack rejecting an out-of-date claimed browser version, not a real compatibility problem — ThreadLight already presents as a current desktop Safari; if this recurs after a Slack platform update, the version it claims may need bumping to match Slack's current minimum (see `https://slack.com/help/articles/115002037526-Minimum-requirements-for-using-Slack`).

**Org Owner install-only alternative:** an Org Owner can instead expand "Installing the app to the organization for the first time?" and use the original OAuth flow. If Slack returns `no_bot_scopes_requested` there, the app manifest lost its `bot_user` section or the `team:read` bot scope — restore the manifest and sign in again. During that sign-in the browser finishes on a page that cannot be reached (`callback.threadlight.invalid`); this is expected. Copy the entire address from the browser's address bar and paste it into ThreadLight to complete the sign-in.

## Prepare an encrypted package

1. Open **ThreadLight → Settings → Prepare Packages**.
2. Select an active legal hold and confirm its name and description.
3. Add one or more untouched Slack JSON export ZIPs. Do not unzip, edit, or recompress them.
4. Choose **Save encrypted package…**.
5. Transfer the `.threadlight` file through the approved channel.

On a managed review Mac, ThreadLight loads the legal holds available to the signed-in person. Select a hold, choose **Import encrypted package**, then search the imported messages. If Slack later reports a different hold or member list, ThreadLight removes the old local data and requires a new package.

The package key is derived from authorization-visible identifiers. This gates normal app access through Slack, but it is not equivalent to a high-entropy user-held private key if those identifiers leak.
