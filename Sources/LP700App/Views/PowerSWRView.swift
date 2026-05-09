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
    var avgValue: ReadingValue
    var peakValue: ReadingValue
    var swrValue: ReadingValue
    var swrTint: Color
    var avgBar: BarConfig
    var peakBar: BarConfig

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

        let scale = fullScaleW(snapshot?.range) ?? autoScale(snapshot)

        return PowerSWRModel(
            avgValue: formatPower(snapshot?.powerAvgW),
            peakValue: formatPower(snapshot?.displayedPeakW),
            swrValue: formatSWR(snapshot?.swr),
            swrTint: swrTintColor(snapshot?.swr ?? 1.0),
            avgBar: powerBar(for: snapshot?.powerAvgW, scale: scale, baseTint: .cyan),
            peakBar: powerBar(for: snapshot?.displayedPeakW, scale: scale, baseTint: .orange),
            controls: ControlsModel(
                channelLabel: channelLabel(snapshot),
                nextChannel: nextChannel(snapshot),
                rangeLabel: snapshot?.range ?? "—",
                peakModeLabel: peakModeLabel(snapshot?.peakMode),
                nextPeakMode: nextPeakMode(snapshot?.peakMode),
                alarmLabel: alarmLabel(snapshot),
                alarmTint: alarmTint(snapshot),
                channelDisabled: baseDisabled,
                rangeDisabled: baseDisabled || autoCh,
                peakDisabled: baseDisabled,
                alarmDisabled: baseDisabled || autoCh,
                rangeNote: autoCh ? perChannelLockNote : nil
            ),
            statusMessage: snapshot?.statusMessage ?? ""
        )
    }
}

// MARK: - Pure helpers

private let perChannelLockNote = "Switch to CH 1–4 to use; auto-channel locks per-channel settings."

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

private func fullScaleW(_ range: String?) -> Double? {
    guard let r = range?.lowercased(), !r.isEmpty, r != "auto" else { return nil }
    switch r {
    case "5w":   return 5
    case "10w":  return 10
    case "25w":  return 25
    case "50w":  return 50
    case "100w": return 100
    case "250w": return 250
    case "500w": return 500
    case "1k":   return 1000
    case "2.5k": return 2500
    case "5k":   return 5000
    case "10k":  return 10000
    default:     return nil
    }
}

// Fallback when range is "auto" or unknown (the typical CH-Auto case):
// pick the smallest standard scale that comfortably contains the highest
// power in the current snapshot. `peakHoldW` is the firmware-maintained
// sticky peak (server fc9bde0+), which gives a stable scale across the
// natural envelope of a transmission and resets cleanly the moment the
// operator clears Peak Hold on the meter — no client-side decay loop
// needed.
private func autoScale(_ snap: Snapshot?) -> Double {
    let peak = max(snap?.powerPeakW ?? 0, snap?.peakHoldW ?? 0, snap?.powerAvgW ?? 0)
    let standards: [Double] = [5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000]
    return standards.first(where: { $0 >= peak }) ?? 10000
}

private func channelLabel(_ s: Snapshot?) -> String {
    guard let s else { return "—" }
    return s.autoChannel ? "A" : "\(s.channel)"
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
            HStack(alignment: .top, spacing: 8) {
                ReadingCard(label: "Average power",
                            value: model.avgValue,
                            tint: .accentColor,
                            bar: model.avgBar)
                    .equatable()
                ReadingCard(label: "Peak power",
                            value: model.peakValue,
                            tint: .accentColor,
                            bar: model.peakBar)
                    .equatable()
            }

            HStack(alignment: .top, spacing: 8) {
                ReadingCard(label: "SWR",
                            value: model.swrValue,
                            tint: model.swrTint)
                    .equatable()
                    .frame(maxHeight: .infinity)
                ControlsCard(model: model.controls,
                             onChannelStep: { vm.sendChannelStep($0) },
                             onRangeStep:   { vm.sendRangeStep() },
                             onPeakStep:    { vm.sendPeakToggle($0) },
                             onAlarmToggle: { vm.sendAlarmToggle() })
                    .frame(maxHeight: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)

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

private struct ReadingCard: View, Equatable {
    var label: String
    var value: ReadingValue
    var tint: Color
    var bar: BarConfig? = nil

    static func == (lhs: ReadingCard, rhs: ReadingCard) -> Bool {
        lhs.label == rhs.label
            && lhs.value == rhs.value
            && lhs.tint == rhs.tint
            && lhs.bar == rhs.bar
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelHeader(title: label)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value.value)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(tint)
                if !value.unit.isEmpty {
                    Text(value.unit)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
            }
            if let bar {
                PowerBar(fraction: bar.fraction, baseTint: bar.baseTint)
                Text("0 / \(formatScale(bar.scale))")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
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

    private func formatScale(_ w: Double) -> String {
        if w >= 1000 { return String(format: "%g kW", w / 1000.0) }
        return String(format: "%g W", w)
    }
}

private struct PowerBar: View {
    var fraction: Double
    var baseTint: Color

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
            }
        }
        .frame(height: 6)
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
