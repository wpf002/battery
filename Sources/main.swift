// ClaudeBattery — macOS menu bar battery showing remaining Claude Code quota.
// Reads the OAuth token Claude Code stores in Keychain, calls the same
// usage endpoint /usage uses. Nothing leaves the machine except that one call.

import AppKit
import Foundation
import Security
import ServiceManagement

// MARK: - Model

struct UsageWindow {
    let usedPct: Double
    let resetsAt: Date?
    var remainingPct: Double { max(0, min(100, 100 - usedPct)) }
}

struct UsageStatus {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
}

enum BatteryError: Error {
    case noToken(OSStatus)   // OSStatus so Keychain denials are distinguishable from "never logged in"
    case emptyToken          // credential is present but signed out
    case noneUsable(total: Int, signedOut: Int, denied: Int)
    case badCredential
    case http(Int)
    case parse
}

// MARK: - Keychain

// Every Keychain read can raise a system password prompt, and the refresh
// timer runs every 30s — so the result, success or failure, is cached for the
// process lifetime. Only a 401 or an explicit Refresh now re-reads it.
private let tokenLock = NSLock()
private var cachedToken: Result<String, Error>?

func forgetCachedToken() {
    tokenLock.lock(); defer { tokenLock.unlock() }
    cachedToken = nil
}

func readAccessToken() throws -> String {
    tokenLock.lock(); defer { tokenLock.unlock() }
    if let cached = cachedToken { return try cached.get() }
    let result = Result { try readTokenFromKeychain() }
    cachedToken = result
    return try result.get()
}

// Claude Code stores credentials under "Claude Code-credentials" plus
// per-install "…-<hash>" variants. The bare one is often a signed-out
// leftover, so prefer the most recently written entry that carries a token.
private let credentialPrefix = "Claude Code-credentials"

private func credentialServices() -> [String] {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var out: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
          let items = out as? [[String: Any]] else { return [] }
    return items
        .filter { ($0[kSecAttrService as String] as? String)?.hasPrefix(credentialPrefix) == true }
        .sorted {
            let l = $0[kSecAttrModificationDate as String] as? Date ?? .distantPast
            let r = $1[kSecAttrModificationDate as String] as? Date ?? .distantPast
            return l > r
        }
        .compactMap { $0[kSecAttrService as String] as? String }
}

// Distinguishing these three matters: "no token anywhere" and "the Keychain
// wouldn't let us look" need very different advice.
enum CredentialRead {
    case token(String)
    case signedOut(OSStatus)   // readable, but accessToken was absent or empty
    case denied(OSStatus)      // Keychain refused the read
}

private func read(service: String) -> CredentialRead {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &out)
    guard status == errSecSuccess, let data = out as? Data else { return .denied(status) }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String,
          !token.isEmpty
    else { return .signedOut(status) }
    return .token(token)
}

private func readTokenFromKeychain() throws -> String {
    let services = credentialServices()
    guard !services.isEmpty else { throw BatteryError.noToken(errSecItemNotFound) }

    // Remembering the entry that worked keeps this to one Keychain prompt per
    // launch instead of one per candidate.
    var ordered = services
    if let remembered = UserDefaults.standard.string(forKey: "credentialService"),
       let i = ordered.firstIndex(of: remembered) {
        ordered.remove(at: i)
        ordered.insert(remembered, at: 0)
    }

    var signedOut = 0, denied = 0
    for service in ordered.prefix(6) {
        switch read(service: service) {
        case .token(let t):
            UserDefaults.standard.set(service, forKey: "credentialService")
            return t
        case .signedOut: signedOut += 1
        case .denied: denied += 1
        }
    }
    let err = BatteryError.noneUsable(total: services.count, signedOut: signedOut, denied: denied)
    FileHandle.standardError.write(Data("claudebattery: \(describe(err))\n".utf8))
    throw err
}

// MARK: - API

private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain = ISO8601DateFormatter()

