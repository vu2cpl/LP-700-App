import SwiftUI

// SETUP overlay — the equivalent of the dialog in the embedded web client.
// One pane: server log-level picker, plus a backend annotation. Numeric
// alarm thresholds, callsign, coupler, and firmware revision live in the
// meter's NVRAM and aren't transmitted via USB, so they're informational
// only (read-only display in the main meter pane via PowerSWRView /
// statusRow).
struct SetupOverlay: View {
    @ObservedObject var vm: MeterViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section(title: "Server log level") {
                Picker("", selection: levelBinding) {
                    Text("ERROR (default)").tag("error")
                    Text("WARN").tag("warn")
                    Text("INFO").tag("info")
                    Text("DEBUG").tag("debug")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Posted to /api/log-level. Resets on server restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            section(title: "Backend") {
                HStack(spacing: 8) {
                    Image(systemName: backendIcon)
                        .foregroundStyle(backendTint)
                    Text(backendLabel)
                        .font(.body.weight(.medium))
                    Spacer()
                }
                if vm.backend == "simulator" {
                    Text("The server has no real LP-500/700 attached. Telemetry shown here is synthesised — useful for client development or UI smoke tests.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            section(title: "Meter NVRAM (read-only via web/USB)") {
                HStack(alignment: .top, spacing: 24) {
                    field(label: "Callsign",
                          value: vm.snapshot?.callsign.isEmpty == false
                                 ? (vm.snapshot?.callsign ?? "—") : "—")
                    field(label: "Coupler",
                          value: vm.snapshot?.coupler.isEmpty == false
                                 ? (vm.snapshot?.coupler ?? "—") : "—")
                    field(label: "Firmware",
                          value: vm.snapshot?.firmwareRev.isEmpty == false
                                 ? (vm.snapshot?.firmwareRev ?? "—") : "—")
                }
                Text("Numeric alarm thresholds are set on the meter's LCD setup screens and are not transmitted via USB.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var levelBinding: Binding<String> {
        Binding(
            get: { vm.serverLogLevel },
            set: { newValue in
                Task { await vm.setLogLevel(newValue) }
            }
        )
    }

    private var backendIcon: String {
        switch vm.backend {
        case "hid": return "cable.connector.horizontal"
        case "simulator": return "waveform.badge.exclamationmark"
        default: return "questionmark.circle"
        }
    }

    private var backendTint: Color {
        switch vm.backend {
        case "hid": return .green
        case "simulator": return .yellow
        default: return .secondary
        }
    }

    private var backendLabel: String {
        switch vm.backend {
        case "hid": return "HID — meter attached over USB"
        case "simulator": return "Simulator — synthesised data"
        default: return vm.backend.isEmpty ? "Unknown" : vm.backend
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.12 * 11)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    private func field(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.medium))
                .monospacedDigit()
        }
    }
}
