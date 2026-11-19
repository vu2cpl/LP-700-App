import SwiftUI

// Compact one-line power readout shown above the scope / spectrum
// renderers. Sample frames carry display-normalised values (0..255),
// not absolute watts, so the operator still wants the live numbers
// from the telemetry channel handy while watching the trace.
//
// It shows what the meter's own LCD shows on that page (LP-500 guide
// v5.4; Manoj, 2026-11-19):
// - Waveform: average and peak power.
// - Spectrum: one "Pwr" reading, the total peak power summed over the
//   frequency bins, and its dBm. The meter sends no average there and
//   the SWR bytes don't hold SWR on that page, so neither is shown.
//   The server decodes that page's power at its own scale (LP-700-Server
//   `spectrumWattsPerStep`).
// No controls, no bars: the ControlsCard and keypad stay in the bottom
// panel on every page.
struct PowerStrip: View {
    enum Page { case waveform, spectrum }

    @ObservedObject var vm: MeterViewModel
    let page: Page

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            switch page {
            case .waveform:
                block(label: "Avg",
                      value: formatPower(vm.snapshot?.powerAvgW),
                      tint: .cyan)
                block(label: "Pk",
                      value: formatPower(vm.snapshot?.displayedPeakW),
                      tint: .orange)
                Spacer(minLength: 0)
            case .spectrum:
                block(label: "Pwr",
                      value: formatPower(vm.snapshot?.powerPeakW),
                      tint: .orange)
                Spacer(minLength: 0)
                block(label: "",
                      value: Self.formatDBm(vm.snapshot?.powerPeakW),
                      tint: .orange)
            }
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

    /// Power in dBm (dB above 1 mW), signed like the meter's "+37 dBm".
    /// The meter drops the decimals; the app keeps one, as it does for
    /// watts. Nothing to show when there is no power.
    static func formatDBm(_ w: Double?) -> (String, String) {
        guard let w, w > 0, !w.isNaN else { return ("—", "dBm") }
        let dBm = 10 * log10(w * 1000)
        return (String(format: "%+.1f", dBm), "dBm")
    }

    @ViewBuilder
    private func block(label: String, value: (String, String), tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
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
