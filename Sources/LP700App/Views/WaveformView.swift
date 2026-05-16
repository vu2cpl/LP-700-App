import SwiftUI

// Envelope-scope view, fed by the server's `scope` frame type. Renders
// 320 normalised samples (0..255) as a centred, mirrored bar plot —
// each column is a vertical line spanning [centre − s/2, centre + s/2]
// where s is the column's sample value. Matches the Teensy reference
// at `/Users/manoj/Desktop/TEENSY_SWR12082022_night/f_page1.ino`,
// which is the precursor firmware to the LP-700 LCD.
//
// Samples are display-normalised; the firmware auto-scales each trace
// so its peak fits. For absolute power readings, use the telemetry
// frame's `power_avg_w` / `power_peak_w` (shown below in PowerStrip).
//
// Refresh rate is ~4 Hz while the meter is on the waveform LCD page;
// nothing arrives in other modes. We show a placeholder when the last
// frame is older than ~2 s or the meter isn't on this page.
struct WaveformView: View {
    @ObservedObject var vm: MeterViewModel

    var body: some View {
        // Build the same controls model PowerSWRView uses, so a single
        // factory drives every view's CH / Rng / Mode / Alm state.
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
            // Compact power strip at the top so the operator still sees
            // absolute numbers while a trace is on screen.
            PowerStrip(vm: vm)

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
                    )

                // Hardware constraint: the LP-500/700 firmware doesn't
                // support auto-channel on the Waveform / Spectrum LCD
                // pages. The meter returns IN reports with undefined
                // channel + sample bytes in this state, so the trace
                // we'd render is meaningless and the telemetry slot
                // garbage. Refuse to render the trace and prompt the
                // operator to switch to a manual channel — the CH
                // cycle button is right below.
                if vm.stableAutoChannel {
                    PlaceholderText("Switch to CH 1–4 below. Auto-channel isn't supported on the Waveform LCD page.")
                } else if let scope = vm.lastScope, isFresh(vm.lastScopeAt) {
                    Canvas { ctx, size in
                        drawWaveform(samples: scope.samples, in: size, ctx: ctx)
                    }
                    .padding(10)
                    .drawingGroup()
                } else {
                    PlaceholderText("Waveform — keep meter on the Waveform LCD page (F1)")
                }
            }

            ControlsCard(model: controls,
                         style: .sampleMode,
                         onChannelStep: { vm.sendChannelStep($0) },
                         onRangeStep:   { vm.sendRangeStep() },
                         onPeakStep:    { vm.sendPeakToggle($0) },
                         onAlarmToggle: { vm.sendAlarmToggle() })

            Text("Signal mode (CW/SSB/PSK), waveform subtype, and user presets are on the meter's front panel — server doesn't yet expose those commands.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 4)
        }
    }

    private func isFresh(_ at: Date) -> Bool {
        Date().timeIntervalSince(at) < 2.0
    }

    private func drawWaveform(samples: [UInt8], in size: CGSize, ctx: GraphicsContext) {
        guard !samples.isEmpty else { return }
        let centre = size.height / 2
        let count = CGFloat(samples.count)
        let dx = size.width / count
        let scale = (size.height - 4) / 255.0   // leave 2 px margin top + bottom

        // Centre line — subtle, lets the eye anchor symmetry.
        var centreLine = Path()
        centreLine.move(to: CGPoint(x: 0, y: centre))
        centreLine.addLine(to: CGPoint(x: size.width, y: centre))
        ctx.stroke(centreLine, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)

        // Stroke each column as a thin vertical line centred on the
        // midline, height proportional to the sample.
        var path = Path()
        for (i, s) in samples.enumerated() {
            let x = CGFloat(i) * dx + dx / 2
            let half = CGFloat(s) * scale / 2
            path.move(to: CGPoint(x: x, y: centre - half))
            path.addLine(to: CGPoint(x: x, y: centre + half))
        }
        ctx.stroke(path, with: .color(.cyan), lineWidth: max(1, dx))
    }
}
