import SwiftUI

// Mirrors the LP-500/700 Power/SWR LCD screen. Avg + Peak power readouts,
// SWR with sticky-peak indicator, channel pills (Auto / 1..4), range
// cycle button, peak-mode segmented selector, and alarm pill.
struct PowerSWRView: View {
    @ObservedObject var vm: MeterViewModel

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ReadingCard(label: "Average power",
                            value: formatPower(vm.snapshot?.powerAvgW),
                            tint: .accentColor,
                            bar: powerBar(for: vm.snapshot?.powerAvgW, baseTint: .cyan))
                ReadingCard(label: "Peak power",
                            value: formatPower(vm.snapshot?.displayedPeakW),
                            tint: .accentColor,
                            bar: powerBar(for: vm.snapshot?.displayedPeakW, baseTint: .orange))
            }

            HStack(alignment: .top, spacing: 14) {
                ReadingCard(label: "SWR",
                            value: formatSWR(vm.snapshot?.swr),
                            tint: swrTint(vm.snapshot?.swr ?? 1.0))
                AlarmCard(snapshot: vm.snapshot,
                          disabled: alarmDisabled,
                          note: autoChannelLocked ? perChannelLockNote : nil) {
                    vm.sendAlarmToggle()
                }
            }

            ChannelRow(snapshot: vm.snapshot, disabled: controlsDisabled) { idx in
                vm.sendChannelStep(idx)
            }

            HStack(spacing: 14) {
                RangeCard(range: vm.snapshot?.range,
                          disabled: rangeDisabled,
                          note: autoChannelLocked ? perChannelLockNote : nil) {
                    vm.sendRangeStep()
                }
                PeakModeCard(snapshot: vm.snapshot, disabled: controlsDisabled) { value in
                    vm.sendPeakToggle(value)
                }
            }

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
        VStack(alignment: .leading, spacing: 8) {
            PanelHeader(title: label)
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(value.value)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
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
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
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
        .frame(height: 8)
        .animation(.easeOut(duration: 0.15), value: fraction)
    }
}

private struct AlarmCard: View {
    var snapshot: Snapshot?
    var disabled: Bool
    var note: String?
    var onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelHeader(title: "Alarm")
            Button(action: onToggle) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .foregroundColor(tint)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(tint.opacity(0.6), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            Text(note ?? "Numeric thresholds are set on the meter LCD and not retrievable via USB.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
    }

    private var icon: String {
        guard let s = snapshot else { return "minus.circle" }
        if !s.alarmEnabled { return "bell.slash" }
        if s.alarmTripped { return "bell.and.waves.left.and.right.fill" }
        return "bell.fill"
    }

    private var label: String {
        guard let s = snapshot else { return "—" }
        if !s.alarmEnabled { return "Disabled" }
        if s.alarmTripped { return "TRIPPED" }
        return "Armed"
    }

    private var tint: Color {
        guard let s = snapshot else { return .secondary }
        if !s.alarmEnabled { return .secondary }
        if s.alarmTripped { return .red }
        return .green
    }
}

private struct ChannelRow: View {
    var snapshot: Snapshot?
    var disabled: Bool
    var onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelHeader(title: "Channel")
            HStack(spacing: 8) {
                pill(label: "CH Auto", index: 0, active: snapshot?.autoChannel == true)
                ForEach(1...4, id: \.self) { i in
                    pill(label: "CH \(i)",
                         index: i,
                         active: (snapshot?.autoChannel == false) && (snapshot?.channel == i))
                }
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
    }

    private func pill(label: String, index: Int, active: Bool) -> some View {
        Button(action: { onSelect(index) }) {
            Text(label)
                .font(.system(size: 13, weight: active ? .bold : .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundColor(active ? .accentColor : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(active ? Color.accentColor : Color.secondary.opacity(0.3),
                                     lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

private struct RangeCard: View {
    var range: String?
    var disabled: Bool
    var note: String?
    var onStep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelHeader(title: "Range")
            Button(action: onStep) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Range: \(range ?? "—")")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(disabled)
            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
    }
}

private struct PeakModeCard: View {
    var snapshot: Snapshot?
    var disabled: Bool
    var onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelHeader(title: "Peak / Avg / Tune")
            HStack(spacing: 8) {
                modeButton(label: "Peak Hold", value: 0, mode: .peakHold)
                modeButton(label: "Average",   value: 1, mode: .average)
                modeButton(label: "Tune",      value: 2, mode: .tune)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
    }

    private func modeButton(label: String, value: Int, mode: PeakMode) -> some View {
        let active = snapshot?.peakMode == mode
        return Button(action: { onSelect(value) }) {
            Text(label)
                .font(.system(size: 13, weight: active ? .bold : .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .foregroundColor(active ? .accentColor : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(active ? Color.accentColor : Color.secondary.opacity(0.3),
                                     lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
