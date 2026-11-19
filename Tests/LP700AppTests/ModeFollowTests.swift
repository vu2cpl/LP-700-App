import XCTest
@testable import LP700App

/// The app's view follows the meter's LCD page, and an LCD Mode press
/// from the app presses the meter's Mode key once more only if it lands
/// on the Setup page.
final class ModeFollowTests: XCTestCase {

    func testActiveViewFollowsTopMode() {
        XCTAssertEqual(MeterViewModel.activeView(for: .powerSWR), .powerSWR)
        XCTAssertEqual(MeterViewModel.activeView(for: .waveform), .waveform)
        XCTAssertEqual(MeterViewModel.activeView(for: .spectrum), .spectrum)
        // Setup has no view of its own.
        XCTAssertEqual(MeterViewModel.activeView(for: .setup), .powerSWR)
    }

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    func testNoPressNoExtraStep() {
        var tracker = ModeStepTracker()
        XCTAssertFalse(tracker.observe(.setup, at: t0))
    }

    func testThreePageCycleNeedsNoExtraStep() {
        // LP-500 user guide: Spectrum → Mode → Power/SWR.
        var tracker = ModeStepTracker()
        tracker.didSendModeStep(from: .spectrum, at: t0)
        XCTAssertFalse(tracker.observe(.spectrum, at: t0 + 0.1), "page not changed yet")
        XCTAssertFalse(tracker.observe(.powerSWR, at: t0 + 0.2))
        // Settled: a later Setup page is the operator's, not ours.
        XCTAssertFalse(tracker.observe(.setup, at: t0 + 0.5))
    }

    func testLandingOnSetupSendsOneMorePress() {
        var tracker = ModeStepTracker()
        tracker.didSendModeStep(from: .spectrum, at: t0)
        XCTAssertFalse(tracker.observe(.spectrum, at: t0 + 0.1))
        XCTAssertTrue(tracker.observe(.setup, at: t0 + 0.2))
        // Only once.
        XCTAssertFalse(tracker.observe(.setup, at: t0 + 0.3))
    }

    func testPressFromSetupIsNotSkippedAgain() {
        // Mode from Setup returns to Power/SWR; nothing extra to do.
        var tracker = ModeStepTracker()
        tracker.didSendModeStep(from: .setup, at: t0)
        XCTAssertFalse(tracker.observe(.setup, at: t0 + 0.1))
        XCTAssertFalse(tracker.observe(.powerSWR, at: t0 + 0.2))
    }

    func testStalePressIsDropped() {
        var tracker = ModeStepTracker()
        tracker.didSendModeStep(from: .waveform, at: t0)
        XCTAssertFalse(tracker.observe(.setup, at: t0 + ModeStepTracker.window + 0.1))
    }
}
