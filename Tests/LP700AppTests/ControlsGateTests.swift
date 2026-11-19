import XCTest
@testable import LP700App

/// Pins which Controls-card buttons are usable on each meter page. The
/// buttons are key presses (Rng = F3, Alm = F4, Mode = F5), and:
/// - In CH Auto on Power/SWR, Range and Alarm "can't be changed" (LP-500
///   user guide v5.4; bench-tested on the LP-700 2026-10-13); Channel and
///   Peak/Avg/Tune still work.
/// - On Waveform / Spectrum, F3-F5 set V/div or dB range, sweep or span,
///   and style or averaging, so only CH is offered (bench 2026-11-19: a
///   Range press there changed V/div).
/// - On Setup, F2-F5 select and adjust settings, so nothing but LCD Mode.
final class ControlsGateTests: XCTestCase {

    private func snapshot(autoChannel: Bool, page: String = "power_swr") throws -> Snapshot {
        let json = #"{"channel": 2, "auto_channel": \#(autoChannel), "range": "100W", "top_mode": "\#(page)"}"#
        return try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    }

    private func controls(autoChannel: Bool, page: String = "power_swr") throws -> ControlsModel {
        PowerSWRModel.make(snapshot: try snapshot(autoChannel: autoChannel, page: page),
                           allowControl: true,
                           connected: true,
                           setupOpen: false,
                           skipAutoChannel: page == "waveform" || page == "spectrum").controls
    }

    func testCHAutoGreysOutRangeAndAlarm() throws {
        let c = try controls(autoChannel: true)
        XCTAssertTrue(c.rangeDisabled)
        XCTAssertTrue(c.alarmDisabled)
        XCTAssertFalse(c.channelDisabled, "CH must stay usable so the operator can leave Auto")
        XCTAssertFalse(c.peakDisabled)
        XCTAssertNotNil(c.lockNote)
        XCTAssertEqual(c.rangeLabel, "100W", "the real range still shows while locked")
    }

    func testExplicitChannelEnablesRangeAndAlarm() throws {
        let c = try controls(autoChannel: false)
        XCTAssertFalse(c.rangeDisabled)
        XCTAssertFalse(c.alarmDisabled)
        XCTAssertNil(c.lockNote)
    }

    func testSamplePagesOfferOnlyChannel() throws {
        for page in ["waveform", "spectrum"] {
            // These pages never report CH Auto (LP-700-Server PR #9).
            let c = try controls(autoChannel: false, page: page)
            XCTAssertFalse(c.channelDisabled, "\(page): CH picks the page's own CH 1-4")
            XCTAssertTrue(c.rangeDisabled, "\(page): F3 is V/div or dB range here")
            XCTAssertTrue(c.alarmDisabled, "\(page): F4 is sweep or span here")
            XCTAssertTrue(c.peakDisabled, "\(page): F5 is style or averaging here")
            XCTAssertNotNil(c.lockNote, "\(page): the greyed buttons stay in place, so say why")

            let keys = PageKeys.make(try snapshot(autoChannel: false, page: page))
            XCTAssertEqual(keys.lock, .samplePage)
        }
    }

    func testSetupPageLocksEveryKeyButMode() throws {
        let c = try controls(autoChannel: false, page: "setup")
        XCTAssertTrue(c.channelDisabled)
        XCTAssertTrue(c.rangeDisabled, "F3 scrolls the setup list")
        XCTAssertTrue(c.alarmDisabled, "F4 is Adj Dn: it would change the selected setting")
        XCTAssertTrue(c.peakDisabled, "F5 is Adj Up: it would change the selected setting")
        XCTAssertNotNil(c.lockNote, "the Power/SWR view shows Setup, so say why it is locked")
    }

    func testNoSnapshotBehavesLikePowerSWR() {
        let keys = PageKeys.make(nil)
        XCTAssertTrue(keys.channel && keys.range && keys.alarm && keys.peak)
        XCTAssertNil(keys.lock)
    }
}
