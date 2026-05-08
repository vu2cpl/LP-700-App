import XCTest
@testable import LP700App

final class WireProtocolTests: XCTestCase {

    // MARK: - Telemetry decode

    func testTelemetryDecodes() throws {
        let json = """
        {
          "type": "telemetry",
          "seq": 42,
          "ts": "2026-05-08T10:11:12.123456Z",
          "data": {
            "channel": 2,
            "auto_channel": false,
            "power_avg_w": 57.4,
            "power_peak_w": 94.2,
            "peak_hold_w": 110.0,
            "swr": 1.42,
            "range": "100W",
            "peak_mode": "average",
            "power_mode": "net",
            "alarm_enabled": true,
            "alarm_power_w": 0,
            "alarm_swr": 2.5,
            "alarm_tripped": false,
            "callsign": "VU3ESV",
            "coupler": "LPC502",
            "top_mode": "power_swr",
            "firmware_rev": "v2.5.2b4",
            "status_message": ""
          }
        }
        """.data(using: .utf8)!

        let frame = try JSONDecoder().decode(ServerFrame.self, from: json)
        guard case .telemetry(let seq, _, let snap) = frame else {
            return XCTFail("expected telemetry")
        }
        XCTAssertEqual(seq, 42)
        XCTAssertEqual(snap.channel, 2)
        XCTAssertFalse(snap.autoChannel)
        XCTAssertEqual(snap.powerAvgW, 57.4, accuracy: 0.001)
        XCTAssertEqual(snap.powerPeakW, 94.2, accuracy: 0.001)
        XCTAssertEqual(snap.swr, 1.42, accuracy: 0.001)
        XCTAssertEqual(snap.range, "100W")
        XCTAssertEqual(snap.peakMode, .average)
        XCTAssertEqual(snap.powerMode, .net)
        XCTAssertTrue(snap.alarmEnabled)
        XCTAssertEqual(snap.alarmSWR, 2.5, accuracy: 0.001)
        XCTAssertEqual(snap.callsign, "VU3ESV")
        XCTAssertEqual(snap.coupler, "LPC502")
        XCTAssertEqual(snap.topMode, .powerSWR)
        XCTAssertEqual(snap.firmwareRev, "v2.5.2b4")
    }

    func testHeartbeatDecodes() throws {
        let json = #"{"type":"heartbeat","seq":7,"ts":"2026-05-08T10:11:12Z"}"#
        let frame = try JSONDecoder().decode(ServerFrame.self, from: json.data(using: .utf8)!)
        guard case .heartbeat(let seq, _) = frame else {
            return XCTFail("expected heartbeat")
        }
        XCTAssertEqual(seq, 7)
    }

    func testAckFailureDecodes() throws {
        let json = #"{"type":"ack","ref":"abc","ok":false,"reason":"control disabled"}"#
        let frame = try JSONDecoder().decode(ServerFrame.self, from: json.data(using: .utf8)!)
        guard case .ack(let ref, let ok, let reason) = frame else {
            return XCTFail("expected ack")
        }
        XCTAssertEqual(ref, "abc")
        XCTAssertFalse(ok)
        XCTAssertEqual(reason, "control disabled")
    }

    func testStatusDecodes() throws {
        let json = #"{"type":"status","level":"warn","msg":"Reduce power"}"#
        let frame = try JSONDecoder().decode(ServerFrame.self, from: json.data(using: .utf8)!)
        guard case .status(let level, let msg) = frame else {
            return XCTFail("expected status")
        }
        XCTAssertEqual(level, "warn")
        XCTAssertEqual(msg, "Reduce power")
    }

    func testUnknownTypeDoesNotThrow() throws {
        let json = #"{"type":"future_kind","payload":42}"#
        let frame = try JSONDecoder().decode(ServerFrame.self, from: json.data(using: .utf8)!)
        guard case .unknown(let type) = frame else {
            return XCTFail("expected unknown")
        }
        XCTAssertEqual(type, "future_kind")
    }

    // MARK: - Client frames

    func testCommandWithValueEncodes() throws {
        let frame = ClientFrame.command(id: "id-1", action: .peakToggle, value: 2)
        let data = try JSONEncoder().encode(frame)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "command")
        XCTAssertEqual(json["id"] as? String, "id-1")
        XCTAssertEqual(json["action"] as? String, "peak_toggle")
        XCTAssertEqual(json["value"] as? Int, 2)
    }

    func testCommandWithoutValueEncodes() throws {
        let frame = ClientFrame.command(id: "id-2", action: .modeStep, value: nil)
        let data = try JSONEncoder().encode(frame)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "command")
        XCTAssertEqual(json["action"] as? String, "mode_step")
        XCTAssertNil(json["value"])
    }

    func testResyncEncodes() throws {
        let data = try JSONEncoder().encode(ClientFrame.resync)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "resync")
    }

    func testRangeNamesMatchServer() {
        // Must mirror RANGE_NAMES in the server's embedded web client
        // (internal/web/static/index.html). If the server's order changes,
        // range_step values would target the wrong slot.
        XCTAssertEqual(RangeNames.cycle, [
            "auto", "5W", "10W", "25W", "50W", "100W",
            "250W", "500W", "1K", "2.5K", "5K", "10K"
        ])
    }
}
