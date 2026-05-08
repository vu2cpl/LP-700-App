# LP-700-App

A native macOS client for the
[LP-700 WebSocket Server](https://github.com/VU3ESV/LP-700-Server) — the
upstream daemon that owns the USB HID handle on the Telepost LP-500 / LP-700
Digital Station Monitor and exposes telemetry + control verbs over WebSocket.
This app is one of those clients, replicating the look & feel of the server's
embedded reference web UI as a real Mac app.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange) ![License](https://img.shields.io/badge/License-MIT-green)

Companion of [VU3ESV/LP-100A-App](https://github.com/VU3ESV/LP-100A-App).
Same shell, same reconnect machinery, different telemetry shape — HID
instead of serial, with channel + range + alarm semantics specific to
the LP-500/700.

## What it does

A native Mac window with a standard `NSToolbar` — connection badge on
the leading side (green/yellow/red dot + host label), a backend pill in
the principal slot (HID / SIMULATOR), and shield + wrench gear buttons
trailing. The content area is two `regularMaterial` panels: live
readouts on top, status row + keypad beneath.

- **Live telemetry** from the LP-500/700: average power, peak power,
  SWR, range, channel + auto-channel, peak/avg/tune mode, alarm state,
  callsign, coupler, firmware revision, status messages — pushed over
  WebSocket from the server.
- **Power & SWR mirror** — the meter's main LCD page rendered with
  large numeric readouts, SWR-tinted (green/yellow/red at 1.5 / 2.0
  thresholds), channel pills (Auto / 1..4), range cycle button, peak
  mode trio (Peak Hold / Average / Tune), alarm pill.
- **Control verbs** the server's `/ws` channel accepts:
  `peak_toggle`, `range_step`, `channel_step`, `alarm_toggle`,
  `mode_step`. All gated behind the server's `allow_control` flag.
- **SETUP overlay** — server log-level picker (`/api/log-level`),
  backend annotation (HID vs simulator), and a read-only display of
  meter NVRAM fields (callsign / coupler / firmware).

Mac-specific affordances:

- **First-launch Connect sheet** — modal panel asking for the server URL,
  with an inline "Test connection" probe (`/healthz`). Re-openable from the
  toolbar shield button or via **⌘K**.
- **Toolbar connection badge** — green dot + host label.
- **Backend pill** — HID = real meter, SIMULATOR = synthesised data.
- **Menu-bar live readout** — glance-able Avg power + SWR + connection
  state while the main window is hidden.
- **Native macOS notifications** — alert when `alarm_tripped` rises,
  throttled to one per 30 s.
- **Preferences (⌘,)** — server status + Change/Reconnect/Disconnect
  buttons, notifications toggle, menu-bar toggle.
- **Keyboard shortcuts** — ⌘R range step, ⌘A alarm toggle, ⌘M LCD mode
  step, ⌘Y resync, ⌘. SETUP overlay, ⇧⌘1/2/3 force Peak Hold / Avg /
  Tune, **⌘K Connect to Server…**, **⇧⌘D Disconnect / Reconnect**.
- **Sleep/wake hook** — reconnects on `NSWorkspace.didWakeNotification`
  so the meter is correct the moment the lid opens.

The window respects the system appearance (light/dark) — readouts use
the system tint color and `regularMaterial` panel backgrounds.

## Install

### From a release DMG

1. Download `LP-700-App-<version>.dmg` from the
   [Releases](https://github.com/VU3ESV/LP-700-App/releases) page.
2. Open the DMG, drag **LP-700-App.app** to `/Applications`.
3. **Gatekeeper bypass.** This app is ad-hoc-signed, not Apple-notarized
   (yet). Once after install, run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/LP-700-App.app
   ```
   Then double-click as normal. A future release will be notarized; until
   then, this one-time bypass is the cost of skipping the Apple Developer
   Program fee.

### Install to /Applications from source (one command)

The `scripts/install-local.sh` helper builds the app and copies it into
`/Applications` in one step (including the `xattr -d` quarantine strip):

```sh
git clone https://github.com/VU3ESV/LP-700-App
cd LP-700-App
VERSION=$(git describe --tags --always 2>/dev/null || echo 0.0.0-dev) \
    ./scripts/install-local.sh
open /Applications/LP-700-App.app
```

The script builds the universal release binary, ad-hoc signs it, then
ditto-copies the bundle into `/Applications`. If `/Applications` requires
elevated access (rare on personal Macs), it re-runs itself with `sudo`.

### Configure

The app opens a **Connect to LP-700 Server** sheet automatically the
first time it runs (no `serverURL` configured yet). Enter the URL of your
server (e.g. `http://localhost:8089` for a local server, or
`http://raspberrypi.local:8089` for a Pi on the LAN), tap **Test
connection** to probe `/healthz`, then **Connect**. Note the default
port is **8089** — LP-100A-Server uses 8088, LP-700-Server uses 8089 so
the two can coexist on the same Pi.

To change servers later: click the shield icon in the toolbar, choose
**File → Connect to Server… (⌘K)**, or open **Preferences (⌘,) → Server
→ Change Server…**. To disconnect cleanly, hit **⇧⌘D**.

## Build from source

Requirements: macOS 13+, Xcode 15+ (or Xcode-CLT with Swift 5.9+).

```sh
git clone https://github.com/VU3ESV/LP-700-App
cd LP-700-App

# Run tests
swift test

# Run from the command line (debug, single-arch — fast iteration)
swift run

# Build a universal (arm64+x86_64) release .app bundle in dist/
VERSION=$(git describe --tags --always) ./scripts/build-app.sh

# Wrap the .app in a DMG with /Applications symlink
VERSION=$(git describe --tags --always) ./scripts/make-dmg.sh

# Build + install directly to /Applications
VERSION=$(git describe --tags --always) ./scripts/install-local.sh
```

The `.app` is ad-hoc-signed (`codesign --sign -`); fine for local use and
for distribution if users do the `xattr -d` step above. Notarization is a
TODO item.

## Releasing

Releases are produced by GitHub Actions
([`.github/workflows/release.yml`](.github/workflows/release.yml)),
which runs on `macos-14` (Apple Silicon, Xcode 15.x). Two ways to fire it:

### 1. Tag-driven release (creates a public Release object)

```sh
git tag v0.1.0
git push origin v0.1.0
```

The workflow:

1. Runs `swift test`.
2. Builds the universal `.app` via `scripts/build-app.sh`.
3. Wraps it in a DMG via `scripts/make-dmg.sh`.
4. Computes the SHA-256 checksum.
5. Creates a GitHub Release at `v0.1.0` with auto-generated release
   notes from the previous tag's commits, and attaches `LP-700-App-0.1.0.dmg`
   plus its `.sha256`.

### 2. Manual dispatch (also creates a Release; tag is created at the run's commit)

From the GitHub Actions UI: **Actions → Release → Run workflow**. Enter
a version string (e.g. `0.1.0`). The workflow creates the matching
`v0.1.0` git tag at `HEAD` of `main` and cuts the same kind of public
Release the tag-push path does. Tick the **prerelease** checkbox if
you don't want the new tag to become `latest`.

Because manual dispatch creates a real tag, re-running with the same
version will fail (the tag already exists). Bump the version or delete
the old tag first.

CI smoke-builds the same `.app` on every push and PR, so a tag push
that gets to the release stage is already known to compile and pass tests.

## How it works

- One `MeterViewModel` (`@MainActor`) owns the latest snapshot, connection
  state, and SETUP toggle.
- A `WSClient` actor wraps `URLSessionWebSocketTask`, auto-reconnects with
  0.5 → 10 s exponential backoff, and runs a 4 s heartbeat watchdog (no
  inbound frame for >4 s = drop and reconnect).
- A `ConfigClient` actor handles `GET /api/config` (bootstrap) and
  `GET/POST /api/log-level` (SETUP overlay).
- The wire protocol mirrors the server's `internal/lpmeter/snapshot.go`
  JSON shape and the `command` / `resync` verbs handled by
  `internal/hub/hub.go`.

- [**User manual**](docs/USER_MANUAL.md) — installation walkthrough,
  view-by-view tour with screenshots, keyboard shortcuts, troubleshooting.
- [**Architecture review**](ARCHITECTURE.md) — layered design, concurrency
  model, connection lifecycle, risks.

## Project layout

```
LP-700-App/
├── README.md                # this file
├── CLAUDE.md                # session orientation for AI assistants
├── ARCHITECTURE.md          # architecture review
├── LICENSE                  # MIT
├── Package.swift            # Swift Package manifest (executable + tests)
├── Sources/LP700App/
│   ├── App.swift            # @main, scenes (WindowGroup, Settings, MenuBarExtra)
│   ├── Net/                 # WireProtocol, WSClient, ConfigClient
│   ├── ViewModels/          # MeterViewModel
│   ├── Views/               # ContentView, PowerSWRView, KeypadView,
│   │                        # ConnectionSheet, PreferencesView, SetupOverlay,
│   │                        # Panel
│   └── MenuBar/             # MenuBarLabel + MenuBarContent popover
├── Tests/LP700AppTests/     # WireProtocol decode/encode round-trips
├── Resources/Info.plist     # bundle template (VERSION substituted at build time)
├── scripts/
│   ├── build-app.sh         # universal release .app, ad-hoc signed
│   ├── make-dmg.sh          # DMG with /Applications symlink
│   ├── make-icon.sh         # generates AppIcon.icns from a 1024×1024 PNG
│   └── install-local.sh     # build + ditto-copy to /Applications
└── .github/workflows/
    ├── ci.yml               # build+test on every push/PR
    └── release.yml          # builds DMG, creates Release on tag
```

## Testing without a real meter

The server has a built-in `simulator` backend that emits synthesised
telemetry frames. Start it with:

```sh
go run . -backend simulator -config deploy/config.example.toml
```

Connect this app to `http://localhost:8089` and you'll see synthetic
power/SWR sweeps at the simulator's poll rate. The toolbar's **SIMULATOR**
pill makes it obvious the data isn't from a real meter.

## Limitations

- **No authentication.** The server is LAN-only by design; this client
  follows suit. For remote access, front the server with Tailscale or
  WireGuard.
- **No bargraphs (yet).** v0 is large numeric readouts only. The
  bargraph + sticky-peak-marker visuals from LP-100A-App will arrive
  in v0.2.
- **No notarization** — first release is ad-hoc-signed; Gatekeeper
  bypass documented above.

## Acknowledgements

Telepost Inc. designed and manufactures the LP-500 and LP-700. This
project is unaffiliated; product names and trademarks belong to
TelePost. The wire protocol, range labels, and peak-mode encoding
mirror the upstream
[LP-700-Server](https://github.com/VU3ESV/LP-700-Server)'s
`internal/lpmeter/snapshot.go` and the embedded reference web client.

## License

MIT — see [LICENSE](LICENSE).