func parseWindow(_ any: Any?) -> UsageWindow? {
    guard let dict = any as? [String: Any],
          let used = dict["utilization"] as? Double else { return nil }
    var reset: Date?
    if let s = dict["resets_at"] as? String {
        reset = isoFractional.date(from: s) ?? isoPlain.date(from: s)
    } else if let t = dict["resets_at"] as? Double {
        reset = Date(timeIntervalSince1970: t > 1e11 ? t / 1000 : t)
    }
    return UsageWindow(usedPct: used, resetsAt: reset)
}

func fetchStatus(completion: @escaping (Result<UsageStatus, Error>) -> Void) {
    let token: String
    do { token = try readAccessToken() } catch { completion(.failure(error)); return }

    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.timeoutInterval = 15
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

    URLSession.shared.dataTask(with: req) { data, resp, err in
        if let err = err { completion(.failure(err)); return }
        guard let http = resp as? HTTPURLResponse, let data = data else {
            completion(.failure(BatteryError.parse)); return
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { forgetCachedToken() }   // token rotated; re-read next time
            completion(.failure(BatteryError.http(http.statusCode))); return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            completion(.failure(BatteryError.parse)); return
        }
        completion(.success(UsageStatus(fiveHour: parseWindow(json["five_hour"]),
                                        sevenDay: parseWindow(json["seven_day"]))))
    }.resume()
}

func describe(_ error: Error) -> String {
    if let e = error as? BatteryError {
        switch e {
        case .noToken(errSecItemNotFound): return "Not logged in. Run `claude` and sign in."
        case .noToken(let st):
            let msg = SecCopyErrorMessageString(st, nil) as String? ?? "unknown"
            return "Keychain denied access (\(st): \(msg))"
        case .emptyToken: return "Signed out. Run `claude` and sign in."
        case .noneUsable(let total, let signedOut, let denied):
            return "\(total) credential entries; checked \(signedOut + denied): \(signedOut) signed out, \(denied) unreadable"
        case .badCredential: return "Keychain entry isn't a Claude Code credential"
        case .http(401): return "Token expired. Start a Claude Code session to refresh it."
        case .http(let code): return "API error HTTP \(code)"
        case .parse: return "Unexpected API response"
        }
    }
    return error.localizedDescription
}

func humanReset(_ date: Date?) -> String {
    guard let date = date else { return "reset time unknown" }
    let s = Int(date.timeIntervalSinceNow)
    if s <= 0 { return "resetting now" }
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "resets in \(d)d \(h)h" }
    if h > 0 { return "resets in \(h)h \(m)m" }
    return "resets in \(m)m"
}

// MARK: - Icon

func levelColor(_ remaining: Double) -> NSColor {
    if remaining > 50 { return NSColor(srgbRed: 0.55, green: 0.79, blue: 0.55, alpha: 1) }
    if remaining > 20 { return NSColor(srgbRed: 0.90, green: 0.68, blue: 0.33, alpha: 1) }
    return NSColor(srgbRed: 0.89, green: 0.32, blue: 0.27, alpha: 1)
}

// Claude's mark: tapered petals radiating from a point.
func drawSunburst(center: NSPoint, radius: CGFloat, color: NSColor, spokes: Int = 11) {
    color.setFill()
    for i in 0..<spokes {
        let a = CGFloat(i) * 2 * .pi / CGFloat(spokes)
        let perp = a + .pi / 2
        let w = radius * 0.30
        let tip = NSPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
        let mid = NSPoint(x: center.x + cos(a) * radius * 0.34, y: center.y + sin(a) * radius * 0.34)
        let p = NSBezierPath()
        p.move(to: center)
        p.line(to: NSPoint(x: mid.x + cos(perp) * w * 0.5, y: mid.y + sin(perp) * w * 0.5))
        p.line(to: tip)
        p.line(to: NSPoint(x: mid.x - cos(perp) * w * 0.5, y: mid.y - sin(perp) * w * 0.5))
        p.close()
        p.fill()
    }
}

