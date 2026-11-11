import SwiftUI

/// Fast operations finish without flashing a spinner. Content is never held back for the indicator.
struct MailActivityIndicator: View {
    let title: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .opacity(isVisible ? 1 : 0)
        .accessibilityHidden(!isVisible)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isVisible)
        .task {
            do {
                try await Task.sleep(for: .milliseconds(180))
                try Task.checkCancellation()
                isVisible = true
            } catch {
                // Disappearing indicators must not update a replacement loading state.
            }
        }
    }
}

#Preview("Loading") {
    MailActivityIndicator(title: String(localized: "Loading mail…"))
        .frame(width: 330, height: 240)
}
