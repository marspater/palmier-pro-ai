import SwiftUI

struct TimelineContainerView: NSViewRepresentable {
    @Environment(EditorViewModel.self) var editor

    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        let headerView = TimelineHeaderView(editor: editor)
        headerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerView)

        let scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.horizontalScroller?.controlSize = .mini
        scrollView.verticalScroller?.controlSize = .mini

        let timelineView = TimelineView(editor: editor)
        timelineView.autoresizingMask = []
        scrollView.documentView = timelineView
        headerView.requestCanvasRedraw = { [weak timelineView] in timelineView?.needsDisplay = true }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = AppTheme.Border.primary.cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(border)

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerView.topAnchor.constraint(equalTo: container.topAnchor),
            headerView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            headerView.widthAnchor.constraint(equalToConstant: Layout.trackHeaderWidth),

            scrollView.leadingAnchor.constraint(equalTo: headerView.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            border.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            border.topAnchor.constraint(equalTo: container.topAnchor),
            border.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            border.widthAnchor.constraint(equalToConstant: 1)
        ])

        context.coordinator.headerView = headerView
        context.coordinator.timelineView = timelineView
        context.coordinator.scrollView = scrollView
        context.coordinator.editor = editor

        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipViewFrameChanged),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let renderState = RenderState(
            revision: editor.timelineRenderRevision,
            zoomScale: editor.zoomScale,
            selectedClipIds: editor.selectedClipIds,
            selectedTimelineRange: editor.selectedTimelineRange,
            pendingReplacements: editor.pendingReplacements,
            generatingAssetIds: Set(editor.mediaAssets.lazy.filter(\.isGenerating).map(\.id))
        )

        if context.coordinator.needsRender(for: renderState) {
            context.coordinator.timelineView?.updateContentSize()
            context.coordinator.timelineView?.needsDisplay = true
            context.coordinator.headerView?.needsDisplay = true
        }

        if let x = editor.timelineScrollRestoreX,
           let scrollView = context.coordinator.scrollView {
            let y = scrollView.contentView.bounds.origin.y
            scrollView.contentView.setBoundsOrigin(NSPoint(x: max(0, x), y: y))
            DispatchQueue.main.async { editor.timelineScrollRestoreX = nil }
        }

        if editor.isPlaying,
           let timelineView = context.coordinator.timelineView,
           let scrollView = context.coordinator.scrollView {
            let geo = timelineView.geometry
            let playheadX = geo.xForFrame(editor.activeFrame)
            let visibleRect = scrollView.contentView.bounds
            let margin: CGFloat = 60

            if playheadX < visibleRect.origin.x + margin ||
               playheadX > visibleRect.origin.x + visibleRect.width - margin {
                let newOriginX = max(0, playheadX - visibleRect.width * 0.25)
                scrollView.contentView.setBoundsOrigin(
                    NSPoint(x: newOriginX, y: visibleRect.origin.y)
                )
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    struct RenderState: Equatable {
        let revision: Int
        let zoomScale: Double
        let selectedClipIds: Set<String>
        let selectedTimelineRange: TimelineRangeSelection?
        let pendingReplacements: Set<String>
        let generatingAssetIds: Set<String>
    }

    final class Coordinator: NSObject {
        var headerView: TimelineHeaderView?
        var timelineView: TimelineView?
        var scrollView: NSScrollView?
        weak var editor: EditorViewModel?
        private var renderState: RenderState?

        func needsRender(for next: RenderState) -> Bool {
            defer { renderState = next }
            return renderState != next
        }

        @MainActor @objc func scrollViewBoundsChanged(_ notification: Notification) {
            timelineView?.needsDisplay = true
            timelineView?.updatePlayheadLayer()
            if let scrollX = scrollView?.contentView.bounds.origin.x {
                editor?.timelineScrollOffsetX = scrollX
            }
            if let scrollY = scrollView?.contentView.bounds.origin.y {
                headerView?.setBoundsOrigin(NSPoint(x: 0, y: scrollY))
                headerView?.needsDisplay = true
            }
        }

        @MainActor @objc func clipViewFrameChanged(_ notification: Notification) {
            timelineView?.updateContentSize()
            timelineView?.updatePlayheadLayer()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
