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

func readAccessToken() throws -> String {
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
        guard http.statusCode == 200 else { completion(.failure(BatteryError.http(http.statusCode))); return }
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

func batteryImage(remaining: Double?) -> NSImage {
    let size = NSSize(width: 26, height: 14)
    return NSImage(size: size, flipped: false) { _ in
        let body = NSRect(x: 1, y: 1.5, width: 21, height: 11)
        let ink = NSColor.labelColor.withAlphaComponent(0.85)

        let outline = NSBezierPath(roundedRect: body, xRadius: 2.5, yRadius: 2.5)
        outline.lineWidth = 1.2
        ink.setStroke()
        outline.stroke()

        ink.setFill()
        NSBezierPath(roundedRect: NSRect(x: 22.6, y: 5, width: 2, height: 4), xRadius: 0.8, yRadius: 0.8).fill()

        if let r = remaining {
            let inner = body.insetBy(dx: 2, dy: 2)
            let w = max(1.5, inner.width * CGFloat(r) / 100)
            levelColor(r).setFill()
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: w, height: inner.height),
                         xRadius: 1.2, yRadius: 1.2).fill()
        } else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ]
            let q = NSAttributedString(string: "?", attributes: attrs)
            let sz = q.size()
            q.draw(at: NSPoint(x: body.midX - sz.width / 2, y: body.midY - sz.height / 2))
        }
        return true
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
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
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshAction), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc func refreshAction() { refresh() }

    func refresh() {
        fetchStatus { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let s):
                    self.status = s
                    self.lastError = nil
                    self.lastUpdate = Date()
                case .failure(let e):
                    self.lastError = describe(e)
                }
                self.render()
            }
        }
    }

    private func render() {
        let remaining = status?.fiveHour?.remainingPct
        item.button?.image = batteryImage(remaining: remaining)
        if showPercent, let r = remaining {
            item.button?.title = " \(Int(r.rounded()))%"
        } else {
            item.button?.title = ""
        }
        var tip = "Claude Code usage"
        if let w = status?.fiveHour { tip += "\n5-hour: \(Int(w.remainingPct.rounded()))% left, \(humanReset(w.resetsAt))" }
        if let w = status?.sevenDay { tip += "\nWeekly: \(Int(w.remainingPct.rounded()))% left, \(humanReset(w.resetsAt))" }
        if let e = lastError { tip += "\n\(e)" }
        item.button?.toolTip = tip
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
