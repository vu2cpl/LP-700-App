import SwiftUI
import AppKit

// First-launch / reconfiguration sheet. Shown automatically when no
// server URL is configured, and on demand from the toolbar shield button.
struct ConnectionSheet: View {
    @ObservedObject var vm: MeterViewModel
    @AppStorage("serverURL") private var persistedURL: String = ""

    @State private var urlString: String = ""
    @State private var testStatus: TestStatus = .idle
    @State private var testTask: Task<Void, Never>?
    var onDismiss: () -> Void

    enum TestStatus: Equatable {
        case idle
        case running
        case ok
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                fieldSection
                hintSection
            }
            .padding(20)

            Divider()

            footer
        }
        .frame(width: 480)
        .onAppear {
            urlString = vm.serverURLString.nilIfEmpty
                ?? persistedURL.nilIfEmpty
                ?? "http://localhost:8089"
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("Connect to LP-700 Server")
                    .font(.headline)
                Text("Enter the URL of your LP-500 / LP-700 WebSocket bridge.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var fieldSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Server URL")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("http://host:8089", text: $urlString, onCommit: connect)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .onChange(of: urlString) { _ in testStatus = .idle }

            HStack(spacing: 8) {
                Button(action: test) {
                    HStack(spacing: 4) {
                        if testStatus == .running {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "wave.3.right")
                                .foregroundStyle(.secondary)
                        }
                        Text("Test connection")
                    }
                }
                .disabled(testStatus == .running || urlString.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()

                statusLabel
            }
        }
    }

    @ViewBuilder
    private var hintSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tip")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text("On the server host: `lp700-server` listens on port 8089 by default (LP-100A-Server uses 8088). Use http://localhost:8089 if running on this Mac, or http://raspberrypi.local:8089 for a Pi on the LAN.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var footer: some View {
        HStack {
            if vm.connection != .disconnected || vm.hasConfiguredServer {
                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            Spacer()
            Button(action: connect) {
                Text("Connect")
                    .frame(minWidth: 80)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(urlString.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch testStatus {
        case .idle: EmptyView()
        case .running:
            Text("Probing…").font(.caption).foregroundStyle(.secondary)
        case .ok:
            Label("Reachable", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
    }

    private func test() {
        testTask?.cancel()
        testStatus = .running
        let candidate = urlString
        let model = vm
        testTask = Task { @MainActor in
            let result = await model.testConnection(urlString: candidate)
            switch result {
            case .ok: testStatus = .ok
            case .failure(let msg): testStatus = .failure(msg)
            }
        }
    }

    private func connect() {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.host?.isEmpty == false else {
            testStatus = .failure("Invalid URL")
            return
        }
        persistedURL = trimmed
        Task {
            await vm.reconnect(serverURL: url)
            onDismiss()
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
