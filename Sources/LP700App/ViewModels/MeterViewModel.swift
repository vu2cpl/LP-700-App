import Foundation
import SwiftUI
import os.log
#if canImport(UserNotifications)
import UserNotifications
#endif

// Single source of truth for the UI. Owns connection lifecycle, the
// latest telemetry snapshot, and command dispatch.
@MainActor
final class MeterViewModel: ObservableObject {
    // Telemetry / connection
    @Published var snapshot: Snapshot?
    @Published var connection: WSClient.ConnectionState = .disconnected
    @Published var statusBanner: String?
    @Published var allowControl: Bool = true
    @Published var backend: String = "unknown"
    @Published var serverTitle: String = "LP-500 / LP-700"
    @Published var serverURLString: String = ""
    @Published var connectionSheetOpen: Bool = false
    @Published var lastConnectError: String?

    /// True once the user has entered a server URL — drives whether the
    /// connection sheet opens automatically on launch.
    var hasConfiguredServer: Bool {
        guard let url = URL(string: serverURLString),
              url.host?.isEmpty == false else { return false }
        return true
    }

    // Server log level (read from /api/log-level)
    @Published var serverLogLevel: String = "error"
    @Published var setupOpen: Bool = false

    // Sticky-max SWR shown alongside the live SWR readout, matching the
    // hardware LCD's "Peak: 1.50" indicator. Pure max, no decay; resets
    // on disconnect / explicit reconnect.
    @Published var peakSwr: Double = 1.0

    // Alarm-trip notification edge tracking
    private var lastAlarmTripped: Bool = false
    private var lastAlarmAt: Date = .distantPast

    // UI publish coalescing. The server pushes telemetry at the meter's
    // poll cadence (~25 Hz on real hardware, similar on the simulator),
    // but a human can't read more than ~5 numbers/second. We coalesce
    // to 5 Hz: SwiftUI body re-evaluation, the toolbar's NSHostingView
    // relayout (which dominates residual CPU because the toolbar
    // content closure rebuilds on every ContentView.body), and the
    // menu-bar label tick all run at most 5×/second. Alarm edges and
    // status banners still process on every inbound frame so
    // notifications stay timely.
    private static let publishInterval: TimeInterval = 0.2  // 200 ms (5 Hz)
    private var pendingSnapshot: Snapshot?
    private var publishTask: Task<Void, Never>?
    private var lastPublishAt: Date = .distantPast

    // Net
    private var ws: WSClient?
    private var configClient: ConfigClient?
    private var listenTask: Task<Void, Never>?

    private let log = Logger(subsystem: "com.vu3esv.lp700-app", category: "viewmodel")

    init() {}

    // MARK: - Connection management

    func start(serverURL: URL) async {
        log.debug("Starting against \(serverURL.absoluteString, privacy: .public)")
        serverURLString = serverURL.absoluteString
        lastConnectError = nil
        let cfg = ConfigClient(baseURL: serverURL)
        configClient = cfg

        // Bootstrap from /api/config (best-effort).
        if let server = try? await cfg.fetchConfig() {
            backend = server.backend
            serverTitle = server.title.isEmpty ? "LP-500 / LP-700" : server.title
            allowControl = server.allowControl
        }
        if let lvl = try? await cfg.fetchLogLevel() { serverLogLevel = lvl.level }

        let ws = WSClient(baseURL: serverURL)
        self.ws = ws
        await ws.start()
        listenTask?.cancel()
        let events = ws.events
        listenTask = Task { [weak self] in
            guard let self else { return }
            for await event in events {
                await self.handle(event: event)
            }
        }
    }

    func reconnect(serverURL: URL) async {
        serverURLString = serverURL.absoluteString
        await stop()
        await start(serverURL: serverURL)
    }

    func disconnect() async {
        await stop()
        connection = .disconnected
        snapshot = nil
        peakSwr = 1.0
    }

    func stop() async {
        listenTask?.cancel()
        listenTask = nil
        publishTask?.cancel()
        publishTask = nil
        pendingSnapshot = nil
        await ws?.stop()
        ws = nil
    }

    enum ConnectionTestResult: Equatable {
        case ok
        case failure(String)
    }

