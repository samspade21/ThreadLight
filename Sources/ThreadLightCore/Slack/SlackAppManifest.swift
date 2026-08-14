import Foundation

public enum SlackAppManifest {
    public static let filename = "threadlight-slack-app-manifest.yaml"
    public static let createAppURL = URL(string: "https://api.slack.com/apps")!

    public static let template = """
    _metadata:
      major_version: 1
    display_information:
      name: ThreadLight
      description: Local, read-only legal-hold discovery for ThreadLight
      background_color: "#4A154B"
    features:
      bot_user:
        display_name: ThreadLight
        always_online: false
    oauth_config:
      redirect_urls:
        - https://callback.threadlight.invalid/oauth/callback
      scopes:
        bot:
          - team:read
        user:
          - admin.legal_holds:read
          - users:read
          - users:read.email
          - reactions:read
          - emoji:read
      pkce_enabled: true
    settings:
      org_deploy_enabled: true
      socket_mode_enabled: false
    """
}
