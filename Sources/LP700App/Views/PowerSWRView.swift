import SwiftUI

// MARK: - Value-typed model

// Everything `PowerSWRView` needs to render, fully resolved into
// Equatable display values. Built once in `ContentView.body` from the
// view-model and passed in; SwiftUI's `.equatable()` then short-circuits
// the entire `PowerSWRView` subtree (including the bargraph layout pass
// and the ControlsCard) when the model is unchanged frame-over-frame.
//
// The raw `Snapshot` is deliberately *not* part of this struct — including
// it would invalidate the model on every wire-level field change, even
// when none of the displayed strings or quantized values moved. Instead,
// every input the cards consume is pre-computed (rounded, formatted,
// quantized, enum-mapped) at construction time.
struct PowerSWRModel: Equatable {
    // Hardware-style single card: one big power number on the left
    // (chosen by peak_mode), one big SWR on the right, small Avg/Pk
    // indicators underneath, three bargraphs (Avg, Pk, SWR) below.
    var cardLabel: String                // "Average" / "Peak" / "Tune"
    var bigPowerValue: ReadingValue
    var bigPowerTint: Color              // mode-driven (orange/cyan/green)
    var avgValue: ReadingValue
    var peakValue: ReadingValue
    var refValue: ReadingValue           // derived from SWR + power + power_mode
    var swrValue: ReadingValue
    var swrTint: Color                   // green / yellow / red by severity

    var avgBar: BarConfig                // cyan
    var peakBar: BarConfig               // orange
    var swrBar: BarConfig                // severity-tinted
    var scaleLabel: String               // power axis label, e.g. "0 / 5 W"

    var controls: ControlsModel
    var statusMessage: String
}

struct ControlsModel: Equatable {
    var channelLabel: String
    var nextChannel: Int
    var rangeLabel: String
    var peakModeLabel: String
    var nextPeakMode: Int
    var alarmLabel: String
    var alarmTint: Color?
    var channelDisabled: Bool
    var rangeDisabled: Bool
    var peakDisabled: Bool
    var alarmDisabled: Bool
    var rangeNote: String?
}

struct ReadingValue: Equatable {
    var value: String
    var unit: String
}

struct BarConfig: Equatable {
    var fraction: Double
    var scale: Double
    var baseTint: Color
}

extension PowerSWRModel {
    /// Builds a model from a snapshot + context flags. Pure function;
    /// safe to call on every `ContentView.body` evaluation.
    static func make(snapshot: Snapshot?,
                     allowControl: Bool,
                     connected: Bool,
                     setupOpen: Bool) -> PowerSWRModel {
        let baseDisabled = !allowControl || !connected || setupOpen
        let autoCh = snapshot?.autoChannel == true

        // Always auto-scale the bargraph for the visual display, even
        // when the meter has a manual range set. The meter's range
        // setting still matters on the hardware (alarms are indexed
        // to it, the meter's LCD bargraph uses it) but is irrelevant
        // for the App's display — a 2 W signal on a 500 W manual
        // range would otherwise show as a 0.4 % sliver, which is
        // illegible. The range label still shows the meter's actual
        // setting; the bar's full-scale is computed from live power.
        let scale = autoScale(snapshot)
        let active = activePower(snapshot)
        let swr = snapshot?.swr ?? 1.0
        let swrTint = swrTintColor(swr)

        return PowerSWRModel(
            cardLabel: active.label,
            bigPowerValue: formatPower(active.watts),
            bigPowerTint: active.tint,
            avgValue: formatPower(snapshot?.powerAvgW),
            peakValue: formatPower(snapshot?.displayedPeakW),
            refValue: formatPower(reflectedPower(swr: swr,
                                                 displayed: snapshot?.powerAvgW,
                                                 mode: snapshot?.powerMode)),
            swrValue: formatSWR(snapshot?.swr),
            swrTint: swrTint,
            avgBar: powerBar(for: snapshot?.powerAvgW, scale: scale, baseTint: .cyan),
            peakBar: powerBar(for: snapshot?.displayedPeakW, scale: scale, baseTint: .orange),
            swrBar: makeSwrBar(swr, tint: swrTint),
            scaleLabel: formatScaleLabel(scale),
            controls: ControlsModel(
                channelLabel: channelLabel(snapshot),
                nextChannel: nextChannel(snapshot),
                rangeLabel: snapshot?.range ?? "—",
                peakModeLabel: peakModeLabel(snapshot?.peakMode),
                nextPeakMode: nextPeakMode(snapshot?.peakMode),
                alarmLabel: alarmLabel(snapshot),
                alarmTint: alarmTint(snapshot),
                channelDisabled: baseDisabled,
                // Range is per-channel on the meter, but F3 / range_step
                // is accepted by the firmware in pwr/swr mode regardless
                // of auto-channel state — pressing it cycles the
                // currently auto-locked channel's range. (Earlier this
                // was gated with `|| autoCh` based on a misread of an
                // empirical probe; corrected 2026-05-16 against the
                // bench LP-700.)
                rangeDisabled: baseDisabled,
                peakDisabled: baseDisabled,
                alarmDisabled: baseDisabled || autoCh,
                rangeNote: nil
            ),
            statusMessage: snapshot?.statusMessage ?? ""
        )
    }
}

