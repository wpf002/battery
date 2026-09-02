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

private func readTokenFromKeychain() throws -> String {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { throw BatteryError.noToken(status) }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String
    else { throw BatteryError.badCredential }
    guard !token.isEmpty else { throw BatteryError.emptyToken }
    return token
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
    if remaining > 50 { return .systemGreen }
    if remaining > 20 { return .systemOrange }
    return .systemRed
}

// Content is drawn at the LEFT end of the image. `padTo` widens the image to
// the right with transparent filler, which is how the icon escapes the notch:
// the menu bar pins the item's right edge, so a wider item reaches further left.
func batteryImage(remaining: Double?, percentText: String?, padTo: CGFloat = 0) -> NSImage {
    let glyph: CGFloat = 26
    var textWidth: CGFloat = 0
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.labelColor,
    ]
    var label: NSAttributedString?
    if let t = percentText {
        let a = NSAttributedString(string: t, attributes: attrs)
        label = a
        textWidth = a.size().width + 3
    }
    let contentWidth = glyph + textWidth
    let size = NSSize(width: max(contentWidth, padTo), height: 16)

    return NSImage(size: size, flipped: false) { _ in
        let body = NSRect(x: 1, y: 2.5, width: 21, height: 11)
        let ink = NSColor.labelColor.withAlphaComponent(0.85)

        let outline = NSBezierPath(roundedRect: body, xRadius: 2.5, yRadius: 2.5)
        outline.lineWidth = 1.2
        ink.setStroke()
        outline.stroke()

        ink.setFill()
        NSBezierPath(roundedRect: NSRect(x: 22.6, y: 6, width: 2, height: 4), xRadius: 0.8, yRadius: 0.8).fill()

        if let r = remaining {
            let inner = body.insetBy(dx: 2, dy: 2)
            let w = max(1.5, inner.width * CGFloat(r) / 100)
            levelColor(r).setFill()
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: w, height: inner.height),
                         xRadius: 1.2, yRadius: 1.2).fill()
        } else {
            let q = NSAttributedString(string: "?", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ])
            let sz = q.size()
            q.draw(at: NSPoint(x: body.midX - sz.width / 2, y: body.midY - sz.height / 2))
        }

        label?.draw(at: NSPoint(x: glyph, y: 2))
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

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var panel: NSPanel?
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
        showWindow()
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
