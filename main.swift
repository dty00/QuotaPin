// QuotaPin — 在 macOS 菜单栏显示 Claude / Codex 订阅额度
// 配置文件：~/.config/quotapin/accounts.json（首次运行自动生成）

import AppKit
import CryptoKit
import Foundation

// MARK: - 配置

struct AccountConfig: Codable {
    var type: String          // "claude" | "codex"
    var name: String          // 显示名
    var short: String         // 菜单栏上的缩写
    var configDir: String?    // claude: CLAUDE_CONFIG_DIR（默认账号留空）；codex: CODEX_HOME（默认 ~/.codex）
}

struct AppConfig: Codable {
    var accounts: [AccountConfig]
    var refreshMinutes: Int?
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

let configURL = URL(fileURLWithPath: home + "/.config/quotapin/accounts.json")

func loadConfig() -> AppConfig {
    if let data = try? Data(contentsOf: configURL),
       let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) {
        return cfg
    }
    let def = AppConfig(
        accounts: [
            AccountConfig(type: "claude", name: "Claude 1", short: "C1", configDir: nil),
            AccountConfig(type: "claude", name: "Claude 2", short: "C2", configDir: "~/.claude-account2"),
            AccountConfig(type: "codex", name: "Codex", short: "X", configDir: nil),
        ],
        refreshMinutes: 5)
    try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? enc.encode(def).write(to: configURL)
    return def
}

// MARK: - 结果模型

struct Window {
    var label: String       // "5 小时" / "每周" ...
    var percent: Double     // 已用 %
    var resetsAt: Date?
    var kind: String = ""   // session / weekly_all / weekly_scoped
    var model: String?      // 按模型计算的额度对应的模型名，例如 Fable

    /// 显示用的百分比：重置时间已过（数据是旧的）就当作 0%
    var pct: Double { (resetsAt.map { $0 < Date() } ?? false) ? 0 : percent }
}

struct AccountStatus {
    var config: AccountConfig
    var windows: [Window] = []
    var plan: String?
    var error: String?
    var errorCode: Int?
    var fetchedAt: Date?
    var staleNote: String?   // 显示的是旧数据时的说明（例如接口限流）

    /// 菜单栏显示的数字：总额度里用得最多的那个（模型专属额度只在菜单里显示）
    var headline: Double? { windows.filter { $0.model == nil }.map(\.pct).max() }
    var session: Window? { windows.first { $0.kind == "session" } }
    var weekly: Window? { windows.first { $0.model == nil && $0.kind.hasPrefix("weekly") } ?? windows.first { $0.label == "每周" } }
    var scoped: [Window] { windows.filter { $0.model != nil } }
}

// MARK: - 推荐：先用哪个 Claude 账号

struct Advice {
    var best: String?          // 推荐账号的 short
    var lines: [String]
}

/// 思路：每周额度到点就清零，用不完就浪费。
/// 1. 当前不能用的账号（5 小时或每周额度 ≥ 98%）排除；
/// 2. 剩下的账号里，算"要在重置前用完，每小时需要用掉多少 %"，这个值越大越紧迫，优先用它；
/// 3. 某个模型（例如 Fable）的专属额度快满时，提示用这个模型时切到另一个账号。
func makeAdvice(_ all: [AccountStatus]) -> Advice {
    let claude = all.filter { $0.config.type == "claude" && $0.error == nil && $0.weekly != nil }
    guard claude.count >= 2 else { return Advice(best: nil, lines: []) }

    func hoursLeft(_ w: Window?) -> Double? { w?.resetsAt.map { max($0.timeIntervalSinceNow / 3600, 0.1) } }
    func blocked(_ s: AccountStatus) -> String? {
        if let w = s.weekly, w.pct >= 98 { return "每周额度已满" }
        if let w = s.session, w.pct >= 98 { return "5 小时额度已满" + resetText(w.resetsAt) }
        return nil
    }
    func urgency(_ s: AccountStatus) -> Double {
        let remain = 100 - (s.weekly?.pct ?? 0)
        // 还没开始计时的每周窗口（没有重置时间）不会浪费，紧迫度最低
        guard let h = hoursLeft(s.weekly) else { return remain / (7 * 24) * 0.5 }
        return remain / h
    }
    func fmtHours(_ h: Double) -> String { h >= 24 ? String(format: "%.1f 天", h / 24) : String(format: "%.0f 小时", h) }

    var lines: [String] = []
    let usable = claude.filter { blocked($0) == nil }.sorted { urgency($0) > urgency($1) }
    for s in claude where blocked(s) != nil { lines.append("\(s.config.short) 暂不可用：\(blocked(s)!)") }

    guard let best = usable.first else {
        lines.insert("两个 Claude 账号现在都用不了", at: 0)
        return Advice(best: nil, lines: lines)
    }
    let remain = 100 - (best.weekly?.pct ?? 0)
    var why = "还剩 \(Int(remain))%"
    if let h = hoursLeft(best.weekly) { why += "，\(fmtHours(h))后清零" }
    lines.insert("👉 现在先用 \(best.config.short)（\(best.config.name)）：\(why)", at: 0)

    // 节奏：要在重置前用完，每 5 小时大约该用多少
    for s in usable {
        guard let h = hoursLeft(s.weekly) else { continue }
        let rem = 100 - (s.weekly?.pct ?? 0)
        let per5h = rem / max(h / 5, 1)
        lines.append("\(s.config.short) 想在重置前用完：每 5 小时约用掉每周额度的 \(String(format: "%.1f", per5h))%")
    }

    // 模型专属额度快满时的提示
    for s in claude {
        for w in s.scoped where w.pct >= 80 {
            let m = w.model ?? "该模型"
            let others = usable.filter { $0.config.short != s.config.short }.map(\.config.short)
            var t = "\(s.config.short) 的 \(m) 额度已用 \(Int(w.pct))%"
            t += others.isEmpty ? "，省着用" : "：在 \(s.config.short) 上改用其他模型，要用 \(m) 就切到 \(others.joined(separator: "/"))"
            lines.append(t)
        }
    }
    return Advice(best: best.config.short, lines: lines)
}

