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
                      # universal release .app in dist/
VERSION=$(git describe --tags --always) ./scripts/install-local.sh
                      # build + install to /Applications + strip quarantine
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
│   ├── App.swift                       # @main, scenes, menu commands
│   ├── Net/
│   │   ├── WireProtocol.swift          # Snapshot, ServerFrame, ClientFrame
│   │   ├── WSClient.swift              # actor; reconnect + heartbeat watchdog
│   │   └── ConfigClient.swift          # actor; /api/config + /api/log-level
│   ├── ViewModels/
│   │   └── MeterViewModel.swift        # @MainActor source-of-truth
│   ├── Views/
│   │   ├── ContentView.swift           # toolbar + body composition + bottom CompactPanel (status + keypad)
│   │   ├── PowerSWRView.swift          # PowerSWRCombinedCard (mode-driven big readout + Avg/Pk/Ref + 3 graduated bars) + ControlsCard
│   │   ├── KeypadView.swift            # inline keypad row (Range / Alarm / LCD Mode / Resync)
│   │   ├── ConnectionSheet.swift       # first-launch sheet (Cmd+K)
│   │   ├── PreferencesView.swift       # Settings scene (Cmd+,)
│   │   ├── SetupOverlay.swift          # log-level picker + backend annotation
│   │   └── Panel.swift                 # reusable regularMaterial card (Panel + CompactPanel)
│   └── MenuBar/
│       └── MenuBarContent.swift        # MenuBarExtra label + popover
├── Tests/LP700AppTests/
│   └── WireProtocolTests.swift         # decode/encode round-trips + RangeNames canary
├── Resources/Info.plist                # bundle template (__VERSION__ substituted)
├── scripts/
│   ├── build-app.sh                    # universal release .app, ad-hoc signed
│   ├── make-dmg.sh                     # DMG with /Applications symlink
│   ├── make-icon.sh                    # AppIcon.icns from a 1024×1024 PNG
│   └── install-local.sh                # build + ditto-copy to /Applications
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
- **Range and Alarm are per-channel; firmware ignores them in
  auto-channel mode.** F3 (`range_step`) and F4 (`alarm_toggle`) are
  silently dropped by the LP-500/700 firmware when `auto_channel == true`.
  The server NACKs both verbs in this state with a reason (surfaces in
  `MeterViewModel.statusBanner`); the UI also greys out the Range / Alarm
  cycle buttons inside `PowerSWRView`'s `ControlsCard` (and the duplicate
  Range/Alarm keys in `KeypadView`) when `autoChannel == true`, with a
  caption pointing at CH 1–4. The Channel button stays enabled so the
  user can cycle out. Only `range_step` and `alarm_toggle` are gated —
  `peak_toggle`, `channel_step`, `mode_step` work in any channel state.
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
- **Auto-scale fallback** for the power bars when `range == "auto"`
  (typical CH-Auto case): `autoScale()` picks the smallest standard
  scale (5W..10K) ≥ the highest power in the current snapshot, using
  `peakHoldW` + `powerPeakW` + `powerAvgW` as a max so the scale stays
  stable across a transmission envelope. Mirrors how the meter's
  hardware auto-range chooses scale.
- **Window sizing matches Macexpert SPE** (sibling shack utility):
  `.frame(minWidth: 380, minHeight: 520)` + `.defaultSize(width: 400,
  height: 580)`. `.windowResizability(.contentMinSize)` so the user
  can grow the window past the content floor but never shrink it
  below the readable minimum.

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
