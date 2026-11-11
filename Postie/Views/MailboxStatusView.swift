import SwiftUI

/// A stable place for background work, outside the selectable rows.
struct MailboxStatusView: View {
    let count: Int
    let isLoading: Bool
    let isLoadingMore: Bool
    let isSearching: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var activity: String? {
        guard isLoading else { return nil }
        if isLoadingMore { return String(localized: "Loading more…") }
        return isSearching ? String(localized: "Searching…") : String(localized: "Updating…")
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if count == 1 { Text("1 conversation") }
                else { Text("\(count) conversations") }
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            ZStack(alignment: .trailing) {
                if let activity {
                    MailActivityIndicator(title: activity)
                        .id(activity)
                        .transition(.opacity)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(height: 18)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: activity)
    }
}

#Preview("Updating") {
    MailboxStatusView(count: 24, isLoading: true, isLoadingMore: false, isSearching: false)
        .frame(width: 330)
}
