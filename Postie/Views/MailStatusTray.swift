import SwiftUI

/// Transient status floating at the bottom of the conversation list, next to the rows that just changed.
/// It overlays the list, so showing or hiding it never moves anything.
struct MailStatusTray: View {
    let removal: MailRemovalUndo?
    let dismissRemoval: () -> Void
    let queuedNoticeID: UUID?
    let showOutbox: () -> Void
    let dismissQueued: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            if let removal {
                MailUndoNotice(operation: removal, dismiss: dismissRemoval)
                    .id(removal.id)
                    .transition(transition)
            }
            if let queuedNoticeID {
                MailQueuedNotice(showOutbox: showOutbox, dismiss: dismissQueued)
                    .id(queuedNoticeID)
                    .transition(transition)
            }
        }
        .padding(14)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: removal?.id)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: queuedNoticeID)
    }

    private var transition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }
}

/// One card in the tray. It dismisses itself after `timeout`, unless the pointer is over it
/// or the window is inactive, so a notice is never missed. A `nil` timeout keeps it until dismissed.
struct MailStatusCard<Icon: View, Actions: View>: View {
    let message: String
    let timeout: Duration?
    let dismiss: () -> Void
    @ViewBuilder let icon: Icon
    @ViewBuilder let actions: Actions

    @Environment(\.appearsActive) private var appearsActive
    @State private var isHovering = false

    private struct DismissTimer: Hashable {
        let timeout: Duration?
        let isPaused: Bool
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
                .font(.title3)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(message)
                .font(.body)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        // Like a system notification: the close control only appears on hover, out of the way of Undo.
        .overlay(alignment: .topLeading) {
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .font(.caption.weight(.bold))
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .offset(x: -8, y: -8)
                .opacity(isHovering ? 1 : 0)
        }
        .frame(maxWidth: 380)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .onChange(of: message, initial: true) { AccessibilityNotification.Announcement(message).post() }
        .task(id: DismissTimer(timeout: timeout, isPaused: isHovering || !appearsActive)) {
            let timer = DismissTimer(timeout: timeout, isPaused: isHovering || !appearsActive)
            guard let timeout = timer.timeout, !timer.isPaused else { return }
            do { try await Task.sleep(for: timeout) } catch { return }
            dismiss()
        }
    }
}

#Preview("Status cards") {
    VStack(spacing: 8) {
        MailStatusCard(message: "Conversation archived", timeout: nil, dismiss: {}) {
            Image(systemName: "archivebox.fill").foregroundStyle(.secondary)
        } actions: {
            Button("Undo") {}.buttonStyle(.glassProminent).controlSize(.large)
        }
        MailStatusCard(message: "3 conversations moved to Trash", timeout: nil, dismiss: {}) {
            Image(systemName: "trash.fill").foregroundStyle(.secondary)
        } actions: {
            Button("Undo") {}.buttonStyle(.glassProminent).controlSize(.large)
        }
        MailStatusCard(message: "Couldn’t undo: The network connection was lost.", timeout: nil, dismiss: {}) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } actions: {
            Button("Retry Undo") {}.buttonStyle(.glassProminent).controlSize(.large)
        }
        MailStatusCard(message: "Message queued for sending", timeout: nil, dismiss: {}) {
            Image(systemName: "paperplane.fill").foregroundStyle(.secondary)
        } actions: {
            Button("Show Outbox") {}.buttonStyle(.glassProminent).controlSize(.large)
        }
    }
    .padding(20)
    .frame(width: 400, height: 340, alignment: .bottom)
}
