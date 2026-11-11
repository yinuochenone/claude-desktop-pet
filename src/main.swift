import Cocoa
import WebKit
import Carbon.HIToolbox

// MARK: - Reading Claude Code transcripts (~/.claude/projects/**/*.jsonl)

struct Entry {
    var ts: Date
    var tokens: Int
}

func ms(_ d: Date) -> Double { (d.timeIntervalSince1970 * 1000).rounded() }

/// Only touched from the scan queue.
final class UsageStore: @unchecked Sendable {
    private let roots: [URL]
    private var offsets: [String: UInt64] = [:]
    private var byId: [String: Entry] = [:]
    private var sorted: [Entry] = []
    private var dirty = false
    private let isoFrac = ISO8601DateFormatter()
    private let iso = ISO8601DateFormatter()
    private let needle = Data("\"usage\"".utf8)

    init() {
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots = [".claude/projects", ".config/claude/projects"].map { home.appendingPathComponent($0) }
    }

    /// Reads whatever was appended since the last call and returns the summary as JSON.
    func snapshot() -> String {
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                ingestFile(url, size: UInt64(size))
            }
        }
        if dirty {
            sorted = byId.values.sorted { $0.ts < $1.ts }
            dirty = false
        }
        let data = (try? JSONSerialization.data(withJSONObject: summarize(now: Date()))) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func ingestFile(_ url: URL, size: UInt64) {
        var start = offsets[url.path] ?? 0
        if size < start { start = 0 }  // file was rewritten
        guard size > start, let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        guard (try? fh.seek(toOffset: start)) != nil, let data = try? fh.readToEnd(),
              let lastNewline = data.lastIndex(of: 0x0A) else { return }
        // Leave a half-written last line for the next pass.
        offsets[url.path] = start + UInt64(data.distance(from: data.startIndex, to: lastNewline) + 1)
        for line in data[..<lastNewline].split(separator: 0x0A) where line.range(of: needle) != nil {
            ingestLine(line)
        }
    }

    private func ingestLine(_ line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let stamp = obj["timestamp"] as? String,
              let ts = isoFrac.date(from: stamp) ?? iso.date(from: stamp),
              msg["model"] as? String != "<synthetic>" else { return }
        let tokens = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
            .reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
        guard tokens > 0 else { return }
        // Streaming writes the same message several times; keep one copy, the most complete.
        let id = [msg["id"] as? String, obj["requestId"] as? String].compactMap { $0 }.joined(separator: ":")
        let key = id.isEmpty ? UUID().uuidString : id
        var e = Entry(ts: ts, tokens: tokens)
        if let old = byId[key] {
            guard e.tokens > old.tokens else { return }
            e.ts = old.ts
        }
        byId[key] = e
        dirty = true
    }

    /// Activity for the buddy's mood, plus a guess at the session reset in case plan limits can't be read.
    private func summarize(now: Date) -> [String: Any] {
        let window: TimeInterval = 5 * 3600
        var blockStart: Date?
        var msgs5 = 0

        // 5-hour windows start on the hour of the first message after the previous window ran out.
        for e in sorted {
            if blockStart == nil || e.ts >= blockStart! + window {
                blockStart = Calendar.current.dateInterval(of: .hour, for: e.ts)?.start ?? e.ts
            }
            if now.timeIntervalSince(e.ts) < 300 { msgs5 += 1 }
        }
        var blockEnd: Any = NSNull()
        if let s = blockStart, now < s + window { blockEnd = ms(s + window) }
        return ["blockEnd": blockEnd, "msgs5": msgs5, "last": sorted.last.map { ms($0.ts) } ?? 0]
    }
}

// MARK: - Plan limits (the numbers on Claude's usage page)

/// Asks Anthropic for this account's limits with the login Claude Code keeps in the keychain.
/// The token is only ever sent to api.anthropic.com.
final class LimitsFetcher: @unchecked Sendable {
    private let iso = ISO8601DateFormatter()
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ClaudeUsage/last-usage.json")
    private let renewLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ClaudeUsage/renew.log")

    private var lastRenew = Date.distantPast
    private var pausedUntil = Date.distantPast

    func fetch(_ done: @escaping @Sendable (String) -> Void) {
        guard Date() >= pausedUntil else { return done(Self.json(["error": "rate limited, retrying soon"])) }
        var login: Login
        switch readLogin() {
        case .success(let l): login = l
        case .failure(let reason): return done(Self.json(["error": reason.message]))
        }
        // The access token only lasts ~8h; renew it through the CLI shortly before it runs out.
        if login.expiresAt - ms(Date()) < 15 * 60e3 {
            renew(login)
            guard case .success(let fresh) = readLogin(), fresh.expiresAt > ms(Date()) else {
                return done(Self.json(["error": "login expired, run: claude auth login"]))
            }
            login = fresh
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
        req.setValue("Bearer \(login.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let data { self.log(status, data) }
            if status == 429 { self.pausedUntil = Date().addingTimeInterval(300) }
            guard status == 200, let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return done(Self.json(["error": status == 401 ? "login expired, run: claude auth login" : "couldn't reach claude (\(status))"]))
            }
            done(Self.json(["session": self.window(obj["five_hour"]), "weekly": self.window(obj["seven_day"])]))
        }.resume()
    }

