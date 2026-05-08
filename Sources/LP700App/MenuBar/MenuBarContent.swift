import SwiftUI

// Compact glance shown in NSStatusBar: connection dot + Avg power + SWR.
struct MenuBarLabel: View {
    @ObservedObject var vm: MeterViewModel

    var body: some View {
        let dot: String = {
            switch vm.connection {
            case .connected: return "●"
            case .reconnecting: return "◐"
            case .disconnected: return "○"
            }
        }()
        let pwr = vm.snapshot.map { formatPower($0.powerAvgW) } ?? "—"
        let swr = vm.snapshot.map { String(format: "%.2f", $0.swr) } ?? "—"
        Text("\(dot) \(pwr) · \(swr)")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
    }

    private func formatPower(_ w: Double) -> String {
        if w >= 1000 { return String(format: "%.1fkW", w / 1000.0) }
        return String(format: "%.0fW", w)
    }
}

struct MenuBarContent: View {
    @ObservedObject var vm: MeterViewModel
    var onShowMain: () -> Void
    var onConnect: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Avg",   value: power(vm.snapshot?.powerAvgW))
            row("Peak",  value: power(vm.snapshot?.displayedPeakW))
            row("SWR",   value: vm.snapshot.map { String(format: "%.2f", $0.swr) } ?? "—")
            row("Range", value: vm.snapshot?.range ?? "—")
            row("CH",    value: channelLabel)
            row("Mode",  value: peakModeLabel)
            row("Alarm", value: alarmLabel)
            Divider()
            Button("Show LP-700 Window") {
                onShowMain()
            }
            .keyboardShortcut("o", modifiers: [.command])
            Button("Connect to Server…") {
                onConnect()
                onShowMain()
            }
            Divider()
            Button("Quit") { onQuit() }
                .keyboardShortcut("q", modifiers: [.command])
        }
        .padding(8)
        .frame(width: 240)
    }

    private func power(_ w: Double?) -> String {
        guard let w else { return "—" }
        if w >= 1000 { return String(format: "%.2f kW", w / 1000.0) }
        return String(format: "%.1f W", w)
    }

    private var channelLabel: String {
        guard let s = vm.snapshot else { return "—" }
        if s.autoChannel { return "Auto" }
        return "\(s.channel)"
    }

    private var peakModeLabel: String {
        switch vm.snapshot?.peakMode {
        case .peakHold: return "Peak Hold"
        case .average: return "Average"
        case .tune: return "Tune"
        case nil: return "—"
        }
    }

    private var alarmLabel: String {
        guard let s = vm.snapshot else { return "—" }
        if s.alarmTripped { return "Tripped" }
        return s.alarmEnabled ? "Armed" : "Off"
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced))
        }
        .font(.system(size: 12))
    }
}
