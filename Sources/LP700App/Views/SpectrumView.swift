import SwiftUI

// FFT spectrum view, fed by the server's `spectrum` frame type. Renders
// 320 normalised bin magnitudes (0..255) as a vertical bar graph from
// the baseline up. Matches the Teensy reference at
// `/Users/manoj/Desktop/TEENSY_SWR12082022_night/g_page2.ino` — same
// auto-scaling shape as the LP-700 firmware does on the values we
// receive.
//
// The first bin (DC / very-low-freq leakage) is often anomalously high
// versus the rest; we clip its visual height to the next-bin max so it
// doesn't squash the rest of the spectrum's dynamic range. The actual
// value is shown numerically in a corner readout for transparency.
//
// Frame rate: ~4 Hz while the meter is on the spectrum LCD page;
// nothing in other modes. Placeholder shown when stale or off-page.
struct SpectrumView: View {
    @ObservedObject var vm: MeterViewModel

    var body: some View {
        let controls = PowerSWRModel.make(
            snapshot: vm.snapshot,
            channel: vm.stableChannel,
            autoChannel: vm.stableAutoChannel,
            peakMode: vm.stablePeakMode,
            alarmEnabled: vm.stableAlarmEnabled,
            range: vm.stableRange,
            allowControl: vm.allowControl,
            connected: vm.connection == .connected,
            setupOpen: vm.setupOpen,
            skipAutoChannel: true
        ).controls

        VStack(spacing: 8) {
            PowerStrip(vm: vm)

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
                    )

                // See the same note in WaveformView: auto-channel isn't
                // supported on the Spectrum LCD page. Refuse to render
                // a trace that's known to be indeterminate — but keep
                // the controls visible so the operator can switch CH
                // without backing out of the page.
                if vm.stableAutoChannel {
                    PlaceholderText("Switch to CH 1–4 below. Auto-channel isn't supported on the Spectrum LCD page.")
                } else if let spec = vm.lastSpectrum, isFresh(vm.lastSpectrumAt) {
                    Canvas { ctx, size in
                        drawSpectrum(bins: spec.bins, in: size, ctx: ctx)
                    }
                    .padding(10)
                    .drawingGroup()
                } else {
                    PlaceholderText("Spectrum — keep meter on the Spectrum LCD page (F1)")
                }
            }

            ControlsCard(model: controls,
                         style: .sampleMode,
                         onChannelStep: { vm.sendChannelStep($0) },
                         onRangeStep:   { vm.sendRangeStep() },
                         onPeakStep:    { vm.sendPeakToggle($0) },
                         onAlarmToggle: { vm.sendAlarmToggle() })

            Text("Signal mode, FFT window, span, and user presets are on the meter's front panel — server doesn't yet expose those commands.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 4)
        }
    }

    private func isFresh(_ at: Date) -> Bool {
        Date().timeIntervalSince(at) < 2.0
    }

    private func drawSpectrum(bins: [UInt8], in size: CGSize, ctx: GraphicsContext) {
        guard !bins.isEmpty else { return }

        // DC bin (index 0) leaks high; clip its visual height to the
        // 99th-percentile of the rest so it doesn't dominate.
        let rest = bins.dropFirst().map { Int($0) }.sorted()
        let p99 = rest.isEmpty ? 255 : rest[min(rest.count - 1, Int(Double(rest.count) * 0.99))]
        let dcClip = UInt8(min(255, p99))

        let baseline = size.height - 2
        let count = CGFloat(bins.count)
        let dx = size.width / count
        let scale = (size.height - 4) / 255.0

        // Faint horizontal grid lines at 25 / 50 / 75 %.
        for f in [0.25, 0.5, 0.75] {
            var line = Path()
            let y = baseline - (size.height - 4) * f
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(line, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
        }

        var path = Path()
        for (i, raw) in bins.enumerated() {
            let v = (i == 0) ? min(raw, dcClip) : raw
            let x = CGFloat(i) * dx + dx / 2
            let h = CGFloat(v) * scale
            path.move(to: CGPoint(x: x, y: baseline))
            path.addLine(to: CGPoint(x: x, y: baseline - h))
        }
        ctx.stroke(path, with: .color(.green), lineWidth: max(1, dx))
    }
}
