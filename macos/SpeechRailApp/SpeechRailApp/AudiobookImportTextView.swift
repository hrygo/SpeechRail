import AppKit
import SwiftUI

/// AppKit owns both scrolling and selectable text layout. The document's changing
/// height must not feed back into the SwiftUI sheet's size during a layout switch.
struct AudiobookImportTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        updateText(in: scrollView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func makeScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityLabel("书稿正文预览")
        scrollView.documentView = textView
        updateText(in: scrollView)
        return scrollView
    }

    func updateText(in scrollView: NSScrollView) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else { return }
        // Unrelated sheet updates must preserve selection and scroll position.
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
