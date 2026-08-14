import Foundation

/// Generates the DevTools console script an Org Owner pastes on Slack's
/// `/manage/<id>/security/exports` page to bulk-start compliance exports for
/// every custodian on a legal hold.
public enum SlackExportScript {
    public static let filename = "threadlight-slack-export.js"

    /// A ready-to-paste script that exports every listed custodian for the
    /// given date range, then runs itself automatically once pasted.
    public static func build(custodianIDs: [String], startDate: String, endDate: String) -> String {
        template + "\n" + """

        /* ThreadLight: generated for \(custodianIDs.count) custodian(s). Dates are in the rows below. */
        async function runThreadLightExport() {
          if (!seenEnterpriseHost()) {
            console.log('%cThreadLight: ' + NO_TRAFFIC_SEEN_HINT, 'color:#4A154B;font-weight:bold');
            const start = Date.now();
            while (!seenEnterpriseHost()) {
              if (Date.now() - start > 60000) {
                console.error('ThreadLight: still no Slack request seen from this page. Interact with the page (e.g. its search box), then run runThreadLightExport() again.');
                return;
              }
              await new Promise(r => setTimeout(r, 1000));
            }
          }
          const rows = \(encodeRows(custodianIDs: custodianIDs, startDate: startDate, endDate: endDate));
          console.log(`ThreadLight: exporting ${rows.length} custodian(s)…`);
          await slackExportMany(rows);
          console.log('%cTHREADLIGHT EXPORT COMPLETE', 'font-weight:bold;font-size:16px;color:#4A154B');
        }
        runThreadLightExport();
        """
    }

