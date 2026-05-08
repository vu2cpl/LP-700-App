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

    // Sticky peaks (used by the bargraphs). Decay 5 %/frame after 1.5 s
    // of no new max — same shape the LP-100A-App uses.
    @Published var peakAvg: Double = 0
    @Published var peakPeak: Double = 0
    @Published var peakSwr: Double = 1.0
    private var peakAvgAt: Date = .distantPast
    private var peakPeakAt: Date = .distantPast
    private var peakSwrAt: Date = .distantPast

    // Server log level (read from /api/log-level)
    @Published var serverLogLevel: String = "error"
    @Published var setupOpen: Bool = false

    // Alarm-trip notification edge tracking
    private var lastAlarmTripped: Bool = false
    private var lastAlarmAt: Date = .distantPast

    // Net
    private var ws: WSClient?
    private var configClient: ConfigClient?
    private var listenTask: Task<Void, Never>?
    private var decayTask: Task<Void, Never>?

    private let log = Logger(subsystem: "com.vu3esv.lp700-app", category: "viewmodel")

    init() {
        startDecayLoop()
    }

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
    }

    func stop() async {
        listenTask?.cancel()
        listenTask = nil
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
            snapshot = data
            updatePeaks(from: data)
            handleAlarmEdge(data: data)
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

    private func scheduleBannerDismiss() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run { self?.statusBanner = nil }
        }
    }

    private func updatePeaks(from d: Snapshot) {
        let now = Date()
        if d.powerAvgW > peakAvg { peakAvg = d.powerAvgW; peakAvgAt = now }
        if d.powerPeakW > peakPeak { peakPeak = d.powerPeakW; peakPeakAt = now }
        if d.swr > peakSwr { peakSwr = d.swr; peakSwrAt = now }
    }

    private func startDecayLoop() {
        decayTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000) // ~16 fps
                await MainActor.run {
                    guard let self else { return }
                    let now = Date()
                    if now.timeIntervalSince(self.peakAvgAt) > 1.5 {
                        self.peakAvg = max(0, self.peakAvg - self.peakAvg * 0.05)
                    }
                    if now.timeIntervalSince(self.peakPeakAt) > 1.5 {
                        self.peakPeak = max(0, self.peakPeak - self.peakPeak * 0.05)
                    }
                    if now.timeIntervalSince(self.peakSwrAt) > 1.5 {
                        self.peakSwr = max(1.0, self.peakSwr - (self.peakSwr - 1.0) * 0.05)
                    }
                }
            }
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
