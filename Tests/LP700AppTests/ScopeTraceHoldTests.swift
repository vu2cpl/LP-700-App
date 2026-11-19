import XCTest
@testable import LP700App

/// Pins how the Waveform view rides through the meter's capture glitches.
/// The frame shapes copy the ones seen on the bench (2026-11-19, LP-700,
/// carrier keyed): segment maxima such as [174, 0, 0, 0, 0] for a torn
/// frame and [77, 42, 11, 0, 0] for a real decay.
final class ScopeTraceHoldTests: XCTestCase {

    private func frame(_ value: (Int) -> Int) -> [UInt8] {
        (0..<320).map { UInt8(clamping: value($0)) }
    }

    // Real shapes: smooth, neighbouring samples differ by at most 1.
    private var carrier: [UInt8] { frame { _ in 174 } }
    private var attack: [UInt8] { frame { 85 + $0 * 88 / 319 } }
    private var decay: [UInt8] { frame { max(0, 77 - $0 * 77 / 200) } }

    // Glitches.
    private var empty: [UInt8] { frame { _ in 0 } }
    private var tornHead: [UInt8] { frame { $0 < 64 ? 174 : 0 } }          // [174, 0, 0, 0, 0]
    private var tornTail: [UInt8] { frame { $0 < 64 ? 0 : 174 } }          // [0, 174, 174, 174, 174]
    private var tornMid: [UInt8] { frame { $0 < 64 ? $0 * 57 / 63 : 15 + ($0 - 64) / 8 } } // edge 57 -> 15

    func testRealShapesAreClean() {
        XCTAssertFalse(ScopeTraceHold.isGlitch(carrier))
        XCTAssertFalse(ScopeTraceHold.isGlitch(attack))
        XCTAssertFalse(ScopeTraceHold.isGlitch(decay), "a decay to zero runs down across segment edges")
    }

    func testEmptyAndTornFramesAreGlitches() {
        XCTAssertTrue(ScopeTraceHold.isGlitch(empty))
        XCTAssertTrue(ScopeTraceHold.isGlitch(tornHead))
        XCTAssertTrue(ScopeTraceHold.isGlitch(tornTail))
        XCTAssertTrue(ScopeTraceHold.isGlitch(tornMid))
    }

    func testGlitchesHoldTheLastCleanTraceForOneSecond() {
        var hold = ScopeTraceHold()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(hold.accept(carrier, at: t0))
        XCTAssertFalse(hold.accept(empty, at: t0 + 0.25), "an empty frame mid-TX keeps the trace")
        XCTAssertFalse(hold.accept(tornHead, at: t0 + 0.5), "a torn frame keeps the trace")
        XCTAssertTrue(hold.accept(decay, at: t0 + 0.75), "a clean frame always replaces it")
        XCTAssertFalse(hold.accept(empty, at: t0 + 1.0))
        XCTAssertTrue(hold.accept(empty, at: t0 + 1.8), "after key-up the trace goes flat within a second")
        XCTAssertTrue(hold.accept(empty, at: t0 + 2.0))
    }

    func testIdleWithNoCleanFrameShowsWhatArrives() {
        var hold = ScopeTraceHold()
        XCTAssertTrue(hold.accept(empty, at: Date(timeIntervalSince1970: 1_000)))
    }
}