    private struct Reason: Error { let message: String }
    private struct Login { let token: String; let expiresAt: Double; let refreshToken: String?; let scopes: [String] }

    private func readLogin() -> Result<Login, Reason> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return .failure(Reason(message: "couldn't open keychain")) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let creds = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = creds["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return .failure(Reason(message: "no claude login, run: claude auth login"))
        }
        return .success(Login(token: token,
                              expiresAt: (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? .infinity,
                              refreshToken: oauth["refreshToken"] as? String,
                              scopes: oauth["scopes"] as? [String] ?? []))
    }

    /// Runs `claude auth login` with the stored refresh token, the CLI's own non-interactive
    /// path, so it rotates and saves the credentials itself. At most one try per 10 minutes.
    /// What the CLI prints (never the tokens) goes to renew.log.
    private func renew(_ login: Login) {
        // An empty token would make the CLI fall back to its interactive browser login.
        guard let refresh = login.refreshToken, !refresh.isEmpty, !login.scopes.isEmpty,
              Date().timeIntervalSince(lastRenew) > 600 else { return }
        lastRenew = Date()
        let log = openRenewLog()
        func note(_ line: String) {
            let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
            log?.seekToEndOfFile()
            log?.write(Data("\(stamp) \(line)\n".utf8))
        }
        guard let claude = Self.findClaude() else { return note("claude CLI not found") }

        let p = Process()
        p.executableURL = claude
        p.arguments = ["auth", "login"]
        // Drop Claude session variables (when launched from inside one) so the CLI uses its normal config.
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("ANTHROPIC") }
        env["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] = refresh
        env["CLAUDE_CODE_OAUTH_SCOPES"] = login.scopes.joined(separator: " ")
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = log ?? FileHandle.nullDevice
        p.standardError = log ?? FileHandle.nullDevice
        note("renewing via \(claude.path)")
        let started = Date()
        guard (try? p.run()) != nil else { return note("couldn't start the CLI") }
        // Only a backstop for a hung CLI: stopping it between the refresh and the save loses the login.
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) { if p.isRunning { p.terminate() } }
        p.waitUntilExit()
        let saved = (try? readLogin().get())?.token != login.token
        note(String(format: "exit %d after %.1fs, new token in keychain: %@",
                     p.terminationStatus, Date().timeIntervalSince(started), saved ? "yes" : "NO"))
    }

    private func openRenewLog() -> FileHandle? {
        try? FileManager.default.createDirectory(at: renewLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: renewLogURL.path) {
            FileManager.default.createFile(atPath: renewLogURL.path, contents: nil)
        }
        return try? FileHandle(forWritingTo: renewLogURL)
    }

    /// Apps opened from Finder don't get the shell's PATH, so look in the usual install spots.
    private static func findClaude() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/usr/local/bin/claude", "/opt/homebrew/bin/claude", "\(home)/.local/bin/claude",
                "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private func window(_ raw: Any?) -> Any {
        guard let w = raw as? [String: Any], let used = (w["utilization"] as? NSNumber)?.doubleValue else { return NSNull() }
        var out: [String: Any] = ["used": used]
        // e.g. "2026-11-04T02:00:00.295123+00:00"; drop the fraction so the formatter accepts it.
        if let stamp = (w["resets_at"] as? String)?.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression),
           let date = iso.date(from: stamp) {
            out["resetsAt"] = ms(date)
        }
        return out
    }

    private func log(_ status: Int, _ body: Data) {
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (Data("HTTP \(status)\n".utf8) + body).write(to: logURL)
    }

    private static func json(_ obj: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Overlay window

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class OverlayWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Never a drop target: a file dropped on a web view would open in place of the page.
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private let store = UsageStore()
    private let fetcher = LimitsFetcher()
    private let scanQueue = DispatchQueue(label: "claude-usage.scan")
    private let limitsQueue = DispatchQueue(label: "claude-usage.limits")
    private let prefs = UserDefaults.standard
    private let themes = ["bubblegum", "aqua", "cyber"]
    private var panel: OverlayPanel!
    private var web: OverlayWebView!
    private var statusItem: NSStatusItem!
    private var topItem: NSMenuItem!
    private var ghostItem: NSMenuItem!
    private var hideItem: NSMenuItem!
    private var roamItem: NSMenuItem!
    private var pet: Pet!
    private var hotKeys: [HotKey] = []
    private var themeItems: [NSMenuItem] = []
    private var opacityItems: [NSMenuItem] = []
    private var pageReady = false
    private var scanning = false
    private var fetching = false
    private var latest: String?
    private var latestLimits: String?
    private var statsTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        makePanel()
        pet = Pet(home: { [unowned self] in self.petHome })
        pet.onTap = { [weak self] _ in self?.showStats() }
        if let cached = prefs.string(forKey: "lastLimits") { deliverLimits(cached) }
        hotKeys = [
            HotKey(key: kVK_ANSI_P, modifiers: controlKey | optionKey) { [weak self] in self?.callPet() },
            HotKey(key: kVK_ANSI_H, modifiers: controlKey | optionKey) { [weak self] in self?.toggleHidden() },
            HotKey(key: kVK_ANSI_F, modifiers: controlKey | optionKey) { [weak self] in self?.focusKey() },
        ]
        makeMenu()
        applyPrefs()
        Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(refreshLimits), userInfo: nil, repeats: true)
        refresh()
        refreshLimits()
    }

    /// The top-right corner of the main screen, under the menu bar: the pet's bedroom.
    private var petHome: NSPoint {
        let visible = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX, y: visible.maxY)
    }

    private var theme: String {
        let saved = prefs.string(forKey: "theme") ?? ""
        return themes.contains(saved) ? saved : themes[0]
    }

    private var opacity: CGFloat { CGFloat(prefs.object(forKey: "opacity") as? Int ?? 100) / 100 }

    /// The usage pill. It stays hidden until the pet is tapped, then rides along next to it.
    private func makePanel() {
        // The page reports its real size once it has laid out; see fit(width:height:).
        let size = NSSize(width: 220, height: 46)
        panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "app")
        web = OverlayWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.navigationDelegate = self
        panel.contentView = web

        let page = Bundle.main.url(forResource: "overlay", withExtension: "html")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("overlay.html")
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "✦"
        let menu = NSMenu()
        let focus = addItem(menu, "Focus with Pet · 25 min", #selector(focus25))
        focus.keyEquivalent = "f"
        focus.keyEquivalentModifierMask = [.control, .option]
        addItem(menu, "Focus with Pet · 45 min", #selector(focus45))
        addItem(menu, "End Focus Session", #selector(endFocus))
        menu.addItem(.separator())
        let call = addItem(menu, "Call Pet", #selector(callPet))
        call.keyEquivalent = "p"
        call.keyEquivalentModifierMask = [.control, .option]
        hideItem = addItem(menu, "Hide Pet", #selector(toggleHidden))
        hideItem.keyEquivalent = "h"
        hideItem.keyEquivalentModifierMask = [.control, .option]
        addItem(menu, "Show Usage", #selector(showStats))
        roamItem = addItem(menu, "Pet Roams & Hides", #selector(toggleRoam))
        if !AXIsProcessTrusted() { addItem(menu, "Let Pet Hop on Exact Dock Icons…", #selector(askDockAccess)) }
        menu.addItem(.separator())
        let themeMenu = NSMenu()
        for (i, name) in themes.enumerated() { themeItems.append(addItem(themeMenu, name.capitalized, #selector(setTheme(_:)), tag: i)) }
        addSubmenu(menu, "Theme", themeMenu)
        let opacityMenu = NSMenu()
        for pct in [100, 85, 70, 50] { opacityItems.append(addItem(opacityMenu, "\(pct)%", #selector(setOpacity(_:)), tag: pct)) }
        addSubmenu(menu, "Opacity", opacityMenu)
        topItem = addItem(menu, "Always on Top", #selector(toggleOnTop))
        ghostItem = addItem(menu, "Ghost Mode (click-through)", #selector(toggleGhost))
        menu.addItem(.separator())
        addItem(menu, "Quit", #selector(quit))
        statusItem.menu = menu
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        menu.addItem(item)
        return item
    }

    private func addSubmenu(_ menu: NSMenu, _ title: String, _ submenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    private func applyPrefs() {
        let onTop = prefs.object(forKey: "onTop") as? Bool ?? true
        let ghost = prefs.bool(forKey: "ghost")
        let petShown = prefs.object(forKey: "petShown") as? Bool ?? true
        let roams = prefs.object(forKey: "petRoams") as? Bool ?? true
        // Off = lives on the desktop like a widget, under your windows.
        panel.level = onTop ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.ignoresMouseEvents = ghost
        if panel.isVisible { panel.alphaValue = opacity }
        pet.apply(theme: theme, level: panel.level, opacity: opacity, ghost: ghost, roams: roams, shown: petShown)
        if !petShown { hideStats() }
        topItem.state = onTop ? .on : .off
        ghostItem.state = ghost ? .on : .off
        hideItem.title = petShown ? "Hide Pet" : "Show Pet"
        roamItem.state = roams ? .on : .off
        let pct = Int((opacity * 100).rounded())
        for item in opacityItems { item.state = item.tag == pct ? .on : .off }
        for item in themeItems { item.state = themes[item.tag] == theme ? .on : .off }
        if pageReady { web.evaluateJavaScript("setTheme('\(theme)')") }
    }

    /// Focus sessions: the pet sits at its desk and works alongside you (a body double).
    @objc private func focus25() { startFocus(25) }
    @objc private func focus45() { startFocus(45) }
    @objc private func endFocus() { pet.endFocus() }

    private func focusKey() {
        if !pet.isShown { toggleHidden() }
        pet.focusKey()
    }

    private func startFocus(_ minutes: Int) {
        if !pet.isShown { toggleHidden() }
        pet.startFocus(minutes: minutes)
    }

    @objc private func callPet() {
        if !pet.isShown { toggleHidden() }
        pet.call()
    }

    @objc private func toggleHidden() { prefs.set(!(prefs.object(forKey: "petShown") as? Bool ?? true), forKey: "petShown"); applyPrefs() }
    @objc private func toggleRoam() { prefs.set(!(prefs.object(forKey: "petRoams") as? Bool ?? true), forKey: "petRoams"); applyPrefs() }
    @objc private func toggleOnTop() { prefs.set(!(prefs.object(forKey: "onTop") as? Bool ?? true), forKey: "onTop"); applyPrefs() }
    @objc private func toggleGhost() { prefs.set(!prefs.bool(forKey: "ghost"), forKey: "ghost"); applyPrefs() }
    @objc private func setTheme(_ sender: NSMenuItem) { prefs.set(themes[sender.tag], forKey: "theme"); applyPrefs() }
    @objc private func setOpacity(_ sender: NSMenuItem) { prefs.set(sender.tag, forKey: "opacity"); applyPrefs() }
    @objc private func quit() { NSApp.terminate(nil) }

    /// Accessibility is how it reads where each Dock icon is; without it, it guesses from the Dock's settings.
    @objc private func askDockAccess() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Pops the usage pill up next to the pet for a few seconds; each tap starts the count again.
    @objc private func showStats() {
        guard pet.isShown else { return }
        pet.companion = panel
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = opacity
        }
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.hideStats() }
    }

    private func hideStats() {
        statsTimer?.invalidate()
        statsTimer = nil
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.statsTimer == nil else { return }  // tapped again while it faded
            self.panel.orderOut(nil)
            self.pet.companion = nil
        })
    }

    @objc private func refresh() {
        guard !scanning else { return }
        scanning = true
        let store = self.store
        scanQueue.async {
            let json = store.snapshot()
            Task { @MainActor [weak self] in self?.deliver(json) }
        }
    }

    private func deliver(_ json: String) {
        scanning = false
        latest = json
        if pageReady { web.evaluateJavaScript("update(\(json))") }
    }

    @objc private func refreshLimits() {
        guard !fetching else { return }
        fetching = true
        let fetcher = self.fetcher
        limitsQueue.async {
            fetcher.fetch { json in
                Task { @MainActor [weak self] in self?.deliverLimits(json) }
            }
        }
    }

    private func deliverLimits(_ json: String) {
        fetching = false
        latestLimits = json
        if !json.contains("\"error\"") { prefs.set(json, forKey: "lastLimits") }  // shown right away on the next launch
        if pageReady { web.evaluateJavaScript("limits(\(json))") }
        // The pet runs on whichever is lower: session or weekly allowance left.
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return }
        let used = { (key: String) in ((obj[key] as? [String: Any])?["used"] as? NSNumber)?.doubleValue }
        if let session = used("session") { pet.setEnergy((100 - max(session, used("weekly") ?? 0)) / 100) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        applyPrefs()
        // The last good numbers first, so a failed refresh since launch doesn't blank them.
        if let good = prefs.string(forKey: "lastLimits") { web.evaluateJavaScript("limits(\(good))") }
        if let latestLimits { web.evaluateJavaScript("limits(\(latestLimits))") }
        if let latest { web.evaluateJavaScript("update(\(latest))") }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "dismiss": hideStats()
        case "size":
            if let w = body["w"] as? Double, let h = body["h"] as? Double { fit(width: CGFloat(w), height: CGFloat(h)) }
        default: break
        }
    }

    /// Keeps the top-left corner put while the page settles on its size.
    private func fit(width: CGFloat, height: CGFloat) {
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: ceil(width), height: ceil(height))
        frame.origin.y = top - frame.size.height
        panel.setFrame(frame, display: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