    /// Probe the server's `/healthz` endpoint. Used by the Connect sheet.
    func testConnection(urlString: String) async -> ConnectionTestResult {
        guard let url = URL(string: urlString), url.host?.isEmpty == false else {
            return .failure("Invalid URL")
        }
        let probe = url.appendingPathComponent("/healthz")
        do {
            let (_, resp) = try await URLSession.shared.data(from: probe)
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return .ok
            }
            return .failure("Server returned non-2xx")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Commands

    /// Cycle the next range. Computes the next index from the last-known
    /// snapshot's range label, matching the behavior of the embedded web
    /// client's "Range:" button.
    func sendRangeStep() {
        let cycle = RangeNames.cycle
        let current = snapshot?.range ?? "auto"
        let idx = cycle.firstIndex(of: current) ?? 0
        let next = (idx + 1) % cycle.count
        sendCommand(.rangeStep, value: next)
    }

    /// Set the meter channel: 0 = auto, 1..4 = explicit channel.
    func sendChannelStep(_ value: Int) {
        sendCommand(.channelStep, value: value)
    }

    /// Force the meter into one of peak_hold (0), average (1), tune (2).
    func sendPeakToggle(_ value: Int) {
        sendCommand(.peakToggle, value: value)
    }

    /// Toggle the alarm: 0 = off, 1 = on. Reads the last-known state.
    func sendAlarmToggle() {
        let next = (snapshot?.alarmEnabled == true) ? 0 : 1
        sendCommand(.alarmToggle, value: next)
    }

    /// Cycle the meter's top-level LCD mode (Power-SWR / Waveform /
    /// Spectrum / Setup). Visible on the meter's LCD only — not in the UI.
    func sendModeStep() {
        sendCommand(.modeStep, value: nil)
    }

    func resync() { sendRaw(.resync) }

    private func sendCommand(_ action: CommandAction, value: Int?) {
        guard allowControl, connection == .connected else { return }
        sendRaw(.command(id: UUID().uuidString, action: action, value: value))
    }

    private func sendRaw(_ frame: ClientFrame) {
        Task { [ws] in
            try? await ws?.send(frame)
        }
    }

    // MARK: - Setup / log level

    func toggleSetup() { setupOpen.toggle() }

    func setLogLevel(_ level: String) async {
        guard let configClient else { return }
        if let updated = try? await configClient.setLogLevel(level) {
            serverLogLevel = updated.level
        }
    }

    func refreshLogLevel() async {
        guard let configClient else { return }
        if let updated = try? await configClient.fetchLogLevel() {
            serverLogLevel = updated.level
        }
    }

    // MARK: - Event handling

    private func handle(event: WSClient.Event) async {
        switch event {
        case .stateChanged(let s):
            connection = s
        case .frame(let frame):
            applyFrame(frame)
        case .parseError(let msg):
            log.warning("WS parse error: \(msg, privacy: .public)")
        }
    }

    private func applyFrame(_ frame: ServerFrame) {
        switch frame {
        case .telemetry(_, _, let data):
            // Alarm-edge detection runs on every frame so notifications
            // are timely; the @Published snapshot is coalesced to 10 Hz
            // to bound SwiftUI re-render cost.
            handleAlarmEdge(data: data)
            schedulePublish(data)
        case .heartbeat:
            break
        case .status(let level, let msg):
            statusBanner = "[\(level.uppercased())] \(msg)"
            scheduleBannerDismiss()
        case .ack(_, let ok, let reason):
            if !ok, let reason {
                statusBanner = "Server rejected: \(reason)"
                scheduleBannerDismiss()
            }
        case .unknown:
            break
        }
    }

    /// Coalesces inbound telemetry to a 10 Hz @Published mutation rate.
    /// The latest pending snapshot wins; intermediate frames are dropped
    /// from the UI path (alarm edges still saw them upstream). If the
    /// last publish is older than the throttle window, the new snapshot
    /// is committed immediately; otherwise a single trailing publish is
    /// scheduled to flush the most recent value.
    private func schedulePublish(_ data: Snapshot) {
        pendingSnapshot = data
        if publishTask != nil { return }

        let elapsed = Date().timeIntervalSince(lastPublishAt)
        if elapsed >= Self.publishInterval {
            commitPending()
            return
        }

        let waitNs = UInt64((Self.publishInterval - elapsed) * 1_000_000_000)
        publishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: waitNs)
            await MainActor.run { self?.commitPending() }
        }
    }

    private func commitPending() {
        publishTask = nil
        guard let p = pendingSnapshot else { return }
        pendingSnapshot = nil
        snapshot = p
        if p.swr > peakSwr { peakSwr = p.swr }
        lastPublishAt = Date()
    }

    private func scheduleBannerDismiss() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run { self?.statusBanner = nil }
        }
    }

    private func handleAlarmEdge(data: Snapshot) {
        defer { lastAlarmTripped = data.alarmTripped }
        guard data.alarmTripped, !lastAlarmTripped else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAlarmAt) > 30 else { return }
        lastAlarmAt = now
        let enabled = UserDefaults.standard.object(forKey: "alarmNotifications") as? Bool ?? true
        guard enabled else { return }
        postAlarmNotification(swr: data.swr)
    }

    private func postAlarmNotification(swr: Double) {
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = "LP-700 — alarm tripped"
        content.body = String(format: "SWR %.2f — meter alarm condition", swr)
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content,
                                        trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
        #endif
    }
}
