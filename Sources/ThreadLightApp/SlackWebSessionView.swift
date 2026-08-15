import SwiftUI
import WebKit

/// AppKit, not a run-loop delay, decides when the sheet has a real window. Navigation must wait
/// for this callback: loading an unattached `WKWebView` intermittently leaves its remote layer
/// tree blank until WebKit's processes have been warmed by later app launches.
private final class SlackWebViewHost: NSView {
    private let webView: WKWebView
    private let onAttachedToWindow: () -> Void
    // Reassigning always removes the previous registration first, so there is never more than
    // one live observer and a stale one can never fire after this view moves again.
    private var windowVisibilityObserver: NSObjectProtocol? {
        willSet { if let windowVisibilityObserver { NotificationCenter.default.removeObserver(windowVisibilityObserver) } }
    }

    init(webView: WKWebView, onAttachedToWindow: @escaping () -> Void) {
        self.webView = webView
        self.onAttachedToWindow = onAttachedToWindow
        super.init(frame: webView.frame)

        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            windowVisibilityObserver = nil
            return
        }
        // A sheet's child NSWindow can exist — and hold this view — before AppKit has finished
        // animating it on screen as a real, WindowServer-backed drawable; `window != nil` alone
        // still intermittently raced WebKit's compositor. Waiting for the window to actually
        // become key (which a presented sheet always does) is the stronger signal.
        if window.isVisible {
            onAttachedToWindow()
        } else {
            windowVisibilityObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                // `queue: .main` guarantees this already runs on the main thread; this just
                // proves that to the compiler instead of hopping through an actual Task.
                MainActor.assumeIsolated {
                    self?.windowVisibilityObserver = nil
                    self?.onAttachedToWindow()
                }
            }
        }
    }
}

/// Hosts `SlackWebSessionSignIn`'s browser so a person can sign in to Slack exactly as they
/// would anywhere else — nothing here is different-looking, nothing technical is ever shown.
private struct SlackWebView: NSViewRepresentable {
    let signIn: SlackWebSessionSignIn

    func makeNSView(context: Context) -> SlackWebViewHost {
        SlackWebViewHost(webView: signIn.webView) {
            signIn.webViewDidAttachToWindow()
        }
    }

    func updateNSView(_ nsView: SlackWebViewHost, context: Context) {}
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
                Button("Reload", systemImage: "arrow.clockwise") {
                    signIn.reload()
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("If the page below is blank or black, reload it.")
                Button("Cancel", action: onCancel)
            }
            .padding(12)
            Divider()
            SlackWebView(signIn: signIn)
        }
        .frame(minWidth: 720, minHeight: 640)
    }
}
