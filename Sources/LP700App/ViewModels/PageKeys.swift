import Foundation

/// Which of the meter's keys the app may press on the LCD page the meter
/// is showing.
///
/// Every control the app offers is a raw key press (LP-700-Server
/// `EncodeCommand`: LCD Mode = F1, CH = F2, Range = F3, Alarm = F4,
/// Peak/Avg/Tune = F5), and the meter gives F2–F5 a different job on each
/// page (LP-500 user guide v5.4):
///
/// | key | Power/SWR     | Waveform   | Spectrum  | Setup    |
/// |-----|---------------|------------|-----------|----------|
/// | F2  | CH            | its own CH | its own CH| CH being adjusted |
/// | F3  | Range         | V/div      | dB range  | Scroll   |
/// | F4  | Alarm         | Sweep      | Span      | Adj Dn   |
/// | F5  | Peak/Avg/Tune | Wfm Style  | Averaging | Adj Up   |
///
/// So a Range press on the Waveform page changed V/div (bench,
/// 2026-11-19), and on the Setup page Alarm or Peak/Avg/Tune would change
/// whichever setting is selected, such as the coupler type. The server
/// does not report V/div, sweep, span or the setup values, so the app
/// could not even show what such a press did. It offers each key only
/// where it means what the button says. LCD Mode (F1) is always allowed:
/// it is how the operator leaves any page.
struct PageKeys: Equatable {
    enum Lock: Equatable {
        /// Power/SWR in CH Auto. Range and Alarm are per channel and
        /// "can't be changed when the CH button is in Auto" (user guide;
        /// bench-tested 2026-10-13).
        case chAuto
        /// Waveform or Spectrum: only CH (that page's own CH 1–4) is safe.
        case samplePage
        /// Setup: F2–F5 select and adjust settings.
        case setupPage
    }

    var channel: Bool
    var range: Bool
    var alarm: Bool
    var peak: Bool
    var lock: Lock?

    static func make(_ snapshot: Snapshot?) -> PageKeys {
        switch snapshot?.topMode {
        case .waveform, .spectrum:
            return PageKeys(channel: true, range: false, alarm: false, peak: false, lock: .samplePage)
        case .setup:
            return PageKeys(channel: false, range: false, alarm: false, peak: false, lock: .setupPage)
        case .powerSWR, nil:
            if snapshot?.autoChannel == true {
                return PageKeys(channel: true, range: false, alarm: false, peak: true, lock: .chAuto)
            }
            return PageKeys(channel: true, range: true, alarm: true, peak: true, lock: nil)
        }
    }

    /// One line under the Controls card when buttons on it are locked.
    var cardNote: String? {
        switch lock {
        case .chAuto: return "Range and Alarm can't be changed in CH Auto. Pick CH 1–4."
        case .samplePage: return "Rng, Mode and Alm work on the Power/SWR page only."
        case .setupPage: return "In Setup the meter's keys change settings. Mode (below) goes back."
        case nil: return nil
        }
    }
}