// MARK: - 工具函数

@discardableResult
func run(_ path: String, _ args: [String], env: [String: String] = [:]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    var e = ProcessInfo.processInfo.environment
    e["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:" + home + "/.local/bin"
    for (k, v) in env { e[k] = v }
    p.environment = e
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return (-1, "") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func parseISO(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func getJSON(_ url: String, headers: [String: String]) async throws -> [String: Any] {
    var req = URLRequest(url: URL(string: url)!)
    req.timeoutInterval = 20
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    if code != 200 {
        let msg = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(code)"
        throw NSError(domain: "QuotaPin", code: code, userInfo: [NSLocalizedDescriptionKey: msg])
    }
    return obj ?? [:]
}

// MARK: - Claude

/// Claude Code 把登录凭据存在钥匙串里；自定义 CLAUDE_CONFIG_DIR 时服务名带 sha256 前 8 位后缀
func claudeKeychainService(configDir: String?) -> String {
    guard let dir = configDir else { return "Claude Code-credentials" }
    let hash = SHA256.hash(data: Data(expand(dir).utf8)).map { String(format: "%02x", $0) }.joined()
    return "Claude Code-credentials-" + hash.prefix(8)
}

/// 凭据存放位置：钥匙串（带账户名）或 configDir 下的 .credentials.json
enum CredsSource { case keychain(service: String, account: String), file(String) }

func readClaudeCredsFull(configDir: String?) -> (doc: [String: Any], source: CredsSource)? {
    let svc = claudeKeychainService(configDir: configDir)
    let (code, out) = run("/usr/bin/security", ["find-generic-password", "-s", svc, "-w"])
    if code == 0, let data = out.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
       let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        // 写回时要用同一个钥匙串账户名
        let attrs = run("/usr/bin/security", ["find-generic-password", "-s", svc]).1
        let acct = attrs.range(of: #""acct"<blob>="([^"]*)""#, options: .regularExpression)
            .map { String(attrs[$0].dropFirst(14).dropLast()) } ?? NSUserName()
        return (doc, .keychain(service: svc, account: acct))
    }
    if let dir = configDir {   // 兜底：部分环境存在文件里
        let path = expand(dir) + "/.credentials.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (doc, .file(path))
        }
    }
    return nil
}

func readClaudeCreds(configDir: String?) -> [String: Any]? {
    readClaudeCredsFull(configDir: configDir)?.doc["claudeAiOauth"] as? [String: Any]
}

/// 登录过期时用 refresh token 换新 token，并按 Claude Code 的格式写回原处，Claude Code 下次启动会直接用新的。
/// 返回 nil 表示成功，否则是错误说明。
func refreshClaude(configDir: String?) async -> String? {
    guard let (doc, source) = readClaudeCredsFull(configDir: configDir),
          var oauth = doc["claudeAiOauth"] as? [String: Any],
          let refresh = oauth["refreshToken"] as? String else { return "找不到登录信息" }
    var req = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
    req.httpMethod = "POST"
    req.timeoutInterval = 20
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("claude-cli/2.1 (external, cli)", forHTTPHeaderField: "User-Agent")   // 默认 UA 会被 Cloudflare 拦截
    req.httpBody = try? JSONSerialization.data(withJSONObject: [
        "grant_type": "refresh_token", "refresh_token": refresh,
        "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"])
    guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return "网络错误" }
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200, let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let access = r["access_token"] as? String else {
        return code == 400 || code == 401 ? "登录已失效" : "刷新登录失败（HTTP \(code)）"
    }
    oauth["accessToken"] = access
    if let nr = r["refresh_token"] as? String { oauth["refreshToken"] = nr }
    let ttl = (r["expires_in"] as? Double) ?? 3600
    oauth["expiresAt"] = Int((Date().timeIntervalSince1970 + ttl) * 1000)
    var newDoc = doc
    newDoc["claudeAiOauth"] = oauth
    guard let json = try? JSONSerialization.data(withJSONObject: newDoc),
          let text = String(data: json, encoding: .utf8) else { return "写回登录信息失败" }
    switch source {
    case .keychain(let svc, let acct):
        if run("/usr/bin/security", ["add-generic-password", "-U", "-a", acct, "-s", svc, "-w", text]).0 != 0 {
            return "写回钥匙串失败"
        }
    case .file(let path):
        do { try json.write(to: URL(fileURLWithPath: path), options: .atomic) } catch { return "写回登录文件失败" }
    }
    return nil
}

func fetchClaude(_ acc: AccountConfig) async -> AccountStatus {
    var st = AccountStatus(config: acc)
    var creds = readClaudeCreds(configDir: acc.configDir)
    let expired: Bool = {
        guard let ms = (creds?["expiresAt"] as? NSNumber)?.doubleValue else { return true }
        return ms / 1000 < Date().timeIntervalSince1970 + 120
    }()
    // 注意：token 过期时用量接口返回的是 429（看起来像限流），所以必须先刷新
    if creds != nil && expired {
        if let err = await refreshClaude(configDir: acc.configDir) {
            let login = acc.configDir == nil ? "claude auth login" : "CLAUDE_CONFIG_DIR=\(acc.configDir!) claude auth login"
            st.error = err == "登录已失效" ? "登录已失效：在终端运行 \(login)" : err
            return st
        }
        creds = readClaudeCreds(configDir: acc.configDir)
    }
    guard let token = creds?["accessToken"] as? String else {
        st.error = acc.configDir == nil
            ? "未登录：在终端运行 claude auth login"
            : "未登录：CLAUDE_CONFIG_DIR=\(acc.configDir!) claude auth login"
        return st
    }
    st.plan = creds?["subscriptionType"] as? String
    do {
        let j = try await getJSON("https://api.anthropic.com/api/oauth/usage",
                                  headers: ["Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20"])
        if let limits = j["limits"] as? [[String: Any]], !limits.isEmpty {
            // 新版接口：limits 里包含总额度和按模型单独计算的额度（例如 Fable）
            for l in limits {
                guard let pct = (l["percent"] as? NSNumber)?.doubleValue else { continue }
                let kind = l["kind"] as? String ?? ""
                let model = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                let label: String
                switch kind {
                case "session": label = "5 小时"
                case "weekly_all": label = "每周"
                default: label = (kind.hasPrefix("weekly") ? "每周 " : "") + (model ?? kind)
                }
                st.windows.append(Window(label: label, percent: pct, resetsAt: parseISO(l["resets_at"] as? String),
                                         kind: kind, model: model))
            }
        } else {
            let names: [(String, String, String)] = [("five_hour", "5 小时", "session"), ("seven_day", "每周", "weekly_all")]
            for (key, label, kind) in names {
                guard let w = j[key] as? [String: Any], let u = w["utilization"] as? Double else { continue }
                st.windows.append(Window(label: label, percent: u, resetsAt: parseISO(w["resets_at"] as? String), kind: kind))
            }
        }
        // 显示实际登录的是哪个账号 / 哪种套餐，防止串号
        if let cached = profileCache[acc.name], cached.at.timeIntervalSinceNow > -6 * 3600 {
            st.plan = cached.plan
        } else if let p = try? await getJSON("https://api.anthropic.com/api/oauth/profile",
                                      headers: ["Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20"]) {
            let org = p["organization"] as? [String: Any]
            let email = (p["account"] as? [String: Any])?["email"] as? String
            let type = (org?["organization_type"] as? String)?.replacingOccurrences(of: "claude_", with: "")
            st.plan = [type ?? st.plan, email].compactMap { $0 }.joined(separator: " · ")
            profileCache[acc.name] = (st.plan ?? "", Date())
        }
    } catch {
        st.error = error.localizedDescription
        st.errorCode = (error as NSError).code
    }
    return st
}

// MARK: - Codex

func fetchCodex(_ acc: AccountConfig) async -> AccountStatus {
    var st = AccountStatus(config: acc)
    let dir = expand(acc.configDir ?? "~/.codex")
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: dir + "/auth.json")),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tokens = obj["tokens"] as? [String: Any],
          let token = tokens["access_token"] as? String else {
        st.error = "未登录：在终端运行 codex login"
        return st
    }
    var headers = ["Authorization": "Bearer \(token)"]
    if let id = tokens["account_id"] as? String { headers["ChatGPT-Account-Id"] = id }
    do {
        let j = try await getJSON("https://chatgpt.com/backend-api/wham/usage", headers: headers)
        st.plan = j["plan_type"] as? String
        let rl = j["rate_limit"] as? [String: Any] ?? [:]
        for key in ["primary_window", "secondary_window"] {
            guard let w = rl[key] as? [String: Any], let used = w["used_percent"] as? Double else { continue }
            let secs = w["limit_window_seconds"] as? Double ?? 0
            let label = secs >= 6 * 86400 ? "每周" : secs > 0 ? "\(Int(secs / 3600)) 小时" : "额度"
            let reset = (w["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            st.windows.append(Window(label: label, percent: used, resetsAt: reset))
        }
    } catch {
        st.error = (error as NSError).code == 401 ? "登录过期：运行一次 codex 即可刷新" : error.localizedDescription
    }
    return st
}

// 刷新只在一个后台任务里串行进行，这些缓存不会被并发访问
var profileCache: [String: (plan: String, at: Date)] = [:]
var lastGood: [String: AccountStatus] = [:]
var backoff: [String: (until: Date, fails: Int)] = [:]

func hhmm(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }

/// 接口限流或临时出错时：继续显示上次成功的数据，并且逐步拉长重试间隔（5→10→20→40→60 分钟）
func fetchAll(_ cfg: AppConfig) async -> [AccountStatus] {
    var results: [AccountStatus] = []
    for acc in cfg.accounts {
        let key = acc.name
        if let b = backoff[key], b.until > Date() {   // 还在等待重试，不发请求
            if var old = lastGood[key] {
                old.staleNote = "接口限流，显示 \(hhmm(old.fetchedAt ?? Date())) 的数据，\(hhmm(b.until)) 后重试"
                results.append(old)
            } else {
                var st = AccountStatus(config: acc)
                st.error = "接口限流，\(hhmm(b.until)) 后自动重试"
                results.append(st)
            }
            continue
        }
        var st = acc.type == "codex" ? await fetchCodex(acc) : await fetchClaude(acc)
        if st.error == nil {
            st.fetchedAt = Date()
            lastGood[key] = st
            backoff[key] = nil
        } else if st.errorCode == 429 || (st.errorCode ?? 0) >= 500 || st.errorCode == NSURLErrorTimedOut
                    || st.errorCode == NSURLErrorNotConnectedToInternet || st.errorCode == NSURLErrorNetworkConnectionLost {
            let fails = (backoff[key]?.fails ?? 0) + 1
            let mins = min(5 * pow(2, Double(fails - 1)), 60)
            let until = Date().addingTimeInterval(mins * 60)
            backoff[key] = (until, fails)
            let reason = st.errorCode == 429 ? "接口限流" : "网络或服务暂时出错"
            if var old = lastGood[key] {
                old.staleNote = "\(reason)，显示 \(hhmm(old.fetchedAt ?? Date())) 的数据，\(hhmm(until)) 后重试"
                st = old
            } else {
                st.error = "\(reason)，\(hhmm(until)) 后自动重试"
            }
        }
        results.append(st)
    }
    return results
}

// MARK: - 界面

func bar(_ pct: Double) -> String {
    let n = Int((min(max(pct, 0), 100) / 10).rounded())
    return String(repeating: "▰", count: n) + String(repeating: "▱", count: 10 - n)
}

func resetText(_ d: Date?) -> String {
    guard let d else { return "" }
    let s = d.timeIntervalSinceNow
    if s <= 0 { return "  已重置" }
    let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
    let rel = h >= 24 ? "\(h / 24) 天 \(h % 24) 小时" : h > 0 ? "\(h) 小时 \(m) 分" : "\(m) 分钟"
    return "  · \(rel)后重置"
}

func color(_ pct: Double) -> NSColor {
    pct >= 90 ? .systemRed : pct >= 70 ? .systemOrange : .labelColor
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var statuses: [AccountStatus] = []
    var lastUpdate: Date?
    var timer: Timer?
    var loading = false

    func applicationDidFinishLaunching(_ n: Notification) {
        item.button?.title = "⋯"
        let menu = NSMenu(); menu.delegate = self
        item.menu = menu
        rebuildMenu()
        refresh()
        let mins = Double(loadConfig().refreshMinutes ?? 5)
        timer = Timer.scheduledTimer(withTimeInterval: mins * 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }   // 让“几小时后重置”保持最新

    @objc func refresh() {
        guard !loading else { return }
        loading = true
        let cfg = loadConfig()
        Task.detached {
            let results = await fetchAll(cfg)
            await MainActor.run {
                self.statuses = results
                self.lastUpdate = Date()
                self.loading = false
                self.updateTitle()
                self.rebuildMenu()
            }
        }
    }

    func updateTitle() {
        let s = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let best = makeAdvice(statuses).best
        for (i, st) in statuses.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            var val = st.headline.map { "\(Int($0.rounded()))%" } ?? "–"
            if st.scoped.contains(where: { $0.pct >= 90 }) { val += "!" }   // 某个模型的专属额度快满了
            let isBest = st.config.short == best
            s.append(NSAttributedString(string: (isBest ? "▸" : "") + st.config.short + " ",
                                        attributes: [.font: font, .foregroundColor: isBest ? NSColor.controlAccentColor : NSColor.secondaryLabelColor]))
            s.append(NSAttributedString(string: val,
                                        attributes: [.font: font, .foregroundColor: st.headline.map(color) ?? NSColor.secondaryLabelColor]))
        }
        item.button?.attributedTitle = s
    }

    func rebuildMenu() {
        guard let menu = item.menu else { return }
        menu.removeAllItems()
        menu.autoenablesItems = false   // 否则没有点击动作的行会被系统画成灰色
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let advice = makeAdvice(statuses)
        if !advice.lines.isEmpty {
            let h = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            h.attributedTitle = NSAttributedString(string: "推荐", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            menu.addItem(h)
            for l in advice.lines { menu.addItem(NSMenuItem(title: "  " + l, action: nil, keyEquivalent: "")) }
            menu.addItem(.separator())
        }
        for st in statuses {
            let head = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            var title = st.config.name
            if let p = st.plan { title += "  (\(p))" }
            head.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            menu.addItem(head)
            if let e = st.error {
                let it = NSMenuItem(title: "  ⚠️ " + e, action: nil, keyEquivalent: "")
                menu.addItem(it)
            }
            if let note = st.staleNote {
                let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                it.attributedTitle = NSAttributedString(string: "  ⏸ " + note, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
                menu.addItem(it)
            }
            for w in st.windows {
                let line = "  \(w.label)\t\(bar(w.pct)) \(String(format: "%3.0f%%", w.pct))\(resetText(w.resetsAt))"
                let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                let para = NSMutableParagraphStyle()
                para.tabStops = [NSTextTab(textAlignment: .left, location: 110)]   // 用制表位对齐进度条
                it.attributedTitle = NSAttributedString(string: line, attributes: [.font: mono, .foregroundColor: color(w.pct), .paragraphStyle: para])
                menu.addItem(it)
            }
            if st.error == nil && st.windows.isEmpty { menu.addItem(NSMenuItem(title: "  暂无数据", action: nil, keyEquivalent: "")) }
            menu.addItem(.separator())
        }
        if let t = lastUpdate {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            menu.addItem(NSMenuItem(title: "更新于 \(f.string(from: t))", action: nil, keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "加载中…", action: nil, keyEquivalent: ""))
        }
        let r = NSMenuItem(title: "立即刷新", action: #selector(refresh), keyEquivalent: "r"); r.target = self; menu.addItem(r)
        let c = NSMenuItem(title: "编辑账号配置…", action: #selector(openConfig), keyEquivalent: ","); c.target = self; menu.addItem(c)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func openConfig() { NSWorkspace.shared.open(configURL) }
}

// 命令行调试：QuotaPin --dump 直接打印额度后退出
if CommandLine.arguments.contains("--dump") {
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        let all = await fetchAll(loadConfig())
        for st in all {
            print("\(st.config.name) [\(st.plan ?? "?")]" + (st.error.map { "  ⚠️ \($0)" } ?? "") + (st.staleNote.map { "  ⏸ \($0)" } ?? ""))
            for w in st.windows { print("  \(w.label)  \(bar(w.pct)) \(Int(w.pct))%\(resetText(w.resetsAt))") }
        }
        print("\n推荐（菜单栏标 ▸ 的账号）:")
        for l in makeAdvice(all).lines { print("  " + l) }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 不在 Dock 显示
app.run()
