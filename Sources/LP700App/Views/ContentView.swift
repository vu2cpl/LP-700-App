import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var vm: MeterViewModel
    @AppStorage("serverURL") private var persistedURL: String = ""

    var body: some View {
        Group {
            if vm.connectionSheetOpen || (!vm.hasConfiguredServer && persistedURL.isEmpty) {
                ConnectionPlaceholder(vm: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                meterPane
            }
        }
        .navigationTitle(vm.serverTitle)
        .toolbar { mainToolbar }
        .sheet(isPresented: $vm.connectionSheetOpen) {
            ConnectionSheet(vm: vm) { vm.connectionSheetOpen = false }
        }
        .frame(minWidth: 380, minHeight: 520)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        // ConnectionBadge + BackendBadge are Equatable over their value
        // inputs; `.equatable()` lets SwiftUI's diff skip their body
        // (and the AppKit NSToolbarItemViewer relayout that follows)
        // when state hasn't changed. Profile showed the toolbar item's
        // `_layoutSubtreeWithOldSize:` was a major hot spot at 10 Hz.
        ToolbarItem(placement: .navigation) {
            ConnectionBadge(state: vm.connection, host: hostHint)
                .equatable()
                .help(hostHint)
        }

        ToolbarItem(placement: .principal) {
            BackendBadge(backend: vm.backend)
                .equatable()
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                vm.connectionSheetOpen = true
            } label: {
                Image(systemName: "network.badge.shield.half.filled")
                    .help("Server connection settings")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                vm.toggleSetup()
                if vm.setupOpen {
                    Task { await vm.refreshLogLevel() }
                }
            } label: {
                Image(systemName: vm.setupOpen ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver")
                    .help("Open SETUP overlay")
            }
        }
    }

    private var hostHint: String {
        if let url = URL(string: vm.serverURLString), let host = url.host {
            let port = url.port.map { ":\($0)" } ?? ""
            return "\(host)\(port)"
        }
        return "Not configured"
    }

    // MARK: - Main pane

    private var meterPane: some View {
        VStack(spacing: 10) {
            if let banner = vm.statusBanner {
                BannerLabel(text: banner)
            }

            // In normal operation the inner PowerSWRCombinedCard owns its
            // own header (which is mode-aware: "Average" / "Peak" / "Tune"),
            // so we don't wrap it in another titled Panel. Setup overlay
            // still gets the labelled chrome.
            if vm.setupOpen {
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        PanelHeader(title: "Setup overlay", trailing: callsignAccessory)
                        Divider()
                        activeView
                    }
                }
            } else {
                activeView
            }

            CompactPanel {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        statusItem(label: "Coupler",
                                   value: vm.snapshot?.coupler.isEmpty == false
                                          ? (vm.snapshot?.coupler ?? "—") : "—")
                        Spacer(minLength: 4)
                        statusItem(label: "Power",
                                   value: powerModeLabel)
                        Spacer(minLength: 4)
                        statusItem(label: "Top",
                                   value: topModeLabel)
                        Spacer(minLength: 4)
                        statusItem(label: "FW",
                                   value: vm.snapshot?.firmwareRev.isEmpty == false
                                          ? (vm.snapshot?.firmwareRev ?? "—") : "—")
                    }
                    .frame(maxWidth: .infinity)
                    Divider()
                    KeypadView(vm: vm)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private var activeView: some View {
        if vm.setupOpen {
            SetupOverlay(vm: vm)
        } else {
            // Build a value-typed model on each ContentView re-render
            // (cheap; pure functions over the snapshot). PowerSWRView
            // is `Equatable` over this model, so SwiftUI's `.equatable()`
            // skips the entire bargraph + ControlsCard subtree's body
            // re-evaluation and layout pass when display values are
            // unchanged frame-over-frame — extremely common at the
            // 10 Hz publish rate after `formatPower` rounds and the
            // bar fraction is quantized into 1 % steps.
            PowerSWRView(
                model: PowerSWRModel.make(
                    snapshot: vm.snapshot,
                    allowControl: vm.allowControl,
                    connected: vm.connection == .connected,
                    setupOpen: vm.setupOpen
                ),
                vm: vm
            )
            .equatable()
        }
    }

    private var callsignAccessory: AnyView? {
        let cs = vm.snapshot?.callsign.trimmingCharacters(in: .whitespaces) ?? ""
        guard !cs.isEmpty else { return nil }
        return AnyView(
            Text(cs)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
        )
    }

    private var powerModeLabel: String {
        switch vm.snapshot?.powerMode {
        case .net: return "Net (F−R)"
        case .delivered: return "Delivered (F+R)"
        case .forward: return "Forward"
        case nil: return "—"
        }
    }

    private var topModeLabel: String {
        switch vm.snapshot?.topMode {
        case .powerSWR: return "Power / SWR"
        case .waveform: return "Waveform"
        case .spectrum: return "Spectrum"
        case .setup: return "Setup"
        case nil: return "—"
        }
    }

    private func statusItem(label: String, value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(tint)
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

private struct CompactPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
    }
}

// MARK: - Toolbar pieces

private struct ConnectionBadge: View, Equatable {
    var state: WSClient.ConnectionState
    var host: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.7), radius: state == .connected ? 3 : 0)
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Text(host)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var color: Color {
        switch state {
        case .connected: return .green
        case .reconnecting: return .yellow
        case .disconnected: return .red
        }
    }

    private var label: String {
        switch state {
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        case .disconnected: return "Offline"
        }
    }
}

private struct BackendBadge: View, Equatable {
    var backend: String

    var body: some View {
        if backend.isEmpty || backend == "unknown" {
            EmptyView()
        } else {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.06 * 11)
                    .textCase(.uppercase)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundColor(tint)
            .background(
                RoundedRectangle(cornerRadius: 999)
                    .strokeBorder(tint.opacity(0.5), lineWidth: 1)
            )
            .help(helpText)
        }
    }

    private var icon: String {
        switch backend {
        case "hid": return "cable.connector.horizontal"
        case "simulator": return "waveform.badge.exclamationmark"
        default: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch backend {
        case "hid": return .green
        case "simulator": return .yellow
        default: return .secondary
        }
    }

    private var label: String {
        switch backend {
        case "hid": return "HID"
        case "simulator": return "Simulator"
        default: return backend
        }
    }

    private var helpText: String {
        switch backend {
        case "hid": return "Server is reading the LP-500/700 over USB HID"
        case "simulator": return "Server is emitting synthesised data — no real meter attached"
        default: return "Backend: \(backend)"
        }
    }
}

private struct BannerLabel: View {
    var text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
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

// MARK: - First-launch placeholder

struct ConnectionPlaceholder: View {
    @ObservedObject var vm: MeterViewModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("No server connected")
                .font(.title2.weight(.semibold))
            Text("Configure the URL of your LP-700 WebSocket server to begin streaming telemetry from the Telepost LP-500 / LP-700 station monitor.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button {
                vm.connectionSheetOpen = true
            } label: {
                Text("Connect…").frame(minWidth: 100)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
