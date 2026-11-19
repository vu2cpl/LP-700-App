import SwiftUI

// Bottom-row controls: Range step, alarm toggle, LCD page (Mode) step, sync.
// The Peak/Avg/Tune trio lives in PowerSWRView itself (matching the
// embedded web client), so this row complements rather than duplicates.
struct KeypadView: View {
    @ObservedObject var vm: MeterViewModel

    var body: some View {
        let disabled = !vm.allowControl || vm.connection != .connected || vm.setupOpen
        // Range and Alarm are the meter's F3 / F4. They're locked in CH
        // Auto (LP-500 user guide v5.4; bench-tested 2026-10-13), and on
        // the Waveform, Spectrum and Setup pages those keys do other jobs
        // (V/div, sweep, span, adjusting a setting). See PageKeys. Why a
        // key is locked is said once, in the note under the Controls card.
        let keys = vm.keys

        // The largest title size at which all four buttons fit the row,
        // tried from 15 pt down. One size for all four, always.
        ViewThatFits(in: .horizontal) {
            ForEach(Self.titleSizes, id: \.self) { size in
                row(keys: keys, size: size)
            }
        }
        .disabled(disabled)
        .overlay(alignment: .trailing) {
            if !vm.allowControl {
                Label("Read-only", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
            }
        }
    }

    private func row(keys: PageKeys, size: CGFloat) -> some View {
        HStack(spacing: 10) {
            keyButton(title: "Range",
                      systemImage: "arrow.triangle.2.circlepath",
                      size: size,
                      action: { vm.sendRangeStep() })
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!keys.range)

            keyButton(title: "Alarm",
                      systemImage: alarmIcon,
                      size: size,
                      action: { vm.sendAlarmToggle() })
                .keyboardShortcut("a", modifiers: [.command])
                .disabled(!keys.alarm)

            keyButton(title: "Mode",
                      systemImage: "rectangle.3.offgrid",
                      size: size,
                      action: { vm.sendModeStep() })
                .keyboardShortcut("m", modifiers: [.command])

            keyButton(title: "Sync",
                      systemImage: "arrow.clockwise",
                      size: size,
                      action: { vm.resync() })
                .keyboardShortcut("y", modifiers: [.command])
        }
    }

    private var alarmIcon: String {
        switch vm.snapshot?.alarmEnabled {
        case true: return "bell.fill"
        case false: return "bell.slash"
        default: return "bell"
        }
    }

    // One title line per button, all four the same size (Manoj,
    // 2026-11-19: "all button text has to be same size", as big as the
    // Controls card's "A → 1"). So the titles use the card's value font,
    // 15 pt semibold rounded, and step down a point at a time only when
    // the window is too narrow for all four to fit; `ViewThatFits` picks
    // the size from the row's real width. The small second lines are
    // gone: they repeated the Controls card (range, alarm state), its
    // lock note, and the status row's Top field (the LCD page). Short
    // titles ("Mode", "Sync") leave the most room.
    //
    // The label height never changes, so no title can make a button or
    // the row taller or shorter on some page.
    private static let labelHeight: CGFloat = 24
    private static let titles = ["Range", "Alarm", "Mode", "Sync"]
    static let titleSizes: [CGFloat] = Array(stride(from: 15, through: 11, by: -1))

    private func keyButton(title: String, systemImage: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.85))
                    .frame(width: size)
                // Every button reserves the widest title's room. The row
                // splits its width equally, so a size fits only if the
                // widest title fits a quarter of the row, and that is what
                // ViewThatFits then measures ("Range" was cut off at 15 pt
                // while the row as a whole still fit).
                ZStack {
                    ForEach(Self.titles, id: \.self) { widest in
                        Text(widest).hidden()
                    }
                    Text(title)
                }
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: Self.labelHeight, maxHeight: Self.labelHeight)
            .padding(.vertical, 2)
            .padding(.horizontal, 2)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
