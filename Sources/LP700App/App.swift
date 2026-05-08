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
        WindowGroup {
            ContentView(vm: vm)
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

        Settings {
            PreferencesView(vm: vm)
        }

        MenuBarExtra(isInserted: $menuBarEnabled) {
            MenuBarContent(
                vm: vm,
                onShowMain: { showMainWindow() },
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

    private func showMainWindow() {
        if let win = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && $0.contentView != nil }) {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let menuBar = UserDefaults.standard.object(forKey: "menuBarItemEnabled") as? Bool ?? true
        return !menuBar
    }
}