    private static func encodeRows(custodianIDs: [String], startDate: String, endDate: String) -> String {
        let rows = custodianIDs.map { [$0, startDate, endDate] }
        guard let data = try? JSONSerialization.data(withJSONObject: rows),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// Verbatim console helper, validated against a real Enterprise Grid session:
    /// nothing here is hard-coded to a specific org, host, or account — the
    /// enterprise id comes from the current URL, and the API host, token, and
    /// required query params (slack_route, _x_csid) are all read live off
    /// traffic the page itself generates. `credentials: 'include'` is required
    /// because the xoxc token alone isn't sufficient — the enterprise host also
    /// needs the browser's own xoxd session cookie alongside it.
    static let template = #"""
    /**
     * Slack compliance export — console helper
     *
     * Generic across orgs: nothing here is hard-coded to a specific enterprise,
     * host, or account. The enterprise id comes from the current URL, and the API
     * host + required query params are read live off the authenticated session
     * (see installTokenTap below). Auth needs the browser's own session cookie
     * (xoxd) alongside the xoxc token in the body — confirmed by replaying a real
     * captured request with and without it — so these calls use `credentials:
     * 'include'` rather than trying to reconstruct the cookie by hand.
     *
     * Paste this whole file into the DevTools console while sitting on your org's
     * exports admin page:
     *   https://app.slack.com/manage/<ENTERPRISE_ID>/security/exports
     * (logged in as an Org Owner).
     *
     * Then:
     *   await slackExport('U01ABC23DEF', '2026-06-30', '2026-08-13');
     *   await slackExport('U01ABC23DEF', '2026-06-30');            // end date defaults to today
     *   await slackExportMany([['U01ABC23DEF','2026-06-30','2026-08-13'], ...]);
     *
     * Dates are 'YYYY-MM-DD' and are interpreted in YOUR browser's local timezone:
     * start = 00:00:00.000 local, end = 23:59:59 local — same as the UI's date pickers.
     */

    const SLACK_EXPORT_CONFIG = {
      exportType: 'MANUAL_COMPLIANCE_USER',
      format: 'JSON',
    };

    /** Enterprise (org) id — parsed from the current /manage/<id>/... URL. Never hard-coded. */
    function enterpriseId() {
      const m = location.pathname.match(/\/manage\/(E[A-Z0-9]+)/);
      if (!m) {
        throw new Error(
          'Not on a /manage/<ENTERPRISE_ID>/... page. Navigate to your org\'s ' +
          'https://app.slack.com/manage/<enterprise id>/security/exports page first.'
        );
      }
      return m[1];
    }

    /**
     * Watch Slack's own outgoing admin API calls and remember, per host: the xoxc
     * token they carry, and the full query string (slack_route, _x_csid, etc.).
     * The token in page storage (boot_data.api_token, localConfig_v2) is the
     * *workspace* token and gets rejected by the enterprise host with invalid_auth
     * — this tap watches real traffic instead. _x_csid in particular turned out to
     * matter: it's absent from early boot calls (client.init, enterprise.info) but
     * present on every admin/search/export call, and requests built without it
     * failed the same way requests with the wrong token did. Installed
     * automatically when this file is pasted.
     */
    function installTokenTap() {
      if (window.__tokenTapInstalled) return;
      window.__tokenTapInstalled = true;
      window.__slackSessionSeen = window.__slackSessionSeen || {}; // host -> { token, params }

      const extractToken = (b) => {
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
            // JSON body: {"token":"xoxc-..."}
            let m = /"token"\s*:\s*"(xoxc-[^"]+)"/.exec(b);
            if (m) return m[1];
            // form-encoded body: token=xoxc-...
            m = /(?:^|&)token=(xoxc-[^&]*)/.exec(b);
            if (m) return decodeURIComponent(m[1]);
          }
        } catch (e) { /* ignore */ }
        return null;
      };

      const record = (url, body) => {
        const t = extractToken(body);
        if (!t) return;
        let h = '';
        let params = {};
        try {
          const u = new URL(url, location.href);
          h = u.host;
          params = Object.fromEntries(u.searchParams.entries());
        } catch (e) { h = String(url); }
        // Merge rather than overwrite: some calls (client.init, enterprise.info) carry
        // the token but no _x_csid yet — keep the richest params seen for this host.
        const prev = window.__slackSessionSeen[h];
        window.__slackSessionSeen[h] = { token: t, params: { ...(prev && prev.params), ...params } };
      };

      const open = XMLHttpRequest.prototype.open;
      const send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (m, u) { this.__tapUrl = u; return open.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function (b) { record(this.__tapUrl, b); return send.apply(this, arguments); };

      const f = window.fetch;
      window.fetch = function (i, init) {
        const u = (typeof i === 'string') ? i : (i && i.url);
        if (init && init.body) record(u, init.body);
        return f.apply(this, arguments);
      };
    }
    installTokenTap();

    /**
     * Which observed host is the Enterprise Grid admin API host. Every Enterprise
     * Grid org serves its admin API from <org-domain>.enterprise.slack.com — that
     * suffix is a Slack platform convention (confirmed via HAR), not anything
     * specific to one org, so we match on it rather than hard-coding a domain.
     */
    function seenEnterpriseHost() {
      const seen = window.__slackSessionSeen || {};
      return Object.keys(seen).find(h => /\.enterprise\.slack\.com$/i.test(h));
    }

    /** What the tap has seen so far — hosts and whether _x_csid was captured, never token values. */
    function slackTokenStatus() {
      const seen = window.__slackSessionSeen || {};
      const rows = Object.keys(seen).map(h => ({
        host: h,
        isEnterpriseHost: /\.enterprise\.slack\.com$/i.test(h),
        hasCsid: !!(seen[h].params && seen[h].params._x_csid),
      }));
      console.table(rows.length ? rows : [{ host: '(nothing seen yet)', isEnterpriseHost: false, hasCsid: false }]);
      return rows.map(r => r.host);
    }

    const NO_TRAFFIC_SEEN_HINT =
      'The tap only fires when the page makes a request, and cached tabs may not make one. ' +
      'Try: switch to the Downloads tab, or type a letter into the search box at the top, ' +
      'then run slackTokenStatus() to confirm.';

    /** Resolve the Enterprise Grid API host, e.g. "https://acme.enterprise.slack.com". Never hard-coded. */
    function enterpriseApiHost() {
      // 1. Manual override, if you pasted one in yourself.
      if (typeof window.__slackExportHost === 'string' && window.__slackExportHost) {
        return window.__slackExportHost.replace(/\/+$/, '');
      }
      const host = seenEnterpriseHost();
      if (host) return `https://${host}`;

      throw new Error(
        `No enterprise API host seen yet. ${NO_TRAFFIC_SEEN_HINT}\n` +
        'Or set it by hand: window.__slackExportHost = "https://<org>.enterprise.slack.com";'
      );
    }

    /** Resolve the org-level xoxc- token. Never hard-coded. */
    function slackToken() {
      // 1. Manual override, if you pasted one in yourself.
      if (typeof window.__slackExportToken === 'string' && window.__slackExportToken) {
        return window.__slackExportToken;
      }
      const seen = window.__slackSessionSeen || {};
      // 2. Prefer a token seen going to the enterprise host itself.
      const host = seenEnterpriseHost();
      if (host) return seen[host].token;
      // 3. Otherwise any xoxc- token seen on Slack traffic (edgeapi, etc.).
      const any = Object.values(seen)[0];
      if (any) return any.token;

      throw new Error(`No token seen yet. ${NO_TRAFFIC_SEEN_HINT}\nOr set it by hand: window.__slackExportToken = "xoxc-...";`);
    }

    /**
     * Enterprise Grid admin API calls need the query string a real client sends
     * (slack_route plus the _x_* params, especially _x_csid) — confirmed by
     * replaying a real captured request byte-for-byte via curl and seeing it
     * succeed, versus our own hand-built requests (missing these) failing with
     * invalid_auth every time despite a valid token. We clone whatever the tap
     * captured for this host and only override slack_route, since that must match
     * the enterprise id of the page we're actually on.
     */
    function enterpriseApiUrl(path) {
      const id = enterpriseId();
      const host = seenEnterpriseHost();
      const captured = (host && window.__slackSessionSeen[host].params) || {};
      const params = new URLSearchParams(captured);
      params.set('slack_route', `${id}:${id}`);
      return `${enterpriseApiHost()}${path}?${params.toString()}`;
    }

    /** Confirm the token is valid before firing real exports. Read-only, no side effects. */
    async function slackAuthCheck() {
      const body = new FormData();
      body.append('token', slackToken());
      const res = await fetch(enterpriseApiUrl('/api/auth.test'), {
        method: 'POST', body, credentials: 'include',
      });
      const json = await res.json();
      console.log(json.ok ? `✅ authenticated as ${json.user} on ${json.team}` : `❌ ${json.error}`);
      return json;
    }

    /** 'YYYY-MM-DD' -> unix seconds at local start-of-day / end-of-day. */
    function toTs(dateStr, endOfDay) {
      const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(dateStr).trim());
      if (!m) throw new Error(`Bad date "${dateStr}" — expected YYYY-MM-DD`);
      const [, y, mo, d] = m.map(Number);
      const dt = endOfDay
        ? new Date(y, mo - 1, d, 23, 59, 59, 0)
        : new Date(y, mo - 1, d, 0, 0, 0, 0);
      return Math.floor(dt.getTime() / 1000);
    }

    function todayLocal() {
      const n = new Date();
      const p = x => String(x).padStart(2, '0');
      return `${n.getFullYear()}-${p(n.getMonth() + 1)}-${p(n.getDate())}`;
    }

    /**
     * Kick off one compliance export.
     * @param {string} userId    Slack member ID, e.g. 'U01ABC23DEF'
     * @param {string} startDate 'YYYY-MM-DD'
     * @param {string} [endDate] 'YYYY-MM-DD' — defaults to today
     * @param {object} [opts]    { format: 'JSON'|'CSV', exportType, dryRun: true }
     */
    async function slackExport(userId, startDate, endDate, opts = {}) {
      if (!/^[UW][A-Z0-9]+$/i.test(String(userId || '').trim())) {
        throw new Error(`Bad user id "${userId}" — expected something like U01ABC23DEF`);
      }
      const start_ts = toTs(startDate, false);
      const end_ts = toTs(endDate || todayLocal(), true);
      if (end_ts <= start_ts) throw new Error('End date must be after start date');

      const fields = {
        token: slackToken(),
        start_ts: String(start_ts),
        end_ts: String(end_ts),
        export_type: opts.exportType || SLACK_EXPORT_CONFIG.exportType,
        format: opts.format || SLACK_EXPORT_CONFIG.format,
        user: String(userId).trim().toUpperCase(),
        _x_reason: 'StartExportsTab_startExport',
        _x_mode: 'online',
        _x_app_name: 'manage',
      };

      if (opts.dryRun) {
        console.log('[dry run]', { ...fields, token: '<redacted>' },
          new Date(start_ts * 1000).toString(), '->', new Date(end_ts * 1000).toString());
        return { ok: true, dryRun: true };
      }

      const body = new FormData();
      Object.entries(fields).forEach(([k, v]) => body.append(k, v));

      const res = await fetch(enterpriseApiUrl('/api/compliance.exports.start'), {
        method: 'POST',
        body,
        // 'include': the xoxc token in the body is only half of Slack's credential
        // pair — the enterprise host also needs the browser's own xoxd session
        // cookie, confirmed by replaying a real request with and without it.
        credentials: 'include',
      });
      const json = await res.json().catch(() => ({ ok: false, error: `http_${res.status}` }));

      const range = `${new Date(start_ts * 1000).toLocaleDateString()} – ${new Date(end_ts * 1000).toLocaleDateString()}`;
      console.log(json.ok ? `✅ ${fields.user}  ${range}` : `❌ ${fields.user}  ${range}  → ${json.error}`, json);
      return json;
    }

    /**
     * Run several exports back to back, with a pause so Slack doesn't rate-limit.
     * @param {Array<[string,string,string?]>} rows [userId, startDate, endDate?]
     */
    async function slackExportMany(rows, { delayMs = 1500, ...opts } = {}) {
      const results = [];
      for (const [userId, startDate, endDate] of rows) {
        try {
          results.push({ userId, ...(await slackExport(userId, startDate, endDate, opts)) });
        } catch (e) {
          console.error(`❌ ${userId}`, e.message);
          results.push({ userId, ok: false, error: e.message });
        }
        await new Promise(r => setTimeout(r, delayMs));
      }
      console.table(results.map(r => ({ user: r.userId, ok: r.ok, error: r.error || '' })));
      return results;
    }
    """#
}
