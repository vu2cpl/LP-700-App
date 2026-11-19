import SwiftUI

// Bottom-row controls: Range step, alarm toggle, LCD mode step, resync.
// The Peak/Avg/Tune trio lives in PowerSWRView itself (matching the
// embedded web client), so this row complements rather than duplicates.
struct KeypadView: View {
    @ObservedObject var vm: MeterViewModel

    var body: some View {
        let disabled = !vm.allowControl || vm.connection != .connected || vm.setupOpen
        // Range and Alarm are the meter's F3 / F4. They're locked in CH
        // Auto (LP-500 user guide v5.4; bench-tested 2026-10-13), and on
        // the Waveform, Spectrum and Setup pages those keys do other jobs
        // (V/div, sweep, span, adjusting a setting). See PageKeys.
        let keys = vm.keys

        HStack(spacing: 10) {
            keyButton(title: "Range",
                      systemImage: "arrow.triangle.2.circlepath",
                      subtitle: keys.range ? (vm.snapshot?.range ?? "—") : keys.lockedSubtitle,
                      action: { vm.sendRangeStep() })
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!keys.range)

            keyButton(title: "Alarm",
                      systemImage: alarmIcon,
                      subtitle: keys.alarm ? alarmSubtitle : keys.lockedSubtitle,
                      action: { vm.sendAlarmToggle() })
                .keyboardShortcut("a", modifiers: [.command])
                .disabled(!keys.alarm)

            keyButton(title: "LCD Mode",
                      systemImage: "rectangle.3.offgrid",
                      subtitle: lcdModeSubtitle,
                      action: { vm.sendModeStep() })
                .keyboardShortcut("m", modifiers: [.command])

            keyButton(title: "Resync",
                      systemImage: "arrow.clockwise",
                      subtitle: "From server",
                      action: { vm.resync() })
                .keyboardShortcut("y", modifiers: [.command])
        }
        .disabled(disabled)
        .overlay(alignment: .trailing) {
            if !vm.allowControl {
                Label("Read-only", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
            }
        }
    }

    private var alarmIcon: String {
        switch vm.snapshot?.alarmEnabled {
        case true: return "bell.fill"
        case false: return "bell.slash"
        default: return "bell"
        }
    }

    private var alarmSubtitle: String {
        guard let s = vm.snapshot else { return "—" }
        if s.alarmTripped { return "Tripped" }
        return s.alarmEnabled ? "Armed" : "Disabled"
    }

    private var lcdModeSubtitle: String {
        switch vm.snapshot?.topMode {
        case .powerSWR: return "Power / SWR"
        case .waveform: return "Waveform"
        case .spectrum: return "Spectrum"
        case .setup: return "Setup"
        case nil: return "—"
        }
    }

    // Four buttons share the row, so at the default window width each has
    // only about 55 pt for its text. "LCD Mode" (55.3 pt at 11 pt medium)
    // and "Power/SWR only" (71.4 pt at 9 pt) were cut off. The tighter
    // icon and padding give the text about 7 pt more, and both lines
    // shrink to 80 % before they truncate. The button's own size never
    // changes, so the row stays put across pages.
    private func keyButton(title: String, systemImage: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
