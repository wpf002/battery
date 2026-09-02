# Claude Battery

macOS menu bar app (Swift, AppKit, single file). Shows remaining Claude Code quota as a battery icon.

## Build and run
`./build.sh` compiles Sources/main.swift with swiftc, bundles it as build/ClaudeBattery.app, ad-hoc signs, copies to /Applications, launches. No Xcode project, no SPM, no dependencies. Requires macOS 13+ and Xcode CLT.

## How it works
- Token: Keychain generic password, service `Claude Code-credentials`, JSON at `claudeAiOauth.accessToken`. Read only, never written.
- API: GET https://api.anthropic.com/api/oauth/usage with headers `Authorization: Bearer`, `anthropic-beta: oauth-2025-04-20`, `anthropic-version: 2023-06-01`. Response has `five_hour` and `seven_day`, each with `utilization` (0-100 used) and `resets_at`.
- Icon reflects the 5-hour window. Menu shows both windows, rebuilt on open so countdowns are live.
- Prefs in UserDefaults: `showPercent`. Launch at login via SMAppService.

## Conventions
- Keep it one file unless it gets past ~500 lines.
- No third-party deps. No Python.
- Don't add any network call other than the usage endpoint.
