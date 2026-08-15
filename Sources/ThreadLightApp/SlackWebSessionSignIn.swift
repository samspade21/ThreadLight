import Combine
import Foundation
import Observation
import ThreadLightCore
import WebKit

/// Signs a person into Slack's own admin console inside an embedded browser, then reads legal
/// hold data through that same live, cookie-authenticated session instead of OAuth.
///
/// Slack restricts OAuth for `admin.legal_holds:read` to Org Owners, no matter what a person's
/// own Slack role otherwise permits (confirmed empirically: a non-Owner Legal Holds Admin is
/// blocked from every OAuth authorize variant, but can view and use Slack's own
/// `/manage/<id>/security/legal-holds` admin console page — which calls the exact same
/// `admin.legalHold.*` methods, just authenticated by the browser's session cookie instead of a
/// bearer token). This reads that same page's own traffic to make the same calls on the app's
/// behalf, so the person only ever sees an ordinary Slack sign-in screen — never DevTools, never
/// a token, never anything technical.
@MainActor
@Observable
final class SlackWebSessionSignIn: NSObject {
    let webView: WKWebView
    private(set) var isPresented = false
    private(set) var statusText = "Sign in to Slack to continue."

    private var targetPath = ""
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var urlObservation: AnyCancellable?

    override init() {
        let contentController = WKUserContentController()
        // Real Safari exposes a `window.safari` namespace that WKWebView does not; that
        // presence/absence is a well-known way sites tell them apart, independent of the user
        // agent string. This stubs just enough of it to pass a `typeof window.safari` check —
        // unlike the session tap (installed later, post-login), it never touches fetch/XHR.
        contentController.addUserScript(WKUserScript(
            source: Self.safariStubScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        // Installed early so it's active before the target page makes its own first
        // admin.legalHold.* call — installing it later (e.g. after didFinish) would miss that
        // call entirely, since it'd already have gone out through the original, unpatched
        // fetch/XHR. Self-gated to slack.com only, so it never touches Okta/login pages.
        contentController.addUserScript(WKUserScript(
            source: Self.tapScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController = contentController
        // A zero starting frame leaves WKWebView's compositor negotiating its surface size at
        // the same time SwiftUI is still creating the sheet's own window — that race is what
        // painted a black or blank-white frame until the person retried enough times to win it.
        // Starting at the sheet's real size (SlackWebSessionSheet's minWidth/minHeight) avoids
        // the race instead of just narrowing it.
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 720, height: 640), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
#if THREADLIGHT_DEVELOPMENT
        // Dev builds only: lets Safari's Develop menu attach to this web view so the actual
        // cause of a login rejection can be inspected directly, instead of guessed at blind.
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
#endif
        // A WKWebView's default user agent gets rejected by Slack's login page as an
        // unsupported browser; presenting as an ordinary desktop Safari passes that check.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    }

    private static let safariStubScript = #"""
    if (/(^|\.)slack\.com$/i.test(location.hostname) && typeof window.safari === 'undefined') {
      window.safari = {
        pushNotification: {
          permission: function () { return { permission: 'default' }; },
          requestPermission: function () {},
        },
      };
    }
    """#

    /// Navigates to the org's Legal Holds admin page and suspends until the person has signed in
    /// and Slack has actually rendered that page (not a login or SSO redirect page).
    func beginSignIn(enterpriseID: String) async throws {
        // Reset any previous attempt without tearing down the navigation delegate — cancel()
        // clears it defensively for real cancellation, but this method also runs it just to
        // reset state, and a nilled delegate would silently disable didFinish forever after.
        readyContinuation?.resume(throwing: CancellationError())
        readyContinuation = nil
        urlObservation = nil
        webView.navigationDelegate = self

        targetPath = "/manage/\(enterpriseID)/security/legal-holds"
        guard let url = URL(string: "https://app.slack.com\(targetPath)") else {
            throw ThreadLightError.invalidConfiguration("Could not build the Slack legal holds admin console URL.")
        }
        statusText = "Sign in to Slack to continue."
        isPresented = true

        try await withCheckedThrowingContinuation { continuation in
            // readyContinuation must be set before subscribing/loading — WKWebView's .url
            // updates near-instantly when load() starts, before any real navigation or login
            // redirect happens, so the very first KVO firing can arrive before this line if
            // the load happens first. That race meant every URL match got missed, silently
            // discarded by a `readyContinuation != nil` guard that had nothing to resume.
            readyContinuation = continuation
            // Slack's site is a single-page app — the final navigation onto the target page
            // after SSO completes can happen via client-side JS routing, which never fires
            // WKNavigationDelegate.didFinish again. Watching the URL directly catches that too.
            // Also watches isLoading: the URL updates to the requested target optimistically
            // the moment load() starts, well before any login redirect actually happens, so a
            // path match only counts once the page has actually settled.
            let urlChanges = webView.publisher(for: \.url).map { _ in () }
            let loadingChanges = webView.publisher(for: \.isLoading).map { _ in () }
            urlObservation = Publishers.Merge(urlChanges, loadingChanges).sink { [weak self] in
                self?.checkArrival()
            }
            // Starting the load here races SwiftUI's own sheet/window creation triggered by
            // `isPresented = true` above — WebKit can begin compositing before the web view is
            // actually installed in a real window, which is what painted black/white instead of
            // the page. Deferring one run-loop turn lets that window creation finish first.
            let webView = webView
            DispatchQueue.main.async {
                webView.load(URLRequest(url: url))
            }
        }
        urlObservation = nil
        statusText = "Signed in."
        isPresented = false
    }

    private func checkArrival() {
        let url = webView.url
        guard readyContinuation != nil, url?.path == targetPath, !webView.isLoading else { return }
        readyContinuation?.resume()
        readyContinuation = nil
    }

    func cancel() {
        // Stop any in-flight navigation and detach the delegate before this object can be
        // deallocated — releasing a WKWebView while it's still navigating is a real WebKit crash.
        webView.stopLoading()
        webView.navigationDelegate = nil
        urlObservation = nil
        readyContinuation?.resume(throwing: CancellationError())
        readyContinuation = nil
        isPresented = false
    }

    /// Calls a Slack Web API method through the page's own authenticated session — the same
    /// mechanism `SlackLegalHoldClient`'s bearer-token transport uses, just carried by the
    /// browser's cookies and captured session token instead of an `Authorization` header.
    /// Returns raw JSON `Data`, not a parsed dictionary — `[String: Any]` isn't `Sendable` and this
    /// crosses from this `@MainActor` type into the `SlackLegalHoldClient` actor.
    func call(method: String, fields: [String: String]) async throws -> Data {
        let value: Any?
        do {
            value = try await webView.callAsyncJavaScript(
                "return JSON.stringify(await window.__threadLightCallSlackAPI(method, fields));",
                arguments: ["method": method, "fields": fields],
                in: nil,
                contentWorld: .page
            )
        } catch {
            ThreadLightLog.session.error("web session call failed: method=\(method, privacy: .public) category=\(ThreadLightLog.category(of: error), privacy: .public)")
            let nsError = error as NSError
            if nsError.domain == WKError.errorDomain, nsError.code == WKError.Code.javaScriptExceptionOccurred.rawValue {
                // Raw WKError surfaces as "A JavaScript exception occurred", which reads like a
                // crash and says nothing actionable. The JS message carries the real cause —
                // most commonly the session tap timing out because the signed-in Slack page has
                // gone stale — and the fix is always the same: sign in again.
                let jsMessage = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String
                throw ThreadLightError.slack(
                    "Slack's web session could not complete \(method). "
                        + (jsMessage ?? "The Slack page reported a script error.")
                        + " The saved Slack sign-in has likely gone stale — sign in to Slack again, then retry.",
                    remediation: "Sign in to Slack again, then retry."
                )
            }
            throw error
        }
        guard let jsonString = value as? String, let data = jsonString.data(using: .utf8) else {
            ThreadLightLog.session.error("web session call: unreadable response method=\(method, privacy: .public)")
            throw ThreadLightError.slack(
                "Slack's web session returned an unreadable response.",
                remediation: "Try signing in again."
            )
        }
        return data
    }

    /// Generic session tap, adapted from `SlackExportScript`'s DevTools helper: watches the
    /// page's own outgoing requests for its live `xoxc` token and query params, then reuses them
    /// to make additional calls the app asks for. Runs silently — nothing here is ever shown to
    /// the person signing in, unlike the admin-facing DevTools version this was adapted from.
    private static let tapScript = #"""
    (function () {
      if (!/(^|\.)slack\.com$/i.test(location.hostname)) return;
      if (window.__threadLightTapInstalled) return;
      window.__threadLightTapInstalled = true;
      window.__threadLightSessionSeen = {};

      function extractToken(b) {
        try {
          if (!b) return null;
          if (b instanceof FormData) {
            const t = b.get('token');
            return (typeof t === 'string' && t.startsWith('xoxc-')) ? t : null;
          }
          if (b instanceof URLSearchParams) {
            const t = b.get('token');
            return (typeof t === 'string' && t.startsWith('xoxc-')) ? t : null;
          }
          if (typeof b === 'string') {
            let m = /"token"\s*:\s*"(xoxc-[^"]+)"/.exec(b);
            if (m) return m[1];
            m = /(?:^|&)token=(xoxc-[^&]*)/.exec(b);
            if (m) return decodeURIComponent(m[1]);
          }
        } catch (e) {}
        return null;
      }

      function record(url, body) {
        const t = extractToken(body);
        if (!t) return;
        let h = '';
        let params = {};
        try {
          const u = new URL(url, location.href);
          h = u.host;
          params = Object.fromEntries(u.searchParams.entries());
        } catch (e) { h = String(url); }
        const prev = window.__threadLightSessionSeen[h];
        window.__threadLightSessionSeen[h] = { token: t, params: Object.assign({}, prev && prev.params, params) };
      }

      const open = XMLHttpRequest.prototype.open;
      const send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (m, u) { this.__threadLightTapUrl = u; return open.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function (b) { record(this.__threadLightTapUrl, b); return send.apply(this, arguments); };

      const f = window.fetch;
      window.fetch = function (i, init) {
        const u = (typeof i === 'string') ? i : (i && i.url);
        if (init && init.body) record(u, init.body);
        return f.apply(this, arguments);
      };

      function seenEnterpriseHost() {
        return Object.keys(window.__threadLightSessionSeen).find(h => /\.enterprise\.slack\.com$/i.test(h));
      }

      function enterpriseApiUrl(host, path) {
        const captured = (window.__threadLightSessionSeen[host] && window.__threadLightSessionSeen[host].params) || {};
        const params = new URLSearchParams(captured);
        const m = location.pathname.match(/\/manage\/(E[A-Z0-9]+)/);
        if (m) params.set('slack_route', m[1] + ':' + m[1]);
        return 'https://' + host + path + '?' + params.toString();
      }

      window.__threadLightCallSlackAPI = async function (method, fields) {
        const start = Date.now();
        let host = seenEnterpriseHost();
        while (!host) {
          if (Date.now() - start > 20000) {
            throw new Error('ThreadLight never saw a Slack Enterprise admin request on this page — sign in and stay on the legal holds page, then try again.');
          }
          await new Promise(r => setTimeout(r, 500));
          host = seenEnterpriseHost();
        }
        const body = new FormData();
        body.append('token', window.__threadLightSessionSeen[host].token);
        Object.keys(fields || {}).forEach(function (k) { body.append(k, String(fields[k])); });
        const res = await fetch(enterpriseApiUrl(host, '/api/' + method), {
          method: 'POST',
          body: body,
          credentials: 'include',
        });
        return await res.json().catch(function () { return { ok: false, error: 'http_' + res.status }; });
      };
    })();
    """#
}

extension SlackWebSessionSignIn: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkArrival()
    }
}
