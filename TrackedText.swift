// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// A text view that reports a double-click, with the character position under the pointer, after the
/// system has selected the word.
final class TrackedTextView: NSTextView {
    var onDoubleClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2, string.utf16.count > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        onDoubleClick?(min(index, string.utf16.count - 1))
    }
}

/// What both text panes share: the highlight of the sentence being played, scrolling to keep it in view
/// while the user is following the playback, and noticing when the user scrolls by hand.
final class TrackingCoordinator: NSObject {
    var applied = 0                  // how many parts of the text have been appended
    var onUserScroll: (() -> Void)?
    var onDoubleClick: ((Int) -> Void)?
    private var lastHighlight: NSRange?
    private var lastFollow = false
    private var observer: NSObjectProtocol?

    static let highlightColor = NSColor.systemYellow.withAlphaComponent(0.32)

    /// Builds the scrollable text view both panes use.
    func makeScrollView() -> (NSScrollView, TrackedTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = TrackedTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.font = NSFont.preferredFont(forTextStyle: .body)
        view.textColor = .textColor
        view.textContainerInset = NSSize(width: 4, height: 8)
        view.onDoubleClick = { [weak self] i in self?.onDoubleClick?(i) }
        scroll.documentView = view
        // Only a scroll made by the user sends this; scrolling the app does itself does not.
        observer = NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification,
                                                          object: scroll, queue: .main) { [weak self] _ in self?.onUserScroll?() }
        return (scroll, view)
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// Shows the highlight, and brings it into view when following. A change of highlight, or following being
    /// switched on, scrolls; a repeat of the same state does nothing.
    func update(_ scroll: NSScrollView, _ view: NSTextView, highlight: NSRange?, follow: Bool) {
        let length = view.textStorage?.length ?? 0
        guard let layout = view.layoutManager else { return }
        var range = highlight
        if let r = range, r.location + r.length > length { range = length > r.location ? NSRange(location: r.location, length: length - r.location) : nil }
        if range != lastHighlight {
            if let old = lastHighlight, old.location + old.length <= length {
                layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: old)
            }
            if let r = range { layout.addTemporaryAttribute(.backgroundColor, value: Self.highlightColor, forCharacterRange: r) }
            let changed = range != nil
            lastHighlight = range
            if follow && changed { reveal(range!, scroll, view) }
        } else if follow && !lastFollow, let r = range {
            reveal(r, scroll, view)
        }
        lastFollow = follow
    }

    private func reveal(_ range: NSRange, _ scroll: NSScrollView, _ view: NSTextView) {
        guard let layout = view.layoutManager, let container = view.textContainer else { return }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.y += view.textContainerOrigin.y
        let clip = scroll.contentView
        let visible = clip.bounds
        // Move only when the sentence is near the edge of the view or out of it.
        guard rect.minY < visible.minY + visible.height * 0.12 || rect.maxY > visible.maxY - visible.height * 0.30 else { return }
        let maxY = max(0, view.frame.height - visible.height)
        let y = min(max(0, rect.minY - visible.height * 0.30), maxY)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            clip.animator().setBoundsOrigin(NSPoint(x: visible.origin.x, y: y))
        }
        scroll.reflectScrolledClipView(clip)
    }
}

/// A native, scrollable, selectable text view that cannot be edited. New text is appended in place, so a
/// reader who is scrolling is not moved and the whole text is not laid out again.
struct ReadOnlyText: NSViewRepresentable {
    let text: String
    var highlight: NSRange? = nil
    var follow = false
    var onDoubleClick: ((Int) -> Void)? = nil
    var onUserScroll: (() -> Void)? = nil

    func makeCoordinator() -> TrackingCoordinator { TrackingCoordinator() }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeScrollView().0 }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        let coordinator = context.coordinator
        coordinator.onDoubleClick = onDoubleClick
        coordinator.onUserScroll = onUserScroll
        let current = view.string
        if current != text {
            if text.hasPrefix(current), let storage = view.textStorage {
                storage.append(NSAttributedString(string: String(text.dropFirst(current.count)),
                                                  attributes: [.font: view.font as Any, .foregroundColor: NSColor.textColor]))
            } else {
                view.string = text
            }
        }
        coordinator.update(scroll, view, highlight: highlight, follow: follow)
    }
}

/// The polished text: scrollable and selectable, but not editable. New paragraphs are appended in place, and
/// those kept as transcribed are shown in orange.
struct PolishedText: NSViewRepresentable {
    let parts: [PolishPart]
    var highlight: NSRange? = nil
    var follow = false
    var onDoubleClick: ((Int) -> Void)? = nil
    var onUserScroll: (() -> Void)? = nil

    func makeCoordinator() -> TrackingCoordinator { TrackingCoordinator() }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeScrollView().0 }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        let coordinator = context.coordinator
        coordinator.onDoubleClick = onDoubleClick
        coordinator.onUserScroll = onUserScroll
        if parts.count < coordinator.applied {
            view.string = ""
            coordinator.applied = 0
        }
        if let storage = view.textStorage {
            while coordinator.applied < parts.count {
                let part = parts[coordinator.applied]
                storage.append(NSAttributedString(
                    string: (coordinator.applied > 0 ? "\n\n" : "") + part.text,
                    attributes: [.font: view.font as Any, .foregroundColor: part.fallback ? NSColor.systemOrange : NSColor.textColor]))
                coordinator.applied += 1
            }
        }
        coordinator.update(scroll, view, highlight: highlight, follow: follow)
    }
}