// MARK: - Pure helpers

private func formatScaleLabel(_ w: Double) -> String {
    if w >= 1000 { return String(format: "0 / %g kW", w / 1000.0) }
    return String(format: "0 / %g W", w)
}

// The single big power number on the card. Underlying field + tint +
// header label are driven by the meter's peak_mode so the operator can
// tell at a glance which value they're looking at.
private func activePower(_ snap: Snapshot?) -> (watts: Double?, tint: Color, label: String) {
    switch snap?.peakMode {
    case .peakHold: return (snap?.displayedPeakW, .orange, "Peak")
    case .average:  return (snap?.powerAvgW,      .cyan,   "Average")
    case .tune:     return (snap?.powerAvgW,      .green,  "Tune")
    case nil:       return (snap?.powerAvgW,      .accentColor, "Power")
    }
}

// Derives reflected power (Pr) from the displayed forward/net/delivered
// power and the live SWR. Formula:
//
//   ρ = (SWR − 1) / (SWR + 1)      // reflection-coefficient magnitude
//   Pr / Pfwd = ρ²
//
// In `forward` mode the displayed number is Pfwd directly. In `net` /
// `delivered` modes the meter is showing (Pfwd − Pr), so
// Pr = displayed · ρ² / (1 − ρ²). Returns nil when the math is
// degenerate (SWR < 1, no TX, or matched load at the resolution limit)
// so the UI shows "— W" instead of a misleading 0.
private func reflectedPower(swr: Double, displayed: Double?, mode: PowerMode?) -> Double? {
    guard let displayed, displayed > 0, swr >= 1.0 else { return nil }
    let rho = (swr - 1.0) / (swr + 1.0)
    let rhoSq = rho * rho
    switch mode ?? .net {
    case .forward:
        return displayed * rhoSq
    case .net, .delivered:
        guard rhoSq < 0.999 else { return nil }   // pathological full reflection
        return displayed * rhoSq / (1.0 - rhoSq)
    }
}

// Map SWR (1.0–3.0+) onto a 0–100% bar fill with the same severity
// tints used for the numeric readout: green ≤1.5, yellow ≤2.0, red ≥2.0.
// Anything above 3:1 clips to full-scale (already in the red zone).
private func makeSwrBar(_ swr: Double, tint: Color) -> BarConfig {
    let raw = max(0, min(1, (swr - 1.0) / 2.0))
    let quantized = (raw * 100).rounded() / 100
    return BarConfig(fraction: quantized, scale: 3.0, baseTint: tint)
}

private func formatPower(_ w: Double?) -> ReadingValue {
    guard let w, !w.isNaN else { return .init(value: "—", unit: "W") }
    if w >= 1000 { return .init(value: String(format: "%.2f", w / 1000.0), unit: "kW") }
    if w >= 100  { return .init(value: String(format: "%.0f", w), unit: "W") }
    return .init(value: String(format: "%.1f", w), unit: "W")
}

private func formatSWR(_ s: Double?) -> ReadingValue {
    guard let s, !s.isNaN else { return .init(value: "—", unit: "") }
    return .init(value: String(format: "%.2f", s), unit: "")
}

private func swrTintColor(_ swr: Double) -> Color {
    if swr >= 2.0 { return .red }
    if swr >= 1.5 { return .yellow }
    return .green
}

// Quantize the bar fraction to 1 % steps. The eye can't resolve finer
// movement on a 6-pt bar, and step-quantising is what makes the
// surrounding `Equatable` model skip body re-eval when adjacent samples
// land in the same step.
private func powerBar(for watts: Double?, scale: Double, baseTint: Color) -> BarConfig {
    let w = watts ?? 0
    let raw = w / scale
    let quantized = (raw * 100).rounded() / 100
    return BarConfig(fraction: quantized, scale: scale, baseTint: baseTint)
}

