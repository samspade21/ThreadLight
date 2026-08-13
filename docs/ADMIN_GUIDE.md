# Slack app installation and deployment

Install the ThreadLight Slack app once for the organization. Then distribute the generated settings profile through MDM. Each person signs in to Slack locally; no OAuth token, Client Secret, or setup package is transferred.

## Before you begin

You need:

- a Slack Enterprise organization;
- a Slack organization owner for organization-wide installation;
- an account allowed to read Slack legal holds;
- MDM access for the Macs that will use ThreadLight.

## 1. Create the app

1. Open **ThreadLight → Settings → Install Slack App in Org**.
2. Choose **Copy manifest**.
3. Open [Slack app management](https://api.slack.com/apps).
4. Choose **Create New App → From an app manifest**.
5. Choose a workspace in the target organization, select **YAML**, paste the manifest, and create the app.

Use the manifest unchanged. It contains organization deployment, PKCE, `threadlight://oauth/callback`, bot scope `team:read`, and user scope `admin.legal_holds:read`. ThreadLight never needs the Client Secret.

## 2. Enter the app details

In Slack, open **Basic Information → App Credentials**. Copy the public Client ID into ThreadLight. Enter the organization name and Slack address. Do not copy the Client Secret.

## 3. Install and verify

1. Open the ThreadLight app in Slack app management.
2. In the app's left sidebar, choose **Settings → Install App**. The URL ends in `/install-on-team`.
3. Choose **Install to Organization** and select the Enterprise organization.
4. Return to ThreadLight and choose **Sign in and verify**.
5. When ThreadLight confirms that Slack returned the legal hold list, choose **Save MDM profile…**.
6. Add the `.mobileconfig` to MDM and assign it to the managed Macs that will use ThreadLight.

The installation entry point matters. If Slack returns `no_bot_scopes_requested`, return to the specific app's **Settings → Install App** page. ThreadLight's later sign-in uses Slack's user authorization flow and does not reinstall the app.

## Prepare an encrypted package

1. Open **ThreadLight → Settings → Prepare Packages**.
2. Select an active legal hold and confirm its name and description.
3. Add one or more untouched Slack JSON export ZIPs. Do not unzip, edit, or recompress them.
4. Choose **Save encrypted package…**.
5. Transfer the `.threadlight-hold` file through the approved channel.

On a managed review Mac, ThreadLight loads the legal holds available to the signed-in person. Select a hold, choose **Import encrypted package**, then search the imported messages. If Slack later reports a different hold or member list, ThreadLight removes the old local data and requires a new package.

The package key is derived from authorization-visible identifiers. This gates normal app access through Slack, but it is not equivalent to a high-entropy user-held private key if those identifiers leak.