let batterySize = NSSize(width: 30, height: 15)

// Content is drawn at the LEFT end; `padTo` adds transparent filler to the right.
func batteryImage(remaining: Double?, percentText: String?, padTo: CGFloat = 0) -> NSImage {
    var textWidth: CGFloat = 0
    var label: NSAttributedString?
    if let t = percentText {
        let a = NSAttributedString(string: t, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
        label = a
        textWidth = a.size().width + 4
    }
    let contentWidth = batterySize.width + textWidth
    let size = NSSize(width: max(contentWidth, padTo), height: 16)

    return NSImage(size: size, flipped: false) { _ in
        let shell = NSColor(white: 0.80, alpha: 1)
        let body = NSRect(x: 1, y: 1.5, width: 25, height: 13)

        shell.setFill()
        NSBezierPath(roundedRect: NSRect(x: 26.4, y: 5.5, width: 2.6, height: 5),
                     xRadius: 1.1, yRadius: 1.1).fill()

        let outline = NSBezierPath(roundedRect: body, xRadius: 3.4, yRadius: 3.4)
        outline.lineWidth = 1.8
        shell.setStroke()
        outline.stroke()

        let inner = body.insetBy(dx: 2, dy: 2)
        if let r = remaining {
            let fw = max(2, inner.width * CGFloat(r) / 100)
            let fill = NSRect(x: inner.minX, y: inner.minY, width: fw, height: inner.height)
            levelColor(r).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1.6, yRadius: 1.6).fill()

            let c = NSPoint(x: inner.midX, y: inner.midY)
            drawSunburst(center: c, radius: inner.height * 0.52,
                         color: c.x <= fill.maxX - 1 ? NSColor(white: 0.08, alpha: 1) : levelColor(r))
        } else {
            let q = NSAttributedString(string: "?", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: shell,
            ])
            let sz = q.size()
            q.draw(at: NSPoint(x: body.midX - sz.width / 2, y: body.midY - sz.height / 2))
        }

        label?.draw(at: NSPoint(x: batterySize.width + 2, y: 2))
        return true
    }
}

// The notch band on the active screen, in screen points, or nil if there is none.
func notchBand(for screen: NSScreen?) -> (start: CGFloat, end: CGFloat)? {
    guard let screen = screen,
          let left = screen.auxiliaryTopLeftArea,
          let right = screen.auxiliaryTopRightArea else { return nil }
    return (left.maxX, right.minX)
}

// The status item is laid out but never painted when the menu bar has no
// drawable slot left, so the icon is also drawn as a small always-on-top
// window sitting in the menu bar strip.
final class IconView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    override func draw(_ dirty: NSRect) {
        guard let image = image else { return }
        let r = NSRect(x: 0, y: (bounds.height - image.size.height) / 2,
                       width: image.size.width, height: image.size.height)
        image.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var panel: NSPanel?
    private var overlay: NSPanel?
    private var iconView: IconView?
    private var timer: Timer?
    private var status: UsageStatus?
    private var lastError: String?
    private var lastUpdate: Date?
    private let interval: TimeInterval = 30
    private let defaults = UserDefaults.standard

    private var showPercent: Bool {
        get { defaults.object(forKey: "showPercent") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showPercent") }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeft
        item.menu = NSMenu()
        item.menu?.delegate = self
        render()
        showOverlay()
        // The status item has no window until the menu bar has placed it, so the
        // notch check needs a second pass once layout has happened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.render() }
        // Only touch the Keychain on its own once the user has granted access —
        // otherwise every launch raises a system password prompt for nothing.
        if defaults.bool(forKey: "keychainGranted") { refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self, self.defaults.bool(forKey: "keychainGranted") else { return }
            self.refresh()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshAction), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(render), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc func refreshAction() {
        forgetCachedToken()   // manual refresh re-reads the Keychain
        refresh()
    }

    func refresh() {
        // The Keychain read can raise a system prompt, which blocks its thread
        // until answered — so it must not run on the main thread or the window
        // never gets a chance to draw.
        DispatchQueue.global(qos: .utility).async {
            fetchStatus { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success(let s):
                        self.status = s
                        self.lastError = nil
                        self.lastUpdate = Date()
                        self.defaults.set(true, forKey: "keychainGranted")
                    case .failure(let e):
                        self.lastError = describe(e)
                        if case BatteryError.emptyToken = e { self.defaults.set(true, forKey: "keychainGranted") }
                    }
                    self.render()
                }
            }
        }
    }

