import SwiftUI

// Mirrors the LP-500/700 Power/SWR LCD screen. Avg + Peak power readouts
// with scale bars, SWR + alarm, and a single Controls card that cycles
// Channel / Range / Peak-mode in place on each press.
struct PowerSWRView: View {
    @ObservedObject var vm: MeterViewModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                ReadingCard(label: "Average power",
                            value: formatPower(vm.snapshot?.powerAvgW),
                            tint: .accentColor,
                            bar: powerBar(for: vm.snapshot?.powerAvgW, baseTint: .cyan))
                ReadingCard(label: "Peak power",
                            value: formatPower(vm.snapshot?.displayedPeakW),
                            tint: .accentColor,
                            bar: powerBar(for: vm.snapshot?.displayedPeakW, baseTint: .orange))
            }

            HStack(alignment: .top, spacing: 8) {
                ReadingCard(label: "SWR",
                            value: formatSWR(vm.snapshot?.swr),
                            tint: swrTint(vm.snapshot?.swr ?? 1.0))
                    .frame(maxHeight: .infinity)
                ControlsCard(snapshot: vm.snapshot,
                             channelDisabled: controlsDisabled,
                             rangeDisabled: rangeDisabled,
                             peakDisabled: controlsDisabled,
                             alarmDisabled: alarmDisabled,
                             rangeNote: autoChannelLocked ? perChannelLockNote : nil,
                             onChannelStep: { vm.sendChannelStep($0) },
                             onRangeStep:   { vm.sendRangeStep() },
                             onPeakStep:    { vm.sendPeakToggle($0) },
                             onAlarmToggle: { vm.sendAlarmToggle() })
                    .frame(maxHeight: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)

            if let msg = vm.snapshot?.statusMessage, !msg.isEmpty {
                Label(msg, systemImage: "exclamationmark.bubble")
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

    private var controlsDisabled: Bool {
        !vm.allowControl || vm.connection != .connected || vm.setupOpen
    }

    // Range and Alarm are per-channel settings on the LP-500/700; the
    // firmware silently ignores both presses while the meter is in
    // auto-channel mode. Pre-emptively gate the UI so the user sees why
    // before clicking. (Server NACKs the same verbs, but greying out
    // is clearer than a transient toast.)
    private var autoChannelLocked: Bool {
        vm.snapshot?.autoChannel == true
    }

    private var rangeDisabled: Bool { controlsDisabled || autoChannelLocked }
    private var alarmDisabled: Bool { controlsDisabled || autoChannelLocked }

    private let perChannelLockNote = "Switch to CH 1–4 to use; auto-channel locks per-channel settings."

    private func formatPower(_ w: Double?) -> (value: String, unit: String) {
        guard let w, !w.isNaN else { return ("—", "W") }
        if w >= 1000 { return (String(format: "%.2f", w / 1000.0), "kW") }
        if w >= 100  { return (String(format: "%.0f", w), "W") }
        return (String(format: "%.1f", w), "W")
    }

    private func formatSWR(_ s: Double?) -> (value: String, unit: String) {
        guard let s, !s.isNaN else { return ("—", "") }
        return (String(format: "%.2f", s), "")
    }

    private func swrTint(_ swr: Double) -> Color {
        if swr >= 2.0 { return .red }
        if swr >= 1.5 { return .yellow }
        return .green
    }

    private func powerBar(for watts: Double?, baseTint: Color) -> ReadingCard.BarConfig {
        let scale = fullScaleW(vm.snapshot?.range) ?? autoScale(vm.snapshot)
        let w = watts ?? 0
        return ReadingCard.BarConfig(fraction: w / scale, scale: scale, baseTint: baseTint)
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

    // Fallback when range is "auto" or unknown (the typical CH Auto
    // case): pick the smallest standard scale that comfortably contains
    // the highest power seen — same idea as the meter's hardware
    // auto-range. peakHoldW is the firmware-maintained sticky peak,
    // which gives a stable scale across the natural envelope of a
    // transmission rather than flicking with every snapshot.
    private func autoScale(_ snap: Snapshot?) -> Double {
        let peak = max(snap?.powerPeakW ?? 0, snap?.peakHoldW ?? 0, snap?.powerAvgW ?? 0, vm.peakPeak)
        let standards: [Double] = [5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000]
        return standards.first(where: { $0 >= peak }) ?? 10000
    }
}

// MARK: - Pieces

private struct ReadingCard: View {
    var label: String
    var value: (value: String, unit: String)
    var tint: Color
    var bar: BarConfig? = nil

    struct BarConfig {
        var fraction: Double
        var scale: Double
        var baseTint: Color
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
        .animation(.easeOut(duration: 0.15), value: fraction)
    }
}

// One card with four toggle/cycle-on-press buttons in a 2×2 grid:
// Channel, Range, Mode, Alarm. Each button shows the current value
// as its face; tapping advances to the next value (or toggles, for
// Alarm). Range/Alarm grey out when auto-channel locks per-channel
// settings, with a small caption pointing the user at CH 1–4.
private struct ControlsCard: View {
    var snapshot: Snapshot?
    var channelDisabled: Bool
    var rangeDisabled: Bool
    var peakDisabled: Bool
    var alarmDisabled: Bool
    var rangeNote: String?
    var onChannelStep: (Int) -> Void
    var onRangeStep: () -> Void
    var onPeakStep: (Int) -> Void
    var onAlarmToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelHeader(title: "Controls")
            HStack(spacing: 4) {
                cycleButton(title: "CH",
                            value: channelLabel,
                            disabled: channelDisabled) {
                    onChannelStep(nextChannel)
                }
                cycleButton(title: "Rng",
                            value: snapshot?.range ?? "—",
                            disabled: rangeDisabled) {
                    onRangeStep()
                }
                cycleButton(title: "Mode",
                            value: peakModeLabel,
                            disabled: peakDisabled) {
                    onPeakStep(nextPeakMode)
                }
                cycleButton(title: "Alm",
                            value: alarmLabel,
                            disabled: alarmDisabled,
                            valueTint: alarmTint) {
                    onAlarmToggle()
                }
            }
            // Always reserve space for the lock note so the card height
            // doesn't change when the user cycles between CH A and CH 1–4.
            Text(rangeNote ?? " ")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .opacity(rangeNote == nil ? 0 : 1)
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

    private var channelLabel: String {
        guard let s = snapshot else { return "—" }
        return s.autoChannel ? "A" : "\(s.channel)"
    }

    // Cycle order: Auto → 1 → 2 → 3 → 4 → Auto. Server's channel_step
    // verb takes 0 = auto, 1..4 = explicit channel.
    private var nextChannel: Int {
        guard let s = snapshot else { return 1 }
        if s.autoChannel { return 1 }
        return s.channel >= 4 ? 0 : s.channel + 1
    }

    private var peakModeLabel: String {
        switch snapshot?.peakMode {
        case .peakHold: return "Hold"
        case .average:  return "Avg"
        case .tune:     return "Tune"
        case nil:       return "—"
        }
    }

    // Cycle order: Peak Hold (0) → Average (1) → Tune (2) → Peak Hold.
    private var nextPeakMode: Int {
        switch snapshot?.peakMode {
        case .peakHold: return 1
        case .average:  return 2
        case .tune:     return 0
        case nil:       return 1
        }
    }

    private var alarmLabel: String {
        guard let s = snapshot else { return "—" }
        if !s.alarmEnabled { return "Off" }
        if s.alarmTripped  { return "TRIP" }
        return "On"
    }

    private var alarmTint: Color? {
        guard let s = snapshot else { return nil }
        if !s.alarmEnabled { return nil }       // use default secondary
        if s.alarmTripped  { return .red }
        return .green
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
