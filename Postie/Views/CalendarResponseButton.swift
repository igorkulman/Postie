import SwiftUI

struct CalendarResponseButton: View {
    let response: CalendarInvitation.Response
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isSelected {
                Button(response.title, systemImage: "checkmark", action: action)
                    .buttonStyle(.borderedProminent)
                    .accessibilityValue("Current response")
                    .accessibilityAddTraits(.isSelected)
            } else {
                Button(response.title, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .disabled(isDisabled)
        .help("Send \(response.status) to the organizer")
    }
}
