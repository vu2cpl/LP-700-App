# Server-side bug report: stray non-telemetry HID responses being decoded as telemetry frames

> **Filed by:** LP-700-App side, 2026-05-15
> **Target:** [vu2cpl/LP-700-Server](https://github.com/vu2cpl/LP-700-Server) (and upstream VU3ESV/LP-700-Server)
> **Symptom severity:** High — makes any follow-the-meter UI fragile. Visible to the user as flicker, junk readings, garbage status messages.

## Symptom

When the server is running with sample-frame emission enabled (server v0.1.5+, the work landed via `HANDOVER-scope-spectrum.md`), clients see telemetry frames with **physically impossible values**, mixed in with valid ones, in the WS broadcast stream. The bad values aren't random noise — they're the *real* HID payloads of responses to `cmd '1'..'5'` (sample-buffer requests) being mis-decoded as if they were responses to `cmd '0'` (live telemetry).

## Concrete evidence (live, Mac client + bench LP-700)

| What the client saw | What it should be | Likely cause |
|---|---|---|
| `swr: 20.52` | Real SWR was ~1.1 at the moment | Sample byte at the SWR offset, mis-decoded as fixed-point /100 |
| `power_avg_w: 154`, `power_peak_w: 51.4` in the same frame | Peak ≥ Avg by definition | Sample bytes at avg / peak offsets, unrelated to each other |
| `channel` field flipping 1 ↔ 2 ↔ auto across consecutive snapshots | Should be stable at the operator's selection | Sample byte at channel offset; some happen to land in `1..4` range and get decoded as a channel byte |
| `peak_mode` flapping `hold` / `average` / `tune` frame-by-frame | Stable | Same — byte 7 in sample responses isn't the alarm-enable byte |
| `top_mode` flapping `power_swr` / `waveform` / `spectrum` | Stable | Same — byte 3 in sample responses isn't `top_mode` |
| `status_message: "?BFILORUY|_bfilorvy|"` (and similar punctuation-heavy strings) | `""` or a real English phrase | Bytes 40..63 in sample responses carry sample data; `extractStatusMessage`'s "≥75 % printable" filter passes through alphabetised-charset-leak sample data that happens to be in the printable ASCII range |

## Diagnosis (from the client side)

Server-side `Decode` looks like it currently treats every IN report as potentially a telemetry frame, applying only the echo-byte filter (decode.go lines 127-138). When the OUT command was `cmd '0'`, decoding the response yields a real `Snapshot`. When the OUT command was `cmd '1'..'5'`, the IN response is a sample-buffer payload — but the decoder still pulls bytes at the snapshot offsets and returns a "valid" snapshot full of garbage.

The hub then broadcasts each "valid" snapshot as a `telemetry` frame, and the client gets a torrent of mixed real + garbage telemetry.

## Recommended fix

Track which `cmd` was most recently sent on the OUT side (the polling loop already does this — `tickN` in [`owner.go`](LP-700-Server/internal/lpmeter/owner.go) selects between PollReport / StatusReport / sample-buffer cmds). Tag the IN report's expected type accordingly:

```go
type cmdKind int
const (
    cmdTelemetry cmdKind = iota   // cmd '0' → snapshot
    cmdStatus                      // cmd '6' → status text
    cmdScopeSample                 // cmd '1','2'
    cmdSpecSample                  // cmd '3','4','5'
)

// In the poll loop, send the OUT command and record what we asked for:
lastCmd = cmdTelemetry
writeReport(dev, PollReport())

// When the IN report comes back, dispatch based on lastCmd:
switch lastCmd {
case cmdTelemetry:
    snap, err := Decode(frame)
    // ... broadcast as 'telemetry'
case cmdStatus:
    msg := extractStatusMessage(frame[40:])
    // ... merge into next telemetry snapshot
case cmdScopeSample, cmdSpecSample:
    sampleAssembler.feed(frame[40:64], lastCmd)
    // assembler emits scope/spec WS frames when buffer is full
}
```

This eliminates the entire class of "mis-decoded as telemetry" bugs at the source.

## Secondary fixes

These can land alongside or after the primary fix; each addresses a remaining client-visible symptom:

### A. Gate scope/spec frame emission on `top_mode` AND `channel ∈ {1..4}`

Image 1 in the client session showed Spectrum view rendering while telemetry reported `top_mode: power_swr`. Server should only emit `scope` / `spectrum` WS frames when:

1. Decoded `top_mode == "waveform"` (for `scope`) or `"spectrum"` (for `spectrum`)
2. Decoded `auto_channel == false` AND `channel ∈ {1..4}`

Auto-channel + waveform/spectrum is a documented hardware-invalid state (the LP-500/700 firmware doesn't support auto-channel on those LCD pages); sample buffers in that state are indeterminate. Either drop the emission, or include a `valid: false` flag in the JSON payload.

### B. Add a per-frame sequence number for debugging

Each frame already has `seq`. Useful if it's monotonic per frame type (separate counters for `telemetry`, `scope`, `spectrum`) so clients can detect drops vs. server-side gaps.

### C. Tighten `extractStatusMessage`

Current filter passes `?BFILORUY|_bfilorvy|` and other punctuation-heavy alphabetised char-set leaks. Real LP-700 status messages are English phrases ("Reduce power or lower range", "TX Match req'd"). Require both:

- At least one ASCII space character, AND
- At least one 3-letter ASCII letter run

This filter is also implemented client-side as `cleanStatusMessage` in the WIP branch (`PowerSWRView.swift`), but the server is the proper boundary — drop garbage at the source.

### D. Confirm sample-frame cadence

Handover claimed steady ~4 Hz emission while in matching mode. Client observation suggests bursty timing (clusters then gaps). Quick wire trace to confirm; if bursty, either document the actual cadence so client freshness windows can be sized appropriately, or smooth at the assembler.

## Verification path

After landing the primary fix (commands-tagged decoding):

1. Run a parallel Python WS client (template in the previous handover) for ~30 s with the meter in each LCD mode (power_swr, waveform, spectrum).
2. Assert:
   - `swr` ∈ [1.0, 5.0] on every telemetry frame
   - `power_peak_w >= power_avg_w` on every telemetry frame
   - `channel` doesn't change without a `channel_step` command being sent
   - `peak_mode` doesn't change without a `peak_toggle` command being sent
   - `top_mode` doesn't change without a `mode_step` command being sent
   - `status_message` is either `""` or a recognisable English phrase
3. Once the wire is clean, the LP-700-App branch (`feat/scope-spectrum-views`) can be revived and tested without the layers of defensive client-side filtering it currently carries. See `HANDOVER-scope-spectrum-attempt-2026-05-15.md` on that branch for the resume guide.

## Why the client side can't fully fix this

The Mac app added `isSane(_:)` to drop telemetry frames with impossible values, and `cleanStatusMessage(_:)` to drop garbage status banners. Those help but don't fix the underlying problem:

- Many mis-decoded frames pass `isSane` (the garbage bytes happen to fall in plausible ranges).
- Channel/peakMode/topMode jitter requires consecutive-frame debouncing to suppress — adds latency to legitimate user actions.
- Sample-frame dispatch needs the wire to be trustworthy or it bounces between views.

The right fix is **at the source** — the server's HID decode path needs to know which OUT cmd it's responding to. Once that's done, all the client-side defensive layers can come back out.
