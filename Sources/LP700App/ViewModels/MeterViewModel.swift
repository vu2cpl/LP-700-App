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
    /// Why the server refused us (today: the proxy's 401), shown in the meter pane, the
    /// Connect sheet and Preferences. Cleared by the next frame, start() and disconnect().
    @Published var lastConnectError: String?

    /// True once the user has entered a server URL — drives whether the
    /// connection sheet opens automatically on launch.
    var hasConfiguredServer: Bool { Self.configuredServerURL(serverURLString) != nil }

    /// The server a saved "serverURL" preference points at, or `nil` when nothing usable is
    /// configured: empty, or no host (`"localhost:8089"` parses as scheme-only). The one rule
    /// shared by every entry point that connects on launch — `LP700StandaloneApp.bootstrap()`,
    /// `LP700Plugin.activate()` and the hosted `HostedRootView` — so all three behave alike.
    nonisolated static func configuredServerURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    // Server log level (read from /api/log-level)
    @Published var serverLogLevel: String = "error"
    @Published var setupOpen: Bool = false

    // Sticky-max SWR shown alongside the live SWR readout, matching the
    // hardware LCD's "Peak: 1.50" indicator. Pure max, no decay; resets
    // on disconnect / explicit reconnect.
    @Published var peakSwr: Double = 1.0

    // Latest scope (waveform) and spectrum buffers, both 320 normalised
    // (0..255) samples. Only populated when the meter is on the matching
    // LCD page — the server emits them at ~4 Hz in that mode and stops
    // when the operator switches pages. Don't render synthetic data when
    // these are stale; show a placeholder instead.
    @Published var lastScope: ScopePayload?
    @Published var lastSpectrum: SpectrumPayload?
    @Published var lastScopeAt: Date = .distantPast
    @Published var lastSpectrumAt: Date = .distantPast

    // Which top-level view ContentView should render. It follows the
    // meter's LCD page (`top_mode`) on every telemetry frame, so a page
    // change from the meter's own Mode key, another client, or the app's
    // LCD Mode button all land the app on the same page. (Until
    // 2026-11-19 it was user-driven and only seeded once, because the
    // server's telemetry flapped between pages; LP-700-Server PR #9
    // fixed that, and a user-driven view drifted out of step with the
    // meter on the bench.) The Setup page has no view of its own and
    // shows Power/SWR.
    enum ActiveView: Equatable { case powerSWR, waveform, spectrum }
    @Published var activeView: ActiveView = .powerSWR

    nonisolated static func activeView(for topMode: TopMode) -> ActiveView {
        switch topMode {
        case .powerSWR, .setup: return .powerSWR
        case .waveform:         return .waveform
        case .spectrum:         return .spectrum
        }
    }

    /// Page the last telemetry frame reported, and the LCD Mode press
    /// that may still have to skip the Setup page.
    private var lastTopMode: TopMode?
    private var modeStepTracker = ModeStepTracker()

    // (Control state — channel / peak_mode / alarm / range — was
    // briefly tracked in dedicated debounced @Published fields as a
    // workaround for a server-side bug that decoded sample-cmd HID
    // responses as telemetry, producing flapping snapshot fields.
    // The server is now fixed [LP-700-Server PR #2], so the snapshot
    // is the trustworthy source of truth again. Views read
    // `vm.snapshot?.channel` etc. directly.)

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
    /// Bumped by every start()/stop(). A start() that is still awaiting the server when a
    /// newer start()/stop() happens sees a changed value and gives up instead of finishing.
    private var startGeneration = 0
    private var configClient: ConfigClient?
    private var listenTask: Task<Void, Never>?

    private let log = Logger(subsystem: "com.vu3esv.lp700-app", category: "viewmodel")

    init() {}

    deinit {
        // A replaced model (standalone window re-created, hosted scene rebuilt) must not leave
        // its socket streaming into a stream nobody reads.
        listenTask?.cancel()
        publishTask?.cancel()
        if let ws { Task { await ws.stop() } }
    }

    // MARK: - Connection management

    func start(serverURL: URL) async {
        log.debug("Starting against \(serverURL.absoluteString, privacy: .public)")
        // The awaits below can take a full URLSession timeout when the saved server is
        // unreachable. If the operator reconnects elsewhere meanwhile (reconnect() → stop()
        // + start()), this stale attempt must not finish by installing its own WSClient over
        // the live one and cancelling the live listen task.
        // Idempotent: a second start() (window re-created, hosted scene rebuilt, .task re-run)
        // replaces the previous client instead of leaving it connected as a zombie.
        await stop()
        startGeneration &+= 1
        let generation = startGeneration
        serverURLString = serverURL.absoluteString
        lastConnectError = nil
        // The proxy login is read here, at connect time, and only for a TLS URL: over
        // http/ws it is never sent, so there is no reason to touch the Keychain.
        let credentials = ProxyAuth.isSecure(serverURL) ? await ProxyLoginStore.credentials() : nil
        let cfg = ConfigClient(baseURL: serverURL, credentials: credentials)
        configClient = cfg

        // Bootstrap from /api/config (best-effort; a 401 is reported, the WS then retries).
        var server: ServerConfig?
        var authError: ProxyAuthError?
        do {
            server = try await cfg.fetchConfig()
        } catch let error as ProxyAuthError {
            authError = error
        } catch {}
        let level = authError == nil ? try? await cfg.fetchLogLevel() : nil
        guard generation == startGeneration else {
            log.debug("start(\(serverURL.absoluteString, privacy: .public)) superseded — dropping")
            return
        }
        if let server {
            backend = server.backend
            serverTitle = server.title.isEmpty ? "LP-500 / LP-700" : server.title
            allowControl = server.allowControl
        }
        if let level { serverLogLevel = level.level }
        if let authError { lastConnectError = authError.localizedDescription }

        let ws = WSClient(baseURL: serverURL, credentials: credentials)
        self.ws = ws
        await ws.start()
        listenTask?.cancel()
        let events = ws.events
        listenTask = Task { [weak self] in
            for await event in events {
                // Re-acquire per event so a replaced model can be released between frames.
                guard let self else { return }
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
        lastConnectError = nil
        snapshot = nil
        peakSwr = 1.0
        lastScope = nil
        lastSpectrum = nil
        lastScopeAt = .distantPast
        lastSpectrumAt = .distantPast
        activeView = .powerSWR
        lastTopMode = nil
        modeStepTracker = ModeStepTracker()
    }

    func stop() async {
        startGeneration &+= 1   // invalidate any start() still awaiting the server
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
        var probe = URLRequest(url: url.appendingPathComponent("/healthz"))
        let credentials = ProxyAuth.isSecure(url) ? await ProxyLoginStore.credentials() : nil
        ProxyAuth.authorize(&probe, credentials: credentials)
        do {
            let (_, resp) = try await URLSession.shared.data(for: probe)
            try ConfigClient.checkOK(resp, for: probe)
            return .ok
        } catch let authError as ProxyAuthError {
            return .failure(authError.localizedDescription)
        } catch let urlError as URLError where urlError.code == .badServerResponse {
            return .failure("Server returned non-2xx")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Proxy login

    /// Username of the login stored in the Keychain, if any. Never decrypts the password.
    var storedProxyAccount: String? { ProxyLoginStore.storedAccount }

    /// Save to the Keychain (update, else add). The live connection's next attempt and the
    /// next start() use it.
    enum ProxyLoginError: LocalizedError {
        case invalidPassword
        var errorDescription: String? { "The password contains a line break or control character. Paste just the password." }
    }

    func saveProxyLogin(_ login: ProxyCredentials) async throws {
        guard let password = ProxyAuth.normalizedPassword(login.password) else { throw ProxyLoginError.invalidPassword }
        let credentials = ProxyCredentials(username: login.username, password: password)
        try ProxyLoginStore.save(credentials)
        await ws?.setCredentials(credentials)
        await configClient?.setCredentials(credentials)
    }

    func removeProxyLogin() async throws {
        try ProxyLoginStore.remove()
        await ws?.setCredentials(nil)
        await configClient?.setCredentials(nil)
    }

    // MARK: - Commands
    //
    // Each verb just sends to the meter; the next telemetry frame
    // reflects the new state in the @Published `snapshot`. Server is
    // now reliable so we don't need the optimistic-update layer the
    // older WIP carried.

    /// Cycle the meter range one step. Server's `range_step` verb
    /// ignores the value parameter (firmware always advances by one);
    /// we compute the local index from the current snapshot so
    /// re-pressing converges even if the meter and app momentarily
    /// disagree.
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

    /// Toggle the alarm: off ↔ on. Reads current state from snapshot.
    func sendAlarmToggle() {
        let next = (snapshot?.alarmEnabled == true) ? 0 : 1
        sendCommand(.alarmToggle, value: next)
    }

    /// Press the meter's Mode key once. The meter changes page and the
    /// app's view follows from the next telemetry frame; nothing changes
    /// locally first (server is authoritative). The LP-500 user guide
    /// v5.4 gives the Mode key a 3-page cycle (Power/SWR → Waveform →
    /// Spectrum), with Setup on its own key. In case some firmware does
    /// step into Setup, `ModeStepTracker` sends one more press if this
    /// press is seen to land there.
    func sendModeStep() {
        guard allowControl, connection == .connected else { return }
        modeStepTracker.didSendModeStep(from: lastTopMode, at: Date())
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
            if s == .connected { lastConnectError = nil }
        case .authFailed(let error):
            lastConnectError = error.localizedDescription
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
            // are timely; the @Published snapshot is coalesced to 5 Hz
            // to bound SwiftUI re-render cost.
            handleAlarmEdge(data: data)
            schedulePublish(data)
            // Follow the meter's page. Set only on change: @Published
            // notifies on every assignment, and frames arrive faster
            // than the 10 Hz snapshot publish.
            lastTopMode = data.topMode
            let view = Self.activeView(for: data.topMode)
            if activeView != view { activeView = view }
            if modeStepTracker.observe(data.topMode, at: Date()) {
                sendCommand(.modeStep, value: nil)
            }
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
        case .scope(_, _, let payload):
            lastScope = payload
            lastScopeAt = Date()
        case .spectrum(_, _, let payload):
            lastSpectrum = payload
            lastSpectrumAt = Date()
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
        let enabled = AppDefaults.resolved.object(forKey: "alarmNotifications") as? Bool ?? true
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

/// Decides whether an LCD Mode press from the app needs one more press
/// to get past the meter's Setup page. Armed by each press with the page
/// the meter was on; the first telemetry frame that reports a different
/// page settles it: Setup → press once more (Mode from Setup returns to
/// Power/SWR), anything else → done. A press that shows no page change
/// within `window` is dropped, so a Setup page the operator opens later
/// with the meter's own Setup key is left alone.
struct ModeStepTracker {
    static let window: TimeInterval = 2

    private var pendingFrom: TopMode?
    private var pendingSince: Date?

    mutating func didSendModeStep(from page: TopMode?, at now: Date) {
        pendingFrom = page
        pendingSince = now
    }

    /// Returns true when the caller should send one more `mode_step`.
    mutating func observe(_ page: TopMode, at now: Date) -> Bool {
        guard let since = pendingSince else { return false }
        if now.timeIntervalSince(since) > Self.window {
            clear()
            return false
        }
        // Still on the page the press started from: the meter hasn't
        // reported the change yet. (A nil start page means we pressed
        // before any telemetry; any page settles it.)
        if let from = pendingFrom, page == from { return false }
        clear()
        return page == .setup
    }

    private mutating func clear() {
        pendingFrom = nil
        pendingSince = nil
    }
}
