import AppKit
import SwiftUI

/// SwiftUI can leave NSTableView's estimated row height cached after a new cell is populated.
/// Invalidate only stale measurements; the table's delegate still determines the actual height.
struct NativeListRowSizing: NSViewRepresentable {
    func makeNSView(context: Context) -> SizingView { SizingView() }

    func updateNSView(_ view: SizingView, context: Context) {
        view.scheduleSizingCheck()
    }

    final class SizingView: NSView {
        private var checkScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleSizingCheck()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleSizingCheck()
        }

        override func setFrameSize(_ newSize: NSSize) {
            let changed = frame.size != newSize
            super.setFrameSize(newSize)
            if changed { scheduleSizingCheck() }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func scheduleSizingCheck() {
            guard !checkScheduled else { return }
            checkScheduled = true
            // Wait until cell construction/layout finishes; don't invalidate during a table update.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.checkScheduled = false
                self.invalidateStaleHeight()
            }
        }

        private func invalidateStaleHeight() {
            guard window != nil, bounds.height > 0 else { return }
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    let row = table.row(for: self)
                    guard row >= 0, row < table.numberOfRows,
                          abs(table.rect(ofRow: row).height - bounds.height) > 1 else { return }
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
