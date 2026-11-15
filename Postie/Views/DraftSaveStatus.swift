import SwiftUI

struct DraftSaveStatus: View {
    let session: DraftSession
    let draft: ComposeDraft
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch session.state {
            case .idle:
                Text("Drafts save automatically")
            case .saving:
                ProgressView().controlSize(.mini)
                Text(session.isSavedLocally(draft) ? String(localized: "Saved on this Mac · Syncing…") : String(localized: "Saving…"))
            case .savedLocally:
                Text("Saved on this Mac · Complete recipient addresses to sync")
            case .saved:
                Text(session.isSaved(draft) ? String(localized: "Saved to Gmail") : String(localized: "Unsaved changes"))
            case .failed(let error):
                Label(session.isSavedLocally(draft) ? String(localized: "Saved on this Mac · Gmail sync failed")
                      : String(localized: "Couldn’t save draft"), systemImage: "exclamationmark.triangle")
                    .help(error)
                Button("Retry", action: retry).buttonStyle(.link)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Divider() }
    }
}
