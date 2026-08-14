import SwiftUI
import WebKit

/// Hosts `SlackWebSessionSignIn`'s browser so a person can sign in to Slack exactly as they
/// would anywhere else — nothing here is different-looking, nothing technical is ever shown.
private struct SlackWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct SlackWebSessionSheet: View {
    let signIn: SlackWebSessionSignIn
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(signIn.statusText)
                    .font(.headline)
                Spacer()
                Button("Cancel", action: onCancel)
            }
            .padding(12)
            Divider()
            SlackWebView(webView: signIn.webView)
        }
        .frame(minWidth: 720, minHeight: 640)
    }
}
