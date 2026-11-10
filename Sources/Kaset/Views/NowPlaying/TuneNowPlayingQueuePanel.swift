import SwiftUI

// MARK: - TuneNowPlayingQueue

/// The play queue as the fullscreen view shows it. Built by `TuneNowPlayingHost` from
/// `PlayerService.queueEntries`; pure so it renders from fixtures.
struct TuneNowPlayingQueue: Equatable {
    struct Item: Equatable, Identifiable {
        let id: UUID
        var title: String
        var artist: String
        var thumbnailURL: URL?
        /// Seconds; nil when unknown.
        var duration: TimeInterval?
    }

    var items: [Item] = []
    /// Index of the playing item in `items`; nil when nothing in the queue owns playback.
    var currentIndex: Int?

    static let empty = TuneNowPlayingQueue()

    private var validCurrentIndex: Int? {
        guard let currentIndex, self.items.indices.contains(currentIndex) else { return nil }
        return currentIndex
    }

    /// The whole queue, in order: already-played items stay (dimmed) above the playing one, so
    /// history is one scroll up, like YouTube Music.
    var visibleItems: ArraySlice<Item> {
        self.items[...]
    }

    /// Whether the item already played (sits above the playing one).
    func isPlayed(_ id: UUID) -> Bool {
        guard let current = self.validCurrentIndex,
              let index = self.items.firstIndex(where: { $0.id == id })
        else { return false }
        return index < current
    }

    var currentItemID: UUID? {
        self.validCurrentIndex.map { self.items[$0].id }
    }

    /// Items still to play after the current one.
    var upNextCount: Int {
        guard let current = self.validCurrentIndex else { return self.items.count }
        return self.items.count - current - 1
    }

    /// Where "Play Next" moves `id`: the outer optional is nil when nothing should move (the
    /// item is playing, already next, or missing); the inner value is the entry to insert
    /// before, nil meaning the end of the queue.
    func playNextAnchor(moving id: UUID) -> UUID?? {
        guard let current = self.validCurrentIndex,
              self.items.contains(where: { $0.id == id }),
              self.items[current].id != id
        else { return nil }
        let nextIndex = current + 1
        guard self.items.indices.contains(nextIndex) else { return .some(nil) }
        let nextID = self.items[nextIndex].id
        return nextID == id ? nil : .some(nextID)
    }

    /// Where a drag of `id` dropped onto the row `targetID` lands: the outer optional is nil
    /// when nothing should move; the inner value is the entry to insert before (nil = end).
    /// Dropping on a row inserts above it. Nothing may move above the playing row, so a drop
    /// on the playing row lands right after it. Dropping at the end (`targetID == nil`) appends.
    func dropAnchor(moving id: UUID, onto targetID: UUID?) -> UUID?? {
        guard let sourceIndex = self.items.firstIndex(where: { $0.id == id }) else { return nil }
        if let current = self.validCurrentIndex, sourceIndex == current { return nil }
        guard let targetID else {
            return sourceIndex == self.items.count - 1 ? nil : .some(nil)
        }
        guard let targetIndex = self.items.firstIndex(where: { $0.id == targetID }) else { return nil }
        if let current = self.validCurrentIndex, targetIndex <= current {
            return self.playNextAnchor(moving: id)
        }
        // Dropping on itself, or on the row right below it, changes nothing.
        guard targetIndex != sourceIndex, targetIndex != sourceIndex + 1 else { return nil }
        return .some(targetID)
    }
}

// MARK: - TuneNowPlayingQueuePanel

/// The persistent Up Next pane on the right of the fullscreen view: a floating panel with
/// soft panel-radius corners, a caps header with a mono count, then rows whose hover fill is
/// a rounded control shape. The playing row leads, marked by a 2 pt accent rule (the pane's
/// only orange); played rows are hidden.
struct TuneNowPlayingQueuePanel: View {
    let queue: TuneNowPlayingQueue
    /// The field's artwork-tinted dark; the pane is a deeper scrim of it, never glass.
    let tint: Color
    var onPlay: (UUID) -> Void = { _ in }
    var onPlayNext: (UUID) -> Void = { _ in }
    var onRemove: (UUID) -> Void = { _ in }
    /// Drag to reorder: moves the dragged entry above the target row (nil target = end).
    var onMove: (UUID, UUID?) -> Void = { _, _ in }

    @State private var drag: QueueDrag?