// Bargraph full-scale: pick the smallest standard scale that
// comfortably contains the highest power in the current snapshot.
// `peakHoldW` is the firmware-maintained sticky peak (server
// fc9bde0+), which gives a stable scale across the natural envelope
// of a transmission and resets cleanly the moment the
// operator clears Peak Hold on the meter — no client-side decay loop
// needed.
private func autoScale(_ snap: Snapshot?) -> Double {
    let peak = max(snap?.powerPeakW ?? 0, snap?.peakHoldW ?? 0, snap?.powerAvgW ?? 0)
    // 1-2-5 progression below 10W (QRP regime), then matches the
    // LP-700's hardware range ladder (10, 25, 50, 100, 250, 500, 1K,
    // 2.5K, 5K, 10K) above so the App display steps align with the
    // meter's physical range labels.
    let standards: [Double] = [1, 2, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000]
    return standards.first(where: { $0 >= peak }) ?? 10000
}

private func channelLabel(_ s: Snapshot?) -> String {
    guard let s else { return "—" }
    // In CH Auto, also surface the channel the meter is currently
    // decoding so the operator can tell which per-channel settings are
    // active (matches the hardware LCD's "Auto Ch=1" indicator).
    return s.autoChannel ? "A → \(s.channel)" : "\(s.channel)"
}

// Cycle order: Auto → 1 → 2 → 3 → 4 → Auto. Server's `channel_step`
// verb takes 0 = auto, 1..4 = explicit channel.
private func nextChannel(_ s: Snapshot?) -> Int {
    guard let s else { return 1 }
    if s.autoChannel { return 1 }
    return s.channel >= 4 ? 0 : s.channel + 1
}

private func peakModeLabel(_ m: PeakMode?) -> String {
    switch m {
    case .peakHold: return "Hold"
    case .average:  return "Avg"
    case .tune:     return "Tune"
    case nil:       return "—"
    }
}

// Cycle order: Peak Hold (0) → Average (1) → Tune (2) → Peak Hold.
private func nextPeakMode(_ m: PeakMode?) -> Int {
    switch m {
    case .peakHold: return 1
    case .average:  return 2
    case .tune:     return 0
    case nil:       return 1
    }
}

private func alarmLabel(_ s: Snapshot?) -> String {
    guard let s else { return "—" }
    if !s.alarmEnabled { return "Off" }
    if s.alarmTripped  { return "TRIP" }
    return "On"
}

private func alarmTint(_ s: Snapshot?) -> Color? {
    guard let s else { return nil }
    if !s.alarmEnabled { return nil }
    if s.alarmTripped  { return .red }
    return .green
}

// MARK: - View

// Mirrors the LP-500/700 Power/SWR LCD screen. Avg + Peak power readouts
// with scale bars, SWR + alarm, and a single Controls card that cycles
// Channel / Range / Peak-mode / Alarm in place on each press.
//
// The view is `Equatable` over its `model`; the `vm` reference is stable
// for the lifetime of the window so we treat it as equal regardless. This
// lets SwiftUI's `.equatable()` short-circuit the entire subtree (cards
// + bargraphs + ControlsCard) on every parent re-render where displayed
// values are unchanged — extremely common after `formatPower` rounds
// adjacent samples to the same string and the bar fraction quantizes
// into the same 1 % step.
struct PowerSWRView: View, Equatable {
    let model: PowerSWRModel
    // Held by reference; not @ObservedObject (we don't need observation
    // here — ContentView already observes and rebuilds `model` for us).
    // Used only to dispatch control verbs from button taps.
    let vm: MeterViewModel

    static func == (lhs: PowerSWRView, rhs: PowerSWRView) -> Bool {
        lhs.model == rhs.model && lhs.vm === rhs.vm
    }

    var body: some View {
        VStack(spacing: 8) {
            PowerSWRCombinedCard(big: model.bigPowerValue,
                                 bigTint: model.bigPowerTint,
                                 avg: model.avgValue,
                                 peak: model.peakValue,
                                 ref: model.refValue,
                                 swr: model.swrValue,
                                 swrTint: model.swrTint,
                                 avgBar: model.avgBar,
                                 peakBar: model.peakBar,
                                 swrBar: model.swrBar,
                                 scaleLabel: model.scaleLabel,
                                 label: model.cardLabel)
                .equatable()

            ControlsCard(model: model.controls,
                         onChannelStep: { vm.sendChannelStep($0) },
                         onRangeStep:   { vm.sendRangeStep() },
                         onPeakStep:    { vm.sendPeakToggle($0) },
                         onAlarmToggle: { vm.sendAlarmToggle() })

            if !model.statusMessage.isEmpty {
                Label(model.statusMessage, systemImage: "exclamationmark.bubble")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.orange.opacity(0.08))
                    )
            }
        }
    }
}

// MARK: - Pieces

