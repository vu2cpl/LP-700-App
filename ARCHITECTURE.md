# Architecture review — LP-700-App

**Date:** 2026-05-08 · **Status:** v0.1 (initial scaffold mirroring LP-100A-App)

This document is a focused review of the v0.1 implementation of the
LP-700-App macOS client. It covers structure, threading, network
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
- The decay loop in `MeterViewModel.startDecayLoop()` runs in a detached
  Task, sleeping 60 ms between ticks and hopping to the main actor for
  state mutation.

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
- `PowerSWRView` is the meter mirror — Avg + Peak power readouts, SWR
  with severity tint, channel pills (Auto / 1..4), range cycle button,
  peak-mode trio, alarm pill, and the optional `status_message`
  banner. It's the one place the LP-700's wire shape diverges from
  the LP-100A's.
- `KeypadView` is the bottom-row controls: Range step, Alarm toggle,
  LCD Mode step, Resync. Disabled when `!allowControl ||
  connection != .connected || setupOpen`.
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
| `power_avg_w`       | `powerAvgW`       |                                                    |
| `power_peak_w`      | `powerPeakW`      |                                                    |
| `peak_hold_w`       | `peakHoldW`       | filled by simulator only at v0.1 — see snapshot.go |
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

Not yet covered (acceptable gap for v0.1):

- `WSClient` reconnect/backoff behavior. Hard to test deterministically
  without a fake `URLSessionWebSocketTask`.
- `MeterViewModel` peak decay loop. Time-dependent; could be tested
  with a clock abstraction in v0.2.
- UI snapshot tests. Out of scope; visual review against the embedded
  web client.

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

**Known issues (v0.1 → v0.2):**

1. **No bargraphs yet.** The numeric readouts work but the LP-100A-App
   bargraph + sticky-peak-marker visuals would help during fast TX.
   Plan: port `BargraphView.swift` and adapt `RangeScale` to the
   LP-700's wider range cycle (5W–10kW vs LP-100A's three buckets).
2. **Banner UX.** `statusBanner` is global; doesn't pin to the
   offending button. Cheap polish: tint the button red briefly.
3. **No always-on-top window option.** The web client doesn't have one
   either, but it's a common Mac affordance.
4. **No notarization.** First release is ad-hoc-signed; Gatekeeper
   bypass documented in README. Sign + notarize when Developer ID is
   available.
5. **Mode-cycle drift.** `mode_step` cycles the meter's LCD page; the
   server publishes `top_mode` in subsequent telemetry frames so we
   read back the truth. No client-side optimism needed.

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
