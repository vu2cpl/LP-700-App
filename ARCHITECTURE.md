# Architecture review — LP-700-App

**Date:** 2026-05-09 · **Status:** v0.1.3 (Power/SWR meter mirror with bargraphs; second perf pass — value-typed view subtree + 5 Hz coalescing)

## Changes since v0.1

- **Power/SWR mirror is fully laid out.** `PowerSWRView` ships the
  Avg + Peak readouts with auto-scaled bargraphs (cyan/orange,
  yellow ≥ 80 %, red ≥ 95 %), SWR with severity tint, and a single
  `ControlsCard` that cycles Channel / Range / Peak-mode / Alarm in
  place. The "v0.2 bargraphs" follow-up from the v0.1 risk list
  landed.
- **Peak Power respects `peak_mode`.** `Snapshot.displayedPeakW`
  selects `peak_hold_w` (firmware-maintained held peak, bytes 0–1)
  in Peak Hold mode and `power_peak_w` (live envelope, bytes 23–24)
  otherwise — mirrors the meter's LCD and the embedded web client.
- **Profile-driven CPU pass (v0.1.2 + v0.1.3).** Idle CPU during
  25 Hz simulator telemetry dropped from 30 % to **~11 %** across
  two rounds: v0.1.2 cut the dead 16 fps decay loop, added 10 Hz
  publish + WS-side decode throttle, and made the readout cards
  Equatable; v0.1.3 factored `PowerSWRView`'s subtree onto a
  value-typed `PowerSWRModel`, made the toolbar items Equatable,
  and bumped the publish/decode rate to 5 Hz. Detail in
  [§ 2.1 Telemetry coalescing](#21-telemetry-coalescing-and-render-budgets).
- **Layout-aware screenshot tooling.** `--open-setup` /
  `--open-prefs` launch flags pop the SETUP overlay or Settings
  window for documentation regeneration without needing
  Accessibility permission for `osascript` keystroke.

This document is a focused review of the v0.1.2 implementation of
the LP-700-App macOS client. It covers structure, threading, network
behavior, error paths, and known risks. Read alongside
[README.md](README.md) (install + usage) and
[CLAUDE.md](CLAUDE.md) (orientation for contributors).

The architectural shape borrows directly from sibling
[VU3ESV/LP-100A-App](https://github.com/VU3ESV/LP-100A-App): same wire
envelope (telemetry / heartbeat / status / ack), same reconnect
machinery, same MVVM layering. The interesting differences live at the
top of the stack, where the LP-700's telemetry shape is richer
(channel + auto-channel, range cycle, alarm pill, top-mode read-back)
and the LP-100A's vector-impedance view is absent.

## 1. Layered structure

The app is four layers, top to bottom:

```
┌────────────────────────────────────────────────────────────────┐
│  Scenes / Views (SwiftUI)                                      │
│    ContentView, PowerSWRView, KeypadView, SetupOverlay,        │
│    ConnectionSheet, PreferencesView, MenuBarContent            │
│    — read-only consumers of MeterViewModel                     │
└──────────────────────────────┬─────────────────────────────────┘
                               │ ObservableObject (@Published)
┌──────────────────────────────▼─────────────────────────────────┐
│  ViewModel layer (@MainActor)                                  │
│    MeterViewModel — single source of truth for UI:             │
│      snapshot, connection, allowControl, backend,              │
│      setupOpen, peaks, log-level                               │
│    Owns the alarm-edge detector, sticky-peak decay loop, and   │
│    command issuance (gates on allow_control + connected).      │
└──────────────────────────────┬─────────────────────────────────┘
                               │ async / event stream
┌──────────────────────────────▼─────────────────────────────────┐
│  Network actors                                                │
│    WSClient (actor) — URLSessionWebSocketTask wrapper.         │
│      Reconnect 0.5→10 s backoff. 4 s heartbeat watchdog.       │
│      Yields events on a nonisolated AsyncStream.               │
│    ConfigClient (actor) — REST helpers (/api/config,           │
│      /api/log-level GET/POST).                                 │
└──────────────────────────────┬─────────────────────────────────┘
                               │ JSON over WS / HTTP
┌──────────────────────────────▼─────────────────────────────────┐
│  Wire protocol (Codable structs)                               │
│    Snapshot, ServerFrame, ClientFrame                          │
│    — thin mirror of internal/lpmeter/snapshot.go and           │
│      internal/hub/hub.go                                       │
└────────────────────────────────────────────────────────────────┘
```

**Why this shape.** The server already does the hard part — single-writer
HID, fan-out, snapshot-on-connect. The client's job is mostly: render
telemetry, issue five commands, survive network blips. MVVM with one
view-model fits that surface; anything heavier (Redux store, Combine
graph) would be over-built. We deliberately re-use the LP-100A-App's
WSClient verbatim because the wire envelope is byte-for-byte the same.

## 2. Concurrency model

| Component        | Isolation        | Notes                                                          |
|------------------|------------------|----------------------------------------------------------------|
| `MeterViewModel` | `@MainActor`     | All `@Published` state is main-actor isolated. SwiftUI reads directly. |
| `WSClient`       | `actor`          | Owns the `URLSessionWebSocketTask`, backoff state, watchdog.   |
| `ConfigClient`   | `actor`          | Stateless except for `baseURL`; one `URLSession` shared.       |
| `AsyncStream<Event>` | `nonisolated let` on the actor | Emitted from inside the actor via a single `Continuation`. |

Boundary rules:

- The `ws.events` stream is `nonisolated`, so the view-model's listen
  task can iterate it without `await` on each step. The continuation is
  fed only from inside the actor's `emit(_:)` method — single producer.
- Frames cross from the WS actor to `MeterViewModel` via
  `await self.handle(event:)`, hopping to the main actor exactly once
  per frame.
- Commands flow the other way: `MeterViewModel.send*()` (main actor)
  schedules a `Task { try? await ws?.send(frame) }`. `send` on
  `URLSessionWebSocketTask` is itself thread-safe; the actor wraps it.

### 2.1 Telemetry coalescing and render budgets

The wire pushes telemetry at the meter's poll cadence (~25 Hz on real
hardware, similar on the simulator). A human can't read more than ~5
numbers/second, so we cap UI-driving work at three layers:

1. **WSClient drops telemetry frames inside the throttle window.**
   Each `URLSessionWebSocketTask.Message` is examined as a string
   first; if its body contains the `"power_avg_w"` marker (unique to
   telemetry frames; the server's alphabetical key ordering puts it
   near the start of the bytes) AND `Date().timeIntervalSince(lastTelemetryDecodedAt) < 0.2`,
   the actor returns without invoking `JSONDecoder`. Heartbeat,
   status, and ack frames don't match the marker and always decode.
   Result: ~5× fewer JSON decodes during a sustained TX.

2. **MeterViewModel coalesces `@Published var snapshot` to ≤5 Hz.**
   Inbound telemetry events update a private `pendingSnapshot`; a
   single trailing `publishTask` commits the latest pending value to
   `snapshot` after the 200 ms window. `handleAlarmEdge` runs on
   every inbound frame so notifications stay timely; only the
   SwiftUI mutation path is throttled. `stop()` cancels the publish
   task and clears `pendingSnapshot` on disconnect.

3. **Value-typed view subtree + layered Equatable.** `ContentView`
   builds a `PowerSWRModel` (Equatable struct: pre-formatted strings,
   pre-quantized bar fractions, pre-resolved control labels and
   disabled flags) on each body evaluation, and passes it into
   `PowerSWRView` along with the VM reference (used only for
   command dispatch — not observed). `PowerSWRView` is `Equatable`
   over `model`; inside it, the leaf `ReadingCard`s are also
   `Equatable` and `.equatable()`-wrapped so an unchanged Avg card
   skips body + layout even when Peak or SWR card moved. Toolbar
   items (`ConnectionBadge`, `BackendBadge`) are likewise Equatable
   so the SwiftUI ↔ AppKit `NSToolbarItemViewer` bridge skips its
   `_layoutSubtreeWithOldSize:` work when the connection state and
   backend pill haven't changed.

The bar fraction is quantized to 1 % steps in `powerBar()` so
adjacent samples that round to the same display step also collide
in the Equatable check. The 16 fps client-side decay loop that the
v0.1 LP-100A-App pattern inherited is **gone** — `autoScale` relies
on the firmware-maintained `peak_hold_w` from the snapshot directly,
which gives stable scale across a transmission envelope and resets
cleanly when the operator clears Peak Hold on the meter.

Empirical effect on `top` CPU during a sustained simulator TX
sweep:

| state                                  | CPU    |
|----------------------------------------|-------:|
| v0.1.0 (pre-perf pass)                 | ~30 %  |
| v0.1.2 (decay-loop kill + 10 Hz throttle + leaf Equatable) | ~17 %  |
| v0.1.3 (value-typed subtree + 5 Hz throttle + Equatable toolbar) | ~11 %  |

## 3. Connection lifecycle

```
                       ┌─────────────┐
                       │ disconnected│  (initial / after error)
                       └──────┬──────┘
                              │ start() / setBaseURL()
                       ┌──────▼──────┐
                       │ reconnecting│
                       └──────┬──────┘
                              │ WS handshake OK
                              │ + lastFrameAt = now
                       ┌──────▼──────┐
       heartbeat       │  connected  │  ◄── frames reset lastFrameAt
       watchdog        └──┬──────────┘
       fires (>4 s)      │             ↑
       OR socket close   │             │
                         ▼             │
                  handleDisconnect ────┘ via reconnect with backoff
                  (backoff 0.5→10 s)
```

Specifics worth calling out:

- **Snapshot-on-connect.** Per `internal/hub/hub.go`, the moment the WS
  handshake completes the hub replays its last broadcast frame to the
  new client (`if lastJSON != nil { c.send <- lastJSON }`). The client
  does not need to issue `resync` to seed the view; the UI fills in
  within ~one poll cycle.
- **Heartbeat watchdog** fires from a `Task.sleep(1s)` loop, not a
  high-resolution timer. 4 s timeout is 2× the server's default
  `heartbeat_ms` (2000); matches the embedded web client's behavior.
- **Backoff** is 0.5, 1, 2, 4, 8, 10, 10, 10… seconds. Reset to 0.5 on
  a successful connect.
- **Sleep/wake.** `NSWorkspace.didWakeNotification` triggers a full
  `reconnect(serverURL:)` rather than just an inline `resync`. Slightly
  heavier but empirically more reliable when the lid was closed long
  enough that the OS already invalidated the WS.
- **App became active** triggers `vm.resync()`, which is cheap.

## 4. UI model

- `ContentView` composes the static frame: toolbar (badge / backend
  pill / shield / wrench) + body (banner + active panel + status row +
  keypad). The body switches between `PowerSWRView` and `SetupOverlay`
  based on `vm.setupOpen`.
- `PowerSWRView` is the meter mirror: Avg + Peak power readouts in
  `ReadingCard`s with auto-scaling bargraphs, SWR card with severity
  tint, alarm card, and a single `ControlsCard` that cycles
  Channel / Range / Peak-mode / Alarm in place on each press. The
  optional `status_message` banner appears below the cards when the
  meter has an active alert. `ReadingCard` and `PowerBar` are
  `Equatable` so the layout engine can short-circuit body
  re-evaluation (see [§ 2.1](#21-telemetry-coalescing-and-render-budgets)).
- `KeypadView` is the inline keypad row inside the bottom
  `CompactPanel`: Range step, Alarm toggle, LCD Mode step, Resync.
  Disabled when `!allowControl || connection != .connected || setupOpen`.
  Range and Alarm additionally grey out when `auto_channel == true`
  (the LP-500/700 firmware ignores those soft-button verbs in
  CH-Auto mode; the server NACKs them).
- `SetupOverlay` is rendered into the same panel area when
  `vm.setupOpen` is true, replacing `PowerSWRView`. Same compositional
  choice as the embedded web client (which switches to a `<dialog>`).
- `PreferencesView` is three tabs (Server / Notifications / Display)
  in the standard `Settings` scene.
- `MenuBarLabel` + `MenuBarContent` composes the `MenuBarExtra`. The
  label is a 14-char-ish string with a connection dot and Avg power +
  SWR; clicking opens a popover with the full readout block.

**Visual fidelity.** This v0 deliberately uses native Mac chrome
(regularMaterial panels, system tint, SF Symbols) rather than
replicating the LCD aesthetic. The LP-100A-App went the same direction
in its v0.2 review and we picked up there.

## 5. Wire protocol

The `Snapshot` struct in `Sources/LP700App/Net/WireProtocol.swift` is a
direct mirror of `internal/lpmeter/snapshot.go`:

| Server field        | App field         | Notes                                              |
|---------------------|-------------------|----------------------------------------------------|
| `channel`           | `channel`         | 1..4                                               |
| `auto_channel`      | `autoChannel`     | true ↔ "CH Auto" pill active                       |
| `power_avg_w`       | `powerAvgW`       | live forward power                                  |
| `power_peak_w`      | `powerPeakW`      | live envelope peak (bytes 23-24); decays on key-up |
| `peak_hold_w`       | `peakHoldW`       | firmware-maintained held peak (bytes 0-1; HID + simulator since server fc9bde0). `Snapshot.displayedPeakW` selects this in Peak Hold mode |
| `swr`               | `swr`             | severity tint at 1.5 / 2.0                         |
| `range`             | `range`           | "5W" … "10K" \| "auto"                             |
| `peak_mode`         | `peakMode`        | enum: peakHold / average / tune                    |
| `power_mode`        | `powerMode`       | enum: net / delivered / forward                    |
| `alarm_enabled`     | `alarmEnabled`    |                                                    |
| `alarm_power_w`     | `alarmPowerW`     | unused at v0.1 (server stub)                       |
| `alarm_swr`         | `alarmSWR`        | unused at v0.1                                     |
| `alarm_tripped`     | `alarmTripped`    | drives the alarm pill + notification               |
| `callsign`          | `callsign`        | shown in panel header trailing                     |
| `coupler`           | `coupler`         | LPC501..LPC505                                     |
| `top_mode`          | `topMode`         | LCD page indicator                                 |
| `firmware_rev`      | `firmwareRev`     |                                                    |
| `status_message`    | `statusMessage`   | status banner under the readouts                   |

`ServerFrame` has the four envelopes: `telemetry`, `heartbeat`,
`status`, `ack`. Unknown types decode as `.unknown(type:)` — one
`type` value the server might add in future does not crash the client.

`ClientFrame` is just `command(id, action, value?)` and `resync`.
Action verbs match `sendCmd` in the server's
`internal/web/static/index.html`:

| Action          | Value semantics                              |
|-----------------|----------------------------------------------|
| `peak_toggle`   | 0 = peak_hold, 1 = average, 2 = tune         |
| `range_step`    | next index into `RangeNames.cycle`           |
| `channel_step`  | 0 = auto, 1..4 = explicit                    |
| `alarm_toggle`  | 0 = off, 1 = on                              |
| `mode_step`     | (no value — cycles top-level LCD mode)       |

`RangeNames.cycle` is the canonical order from the server's web client
and is tested against that constant in `WireProtocolTests`. If the
server's order changes, those tests fail loudly.

## 6. State persistence

`UserDefaults` (suite: `com.vu3esv.lp700-app`):

| Key                  | Type   | Default                  |
|----------------------|--------|--------------------------|
| `serverURL`          | String | (empty — opens sheet)    |
| `alarmNotifications` | Bool   | `true`                   |
| `menuBarItemEnabled` | Bool   | `true`                   |

Notably **not** persisted: `setupOpen`, sticky peaks, `serverLogLevel`
(the server itself doesn't persist this between restarts so we don't
either), `backend` (re-fetched on connect).

## 7. Error paths

| Failure                                          | Current behavior                                                            | Risk |
|--------------------------------------------------|------------------------------------------------------------------------------|------|
| Server unreachable on launch                     | `WSClient` enters `reconnecting`; toolbar badge yellow; backoff retries forever | Low — user can open shield to fix URL |
| `/api/config` fetch fails                        | Falls back to `backend = "unknown"`, `allow_control = true`, default title  | Low |
| `/api/log-level` fetch fails                     | Picker shows last-known value (initial `"error"`); POST is fire-and-forget  | Low |
| WS drops mid-session                             | `handleDisconnect` → backoff reconnect; badge yellow then red briefly       | Low |
| Bad JSON frame                                   | `JSONDecoder` throws; emit `parseError`; OSLog warning; no disconnect       | Low |
| Unknown frame `type`                             | `ServerFrame.unknown(type:)`; ignored                                       | Low |
| `ack ok:false`                                   | Status banner shown; auto-dismisses after 5 s                               | Med — banner doesn't tie back to the issuing button |
| Mac sleeps for >2 s                              | Watchdog fires on wake → reconnect; `NSWorkspace.didWakeNotification` triggers reconnect explicitly | Low |
| `command` sent while `allow_control: false`      | View-model gates client-side; server would NACK if we tried, but we don't issue | Low |
| Server restart (log-level resets)                | Picker shows the last value we saw; refreshes when SETUP overlay re-opens  | Med — picker is briefly stale |
| Two `range_step` clicks in fast succession       | Both sent. Server processes serially (single source goroutine). Client UI updates from telemetry, not optimistic | Low — robust by design |
| Telemetry frame arrives <100 ms after last decoded telemetry | WSClient drops the message before JSON decode; no event emitted. Alarm-edge detection is delayed up to 100 ms (acceptable — the meter holds an alarm for at least seconds) | Low |
| `peak_hold_w` not yet decoded by older server (= 0 in wire) | `displayedPeakW` falls back to `power_peak_w`, so Peak Power tracks live envelope in all modes — same UX as before the server's fc9bde0 fix | Low |

## 8. Tests

`swift test` runs the WireProtocol suite in
`Tests/LP700AppTests/WireProtocolTests.swift`:

- Telemetry / heartbeat / status / ack frames decode correctly
- `command` frames encode to the exact expected bytes (with and
  without `value`)
- Unknown frame types degrade gracefully (no throw)
- `RangeNames.cycle` matches the server's
  `internal/web/static/index.html` constant — the canary that catches
  protocol drift
- `Snapshot.displayedPeakW` selects `peak_hold_w` in Peak Hold mode,
  `power_peak_w` in Average / Tune, and falls back when `peak_hold_w`
  is zero

Not yet covered (acceptable gap):

- `WSClient` reconnect/backoff behavior. Hard to test deterministically
  without a fake `URLSessionWebSocketTask`.
- `WSClient` telemetry-window decode skip. Time-dependent; would need
  a clock abstraction. Smoke-tested instead via the
  before/after JSONDecoder sample counts during the perf pass
  (156 → 31 over 5 s).
- UI snapshot tests. Out of scope; visual review against the embedded
  web client and the manual's `docs/screenshots/`.

## 9. Build & ship

- **Universal binary** (arm64 + x86_64) via
  `swift build -c release --arch arm64 --arch x86_64`.
- **App bundle** assembled by `scripts/build-app.sh`: copies the
  binary into `Contents/MacOS/`, expands `Resources/Info.plist`
  template (substitutes `__VERSION__`), generates an `AppIcon.icns`
  from a placeholder PNG, ad-hoc signs (`codesign --sign -`).
- **DMG** built by `scripts/make-dmg.sh`: copies the `.app` plus a
  `/Applications` symlink to a staging dir, runs
  `hdiutil create ... -format UDZO`.
- **Local install** via `scripts/install-local.sh`: builds, then
  ditto-copies into `/Applications` with quarantine xattr stripped.
- **Distribution**: ad-hoc-signed only. Users do
  `xattr -dr com.apple.quarantine` once after install. Notarization
  is a TODO (requires Apple Developer Program enrollment).

CI:

- `.github/workflows/ci.yml` — `swift build` / `swift test` /
  smoke build the `.app` on every push and PR. Runs on `macos-14`.
- `.github/workflows/release.yml` — triggered by pushing a `v*` tag
  *or* by manual `workflow_dispatch` with a version input. Builds the
  DMG, computes the SHA-256, uploads as a workflow artifact, and
  creates a public GitHub Release with auto-generated notes. For
  manual dispatch the workflow also creates the matching `vX.Y.Z`
  tag at the run's commit; pass `prerelease: true` to keep it from
  becoming `latest`.

## 10. Risks & follow-ups

**Open follow-ups:**

1. **Banner UX.** `statusBanner` is global; doesn't pin to the
   offending button. Cheap polish: tint the button red briefly.
2. **No always-on-top window option.** The web client doesn't have one
   either, but it's a common Mac affordance.
3. **No notarization.** Releases are ad-hoc-signed; Gatekeeper
   bypass documented in README. Sign + notarize when Developer ID
   is available.
4. **Mode-cycle drift.** `mode_step` cycles the meter's LCD page; the
   server publishes `top_mode` in subsequent telemetry frames so we
   read back the truth. No client-side optimism needed.
5. **5 Hz numeric tick during fast TX.** The publish throttle caps
   the readout update rate at 5 Hz. For station-monitor use this is
   imperceptible; if a future use-case wants 10 Hz back, raise
   `MeterViewModel.publishInterval` and `WSClient.telemetryMinInterval`
   in lockstep — expect ~2× the residual CPU.

**Closed since v0.1:**

- ~~No bargraphs.~~ Avg + Peak power cards now ship auto-scaled bars
  with severity tinting (yellow ≥ 80 %, red ≥ 95 %).
- ~~Peak Hold doesn't actually hold.~~ `Snapshot.displayedPeakW`
  picks `peak_hold_w` in Peak Hold mode (server fc9bde0 +
  app v0.1.1).
- ~~Decay loop fires 16 fps for fields no view reads.~~ Removed in
  v0.1.2 perf pass.
- ~~Residual ~17 % CPU during sustained TX.~~ Driven down to ~11 %
  in v0.1.3 by factoring `PowerSWRView` onto a value-typed
  `PowerSWRModel`, marking toolbar items Equatable, and matching
  WS-decode + @Published throttle at 5 Hz.

**Not at risk:**

- Wire protocol stability — `Snapshot`'s codable shape is 1:1 with the
  server's `internal/lpmeter/snapshot.go`; covered by tests, including
  the `RangeNames.cycle` canary.
- Reconnect correctness — verified manually by `kill -STOP` /
  `kill -CONT` on a local server, and by physically pulling the LAN.
- Memory growth — no caches, no buffers; `snapshot` is a single struct
  replaced per frame.

## 11. Verdict

The v0.1 implementation is **shippable** for VU3ESV's own use and for
small-scale community testing. It mirrors the LP-100A-App's proven
wire/connection/lifecycle stack, swaps in the LP-700-specific telemetry
shape, and ships with a clean DMG + GitHub Actions release path.

Notarization (M2), bargraphs (M3), and per-server profiles (M4) are
the natural follow-ups.
