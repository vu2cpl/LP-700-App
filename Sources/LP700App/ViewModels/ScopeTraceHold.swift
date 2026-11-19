import Foundation

/// Keeps the last clean waveform trace on screen through the meter's
/// capture glitches.
///
/// The server reads a scope trace from the meter as five 64-sample
/// segments, one per poll. The meter re-arms its capture now and then
/// while those reads are under way, so during TX some frames come back
/// all zero, or torn: part of one capture and part of the next (bench,
/// 2026-11-19: about a quarter of the frames while keyed, for example
/// `[174, 0, 0, 0, 0]` or `[0, 174, 174, 174, 174]` as segment maxima).
/// Drawn as they come, the trace blinks.
///
/// A real envelope is smooth. Across every captured frame, neighbouring
/// samples never differ by more than 1 inside a segment or across a
/// segment edge, and a decay to zero runs down gradually (43 → 42 at
/// the edge). A torn frame jumps at a segment edge instead (0 → 174,
/// 28 → 0, 57 → 15). So a frame is a glitch if it is all zero or jumps
/// by more than `edgeJump` at a segment edge. A glitch keeps the last
/// clean trace on screen for up to `window`, after which whatever
/// arrives is shown, so a real key-up still goes flat within a second.
///
/// Waveform only: spectrum bins are not smooth, so the edge rule does not
/// apply there, and no spectrum glitches were seen.
struct ScopeTraceHold {
    static let window: TimeInterval = 1
    static let segment = 64
    static let edgeJump = 8

    private var lastCleanAt: Date?

    /// Returns true when `samples` should replace the trace on screen.
    mutating func accept(_ samples: [UInt8], at now: Date) -> Bool {
        if !Self.isGlitch(samples) {
            lastCleanAt = now
            return true
        }
        guard let clean = lastCleanAt, now.timeIntervalSince(clean) <= Self.window else {
            return true
        }
        return false
    }

    static func isGlitch(_ samples: [UInt8]) -> Bool {
        if !samples.contains(where: { $0 != 0 }) { return true }
        var edge = segment
        while edge < samples.count {
            if abs(Int(samples[edge - 1]) - Int(samples[edge])) > edgeJump { return true }
            edge += segment
        }
        return false
    }
}
