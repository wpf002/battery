# Claude Battery

macOS menu bar app showing remaining Claude Code quota as a battery icon.

- Green above 50%, orange 20–50%, red below 20%. Icon shows the 5-hour window; click for both windows with reset countdowns.
- Reads the OAuth token Claude Code already keeps in Keychain (`Claude Code-credentials`) and calls `https://api.anthropic.com/api/oauth/usage`. That's the only network call it makes.
- Refreshes every 30s and on wake. Single Swift file, AppKit, no dependencies, no Python.

## Build

Requires Xcode (or Command Line Tools) and macOS 13+.

```bash
./build.sh
```

That compiles `Sources/main.swift` into `build/ClaudeBattery.app`, ad-hoc signs it, copies it to `/Applications`, and launches it. First launch prompts for Keychain access: choose Always Allow.

## Menu

Refresh now · Show percentage (toggle the % text next to the icon) · Launch at login · Quit.

## Troubleshooting

- "Not logged in": run `claude` and sign in, then Refresh now.
- "Token expired": Claude Code refreshes the token when it runs; start a session.
- Keychain prompt every launch: rebuild with `./build.sh` (the ad-hoc signature is what makes the grant persistent).

## Layout

```
Sources/main.swift   app
Info.plist           bundle metadata (LSUIElement hides the Dock icon)
build.sh             build + install + launch
```
