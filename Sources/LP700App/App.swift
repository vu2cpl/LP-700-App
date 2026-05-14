import SwiftUI
import AppKit
#if canImport(UserNotifications)
import UserNotifications
#endif

@main
struct LP700App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var vm = MeterViewModel()
    @AppStorage("serverURL") private var serverURL: String = ""
    @AppStorage("menuBarItemEnabled") private var menuBarEnabled: Bool = true

    var body: some Scene {
        // `id: "main"` lets `Environment(\.openWindow)` reach this scene
        // by name from the MenuBarExtra popover. Without an id, the
        // popover's "Show LP-700 Window" button could only `NSApp.activate`
        // — which is a no-op when the window has already been closed.
        WindowGroup(id: "main") {
            ContentView(vm: vm)
                .background(OpenPrefsCapture())
                .task { await bootstrap() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    if vm.connection == .connected { vm.resync() }
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    Task {
                        if let u = URL(string: serverURL), u.host?.isEmpty == false {
                            await vm.reconnect(serverURL: u)
                        }
                    }
                }
        }
        .commands { menuCommands }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 400, height: 580)

        Settings {
            PreferencesView(vm: vm)
        }

        MenuBarExtra(isInserted: $menuBarEnabled) {
            // MenuBarContent reaches `\.openWindow` from its own
            // environment — which lives inside the MenuBarExtra scene
            // and so has access to the SwiftUI window registry. That's
            // how it can re-open the main window after the user has
            // closed it (when the app stays alive thanks to the
            // menu-bar item being enabled).
            MenuBarContent(
                vm: vm,
                onConnect: { vm.connectionSheetOpen = true },
                onQuit: { NSApp.terminate(nil) }
            )
        } label: {
            MenuBarLabel(vm: vm)
        }
        .menuBarExtraStyle(.window)
    }

    private func bootstrap() async {
        requestNotificationPermission()
        if let url = URL(string: serverURL), url.host?.isEmpty == false {
            await vm.start(serverURL: url)
        } else {
            // First launch — open the Connect sheet automatically.
            vm.connectionSheetOpen = true
        }
        // Screenshot/debug launch flags. Used by docs/screenshots regeneration.
        // `open -a LP-700-App --args --open-setup` flips the SETUP overlay on
        // immediately after bootstrap so the docs script can capture it
        // without UI scripting / accessibility permission. Same idea for
        // `--open-prefs`, which dispatches the standard Settings selector.
        if CommandLine.arguments.contains("--open-setup") {
            vm.setupOpen = true
            await vm.refreshLogLevel()
        }
        // `--open-prefs` triggering is wired through the SwiftUI
        // openSettings environment action, captured in OpenPrefsCapture
        // below — macOS 14+ removed the legacy showSettingsWindow: action
        // selector path.
    }

    private func requestNotificationPermission() {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    @CommandsBuilder
    private var menuCommands: some Commands {
        CommandGroup(replacing: .newItem) { }

        CommandGroup(after: .appSettings) {
            Button("Connect to Server…") { vm.connectionSheetOpen = true }
                .keyboardShortcut("k", modifiers: [.command])
            Button(vm.connection == .connected ? "Disconnect" : "Reconnect") {
                if vm.connection == .connected {
                    Task { await vm.disconnect() }
                } else if let url = URL(string: serverURL), url.host?.isEmpty == false {
                    Task { await vm.reconnect(serverURL: url) }
                } else {
                    vm.connectionSheetOpen = true
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }

        CommandMenu("Meter") {
            Button("Step Range") { vm.sendRangeStep() }
                .keyboardShortcut("r", modifiers: [.command])
            Divider()
            Button("Peak Hold") { vm.sendPeakToggle(0) }
                .keyboardShortcut("1", modifiers: [.command, .shift])
            Button("Average") { vm.sendPeakToggle(1) }
                .keyboardShortcut("2", modifiers: [.command, .shift])
            Button("Tune") { vm.sendPeakToggle(2) }
                .keyboardShortcut("3", modifiers: [.command, .shift])
            Divider()
            Button("Toggle Alarm") { vm.sendAlarmToggle() }
                .keyboardShortcut("a", modifiers: [.command])
            Button("Step LCD Mode") { vm.sendModeStep() }
                .keyboardShortcut("m", modifiers: [.command])
            Divider()
            Button("Resync") { vm.resync() }
                .keyboardShortcut("y", modifiers: [.command])
            Button(vm.setupOpen ? "Close Setup" : "Open Setup") { vm.toggleSetup() }
                .keyboardShortcut(".", modifiers: [.command])
        }
    }

}

// Invisible helper that pops the Settings window when `--open-prefs` is
// on argv, so the screenshot driver can capture Preferences without
// needing Accessibility permission for `osascript` keystroke.
//
// Selector-based dispatch is used here rather than SwiftUI's
// `\.openSettings` environment value: the latter is macOS 14+ only and
// the older Xcode SDK on GitHub's `macos-14` runner refuses to resolve
// the key path even inside an `@available` guard, breaking CI. Both
// `showSettingsWindow:` (macOS 14+) and `showPreferencesWindow:`
// (macOS 13) are tried — sendAction returns false cleanly when the
// selector isn't wired up. On macOS 26+ where Apple removed both action
// selectors, regenerate the screenshot manually with ⌘, instead.
private struct OpenPrefsCapture: View {
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                guard CommandLine.arguments.contains("--open-prefs") else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    NSApp.activate(ignoringOtherApps: true)
                    if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                        _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    }
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let menuBar = UserDefaults.standard.object(forKey: "menuBarItemEnabled") as? Bool ?? true
        return !menuBar
    }
}
