import SwiftUI

// Reusable panel with a regularMaterial background. Mirrors the
// `regularMaterial` panels used by LP-100A-App to keep the two clients
// visually consistent.
struct Panel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
    }
}

struct PanelHeader: View {
    var title: String
    var trailing: AnyView?

    init(title: String, trailing: AnyView? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.12 * 11)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            if let trailing { trailing }
        }
    }
}