    @objc private func render() {
        let remaining = status?.fiveHour?.remainingPct
        let text = (showPercent && remaining != nil) ? "\(Int(remaining!.rounded()))%" : nil

        item.button?.title = ""
        item.button?.image = batteryImage(remaining: remaining, percentText: text)
        item.length = NSStatusItem.variableLength
        escapeNotchIfNeeded(remaining: remaining, text: text)

        var tip = "Claude Code usage"
        if let w = status?.fiveHour { tip += "\n5-hour: \(Int(w.remainingPct.rounded()))% left, \(humanReset(w.resetsAt))" }
        if let w = status?.sevenDay { tip += "\nWeekly: \(Int(w.remainingPct.rounded()))% left, \(humanReset(w.resetsAt))" }
        if let e = lastError { tip += "\n\(e)" }
        item.button?.toolTip = tip
        iconView?.image = batteryImage(remaining: remaining, percentText: text)
        updatePanel()
    }

    // A full menu bar leaves only the slot under the camera housing, where
    // nothing is drawn. The menu bar pins the item's right edge, so padding the
    // image to the right pushes the visible content left, out of the notch.
    private func escapeNotchIfNeeded(remaining: Double?, text: String?) {
        guard let win = item.button?.window,
              let notch = notchBand(for: win.screen ?? NSScreen.main) else { return }
        let frame = win.frame
        let contentWidth = item.button?.image?.size.width ?? 26
        guard frame.minX + contentWidth > notch.start, frame.minX < notch.end else { return }

        let needed = frame.maxX - notch.start + contentWidth + 6
        guard needed > contentWidth, needed < 400 else { return }
        item.button?.image = batteryImage(remaining: remaining, percentText: text, padTo: needed)
        item.length = needed
    }

