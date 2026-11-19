import XCTest
@testable import LP700App

/// The Spectrum page's power strip shows Pwr and dBm like the meter's LCD
/// (bench 2026-11-19: 185 W showed as +52 dBm, 5 W as +37 dBm; the meter
/// drops the decimals, the app keeps one).
final class PowerStripTests: XCTestCase {
    func testDBmMatchesTheMeter() {
        XCTAssertEqual(PowerStrip.formatDBm(185.454).0, "+52.7")
        XCTAssertEqual(PowerStrip.formatDBm(5.148).0, "+37.1")
        XCTAssertEqual(PowerStrip.formatDBm(0.5).0, "+27.0")
        XCTAssertEqual(PowerStrip.formatDBm(185).1, "dBm")
    }

    func testNoPowerShowsADash() {
        XCTAssertEqual(PowerStrip.formatDBm(0).0, "—")
        XCTAssertEqual(PowerStrip.formatDBm(nil).0, "—")
    }
}