    private typealias Tokens = TuneTheme.NowPlaying

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            Rectangle()
                .fill(TuneTheme.Palette.ink.opacity(Tokens.queueRuleOpacity))
                .frame(height: 1)
                .padding(.horizontal, Tokens.queueInset)
            if self.queue.items.isEmpty {
                Text("Queue is empty")
                    .tuneCapsLabel()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, Tokens.headerTop)
            } else {
                self.list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: TuneTheme.Radius.panel, style: .continuous)
                .fill(self.tint.opacity(Tokens.queueScrimOpacity))
                .overlay {
                    RoundedRectangle(cornerRadius: TuneTheme.Radius.panel, style: .continuous)
                        .strokeBorder(TuneTheme.Palette.ink.opacity(Tokens.queueRuleOpacity), lineWidth: 1)
                }
                .padding(.vertical, Tokens.queuePanelMargin)
                .padding(.trailing, Tokens.queuePanelMargin)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Up Next"))
        .accessibilityIdentifier(TuneNowPlayingAccessibilityID.queuePanel)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Up Next")
                .tuneCapsLabel()
            Spacer(minLength: TuneTheme.Spacing.itemGap)
            Text(verbatim: "\(self.queue.upNextCount)")
                .font(TuneTheme.Typeface.data)
                .foregroundStyle(TuneTheme.Palette.inkMuted)
        }
        .padding(.horizontal, Tokens.queueInset)
        .padding(.top, Tokens.headerTop)
        .padding(.bottom, TuneTheme.Spacing.unit * 3)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(self.queue.visibleItems.enumerated()), id: \.element.id) { index, item in
                        let isCurrent = item.id == self.queue.currentItemID
                        let isDragged = self.drag?.id == item.id
                        TuneNowPlayingQueueRow(
                            item: item,
                            isCurrent: isCurrent,
                            isPlayed: self.queue.isPlayed(item.id),
                            isDragged: isDragged,
                            onPlay: { self.onPlay(item.id) },
                            onPlayNext: { self.onPlayNext(item.id) },
                            onRemove: { self.onRemove(item.id) }
                        )
                        .overlay(alignment: .top) {
                            if self.drag != nil, self.indicatorRowID == item.id {
                                self.dropIndicator
                            }
                        }
                        .offset(y: isDragged ? (self.drag?.translation ?? 0) : 0)
                        .zIndex(isDragged ? 1 : 0)
                        .gesture(self.reorderGesture(for: item, at: index), including: isCurrent ? .subviews : .all)
                        .id(item.id)
                    }
                    // End slot: where a song dragged past the last row lands.
                    Color.clear
                        .frame(height: Tokens.queueRowHeight)
                        .overlay(alignment: .top) {
                            if self.drag != nil, self.indicatorRowID == nil, self.dragTarget != nil {
                                self.dropIndicator
                            }
                        }
                }
                .padding(.top, TuneTheme.Spacing.unit * 2)
                .padding(.bottom, Tokens.footerBottom)
                // The drag measures against the list, not the moving row (no feedback loop).
                .coordinateSpace(.named(Self.listSpace))
            }
            .scrollIndicators(.hidden)
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: Tokens.queueEdgeFade)
                }
            }
            .onAppear {
                // Open on the playing song; played ones are one scroll up.
                if let currentID = self.queue.currentItemID {
                    proxy.scrollTo(currentID, anchor: .top)
                }
            }
            .onChange(of: self.queue.currentItemID) { _, currentID in
                guard let currentID, self.drag == nil else { return }
                withAnimation(Tokens.controlsAnimation) {
                    proxy.scrollTo(currentID, anchor: .top)
                }
            }
        }
    }
}

extension TuneNowPlayingQueuePanel {
    fileprivate static let listSpace = "tuneNowPlayingQueueList"

    /// Thin rounded insertion line where the dragged song will land.
    private var dropIndicator: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(TuneTheme.Palette.ink)
            .frame(height: 2)
            .padding(.horizontal, TuneTheme.NowPlaying.queueInset)
            .offset(y: -1)
            .allowsHitTesting(false)
    }

    /// The landing slot for the live drag: `.some(rowID)` = above that row, `.some(nil)` = end,
    /// nil = no valid move.
    private var dragTarget: UUID?? {
        guard let drag else { return nil }
        let target = TuneNowPlayingQueue.dragDropTarget(
            items: Array(self.queue.visibleItems),
            sourceIndex: drag.sourceIndex,
            translation: drag.translation,
            rowHeight: TuneTheme.NowPlaying.queueRowHeight
        )
        guard let target, self.queue.dropAnchor(moving: drag.id, onto: target) != nil else { return nil }
        return .some(target)
    }

    private var indicatorRowID: UUID? {
        guard let target = self.dragTarget else { return nil }
        return target
    }

    /// Press-and-drag a row up or down to reorder. A plain mouse drag (no pasteboard), so it
    /// works inside the overlay's scroll view; a click without movement still plays the row.
    private func reorderGesture(for item: TuneNowPlayingQueue.Item, at index: Int) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.listSpace))
            .onChanged { value in
                guard item.id != self.queue.currentItemID else { return }
                if self.drag?.id != item.id {
                    self.drag = QueueDrag(id: item.id, sourceIndex: index, translation: 0)
                }
                self.drag?.translation = value.translation.height
            }
            .onEnded { _ in
                defer { self.drag = nil }
                guard let drag = self.drag, drag.id == item.id, let target = self.dragTarget else { return }
                withAnimation(TuneTheme.NowPlaying.controlsAnimation) {
                    self.onMove(drag.id, target)
                }
            }
    }
}

