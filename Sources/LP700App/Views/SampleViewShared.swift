import SwiftUI

// Compact one-line power+SWR readout shown above scope / spectrum
// renderers. Sample frames carry display-normalised values (0..255),
// not absolute watts, so the operator still wants the live numbers
// from the telemetry channel handy while watching the trace.
//
// Avg / Pk / SWR only — no controls, no bars. The ControlsCard and
// keypad stay in the bottom panel (visible regardless of LCD page),
// so all the per-channel verbs remain reachable.
struct PowerStrip: View {
    @ObservedObject var vm: MeterViewModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            block(label: "Avg",
                  value: formatPower(vm.snapshot?.powerAvgW),
                  tint: .cyan)
            block(label: "Pk",
                  value: formatPower(vm.snapshot?.displayedPeakW),
                  tint: .orange)
            Spacer(minLength: 0)
            block(label: "SWR",
                  value: formatSWR(vm.snapshot?.swr),
                  tint: swrTint(vm.snapshot?.swr ?? 1.0))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
    private func block(label: String, value: (String, String), tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value.0)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(tint)
            if !value.1.isEmpty {
                Text(value.1)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatPower(_ w: Double?) -> (String, String) {
        guard let w, !w.isNaN else { return ("—", "W") }
        if w >= 1000 { return (String(format: "%.2f", w / 1000.0), "kW") }
        if w >= 100  { return (String(format: "%.0f", w), "W") }
        return (String(format: "%.1f", w), "W")
    }

    private func formatSWR(_ s: Double?) -> (String, String) {
        guard let s, !s.isNaN else { return ("—", "") }
        return (String(format: "%.2f", s), "")
    }

    private func swrTint(_ swr: Double) -> Color {
        if swr >= 2.0 { return .red }
        if swr >= 1.5 { return .yellow }
        return .green
    }
}

// Centered hint shown inside a scope / spectrum card when no fresh
// frame has arrived (operator is on a different LCD page, simulator
// backend, or the very first frame after switching modes hasn't
// landed yet). Keeps the card slot occupied so the window doesn't
// jump when sample frames start / stop.
struct PlaceholderText: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "waveform")
                .font(.system(size: 28))
                .foregroundStyle(.secondary.opacity(0.5))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
