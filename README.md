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
trailing. The content area is the meter page on top, then the
Controls card, then a panel with the status row and keypad. The
Controls card and keypad stay at the same place and size on every
page; a key the page doesn't use is greyed out in its slot, not hidden.

- **Live telemetry** from the LP-500/700: average power, peak power,
  SWR, range, channel + auto-channel, peak/avg/tune mode, alarm state,
  callsign, coupler, firmware revision, status messages — pushed over
  WebSocket from the server.
- **Power & SWR mirror** — the meter's main LCD page rendered with
  large numeric readouts, SWR-tinted (green/yellow/red at 1.5 / 2.0
  thresholds), and a Controls card with four cycle-on-press buttons:
  CH (Auto / 1..4), Rng, Mode (Peak Hold / Average / Tune) and Alm.
  Range and Alarm are greyed out in CH Auto, because the meter can't
  change them there.
- **Waveform & Spectrum views** — the meter's other two LCD pages
  rendered natively. `WaveformView` shows the envelope-scope trace
  as a mirrored bar plot; `SpectrumView` shows the FFT as a
  vertical-bar graph (DC bin clipped). Both fed by the server's
  `scope` / `spectrum` WS frames (~4 Hz while the meter is on the
  matching page). The app shows whichever page the meter is on;
  the keypad's Mode button presses the meter's Mode key (Power/SWR →
  Waveform → Spectrum → Power/SWR). On these pages CH picks the
  page's own CH 1–4 (the meter offers no Auto there). Needs
  LP-700-Server v0.2.7 or later. A compact power strip above the trace shows
  what the meter's own screen shows on that page: average and peak
  power on Waveform, one power reading and its dBm on Spectrum. Only CH works on these pages: there the meter's Range,
  Alarm and Peak keys set V/div, sweep, span and so on, which the
  server doesn't report yet, so the app greys them out (set them on the
  meter). In Setup only Mode works. The waveform trace rides
  through the meter's capture glitches: an empty or torn frame keeps
  the last clean trace for up to a second.
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
  buttons, notifications toggle, menu-bar toggle, update-check toggle.
- **Update check** — tells you when a newer release is published on
  GitHub (see [Updates](#updates)); never downloads anything itself.
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

The script builds a release binary for this Mac's architecture only (a local
install never runs anywhere else, so the universal build would double the
compile time and binary size for nothing), strips local symbols, ad-hoc signs
it, then ditto-copies the bundle into `/Applications`. Set
`ARCHS="arm64 x86_64"` to get a universal binary, or `STRIP=0` to keep
symbols. If `/Applications` requires elevated access (rare on personal
Macs), it re-runs itself with `sudo`.

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

**Behind the shack's TLS proxy** (Caddy with HTTP Basic auth in front of
`lp700-server`), use `https://<host>:8089`, e.g. `https://192.168.86.43:8089`;
the app derives `wss://…/ws`. Plain `http://…:8089` stops working once the
proxy is in place. In the same sheet, under **Proxy login**, enter the
username (default `operator`) and password and click **Save to Keychain**
(**Remove** deletes it). The login is a generic password in your login
Keychain, service `ShackProxy`, account = the username, so one made with
`security add-generic-password -s ShackProxy -a operator -w` works too. The
app sends it as `Authorization: Basic …` on the WebSocket upgrade and every
HTTP request to the server, **only over https/wss — never over plain
http/ws**, even when a login is stored. A 401 shows as *Proxy login
required* (none sent) or *Proxy login rejected* (wrong login), and the
retry then waits at least 30 s. The proxy's certificate must be trusted by
macOS (install the Shack CA in the Keychain); the app does no pinning. macOS
may ask once whether LP-700-App may use the `ShackProxy` item: choose
**Always Allow** (an ad-hoc-signed rebuild can ask again).

Loaded in the Amateur Radio Suite, the plugin behaves the same way: the
first time it appears it asks for the server URL, and from then on it
connects on its own. The Suite plugin keeps its own copy of the URL (the
extension's sandbox), so configure it once there even if the standalone
app is already set up.

## Updates

The app tells you when a newer LP-700-App release is out. About
10 seconds after launch, and then once a day while it keeps running, it
makes one anonymous request to GitHub —
`GET https://api.github.com/repos/VU3ESV/LP-700-App/releases/latest` —
and compares that release's tag with its own version. If the release is
newer, a dialog shows its notes with **Download** (opens the release
page in your browser), **Skip This Version** and **Remind Me Later**.
Nothing is downloaded or installed automatically, and no other server is
involved. When the dialog appears on its own it does not take the
keyboard or bring the app forward — whatever you are typing in keeps the
keyboard — and none of its buttons is the default, so Return never opens
the browser: **Download** needs a click, Esc is **Remind Me Later**.

- **LP-700 ▸ Check for Updates…** checks right away and always reports
  (newer release, up to date, or why the check failed).
- **Preferences (⌘,) → Updates → Check for updates automatically**
  turns the automatic check off (default on).
- Automatic checks are silent when GitHub can't be reached; the time is
  remembered only after a successful answer, so a failed attempt is
  retried (at most once an hour) instead of waiting a day.
- Development builds (`0.0.0-dev`, the default when `VERSION` isn't set)
  never check on their own; the menu item still works.
- Only the standalone app checks. Hosted as an Amateur Radio Suite
  plugin, LP-700 never makes the request.

To see the dialog against the real latest release, quit the app and run
`open --env UPDATE_CHECK_TEST_CURRENT_VERSION=0.0.1 /Applications/LP-700-App.app`,
then choose **Check for Updates…** (the variable is ignored unless set).

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
# (ARCHS=native builds only this Mac's slice; STRIP=1 strips local symbols)
VERSION=$(git describe --tags --always) ./scripts/build-app.sh

# Wrap the .app in a DMG with /Applications symlink
VERSION=$(git describe --tags --always) ./scripts/make-dmg.sh

# Build (native arch only) + install directly to /Applications
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
│   ├── UpdateChecker.swift  # GitHub release check (Check for Updates…)
│   ├── Net/                 # WireProtocol, WSClient, ConfigClient, ProxyAuth, ProxyKeychain
│   ├── ViewModels/          # MeterViewModel
│   ├── Views/               # ContentView, PowerSWRView, KeypadView,
│   │                        # ConnectionSheet, PreferencesView, SetupOverlay,
│   │                        # Panel
│   └── MenuBar/             # MenuBarLabel + MenuBarContent popover
├── Tests/LP700AppTests/     # WireProtocol round-trips, UpdateChecker, configuredServerURL, WS reconnect, proxy auth
├── Resources/Info.plist     # bundle template (VERSION substituted at build time)
├── scripts/
│   ├── build-app.sh         # release .app (universal; ARCHS=native, STRIP=1), ad-hoc signed
│   ├── make-dmg.sh          # DMG with /Applications symlink
│   ├── make-icon.sh         # generates AppIcon.icns from a 1024×1024 PNG
│   └── install-local.sh     # native, symbol-stripped build + ditto-copy to /Applications
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

- **No authentication of its own.** The server is LAN-only by design. The
  app does speak HTTP Basic auth to an authenticating TLS reverse proxy in
  front of it (see [Configure](#configure)); for remote access, front the
  server with Tailscale or WireGuard.
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
