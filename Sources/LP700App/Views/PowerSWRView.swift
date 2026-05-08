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
                            tint: .accentColor)
                ReadingCard(label: "Peak power",
                            value: formatPower(vm.snapshot?.powerPeakW),
                            tint: .accentColor)
            }

            HStack(alignment: .top, spacing: 14) {
                ReadingCard(label: "SWR",
                            value: formatSWR(vm.snapshot?.swr),
                            tint: swrTint(vm.snapshot?.swr ?? 1.0))
                AlarmCard(snapshot: vm.snapshot, disabled: alarmDisabled) {
                    vm.sendAlarmToggle()
                }
            }

            ChannelRow(snapshot: vm.snapshot, disabled: controlsDisabled) { idx in
                vm.sendChannelStep(idx)
            }

            HStack(spacing: 14) {
                RangeCard(range: vm.snapshot?.range, disabled: controlsDisabled) {
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

    private var alarmDisabled: Bool { controlsDisabled }

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
}

// MARK: - Pieces

private struct ReadingCard: View {
    var label: String
    var value: (value: String, unit: String)
    var tint: Color

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
}

private struct AlarmCard: View {
    var snapshot: Snapshot?
    var disabled: Bool
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
            Text("Numeric thresholds are set on the meter LCD and not retrievable via USB.")
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