    // Menu is rebuilt each time it opens so countdowns are fresh.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        func line(_ label: String, _ w: UsageWindow?) {
            let text: String
            if let w = w {
                text = "\(label): \(Int(w.remainingPct.rounded()))% left · \(humanReset(w.resetsAt))"
            } else {
                text = "\(label): no data"
            }
            let mi = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            menu.addItem(mi)
        }
        line("5-hour", status?.fiveHour)
        line("Weekly", status?.sevenDay)

        if let e = lastError {
            menu.addItem(.separator())
            let mi = NSMenuItem(title: e, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            menu.addItem(mi)
        }

        if let t = lastUpdate {
            let ago = Int(Date().timeIntervalSince(t))
            let mi = NSMenuItem(title: "Updated \(ago)s ago", action: nil, keyEquivalent: "")
            mi.isEnabled = false
            menu.addItem(mi)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Refresh now", action: #selector(refreshAction), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Show window", action: #selector(showWindow), keyEquivalent: "w"))

        let pct = NSMenuItem(title: "Show percentage", action: #selector(togglePercent), keyEquivalent: "")
        pct.state = showPercent ? .on : .off
        menu.addItem(pct)

        if #available(macOS 13.0, *) {
            let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // The menu bar item does not paint on some macOS versions, so the same
    // numbers are also shown in a small floating window.
    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 170),
                        styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        p.title = "Claude Battery"
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false

        let v = p.contentView!
        let icon = NSImageView(frame: NSRect(x: 18, y: 112, width: 60, height: 34))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.identifier = NSUserInterfaceItemIdentifier("icon")
        v.addSubview(icon)

        func label(_ y: CGFloat, _ id: String, _ size: CGFloat, _ bold: Bool) {
            let t = NSTextField(labelWithString: "")
            t.frame = NSRect(x: 18, y: y, width: 296, height: 18)
            t.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
            t.identifier = NSUserInterfaceItemIdentifier(id)
            t.lineBreakMode = .byTruncatingTail
            v.addSubview(t)
        }
        label(84, "five", 13, true)
        label(62, "week", 13, true)
        label(38, "note", 11, false)

        let refresh = NSButton(title: "Refresh now", target: self, action: #selector(refreshAction))
        refresh.frame = NSRect(x: 14, y: 6, width: 116, height: 26)
        refresh.bezelStyle = .rounded
        v.addSubview(refresh)

        let quit = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.frame = NSRect(x: 250, y: 6, width: 66, height: 26)
        quit.bezelStyle = .rounded
        v.addSubview(quit)

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameTopLeftPoint(NSPoint(x: f.maxX - 350, y: f.maxY - 10))
        }
        return p
    }

    private func sub(_ id: String) -> NSView? {
        panel?.contentView?.subviews.first { $0.identifier?.rawValue == id }
    }

    // Sits in the free strip just right of the notch, where a menu bar icon
    // would go, at the menu bar's own window level.
    private func overlayFrame(on screen: NSScreen) -> NSRect {
        let h: CGFloat = 22
        let w = batterySize.width + 2
        let top = screen.frame.maxY - (screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 24)
        let x: CGFloat
        if let notch = notchBand(for: screen) {
            x = notch.end + 6
        } else {
            x = screen.frame.maxX - 420
        }
        return NSRect(x: x, y: top + 1, width: w, height: h)
    }

    @objc func showOverlay() {
        guard let screen = NSScreen.main else { return }
        if overlay == nil {
            let view = IconView(frame: .zero)
            view.onClick = { [weak self] in self?.toggleWindow() }
            iconView = view

            let p = NSPanel(contentRect: overlayFrame(on: screen),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.level = .statusBar
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.ignoresMouseEvents = false
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            p.contentView = view
            overlay = p
        }
        overlay?.setFrame(overlayFrame(on: screen), display: true)
        overlay?.orderFrontRegardless()
    }

    @objc func toggleWindow() {
        if panel?.isVisible == true { panel?.orderOut(nil) } else { showWindow() }
    }

    @objc func showWindow() {
        if panel == nil { panel = makePanel() }
        panel?.orderFrontRegardless()
        updatePanel()
    }

    private func updatePanel() {
        guard panel != nil else { return }
        (sub("icon") as? NSImageView)?.image = batteryImage(remaining: status?.fiveHour?.remainingPct, percentText: nil)
        func set(_ id: String, _ text: String) { (sub(id) as? NSTextField)?.stringValue = text }
        if let w = status?.fiveHour {
            set("five", "5-hour: \(Int(w.remainingPct.rounded()))% left · \(humanReset(w.resetsAt))")
        } else { set("five", "5-hour: no data") }
        if let w = status?.sevenDay {
            set("week", "Weekly: \(Int(w.remainingPct.rounded()))% left · \(humanReset(w.resetsAt))")
        } else { set("week", "Weekly: no data") }
        set("note", lastError ?? (lastUpdate != nil ? "Updated" : "Click Refresh now"))
    }

    @objc func togglePercent() {
        showPercent.toggle()
        render()
    }

    @objc func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            lastError = "Launch at login failed: \(error.localizedDescription)"
        }
    }
}

// `--register-login` / `--unregister-login`: flip the login item and exit,
// through the same SMAppService path the menu item uses. Scriptable, no UI.
if let flag = CommandLine.arguments.dropFirst().first,
   flag == "--register-login" || flag == "--unregister-login" {
    let enable = flag == "--register-login"
    do {
        if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        print("Launch at login \(enable ? "enabled" : "disabled").")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
