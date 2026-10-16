import AppKit
import SwiftUI

/// The original concept gallery intentionally shows different native window
/// aspect ratios for dashboard/inspector vs compact utility workspaces.
/// Apply recommended sizes only when the workspace tab changes. Users may
/// still resize a window manually without this view fighting their gesture.
private final class ReferenceWindowSizingView: NSView {
    var requestedSize: CGSize = .zero {
        didSet { resizeIfNeeded() }
    }
    private var appliedSize: CGSize = .zero

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resizeIfNeeded()
    }

    private func resizeIfNeeded() {
        guard let window,
              requestedSize.width >= 810,
              requestedSize.height >= 400,
              requestedSize != appliedSize else { return }
        appliedSize = requestedSize
        let desired = requestedSize
        // Deferring avoids changing the NSWindow frame while SwiftUI is
        // resolving the current layout proposal.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            let oldFrame = window.frame
            var newFrame = oldFrame
            newFrame.size = window.frameRect(forContentRect:
                NSRect(origin: .zero, size: desired)).size
            newFrame.origin.y = oldFrame.maxY - newFrame.height
            if let visible = window.screen?.visibleFrame {
                if newFrame.maxX > visible.maxX {
                    newFrame.origin.x = max(visible.minX, visible.maxX - newFrame.width)
                }
                if newFrame.minY < visible.minY {
                    newFrame.origin.y = visible.minY
                }
            }
            window.setFrame(newFrame, display: true, animate: false)
        }
    }
}

struct ReferenceWindowSizer: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> ReferenceWindowSizingView {
        let view = ReferenceWindowSizingView()
        view.requestedSize = size
        return view
    }

    func updateNSView(_ view: ReferenceWindowSizingView, context: Context) {
        view.requestedSize = size
    }
}
