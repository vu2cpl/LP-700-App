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

    // Latest scope (waveform) and spectrum buffers, both 320 normalised
    // (0..255) samples. Only populated when the meter is on the matching
    // LCD page — the server emits them at ~4 Hz in that mode and stops
    // when the operator switches pages. Don't render synthetic data when
    // these are stale; show a placeholder instead.
    @Published var lastScope: ScopePayload?
    @Published var lastSpectrum: SpectrumPayload?
    @Published var lastScopeAt: Date = .distantPast
    @Published var lastSpectrumAt: Date = .distantPast

    // Which top-level view ContentView should render. Purely user-
    // driven via `sendModeStep()` — the cycle is Power/SWR → Waveform
    // → Spectrum → Power/SWR. No autonomous switching from sample-
    // frame arrival or telemetry top_mode (both turned out to be
    // unstable enough to make the view flicker). The operator's
    // intent is what the app shows; the meter's actual LCD page is
    // assumed to follow because mode_step taps go to the meter too.
    enum ActiveView: Equatable { case powerSWR, waveform, spectrum }
    @Published var activeView: ActiveView = .powerSWR

    // Debounced control state. Each field updates only when TWO
    // consecutive sane telemetry frames agree on a new value, so a
    // single mis-decoded frame can't flip the displayed label. User
    // button presses optimistically update the matching stable*
    // value immediately for instant feedback; the debouncer then
    // reconciles against subsequent telemetry. After connect, the
    // first sane frame seeds all of them at once.
    @Published var stableChannel: Int = 1          // 1..4 (when not auto)
    @Published var stableAutoChannel: Bool = false
    @Published var stablePeakMode: PeakMode = .peakHold
    @Published var stableAlarmEnabled: Bool = false
    @Published var stableRange: String = "auto"
    private var stableStateInitialised = false

    // Pending values + run-count, per debounced field.
    private var pendingChannel: Int? = nil
    private var pendingChannelCount = 0
    private var pendingAutoChannel: Bool? = nil
    private var pendingAutoChannelCount = 0
    private var pendingPeakMode: PeakMode? = nil
    private var pendingPeakModeCount = 0
    private var pendingAlarmEnabled: Bool? = nil
    private var pendingAlarmEnabledCount = 0
    private var pendingRange: String? = nil
    private var pendingRangeCount = 0
    private static let debounceThreshold = 2        // 2 consecutive matching frames

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
        lastScope = nil
        lastSpectrum = nil
        lastScopeAt = .distantPast
        lastSpectrumAt = .distantPast
        activeView = .powerSWR
        stableStateInitialised = false
        pendingChannel = nil; pendingChannelCount = 0
        pendingAutoChannel = nil; pendingAutoChannelCount = 0
        pendingPeakMode = nil; pendingPeakModeCount = 0
        pendingAlarmEnabled = nil; pendingAlarmEnabledCount = 0
        pendingRange = nil; pendingRangeCount = 0
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
    //
    // Each control verb does an **optimistic** update on the matching
    // stable* @Published so the UI gives instant feedback, then sends
    // the command. Subsequent telemetry runs through the debouncer
    // and either confirms (no further visible change) or — if the
    // meter ended up at a different value — reconciles after two
    // consecutive frames agree.

    /// Cycle the meter range one step. Server's `range_step` verb
    /// ignores the value, so we advance our local range cycle
    /// optimistically; the debounced `stableRange` reconciles when
    /// the next telemetry frame lands.
    func sendRangeStep() {
        let cycle = RangeNames.cycle
        let idx = cycle.firstIndex(of: stableRange) ?? 0
        let next = (idx + 1) % cycle.count
        stableRange = cycle[next]
        sendCommand(.rangeStep, value: next)
    }

    /// Set the meter channel: 0 = auto, 1..4 = explicit channel.
    func sendChannelStep(_ value: Int) {
        if value == 0 {
            stableAutoChannel = true
            // Keep current stableChannel (the active slot) until the
            // meter tells us which channel it auto-selected.
        } else if (1...4).contains(value) {
            stableAutoChannel = false
            stableChannel = value
        }
        sendCommand(.channelStep, value: value)
    }

    /// Force the meter into one of peak_hold (0), average (1), tune (2).
    func sendPeakToggle(_ value: Int) {
        switch value {
        case 0: stablePeakMode = .peakHold
        case 1: stablePeakMode = .average
        case 2: stablePeakMode = .tune
        default: break
        }
        sendCommand(.peakToggle, value: value)
    }

    /// Toggle the alarm: off ↔ on.
    func sendAlarmToggle() {
        stableAlarmEnabled.toggle()
        sendCommand(.alarmToggle, value: stableAlarmEnabled ? 1 : 0)
    }

    /// Cycle the meter's top-level LCD mode. The app's visible cycle
    /// is 3-mode (Power-SWR → Waveform → Spectrum → Power-SWR), but
    /// the meter's hardware cycle is 4-mode (… → Setup → …). To keep
    /// app and meter in lock-step we send an extra `mode_step` when
    /// wrapping from Spectrum back to Power/SWR — that pulses the
    /// meter from spectrum → setup → power_swr in one go, so its
    /// physical LCD ends up on the same page as the app's view.
    func sendModeStep() {
        let prev = activeView
        switch prev {
        case .powerSWR: activeView = .waveform
        case .waveform: activeView = .spectrum
        case .spectrum: activeView = .powerSWR
        }
        sendCommand(.modeStep, value: nil)
        if prev == .spectrum {
            // Skip the meter's setup page so the cycle stays aligned.
            sendCommand(.modeStep, value: nil)
        }
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
            // Defensive: server sometimes decodes non-cmd-'0' HID
            // responses as telemetry frames. Those carry garbage
            // values at the same byte offsets (we've seen SWR 20.52
            // and peak < avg from this). Drop the obviously bad ones
            // rather than letting them flicker the display.
            guard isSane(data) else {
                log.debug("dropping insane telemetry: swr=\(data.swr) avg=\(data.powerAvgW) peak=\(data.powerPeakW)")
                return
            }
            // First sane snapshot after connect seeds the stable*
            // values directly (so the labels start in sync); after
            // that, run each control field through the 2-frame
            // debouncer to filter single-frame jitter.
            if !stableStateInitialised {
                seedStableState(from: data)
                stableStateInitialised = true
            } else {
                debounceStableState(from: data)
            }
            // Alarm-edge detection runs on every frame so notifications
            // are timely; the @Published snapshot is coalesced to 5 Hz
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

    // MARK: - User state seeding

    /// First-time seed: copy each meter-reported control field
    /// straight into the stable* @Published value. After this, the
    /// debouncer takes over.
    private func seedStableState(from data: Snapshot) {
        stableChannel = data.channel == 0 ? 1 : data.channel
        stableAutoChannel = data.autoChannel
        stablePeakMode = data.peakMode
        stableAlarmEnabled = data.alarmEnabled
        if RangeNames.cycle.contains(data.range) {
            stableRange = data.range
        }
        // Seed the view too, so the app starts on whatever LCD page
        // the meter is showing. The meter's own setup page maps to
        // our Power/SWR view (we don't mirror the meter's setup
        // screen in-app — the operator navigates that on the meter's
        // front panel).
        switch data.topMode {
        case .powerSWR, .setup: activeView = .powerSWR
        case .waveform:         activeView = .waveform
        case .spectrum:         activeView = .spectrum
        }
    }

    /// Per-frame debounce: only commit a new value to a `stable*`
    /// field after `debounceThreshold` consecutive matching telemetry
    /// frames. One-off junk frames (e.g. from mis-decoded sample-cmd
    /// HID responses) get suppressed; real changes — whether
    /// initiated by the app or by the meter's front panel — propagate
    /// after ~200–400 ms (2 frames at the 5 Hz publish rate).
    private func debounceStableState(from data: Snapshot) {
        debounceField(current: stableChannel, incoming: data.channel,
                      pending: &pendingChannel, count: &pendingChannelCount) {
            self.stableChannel = $0
        }
        debounceField(current: stableAutoChannel, incoming: data.autoChannel,
                      pending: &pendingAutoChannel, count: &pendingAutoChannelCount) {
            self.stableAutoChannel = $0
        }
        debounceField(current: stablePeakMode, incoming: data.peakMode,
                      pending: &pendingPeakMode, count: &pendingPeakModeCount) {
            self.stablePeakMode = $0
        }
        debounceField(current: stableAlarmEnabled, incoming: data.alarmEnabled,
                      pending: &pendingAlarmEnabled, count: &pendingAlarmEnabledCount) {
            self.stableAlarmEnabled = $0
        }
        // Range is a string; only debounce if it's one we recognise
        // (drops outright garbage that the server's decoder somehow
        // let through).
        if RangeNames.cycle.contains(data.range) {
            debounceField(current: stableRange, incoming: data.range,
                          pending: &pendingRange, count: &pendingRangeCount) {
                self.stableRange = $0
            }
        }
    }

    private func debounceField<T: Equatable>(
        current: T,
        incoming: T,
        pending: inout T?,
        count: inout Int,
        commit: (T) -> Void
    ) {
        if incoming == current {
            // Match — clear any pending change.
            pending = nil
            count = 0
            return
        }
        if pending == incoming {
            count += 1
            if count >= Self.debounceThreshold {
                commit(incoming)
                pending = nil
                count = 0
            }
        } else {
            pending = incoming
            count = 1
        }
    }

    /// Defensive sanity check on inbound telemetry. The server
    /// occasionally decodes non-cmd-'0' HID responses as telemetry
    /// frames (mis-routed sample-cmd responses); those carry junk
    /// values at the SWR / power offsets. Drop frames that violate
    /// physical invariants so they don't pollute the readouts.
    private func isSane(_ s: Snapshot) -> Bool {
        if s.swr < 1.0 || s.swr > 10.0 { return false }
        if s.powerAvgW.isNaN || s.powerPeakW.isNaN { return false }
        if s.powerAvgW < 0 || s.powerPeakW < 0 { return false }
        // Peak < Avg is physically impossible. Allow 0.5 W slop for
        // rounding on the wire.
        if s.powerPeakW + 0.5 < s.powerAvgW { return false }
        return true
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
