import Foundation

// Wire-protocol mirror of the LP-700 WebSocket server.
// Reference: VU3ESV/LP-700-Server internal/lpmeter/snapshot.go and
// internal/hub/hub.go.

enum PeakMode: String, Codable, Equatable {
    case peakHold = "peak_hold"
    case average
    case tune
}

enum PowerMode: String, Codable, Equatable {
    case net
    case delivered
    case forward
}

enum TopMode: String, Codable, Equatable {
    case powerSWR = "power_swr"
    case waveform
    case spectrum
    case setup
}

enum Coupler: String, Codable, Equatable {
    case lpc501 = "LPC501"
    case lpc502 = "LPC502"
    case lpc503 = "LPC503"
    case lpc504 = "LPC504"
    case lpc505 = "LPC505"
}

// Range labels, in cycle order. Matches RANGE_NAMES in the server's
// embedded reference web client.
enum RangeNames {
    static let cycle: [String] = [
        "auto", "5W", "10W", "25W", "50W", "100W",
        "250W", "500W", "1K", "2.5K", "5K", "10K",
    ]
}

struct Snapshot: Codable, Equatable {
    var channel: Int
    var autoChannel: Bool
    var powerAvgW: Double
    var powerPeakW: Double
    var peakHoldW: Double
    var swr: Double
    var range: String
    var peakMode: PeakMode
    var powerMode: PowerMode
    var alarmEnabled: Bool
    var alarmPowerW: Double
    var alarmSWR: Double
    var alarmTripped: Bool
    var callsign: String
    var coupler: String
    var topMode: TopMode
    var firmwareRev: String
    var statusMessage: String

    enum CodingKeys: String, CodingKey {
        case channel
        case autoChannel = "auto_channel"
        case powerAvgW = "power_avg_w"
        case powerPeakW = "power_peak_w"
        case peakHoldW = "peak_hold_w"
        case swr, range
        case peakMode = "peak_mode"
        case powerMode = "power_mode"
        case alarmEnabled = "alarm_enabled"
        case alarmPowerW = "alarm_power_w"
        case alarmSWR = "alarm_swr"
        case alarmTripped = "alarm_tripped"
        case callsign, coupler
        case topMode = "top_mode"
        case firmwareRev = "firmware_rev"
        case statusMessage = "status_message"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channel        = (try? c.decode(Int.self, forKey: .channel)) ?? 0
        autoChannel    = (try? c.decode(Bool.self, forKey: .autoChannel)) ?? false
        powerAvgW      = (try? c.decode(Double.self, forKey: .powerAvgW)) ?? 0
        powerPeakW     = (try? c.decode(Double.self, forKey: .powerPeakW)) ?? 0
        peakHoldW      = (try? c.decode(Double.self, forKey: .peakHoldW)) ?? 0
        swr            = (try? c.decode(Double.self, forKey: .swr)) ?? 1.0
        range          = (try? c.decode(String.self, forKey: .range)) ?? ""
        peakMode       = (try? c.decode(PeakMode.self, forKey: .peakMode)) ?? .average
        powerMode      = (try? c.decode(PowerMode.self, forKey: .powerMode)) ?? .net
        alarmEnabled   = (try? c.decode(Bool.self, forKey: .alarmEnabled)) ?? false
        alarmPowerW    = (try? c.decode(Double.self, forKey: .alarmPowerW)) ?? 0
        alarmSWR       = (try? c.decode(Double.self, forKey: .alarmSWR)) ?? 0
        alarmTripped   = (try? c.decode(Bool.self, forKey: .alarmTripped)) ?? false
        callsign       = (try? c.decode(String.self, forKey: .callsign)) ?? ""
        coupler        = (try? c.decode(String.self, forKey: .coupler)) ?? ""
        topMode        = (try? c.decode(TopMode.self, forKey: .topMode)) ?? .powerSWR
        firmwareRev    = (try? c.decode(String.self, forKey: .firmwareRev)) ?? ""
        statusMessage  = (try? c.decode(String.self, forKey: .statusMessage)) ?? ""
    }
}

enum ServerFrame: Decodable, Equatable {
    case telemetry(seq: Int, ts: String, data: Snapshot)
    case heartbeat(seq: Int, ts: String)
    case status(level: String, msg: String)
    case ack(ref: String, ok: Bool, reason: String?)
    case unknown(type: String)

    private enum K: String, CodingKey {
        case type, seq, ts, data, level, msg, ref, ok, reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "telemetry":
            self = .telemetry(
                seq: (try? c.decode(Int.self, forKey: .seq)) ?? 0,
                ts: (try? c.decode(String.self, forKey: .ts)) ?? "",
                data: try c.decode(Snapshot.self, forKey: .data)
            )
        case "heartbeat":
            self = .heartbeat(
                seq: (try? c.decode(Int.self, forKey: .seq)) ?? 0,
                ts: (try? c.decode(String.self, forKey: .ts)) ?? ""
            )
        case "status":
            self = .status(
                level: (try? c.decode(String.self, forKey: .level)) ?? "info",
                msg: (try? c.decode(String.self, forKey: .msg)) ?? ""
            )
        case "ack":
            self = .ack(
                ref: (try? c.decode(String.self, forKey: .ref)) ?? "",
                ok: (try? c.decode(Bool.self, forKey: .ok)) ?? false,
                reason: try? c.decode(String.self, forKey: .reason)
            )
        default:
            self = .unknown(type: type)
        }
    }
}

// Command verbs accepted on the /ws channel. Names match the actions
// emitted by the server's reference web client (sendCmd in index.html).
//
// `value` semantics by action:
//   peak_toggle    → 0 = peak_hold, 1 = average, 2 = tune
//   range_step     → next index into RangeNames.cycle
//   channel_step   → 0 = auto, 1..4 = channel number
//   alarm_toggle   → 0 = off, 1 = on
//   mode_step      → no value (cycles top-level LCD mode)
enum CommandAction: String, Codable {
    case peakToggle   = "peak_toggle"
    case rangeStep    = "range_step"
    case channelStep  = "channel_step"
    case alarmToggle  = "alarm_toggle"
    case modeStep     = "mode_step"
}

enum ClientFrame: Encodable {
    case command(id: String, action: CommandAction, value: Int?)
    case resync

    private enum K: String, CodingKey { case type, id, action, value }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .command(let id, let action, let value):
            try c.encode("command", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(action.rawValue, forKey: .action)
            if let v = value { try c.encode(v, forKey: .value) }
        case .resync:
            try c.encode("resync", forKey: .type)
        }
    }
}
