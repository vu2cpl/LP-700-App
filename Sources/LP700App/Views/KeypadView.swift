import SwiftUI

// Bottom-row controls: Range step, alarm toggle, LCD mode step, resync.
// The Peak/Avg/Tune trio lives in PowerSWRView itself (matching the
// embedded web client), so this row complements rather than duplicates.
struct KeypadView: View {
    @ObservedObject var vm: MeterViewModel

    var body: some View {
        let disabled = !vm.allowControl || vm.connection != .connected || vm.setupOpen
        // Gating reads the debounced stable* state, so the keypad
        // stays in lock-step with the ControlsCard inside the
        // active view (both read the same source of truth).
        let autoCh = vm.stableAutoChannel

        HStack(spacing: 10) {
            keyButton(title: "Range",
                      systemImage: "arrow.triangle.2.circlepath",
                      subtitle: autoCh ? "Locked (auto-CH)" : vm.stableRange,
                      action: { vm.sendRangeStep() })
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(autoCh)

            keyButton(title: "Alarm",
                      systemImage: alarmIcon,
                      subtitle: autoCh ? "Locked (auto-CH)" : (vm.stableAlarmEnabled ? "Armed" : "Disabled"),
                      action: { vm.sendAlarmToggle() })
                .keyboardShortcut("a", modifiers: [.command])
                .disabled(autoCh)

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
        vm.stableAlarmEnabled ? "bell.fill" : "bell.slash"
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

    private func keyButton(title: String, systemImage: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