// Hardware-style combined card: ONE big power number (mode-driven) and
// ONE big SWR side-by-side at the top, small Avg / Pk numeric labels
// just under the power number, then three stacked bargraphs (Avg, Pk,
// SWR) spanning the full width of the card. Mirrors the LP-700 LCD's
// main display — at-a-glance reading from across the shack.
private struct PowerSWRCombinedCard: View, Equatable {
    var big: ReadingValue
    var bigTint: Color
    var avg: ReadingValue
    var peak: ReadingValue
    var ref: ReadingValue
    var swr: ReadingValue
    var swrTint: Color
    var avgBar: BarConfig
    var peakBar: BarConfig
    var swrBar: BarConfig
    var scaleLabel: String

    var label: String     // "Average" / "Peak" / "Tune"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelHeader(title: label)

            // Big numbers row: mode-power on the left, SWR on the right.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(big.value)
                        .font(.system(size: 72, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(bigTint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if !big.unit.isEmpty {
                        Text(big.unit)
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Text(swr.value)
                    .font(.system(size: 72, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(swrTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            // Small Avg / Pk under the big power, Ref under the big SWR.
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                smallInline(label: "Avg", value: avg, tint: .cyan)
                smallInline(label: "Pk",  value: peak, tint: .orange)
                Spacer(minLength: 0)
                smallInline(label: "Ref", value: ref, tint: .secondary)
            }

            // Three stacked bargraphs (Avg, Pk, SWR). Power bars share a
            // scale (full = current range), SWR bar uses 1.0–3.0 with
            // ticks at the 1.5 and 2.0 severity thresholds.
            VStack(alignment: .leading, spacing: 6) {
                barRow(label: "Avg", bar: avgBar, ticks: [0.25, 0.5, 0.75])
                barRow(label: "Pk",  bar: peakBar, ticks: [0.25, 0.5, 0.75])
                Text(scaleLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                barRow(label: "SWR", bar: swrBar, ticks: [0.25, 0.5])
                Text("1.0 · 1.5 · 2.0 · 3.0")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func smallInline(label: String, value: ReadingValue, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value.value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(tint)
            if !value.unit.isEmpty {
                Text(value.unit)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func barRow(label: String, bar: BarConfig, ticks: [Double]) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            PowerBar(fraction: bar.fraction, baseTint: bar.baseTint, ticks: ticks)
        }
    }
}

private struct PowerBar: View {
    var fraction: Double
    var baseTint: Color
    /// Tick positions along the bar in 0…1, drawn as short hairline
    /// notches over the fill. Default = quartile ticks for power bars;
    /// SWR bars override with [0.25, 0.5] (the 1.5 / 2.0 SWR thresholds
    /// on a 1.0–3.0 scale).
    var ticks: [Double] = [0.25, 0.5, 0.75]

    var body: some View {
        let f = max(0, min(1, fraction))
        let color: Color = {
            if fraction >= 0.95 { return .red }
            if fraction >= 0.80 { return .yellow }
            return baseTint
        }()
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(2, geo.size.width * f))
                ForEach(ticks, id: \.self) { t in
                    Rectangle()
                        .fill(Color.black.opacity(0.35))
                        .frame(width: 1)
                        .offset(x: geo.size.width * t)
                }
            }
        }
        .frame(height: 18)
    }
}

// One card with four cycle-on-press buttons in a row: Channel, Range,
// Peak-mode, Alarm. Each button shows the current value as its face;
// tapping advances to the next value (or toggles, for Alarm).
// Range / Alarm grey out when auto-channel locks per-channel settings,
// with a small caption pointing the user at CH 1–4.
//
// Reads only Equatable values from the model; closures are constructed
// fresh by the parent on each re-render but only invoked on user input,
// so their non-Equatability doesn't cost render work.
private struct ControlsCard: View {
    var model: ControlsModel
    var onChannelStep: (Int) -> Void
    var onRangeStep: () -> Void
    var onPeakStep: (Int) -> Void
    var onAlarmToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelHeader(title: "Controls")
            HStack(spacing: 4) {
                cycleButton(title: "CH",
                            value: model.channelLabel,
                            disabled: model.channelDisabled) {
                    onChannelStep(model.nextChannel)
                }
                cycleButton(title: "Rng",
                            value: model.rangeLabel,
                            disabled: model.rangeDisabled) {
                    onRangeStep()
                }
                cycleButton(title: "Mode",
                            value: model.peakModeLabel,
                            disabled: model.peakDisabled) {
                    onPeakStep(model.nextPeakMode)
                }
                cycleButton(title: "Alm",
                            value: model.alarmLabel,
                            disabled: model.alarmDisabled,
                            valueTint: model.alarmTint) {
                    onAlarmToggle()
                }
            }
            // Always reserve space for the lock note so the card height
            // doesn't change when the user cycles between CH A and CH 1–4.
            Text(model.rangeNote ?? " ")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .opacity(model.rangeNote == nil ? 0 : 1)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
    }

    private func cycleButton(title: String, value: String, disabled: Bool, valueTint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(disabled ? .secondary : (valueTint ?? .accentColor))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