/// The row being dragged and how far it has moved.
struct QueueDrag: Equatable {
    let id: UUID
    let sourceIndex: Int
    var translation: CGFloat
}

extension TuneNowPlayingQueue {
    /// Where a row dragged `translation` points from `sourceIndex` lands, expressed as the row
    /// to insert above (nil = end of the list). Returns nil when the drag hasn't moved a slot.
    static func dragDropTarget(
        items: [Item],
        sourceIndex: Int,
        translation: CGFloat,
        rowHeight: CGFloat
    ) -> UUID?? {
        guard items.indices.contains(sourceIndex), rowHeight > 0, translation.isFinite else { return nil }
        let steps = Int((translation / rowHeight).rounded())
        guard steps != 0 else { return nil }
        let destination = min(max(sourceIndex + steps, 0), items.count - 1)
        if destination < sourceIndex {
            return .some(items[destination].id)
        }
        // Moving down: land below `destination`, i.e. above the row after it (or at the end).
        let after = destination + 1
        return .some(items.indices.contains(after) ? items[after].id : nil)
    }
}

// MARK: - TuneNowPlayingQueueRow

/// One queue row on the C2 grid: 32 pt hard-edged thumb, title over artist, mono duration.
private struct TuneNowPlayingQueueRow: View {
    let item: TuneNowPlayingQueue.Item
    let isCurrent: Bool
    /// Already played: shown dimmed above the playing row.
    var isPlayed = false
    /// Lifted while the user drags it to a new place.
    var isDragged = false
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    private typealias Tokens = TuneTheme.NowPlaying

    var body: some View {
        Group {
            HStack(spacing: TuneTheme.Spacing.unit * 3) {
                TuneNowPlayingThumbnail(url: self.item.thumbnailURL)

                VStack(alignment: .leading, spacing: 2) {
                    Text(self.item.title)
                        .font(TuneTheme.Typeface.bodyEmphasis)
                        .foregroundStyle(TuneTheme.Palette.ink)
                    Text(self.item.artist)
                        .font(TuneTheme.Typeface.body)
                        .foregroundStyle(TuneTheme.Palette.inkSecondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(self.isPlayed ? TuneTheme.NowPlaying.queuePlayedOpacity : 1)

                if let duration = self.item.duration, duration > 0 {
                    Text(TuneNowPlayingTransport.format(duration))
                        .font(TuneTheme.Typeface.data)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                }
            }
            .padding(.horizontal, Tokens.queueInset)
            .frame(height: Tokens.queueRowHeight)
            .background {
                if self.isHovered, !self.isCurrent {
                    RoundedRectangle(cornerRadius: TuneTheme.Radius.control, style: .continuous)
                        .fill(TuneTheme.Palette.ink.opacity(Tokens.queueHoverOpacity))
                        .padding(.horizontal, Tokens.queueRowFillInset)
                }
            }
            .overlay(alignment: .leading) {
                if self.isCurrent {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(TuneTheme.Palette.accent)
                        .frame(width: 2)
                        .padding(.vertical, Tokens.queueRowFillInset)
                        .padding(.leading, Tokens.queueRowFillInset)
                }
            }
            .contentShape(.rect(cornerRadius: TuneTheme.Radius.control, style: .continuous))
        }
        .background {
            // The lifted row while it's being dragged.
            if self.isDragged {
                RoundedRectangle(cornerRadius: TuneTheme.Radius.control, style: .continuous)
                    .fill(TuneTheme.Palette.raisedStrong)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                    .padding(.horizontal, Tokens.queueRowFillInset)
            }
        }
        .onTapGesture {
            // The playing row is a marker, not a restart.
            guard !self.isCurrent else { return }
            self.onPlay()
        }
        .onHover { self.isHovered = $0 }
        .contextMenu {
            if !self.isCurrent {
                Button("Play Next", action: self.onPlayNext)
                Button("Remove from Queue", action: self.onRemove)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(self.isCurrent ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction {
            guard !self.isCurrent else { return }
            self.onPlay()
        }
    }
}
