# CLAUDE.md — LP-700-App orientation

This file is the entry point for AI assistants (and human collaborators)
joining a session on this repo. Read alongside [README.md](README.md)
(install + usage) and [ARCHITECTURE.md](ARCHITECTURE.md) (design
review). For the *server* side of the link see the upstream
[VU3ESV/LP-700-Server](https://github.com/VU3ESV/LP-700-Server).

## What this repo is

A native macOS SwiftUI client for the LP-700 WebSocket Server — a
WebSocket bridge that owns the USB HID handle on a Telepost LP-500 /
LP-700 Digital Station Monitor and fans telemetry out to multiple
clients. This app is one of those clients.

The architectural shape mirrors sibling
[VU3ESV/LP-100A-App](https://github.com/VU3ESV/LP-100A-App): same
`WSClient` / `ConfigClient` / `MeterViewModel` / `ContentView` layering,
same wire envelope (telemetry / heartbeat / status / ack), same Mac
chrome (`NSToolbar`, `regularMaterial` panels, `MenuBarExtra`,
`Settings` scene). What differs is the inner `Snapshot` shape (channel
+ auto-channel + range + alarm semantics specific to the LP-500/700)
and the absence of the LP-100A's vector-impedance view.

## Quick start

```sh
swift test            # run unit tests
swift run             # debug run, single-arch, fast iteration
VERSION=$(git describe --tags --always) ./scripts/build-app.sh
                      # universal release .app in dist/ (ARCHS=native: host arch only)
VERSION=$(git describe --tags --always) ./scripts/install-local.sh
                      # native, symbol-stripped build + install to /Applications
open /Applications/LP-700-App.app
```

The first launch opens a **Connect to LP-700 Server** sheet; default URL
is `http://localhost:8089`. To smoke-test without a real meter, run the
server in simulator mode:

```sh
# in the LP-700-Server repo:
go run . -backend simulator -config deploy/config.example.toml
```

The toolbar's **SIMULATOR** pill makes it obvious the data isn't from
a real meter.

## Repo layout

```
LP-700-App/
├── Package.swift                       # SPM manifest (executable + tests)
├── Sources/LP700App/
│   ├── App.swift                       # @main, scenes, menu commands, UpdateChecker config
│   ├── UpdateChecker.swift             # GitHub releases/latest check (shared verbatim with VU2CPL's apps)
│   ├── Net/
│   │   ├── WireProtocol.swift          # Snapshot, ServerFrame, ClientFrame
│   │   ├── WSClient.swift              # actor; reconnect + heartbeat watchdog
│   │   ├── ConfigClient.swift          # actor; /api/config + /api/log-level
│   │   ├── ProxyAuth.swift             # Basic-auth header rule (https/wss only) + 401 → ProxyAuthError
│   │   └── ProxyKeychain.swift         # "ShackProxy" Keychain item + in-memory ProxyLoginStore
│   ├── ViewModels/
│   │   ├── MeterViewModel.swift        # @MainActor source-of-truth
│   │   ├── PageKeys.swift              # which meter keys each LCD page allows (CH / Rng / Mode / Alm)
│   │   └── ScopeTraceHold.swift        # keeps the last clean waveform trace through capture glitches
│   ├── Views/
│   │   ├── ContentView.swift           # toolbar + page area + pinned ControlsCard + bottom CompactPanel (status + keypad)
│   │   ├── PowerSWRView.swift          # PowerSWRCombinedCard (mode-driven big readout + Avg/Pk/Ref + 3 graduated bars) + ControlsCard type
│   │   ├── KeypadView.swift            # inline keypad row (Range / Alarm / Mode / Sync), one title size for all
│   │   ├── WaveformView.swift          # scope trace (Canvas) for the meter's Waveform page
│   │   ├── SpectrumView.swift          # FFT bars (Canvas) for the meter's Spectrum page
│   │   ├── SampleViewShared.swift      # PowerStrip + PlaceholderText shared by the two views above
│   │   ├── ConnectionSheet.swift       # first-launch sheet (Cmd+K)
│   │   ├── PreferencesView.swift       # Settings scene (Cmd+,)
│   │   ├── SetupOverlay.swift          # log-level picker + backend annotation
│   │   └── Panel.swift                 # reusable regularMaterial card (Panel + CompactPanel)
│   └── MenuBar/
│       └── MenuBarContent.swift        # MenuBarExtra label + popover
├── Tests/LP700AppTests/
│   ├── WireProtocolTests.swift         # decode/encode round-trips + RangeNames canary
│   ├── UpdateCheckerTests.swift        # version compare, automatic-check rule, dev skip
│   ├── ServerURLTests.swift            # configuredServerURL rule shared by the 3 entry points
│   ├── ControlsGateTests.swift         # PageKeys per page: CH Auto, CH 1–4, Waveform/Spectrum, Setup, no snapshot
│   ├── ScopeTraceHoldTests.swift       # torn / empty scope frames hold the last clean trace for 1 s
│   ├── ModeFollowTests.swift           # view follows top_mode; LCD Mode press skips Setup only if it lands there
│   ├── WSClientReconnectTests.swift    # retry after a refused connection; stop() drops the retry
│   └── ProxyAuthTests.swift            # header only over TLS, base64, 401 required/rejected, local 401 stub
├── Resources/Info.plist                # bundle template (__VERSION__ substituted)
├── scripts/
│   ├── build-app.sh                    # release .app (universal; ARCHS=native, STRIP=1), ad-hoc signed
│   ├── make-dmg.sh                     # DMG with /Applications symlink
│   ├── make-icon.sh                    # AppIcon.icns from a 1024×1024 PNG
│   └── install-local.sh                # native, symbol-stripped build + ditto-copy to /Applications
├── .github/workflows/
│   ├── ci.yml                          # build+test on every push/PR
│   └── release.yml                     # tag-driven OR manual release
├── .support/
│   └── links.txt                       # target + reference URLs
├── README.md                           # install + usage
├── ARCHITECTURE.md                     # design review
├── CLAUDE.md                           # this file
└── LICENSE                             # MIT
```

## Key design decisions

1. **Mirror, don't fork.** The networking actors and view-model
   skeleton are deliberately near-copies of LP-100A-App so a fix in
   one repo can be ported with minimal friction. The only
   intentional divergence is `WireProtocol.swift` (different inner
   `data` shape) and the meter view itself.
2. **One WebSocket, no multiplexing.** Per-server profiles, multi-shack
   support, etc. are explicitly out of v0. Single `serverURL` in
   UserDefaults, single `WSClient` instance.
3. **Server is authoritative.** No client-side optimism for command
   verbs — the meter publishes truth in subsequent telemetry frames,
   so we wait one poll cycle (~40 ms at default config) and read back
   the new state.
4. **Native chrome.** No LCD-replica gradients or scan-lines; we use
   `regularMaterial` panels and the system tint. The LP-100A-App went
   the same direction in its v0.2 review.
5. **Ad-hoc signed only.** Notarization needs a paid Developer ID.
   Until then, the README documents `xattr -dr com.apple.quarantine`
   and `scripts/install-local.sh` does it automatically.

## Wire protocol cheat sheet

`Snapshot` is 1:1 with the server's `internal/lpmeter/snapshot.go`:

- Power: `power_avg_w` (live), `power_peak_w` (live envelope peak — bytes 23-24), `peak_hold_w` (firmware-maintained held peak — bytes 0-1; populated by both real HID and simulator backends as of LP-700-Server fc9bde0)
- SWR: `swr` — severity tint thresholds 1.5 / 2.0
- Channel: `channel` (1..4) + `auto_channel` (bool)
- Range: `range` ("auto" / "5W" / "10W" / … / "10K")
- Modes: `peak_mode`, `power_mode`, `top_mode`
- Alarm: `alarm_enabled`, `alarm_tripped`, `alarm_power_w`, `alarm_swr`
- Static-ish: `callsign`, `coupler`, `firmware_rev`
- Optional: `status_message`

Command verbs (`/ws` JSON):

| Action          | Value semantics                              |
|-----------------|----------------------------------------------|
| `peak_toggle`   | 0 = peak_hold, 1 = average, 2 = tune         |
| `range_step`    | next index into `RangeNames.cycle`           |
| `channel_step`  | 0 = auto, 1..4 = explicit                    |
| `alarm_toggle`  | 0 = off, 1 = on                              |
| `mode_step`     | (no value — cycles top-level LCD mode)       |

`RangeNames.cycle` MUST stay in lockstep with the server's web client.
A unit test in `WireProtocolTests.testRangeNamesMatchServer()` is the
canary.

## Releasing

Two paths, both via `.github/workflows/release.yml`:

```sh
# Tag-driven (creates public GitHub Release + attaches DMG + sha256)
git tag v0.1.0
git push origin v0.1.0
```

Or manually from the GitHub Actions UI: **Actions → Release → Run
workflow**, enter a version like `0.1.0`. The workflow creates the
matching `v0.1.0` tag at the current commit and cuts the same kind
of public Release the tag-push path does. Tick the **prerelease**
checkbox to keep the new tag out of "latest".

The plugin carries the same version as the app. `scripts/make-radioplugin.sh`
and `scripts/package-signed.sh` pass `VERSION` to xcodebuild as
`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` (the extension's Info.plist
holds `$(...)` placeholders that xcodegen emits from `Xcode/project.yml`)
and stamp `plugin.json`'s `__VERSION__` when packaging. After a release,
update the Suite's `docs/catalog/catalog.json` LP-700 entry (`latestVersion`,
`url`, `sha256`): the Suite compares the installed plugin's version against
it. The in-process `LP700Plugin.manifest` version is not used by the Suite.

## Things to watch out for

- **`auto_channel` vs `channel`.** When `auto_channel == true`, the
  numeric `channel` still holds the *currently active* slot the meter
  is decoding. UI shows `A → N` in the Controls CH button so the
  operator can see both that auto-channel is on *and* which channel is
  live (mirrors the hardware LCD's "Auto Ch=1" indicator). `PowerSWRView`'s
  `channelLabel` builds the string; the cycle advances
  0 (auto) → 1 → 2 → 3 → 4 → 0 via `channel_step`.
- **Peak Power display follows `peak_mode`.** The wire frame carries
  two distinct fields: `power_peak_w` (live envelope peak, bytes 23-24,
  decays on key-up) and `peak_hold_w` (firmware-maintained held peak,
  bytes 0-1, sticky until cleared on the meter). The "Peak power"
  readout selects between them via `Snapshot.displayedPeakW`: held in
  Peak Hold mode, live in Average/Tune. Mirrors index.html's render()
  so app + web client stay aligned. Falls back to `power_peak_w` if
  `peak_hold_w` is 0 (older server build, or no peak observed yet).
- **`status_message` empties on TX-end.** When the meter clears its
  alert ASCII, the server sends `status_message: ""`. The UI hides
  the banner when empty — don't show a stale message.
- **The server fans out a snapshot on connect.** Don't issue `resync`
  preemptively on connect — the hub already does it.
- **Range and Alarm are locked in CH Auto.** Both are stored per
  channel, and the LP-500 user guide v5.4 (Power/SWR mode, Range and
  Alarm buttons) ends each paragraph with "This choice can't be
  changed when the CH button is in Auto." A bench test on the LP-700
  (2026-10-13) agrees: F3 / F4 do nothing in CH Auto. So the Controls
  card's `Rng` / `Alm` and the keypad's Range / Alarm are greyed out
  whenever `auto_channel == true`, with a secondary-grey note under the
  Controls card; CH and Mode stay usable so the operator can leave
  Auto. `PageKeys.make` holds this rule together with the per-page
  ones below, and `ControlsGateTests` pins it. History: the 2026-05-09 gate was
  right; a 2026-05-17 "misread probe" correction misquoted the manual,
  ungated Range in the Controls card and reverted the server's NACK
  (LP-700-Server PR #3). Both are undone: this repo's PR #24 restored the
  gate, and LP-700-Server PR #6 (in v0.2.6) restored the NACK, so a
  server from v0.2.6 on rejects `range_step` / `alarm_toggle` in CH Auto
  ("Range can't be changed in CH Auto; select CH 1-4"). Older servers
  forward them and the meter ignores them, so the app gate stays the
  primary guard. Don't ungate them again.
- **Single Controls card with cycle-on-press buttons.** As of the v0.3
  redesign, `PowerSWRView` no longer has separate Channel pills, a
  Range card, a Peak-mode segmented control, and an Alarm card. They
  collapsed into one `ControlsCard` with four inline-label buttons:
  `CH A→N/1/2/3/4`, `Rng auto/5W/.../10K`, `Mode Hold/Avg/Tune`, and
  `Alm Off/On/TRIP`. Each button shows the current value as its face
  and advances on press. `ContentView.meterPane` is now a non-scrolling
  `VStack` (the previous `ScrollView` blocked `.windowResizability(.contentMinSize)`
  from computing a proper floor); status row (Coupler / Power / Top
  / FW) sits above the `KeypadView` keypad row in a single `CompactPanel`.
- **The Controls card and keypad never move between pages.**
  `ContentView.meterPane` owns the `ControlsCard`, not the page views:
  the page area (`PowerSWRView` / `WaveformView` / `SpectrumView`) is a
  flexible frame, and the Controls card and keypad panel sit below it at
  the same place and size on every page. The card always shows all four
  buttons; a key the page doesn't allow is greyed out in its slot with
  a one-line note under the card (`PageKeys.cardNote`), never hidden.
  This is the shack-wide UI rule (Manoj, 2026-11-19, in his global
  CLAUDE.md): before calling UI work done, switch through every page
  and check the shared buttons don't move. Until 0a20fe0 each page
  embedded its own card (the sample pages a 2-button one), so the card
  and keypad jumped on every page change. Button heights are fixed (a
  hidden full-size line in each Controls button, a fixed label height in
  the keypad), so a long or shrunken label can't make a button or a row
  taller or shorter on some page.
- **Keypad titles: one size for all four, as big as fits** (Manoj,
  2026-11-19). The keypad shows Range / Alarm / Mode / Sync as single
  lines in the Controls card's value font (15 pt semibold rounded, like
  "A → 1"). `ViewThatFits` steps all four down together, a point at a
  time to 11 pt, only when the window is too narrow; each button
  reserves the widest title's room, because the row splits its width
  equally ("Range" was cut off when only the row total was checked).
  No small second lines: they repeated the Controls card (range, alarm
  state), its lock note, and the status row's Top field (the page).
  Never size one key's title on its own: Manoj found a big "Mode" next
  to small titles "horrible". "Mode" is the LCD page key (F1), "Sync"
  re-requests a snapshot (`vm.resync()`); the Meter menu says "Sync" too.
- **Every key is gated by the meter's page (`PageKeys`).** Each app
  control is a raw key press (Mode = F1, CH = F2, Range = F3,
  Alarm = F4, Peak/Avg/Tune = F5), and the meter gives F2–F5 another
  job on each page: Waveform F3/F4/F5 = V/div / Sweep / Wfm Style,
  Spectrum = dB range / Span / Averaging, Setup = Scroll / Adj Dn /
  Adj Up (F2 picks the channel being adjusted). A Range press on the
  Waveform page changed V/div on the bench (2026-11-19), and in Setup
  Alarm or Peak/Avg/Tune could change a setting such as the coupler type. So `PageKeys.make(snapshot)`
  allows CH only on Waveform/Spectrum, nothing but Mode (F1) in Setup,
  and everything but Range/Alarm in CH Auto. The Controls card, the
  keypad, the Meter menu and the `MeterViewModel.send…` guards all read
  `vm.keys`, so no path can press a key the page doesn't allow.
- **Hardware-style combined Power & SWR card** (v0.3.x). One unified
  card replaces the previous Avg / Peak / SWR triple. Layout: a single
  big mode-driven power number (Hold → Peak orange, Avg → Avg cyan,
  Tune → Avg green) and a big severity-tinted SWR number side-by-side
  at the top; small `Avg / Pk / Ref` inline labels under the big
  numbers; three stacked graduated bargraphs (Avg, Pk, SWR) below.
  Card header is mode-aware ("AVERAGE" / "PEAK" / "TUNE"). Drives off
  `PowerSWRModel` which carries `cardLabel`, `bigPowerValue`,
  `bigPowerTint`, the three small readings, the three bars, and the
  scale labels — all derived in `PowerSWRModel.make`. SwiftUI
  `.equatable()` short-circuit still wraps the subtree to keep
  re-render cost bounded at the 5 Hz publish rate.
- **Graduated bargraphs (18 pt tall).** Power bars carry quartile
  ticks at 25 / 50 / 75 % of current range; SWR bar carries ticks at
  the 1.5 and 2.0 severity thresholds on a 1.0–3.0 scale. Power axis
  shows e.g. `0 / 5 W`; SWR axis shows `1.0 · 1.5 · 2.0 · 3.0`. Ticks
  are 1-pt-wide hairlines drawn over the fill at 35 % black opacity so
  they read on both filled and unfilled portions.
- **Reflected power (Pr) is derived client-side** in `reflectedPower(swr:displayed:mode:)`.
  Formula: ρ = (SWR − 1)/(SWR + 1); Pr = displayed · ρ² in `forward` mode,
  Pr = displayed · ρ² / (1 − ρ²) in `net` / `delivered` modes. Shown
  as `Ref X.X W` next to the small Avg / Pk labels under the big SWR.
  Returns `nil` (UI shows `— W`) for SWR < 1 / no TX, so we never
  paint a misleading 0.
- **Bargraphs always auto-scale** for the display, independent of
  the meter's range setting. `autoScale()` picks the smallest standard
  from `[1, 2, 5, 10, 25, 50, 100, 250, 500, 1K, 2.5K, 5K, 10K]` ≥
  the highest power in the current snapshot, using
  `peakHoldW` + `powerPeakW` + `powerAvgW` as a max so the scale stays
  stable across a transmission envelope. (1-2-5 progression below
  10 W for QRP resolution; matches the meter's hardware range ladder
  above.) This is a display-side choice: a 2 W signal on a 500 W
  manual meter range would otherwise show as a 0.4 % sliver, which
  is illegible. The Range label still shows the meter's actual
  setting; the bar's full-scale is computed from live power.
- **Window sizing matches Macexpert SPE** (sibling shack utility):
  `.frame(minWidth: 380, minHeight: 520)` + `.defaultSize(width: 400,
  height: 580)`. `.windowResizability(.contentMinSize)` so the user
  can grow the window past the content floor but never shrink it
  below the readable minimum.
- **Scope (Waveform) and Spectrum views.** Server v0.1.6+ emits two
  new WS frame types — `scope` and `spectrum` — each carrying a 320-
  element `[UInt8]` buffer at ~4 Hz while the meter is on the matching
  LCD page. `MeterViewModel.lastScope` / `lastSpectrum` cache the most
  recent payload; `WaveformView` and `SpectrumView` render the buffers
  via SwiftUI `Canvas` (mirrored mid-line plot in cyan for waveform;
  vertical-bar FFT in green for spectrum, with the DC bin clipped to
  the rest-99th-percentile so it doesn't squash dynamic range).
  `PowerStrip` shows the live numerics above the trace because sample
  values are display-normalised (0..255), not absolute watts.
- **The view follows the meter's LCD page.** `MeterViewModel.activeView`
  (`powerSWR` / `waveform` / `spectrum`) is set from `top_mode` on every
  telemetry frame (`MeterViewModel.activeView(for:)`; Setup shows
  Power/SWR). The keypad's Mode button only presses the meter's Mode key once
  and changes nothing locally. The LP-500 guide gives that key a 3-page
  cycle (Power/SWR → Waveform → Spectrum; Setup has its own key), so no
  double press. `ModeStepTracker` sends one more press only if a press
  from the app is seen to land on Setup within 2 s. `ModeFollowTests`
  pins both. History: until 2026-11-19 the view was user-driven and only
  seeded once, because the server's telemetry flapped between pages
  (fixed in LP-700-Server PR #9), and the Spectrum wrap sent two
  presses for a "4-page cycle"; on the bench that left the app on
  Waveform while the meter showed Spectrum.
- **The Waveform / Spectrum pages have their own CH 1–4, never Auto.**
  LP-500 guide v5.4: "CH Auto is not offered in the 'scope mode … The
  channel selection for the 'scope mode is independent of the Power/SWR
  mode" (same for Spectrum). On these pages the CH button (F2) cycles
  1 → 2 → 3 → 4 → 1. A server with LP-700-Server PR #9 reports
  `auto_channel: false` and the page's channel there; older servers read
  them as CH Auto whenever Power/SWR is in CH Auto and hold every trace
  back. The views keep an `autoChannel` placeholder only for that case,
  and it says to update the server. (An earlier note here called Auto
  "hardware-invalid" on these pages; that was a misreading.) Only CH is
  live there (see `PageKeys` above). The server doesn't report V/div,
  sweep, span or averaging, so the app can't offer those keys yet (see
  the wfm-spec-fkeys handover on the server fork); each view's footnote
  says they are set on the meter.
- **Waveform trace hold (`ScopeTraceHold`).** The meter re-arms its
  capture between the server's five 64-sample segment reads, so about a
  quarter of keyed frames arrive all zero or torn (one capture's
  segments next to the next's). A real envelope is smooth: neighbouring
  samples differ by ≤ 1, also across segment edges. A frame that is all
  zero or jumps by more than 8 at a segment edge keeps the last clean
  trace on screen for up to 1 s; after that whatever arrives is drawn,
  so key-up still goes flat within a second. Waveform only: spectrum
  bins are not smooth, and no spectrum glitches were seen.
  `ScopeTraceHoldTests` pins the shapes seen on the bench (2026-11-19).

- **Three entry points, one connect rule.** The standalone window
  (`LP700StandaloneApp.bootstrap()`), the in-process plugin
  (`LP700Plugin.activate()`) and the hosted `.appex` (`HostedRootView` in
  `LP700Extension.swift`) each have to start the connection themselves;
  nothing else does. All three go through
  `MeterViewModel.configuredServerURL(_:)`: saved URL → `vm.start`, none →
  open the Connect sheet. The hosted path used to skip this, which left the
  Suite plugin disconnected until the operator pressed Connect every launch.
  The `.appex` keeps its URL in its own sandbox container
  (`org.vu3esv.radiosuite.LP700`), separate from the standalone app's
  domain, so the Suite asks once on its own. `ContentView(hosted: true)`
  stops the sheet offering Quit there (it would terminate the Suite or the
  extension process), and `MeterViewModel.start()` drops a stale attempt
  that a newer start()/stop() superseded while it was waiting on the server.
- **WSClient retries from its own task.** `handleDisconnect()` runs on the
  receive or watchdog task it cancels, so the retry sleep lives on a
  separate `reconnectTask` (cancelled by `stop()` / `reconnectNow()`).
  `.connected` and the backoff reset happen on the first inbound frame, not
  on `resume()`, and a pending retry reports `.reconnecting`, not
  `.disconnected`. The disconnect handler ignores a socket that is no
  longer current, so `stop()` is final and a replaced socket cannot
  schedule a retry. `WSClientReconnectTests` pins all of this; keep it
  green when touching reconnect logic.
- **Proxy login is https-only.** The server may sit behind a Caddy TLS proxy
  (Basic auth, realm `StationMonitor2`; 401 without a valid login, 403 for a
  foreign `Origin`). Every request to the server — the WS upgrade
  (`WSClient.upgradeRequest`), `ConfigClient`, the `/healthz` probe — goes
  through `ProxyAuth.authorize`, which adds `Authorization` only for
  `https`/`wss`; never add a request path that bypasses it, and never set
  `Origin`. The login is the Keychain generic password `ShackProxy`
  (account = username), read by `ProxyLoginStore` in `MeterViewModel.start()`
  (https URLs only) and cached for the process; an attribute-only check runs
  first so no item means no Keychain prompt. A 401 becomes
  `ProxyAuthError.loginRequired` / `.loginRejected` from whether the request
  carried `Authorization`; `WSClient` emits `.authFailed` and waits ≥ 30 s.
  Trust is the system's (Shack CA in the Keychain): no pinning, no custom trust
  code, no ATS exceptions. Tests inject credentials; don't read the real item
  from tests (it raises a macOS prompt).

## Sources / links

- Target server: https://github.com/VU3ESV/LP-700-Server
- Reference Mac client: https://github.com/VU3ESV/LP-100A-App
- Reference server: https://github.com/VU3ESV/LP-100A-Server
- Local clones (during this session):
  - `/Users/vinodes/Projects/LP-700-Server` — target
  - `/Users/vinodes/Projects/LP-100A-App` — reference Mac client
  - `/Users/vinodes/Projects/LP-100A-Server` — reference server
- Hardware reference: Telepost LP-500 / LP-700 Quick Start Guide,
  user manual page references in `internal/lpmeter/snapshot.go`
  comments on the server side.
