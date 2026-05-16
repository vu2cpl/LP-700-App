# Handover: Scope (Waveform) + Spectrum view exploration — 2026-05-15

> **Status:** archived. Code preserved on branch `feat/scope-spectrum-views` on the `vu2cpl/LP-700-App` fork. Not merged. v0.1.6 (the hardware-style combined Power & SWR card from PR #4) remains the shipping baseline.

## What we tried

Pick up the scope + spectrum sample-frame work after the server-side handover (`HANDOVER-scope-spectrum.md` in LP-700-Server) was completed in **server v0.1.5**. The server is now emitting two new WS frame types (`scope` / `spectrum`) carrying 320-byte normalised sample buffers at ~4 Hz while the meter is on the matching LCD page. The app side needed:

1. Decode the new frames (`ServerFrame.scope`, `ServerFrame.spectrum`).
2. Render `WaveformView` (mirrored centred bar plot, cyan) and `SpectrumView` (vertical bar FFT, green, DC-bin clipped).
3. Switch the active view based on which LCD page the meter is on.
4. Surface the live power + SWR alongside the trace (`PowerStrip`).
5. Make the existing `ControlsCard` reachable from the new views.

All of (1)-(5) were implemented and built clean. Tests added for the new frame decode (`testScopeDecodes` / `testSpectrumDecodes`).

## What worked

- **Frame decoding.** `ScopePayload` / `SpectrumPayload` deserialise correctly; the 320-element `[UInt8]` round-trips via `JSONDecoder` with explicit `CodingKeys` (snake_case → camelCase). Tests added.
- **Renderers.** Both views render using SwiftUI `Canvas` + `.drawingGroup()`. Waveform shows a recognisable AM envelope shape (per the user's screenshot — "looks great visually") when the meter is actually feeding clean data.
- **`PowerStrip`.** Compact Avg / Peak / SWR line above the trace works as intended — operator still sees absolute numbers while watching the scope.
- **Shared `ControlsCard`.** Promoted from `private` to internal, reused from `WaveformView` / `SpectrumView`. Works.
- **The 4-vs-3 mode-cycle alignment.** App's visible cycle is `power_swr → waveform → spectrum → power_swr` (3 modes); meter's hardware cycle includes a `setup` page (4 modes). Send **two** `mode_step` commands when wrapping spectrum → power_swr to skip past meter's setup page. This kept the cycle aligned correctly when the issue was tested.
- **First-frame seed.** First sane telemetry post-connect seeds `activeView` from snapshot `top_mode`, so the app lands on whatever LCD page the meter is showing at startup.

## What didn't work — the core problem

**The server-side data stream is unreliable enough to make a follow-the-meter UI fundamentally fragile.** We hit a cascade of issues, each looking like a UI bug but rooted in the wire data:

### Issue A: stray "telemetry" frames carrying junk values

The server's HID poll cycle is `cmd '0'` (live telemetry) plus `cmd '1'..'5'` (sample buffers, scope/spec). It looks like responses to `cmd '1'..'5'` are sometimes being decoded as telemetry by the server-side `Decode` function and broadcast as `telemetry` WS frames, polluting the @Published `Snapshot`. Symptoms we observed live:

| Symptom | Evidence |
|---|---|
| `SWR 20.52` | Image 1 in chat (SWR is physically capped at 1.00, server clamps; 20.52 means decoded from non-telemetry bytes) |
| `Peak 51.4 W` with `Avg 154 W` | Image 2 — peak < avg is physically impossible |
| Channel byte flipping CH 1 ↔ CH 2 ↔ Auto frame-by-frame | Caused control-card labels to flicker without user input |
| `peak_mode` flapping between hold/avg/tune | Same |
| `top_mode` flapping between power_swr / waveform / spectrum | Caused early view-dispatch logic to bounce |
| Status-message slot containing `?BFILORUY|_bfilorvy|`-class strings | Meter's printable-byte set leaking via sample data through the existing `extractStatusMessage` ASCII filter |

### Issue B: auto-channel × waveform/spectrum is a hardware-invalid combination

User VU2CPL confirmed (from the original LP-700 hardware): in waveform or spectrum LCD pages, **auto-channel doesn't function** — the operator must pick CH 1-4 manually. The meter's IN reports in this state probably have undefined channel/range/sample bytes, which is consistent with the wire garbage in Issue A.

### Issue C: sample frames in modes they shouldn't be in

We saw a Spectrum view rendering even when telemetry reported `top_mode: power_swr` (image 1). That means the server was broadcasting spectrum frames in power_swr mode, contradicting the assembly logic in the handover. Could be a server bug or could be related to Issue A (stale telemetry tagging the broadcast wrongly).

### Issue D: 4 Hz bursty vs continuous

Handover claimed ~4 Hz steady. Our observations suggest sample-frame timing is bursty — clusters of frames followed by short silences — making any naive freshness-window dispatch flicker at boundaries.

## What we tried for each issue

This is the actual sequence of attempts so a future session doesn't repeat the dead ends:

1. **First dispatch attempt** — switch on `snapshot.topMode`. **Flickered** because of Issue A: stray telemetry with the wrong `top_mode` flipped the view every frame.
2. **Freshness-only dispatch** — switch on which sample frame type was most recent. **Flickered at idle** because of Issue D: gaps between bursts exceeded the 1 s threshold; bumped to 2.5 s then 5 s then 30 s, each fixing some flicker but introducing lag.
3. **Combined topMode + freshness gate** — needed BOTH conditions. Still flickered because the topMode disagreement-per-cycle (Issue A) intermittently failed the AND.
4. **Asymmetric hysteresis** (switchInWindow 0.5 s / stayWindow 30 s, computed in VM as a Published `activeView`) — reduced flicker substantially but **still bounced** during long idle gaps with stale-frame leakage.
5. **Purely user-driven `activeView`** (sendModeStep cycles locally, no auto-switch) — **fixed the view flicker** but introduced "displays out of sync" when the user pressed mode_step and the meter didn't follow predictably.
6. **Mode-cycle parity (4-tick vs 3-tick)** — extra `mode_step` on the spectrum → power_swr wrap, plus seeding `activeView` from `top_mode` on first sane frame. **Resolved the cycle mis-alignment**; sync held.
7. **User-driven CH/Range/Mode/Alm** — labels driven by stateful `user*` @Published values, with first-frame seed. **Stopped label flicker** but left the user with permanently-out-of-sync displays if the meter changed state any other way.
8. **Debounced telemetry-driven** (final attempt) — `stable*` @Published values updated only after 2 consecutive matching telemetry frames; user button presses do an optimistic update + reconcile via debouncer. This was the most architecturally sound but **didn't get a real-world bench test** before the user called the session.

## What didn't land in code (deliberately skipped)

- **Renderer accuracy verification.** The user reported "way off" waveform / spectrum displays. Without a clean reference and with Issue A polluting the snapshot, it's unclear whether the renderers themselves are wrong or whether the sample buffers carry garbage. The Teensy reference (`/Users/manoj/Desktop/TEENSY_SWR12082022_night/`) is the model for the correct shape; need a known TX (CW tone into dummy load) for ground-truth comparison.
- **Per-LCD-page control sets.** Discovered the meter's F1-F6 keys re-map per page. Power/SWR has CH/Rng/Mode(peak)/Alm; Waveform has CH/Rng/Mode(signal)/Wfm(subtype)/User1/User2; Spectrum is similar. We trimmed `ControlsCard` to CH+Rng only in waveform/spectrum and added a footnote pointing at the meter's front panel for the missing controls. Full wiring is **scoped in [`HANDOVER-wfm-spec-fkeys.md`](https://github.com/vu2cpl/LP-700-Server/blob/docs/wfm-spec-fkeys-handover/docs/HANDOVER-wfm-spec-fkeys.md)** on the `vu2cpl/LP-700-Server` fork (branch `docs/wfm-spec-fkeys-handover`).

## Code organisation on the archived branch

| Path | What's there |
|---|---|
| `Sources/LP700App/Net/WireProtocol.swift` | `ServerFrame.scope` / `.spectrum` cases + `ScopePayload` / `SpectrumPayload` structs |
| `Sources/LP700App/ViewModels/MeterViewModel.swift` | `activeView` (user-driven enum), `stable*` debounced fields + `debounceField` generic, `isSane(_:)` defensive filter for telemetry, `seedStableState(from:)`, all command verbs do optimistic update + send |
| `Sources/LP700App/Views/WaveformView.swift` | Canvas-based mirrored-bar envelope plot, cyan, `PowerStrip` + `ControlsCard` (sampleMode style) |
| `Sources/LP700App/Views/SpectrumView.swift` | Canvas-based vertical-bar FFT, green, DC-bin clipped, `PowerStrip` + `ControlsCard` |
| `Sources/LP700App/Views/SampleViewShared.swift` | `PowerStrip` (compact Avg/Pk/SWR) and `PlaceholderText` for stale/blocked states |
| `Sources/LP700App/Views/PowerSWRView.swift` | `ControlsCard` promoted to internal + `Style` enum (`.full` / `.sampleMode`); `PowerSWRModel.make` takes stable-state params; `cleanStatusMessage` filter (require space + 3-letter run) |
| `Sources/LP700App/Views/KeypadView.swift` | Reads stable-state for the gating logic + labels |
| `Sources/LP700App/Views/ContentView.swift` | Dispatch on `vm.activeView`, builds `PowerSWRModel.make` with stable-state params |
| `Tests/LP700AppTests/WireProtocolTests.swift` | `testScopeDecodes`, `testSpectrumDecodes` |

## Server-side changes that would unblock this

Listed in priority order. Without these, any client-side attempt to render scope/spectrum is going to flicker, glitch, and look out of sync.

### 1. CRITICAL — don't decode `cmd '1'..'5'` responses as telemetry

The server should ONLY treat `cmd '0'` responses as telemetry frames. Currently it appears to JSON-decode every IN report it gets and tag the ones that look snapshot-shaped as `telemetry`. Bytes at the SWR / power / channel offsets in `cmd '1'..'5'` responses carry sample data, not telemetry values — so they get decoded as nonsense (`SWR 20.52`, `peak < avg`, channel jitter, etc.). Single source of all the Issue A bullets above.

**Fix sketch** in [`internal/lpmeter/owner.go`](LP-700-Server/internal/lpmeter/owner.go): track which OUT command was last sent (already done — `tickN`), and tag the resulting IN report with that. Only run `Decode` (and broadcast as `telemetry`) when the last OUT was `cmd '0'`. For other OUT commands, route the IN report into the sample-buffer assembler instead.

### 2. Gate `scope` / `spectrum` emission on real waveform/spectrum mode

Image 1 in our session showed a Spectrum view rendering with telemetry reporting `top_mode: power_swr`. Server should only emit sample WS frames when its decoded `top_mode` == "waveform" / "spectrum" *and* has been for ≥2 consecutive frames (avoid switching-boundary races).

### 3. Gate sample-frame emission on `channel ∈ {1..4}`

Auto-channel + waveform/spectrum is a hardware-invalid combination. When `auto_channel == true` in the meter's reported state, sample data is indeterminate. Either (a) NACK the operator's mode_step into waveform/spectrum when auto-CH is active, (b) drop sample-frame broadcasts in this state, or (c) flag the buffer as `valid: false` in the JSON payload so the client can render a placeholder.

### 4. Filter the `status_message` slot harder

`extractStatusMessage`'s "≥75 % printable, ≥4 non-zero bytes" filter passed `?BFILORUY|_bfilorvy|` through to clients. Real LP-700 status messages are English phrases; require a space character + a multi-letter word substring. Client also added the same filter (`cleanStatusMessage`), but server is the proper boundary.

### 5. Probe whether sample-frame timing is actually 4 Hz steady

Handover claimed steady ~4 Hz. Our observations suggest bursts. Worth a quick wire dump to confirm — if it really is bursty, document the actual cadence so client-side freshness windows can be sized appropriately. (Or fix the burstiness if it's a server-side queuing issue.)

## What the LP-700-App side will need to do once the server is fixed

The branch as it stands is ~95 % of the work. To resume:

1. Pull the new server build.
2. Verify wire stability — `SWR` stays sane, `channel` doesn't flap, sample frames only flow in matching mode — with a parallel Python WS test (template in this conversation's history; uses `websockets` package).
3. Once wire is stable, decide on the dispatch strategy. With clean telemetry, the **debounced-stable-state** approach in the final commit should work without modification — the debouncer becomes belt-and-braces rather than a workaround. The user-driven `activeView` is the right call regardless of wire quality.
4. Verify the renderers against a known TX (CW tone into dummy load, then SSB voice envelope) to validate or fix the waveform/spectrum visual shape. Compare to Teensy reference in `/Users/manoj/Desktop/TEENSY_SWR12082022_night/` (pages `f_page1.ino`, `g_page2.ino`).
5. Once stable, push as a proper PR to upstream.

## Where to find the archived code

- **Branch**: `feat/scope-spectrum-views` pushed to `vu2cpl/LP-700-App` fork.
- **Server bug report**: see the companion doc `docs/BUGS-server-telemetry-leakage.md` on this same branch (also pushed to the fork).
- **Forward-looking server handovers** that already cover related work:
  - `HANDOVER-scope-spectrum.md` on `docs/scope-spectrum-handover` branch of `vu2cpl/LP-700-Server` (now merged into upstream as v0.1.5).
  - `HANDOVER-wfm-spec-fkeys.md` on `docs/wfm-spec-fkeys-handover` branch of `vu2cpl/LP-700-Server` (not yet merged).
