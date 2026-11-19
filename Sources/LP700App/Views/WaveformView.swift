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
        VStack(spacing: 8) {
            // Compact power strip at the top so the operator still sees
            // absolute numbers while a trace is on screen.
            PowerStrip(vm: vm, page: .waveform)

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
                    )

                // The Waveform and Spectrum pages have their own CH 1–4
                // setting and no Auto (LP-500 user guide v5.4). A server
                // with LP-700-Server PR #9 reports them that way. An
                // older server reads them as CH Auto whenever Power/SWR
                // is in CH Auto, and then holds every trace back, so
                // say that rather than wait forever.
                if vm.snapshot?.autoChannel == true {
                    PlaceholderText("No trace: this LP-700-Server reads the page as CH Auto and holds traces back. Update the server.")
                } else if let scope = vm.lastScope, isFresh(vm.lastScopeAt) {
                    Canvas { ctx, size in
                        drawWaveform(samples: scope.samples, in: size, ctx: ctx)
                    }
                    .padding(10)
                    .drawingGroup()
                } else {
                    PlaceholderText("Waiting for waveform data from the meter")
                }
            }

            Text("V/div, sweep, waveform style and test tone are set on the meter's front panel. The server doesn't report them yet.")
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
