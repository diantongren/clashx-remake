# ClashX Remake

A ground-up rewrite of [ClashX.Meta](https://github.com/MetaCubeX/ClashX.Meta) for macOS 15+,
built the way you would start the project today:

| | ClashX.Meta (2025) | ClashX Remake |
|---|---|---|
| UI | Storyboard + hand-built `NSMenu` views, partial SwiftUI dashboard | SwiftUI `MenuBarExtra`, `Settings`, `Window` scenes only |
| State | RxSwift relays + `NotificationCenter` | `@Observable` model, `async/await`, `AsyncStream` |
| Concurrency | Swift 5 mode, ad-hoc actors | Swift 6 language mode, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` |
| Privileged helper | `SMJobBless` (deprecated) + ObjC `ProxySettingTool` | `SMAppService.daemon` + pure-Swift `SCPreferences` code |
| Core process | helper writes a launchd plist per run, polls `launchctl` | daemon owns the core as a child; orphan-safe |
| Core without helper | not possible | user-space fallback (proxy ports only) |
| XPC | `@objc` protocol + Codable envelopes | same idea, one `send(Data)` entry point, versioned envelopes |
| Client validation | bundle-id check | `SecCodeCheckValidity` against a build-time requirement |
| Networking | `async-http-client` + SwiftNIO stack | `URLSession` only (`bytes(for:).lines` for streams) |
| Dependencies | 30+ packages | Yams |
| Project | hand-maintained `.pbxproj` | `xcodegen` from `project.yml` |
| Tests | none | Swift Testing on the pure-logic package |

## Layout

```
project.yml                  xcodegen description (run `xcodegen generate`)
App/                         the menu bar application
  Sources/AppModel.swift     @Observable single source of truth
  Sources/Core/              CoreBinary (extract+verify), launchers, CoreManager
  Sources/Helper/            HelperClient (SMAppService + XPC)
  Sources/System/            system proxy snapshot/observer, launch at login
  Sources/UI/                MenuBar, Settings, Dashboard (SwiftUI)
  Resources/Core/            mihomo.gz + core-manifest.json (from scripts/fetch-core.sh)
Helper/                      privileged daemon (launchd, SMAppService)
  Sources/CoreSupervisor     runs mihomo as root, kills it when the app goes away
  Sources/SystemProxyConfigurator / DNSConfigurator
Packages/ClashXKit/          SwiftPM package shared by both targets
  MihomoAPI                  REST + streaming client, Codable models
  ConfigKit                  profile override composer, bootstrap config, port allocator, gunzip
  HelperProtocol             XPC protocol + typed messages
scripts/fetch-core.sh        downloads the mihomo release, builds a universal binary, writes manifest
```

## Build

```bash
brew install xcodegen
scripts/fetch-core.sh            # or scripts/fetch-core.sh v1.19.33
xcodegen generate
xcodebuild -project ClashXRemake.xcodeproj -scheme ClashXRemake -configuration Debug \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- build
```

Package tests:

```bash
swift test --package-path Packages/ClashXKit
```

Set `DEVELOPMENT_TEAM` in `project.yml` (and `CLASHX_CLIENT_CODE_REQUIREMENT`, e.g.
`anchor apple generic and identifier "app.clashx.remake" and certificate leaf[subject.OU] = "TEAMID"`)
for a build whose helper actually verifies its client.

## How it runs

1. On launch the app gunzips the bundled core into `~/Library/Application Support/app.clashx.remake/core/`,
   verifies its SHA-256 against `core-manifest.json`, and writes a tiny *bootstrap* config
   (controller address, random secret, ports moved off anything already listening).
2. If the SMAppService helper is registered and answers, the core is started by the daemon as root
   (TUN + system proxy available). Otherwise it is started as the current user and the menu says so.
3. Once `/version` answers, the selected profile from `~/.config/clash.meta/*.yaml` is composed with
   the menu overrides (mode, log level, allow-lan, tun, sniffer) and pushed with `PUT /configs`.
   Remembered group selections are replayed.
4. Traffic, memory, connections and logs are consumed as HTTP line streams; the menu bar label shows speed
   (icon + two-line readout composited into one template image, because `MenuBarExtra` only forwards a single
   image and one line of title to the status-bar button).
5. The profile folder and the active profile file are watched; editing the active profile hot-reloads the core.
6. Quitting stops the core; if the app crashes, the daemon stops the core 15 s after the last XPC
   connection drops, and the user-space launcher reaps a stale PID on the next start.

Set `CLASHX_CONFIG_DIR=/some/dir` in the environment to point the app at a different profile folder.

## Not ported (yet)

iCloud profile sync, SSID-based auto suspend, AppleScript commands, Sparkle updates, remote-profile
auto-update timers (import via `clash://install-config?url=` works), alpha-core switching, bundled
web dashboards (hosted builds are loaded instead), per-item custom menu views (menu style forbids them),
`external-controller-unix`.
