import Foundation
import Testing
@testable import Kaset

@Suite("Tune Now Playing")
@MainActor
struct TuneNowPlayingTests {
    // MARK: Artwork URL

    @Test("Upscales YT image CDN size suffixes")
    func upscalesCDNSizes() throws {
        let sized = try #require(URL(string: "https://lh3.googleusercontent.com/abc=w60-h60-l90-rj"))
        #expect(TuneNowPlayingTrack.upscaled(sized, edge: 1200).absoluteString == "https://lh3.googleusercontent.com/abc=w1200-h1200-l90-rj")

        let square = try #require(URL(string: "https://yt3.googleusercontent.com/abc=s120"))
        #expect(TuneNowPlayingTrack.upscaled(square, edge: 1200).absoluteString == "https://yt3.googleusercontent.com/abc=s1200")
    }

    @Test("Leaves non-CDN artwork untouched")
    func leavesOtherHostsAlone() throws {
        let still = try #require(URL(string: "https://i.ytimg.com/vi/abc/hqdefault.jpg"))
        #expect(TuneNowPlayingTrack.upscaled(still, edge: 1200) == still)
    }

    // MARK: Lyrics focus

    private static func lyrics(_ starts: [Int]) -> SyncedLyrics {
        SyncedLyrics(
            lines: starts.map { SyncedLyricLine(timeInMs: $0, duration: 0, text: "line \($0)", words: nil) },
            source: "test"
        )
    }

    @Test("Focus follows the bridge's current line")
    func focusUsesCurrentLine() {
        let lyrics = Self.lyrics([0, 1000, 2000])
        #expect(TuneSyncedLyricsField.focusIndex(in: lyrics, currentLineIndex: 1, displayTimeMs: 0) == 1)
    }

    @Test("Without a current line, focus stays on the last line already reached")
    func focusFallsBackToDisplayTime() {
        let lyrics = Self.lyrics([500, 1000, 2000])
        #expect(TuneSyncedLyricsField.focusIndex(in: lyrics, currentLineIndex: nil, displayTimeMs: 1500) == 1)
        #expect(TuneSyncedLyricsField.focusIndex(in: lyrics, currentLineIndex: nil, displayTimeMs: 100) == 0)
        #expect(TuneSyncedLyricsField.focusIndex(in: lyrics, currentLineIndex: nil, displayTimeMs: nil) == 0)
    }

    /// Lines with real durations and a gap between the second and third.
    private static func timedLyrics() -> SyncedLyrics {
        SyncedLyrics(
            lines: [
                SyncedLyricLine(timeInMs: 0, duration: 1000, text: "one", words: nil),
                SyncedLyricLine(timeInMs: 1000, duration: 1000, text: "two", words: nil),
                SyncedLyricLine(timeInMs: 5000, duration: 1000, text: "three", words: nil),
            ],
            source: "test"
        )
    }

    @Test("Paused, the current line comes from the player's position")
    func pausedLineFromProgress() {
        let position = TuneNowPlayingLyricsController.linePosition(
            in: Self.timedLyrics(), bridgeLineIndex: nil, bridgeTimeMs: nil, progress: 1.5, isPlaying: false
        )
        #expect(position.lineIndex == 1)
        #expect(position.timeMs == 1500)
    }

    @Test("Paused after a seek, the position wins over a stale bridge line")
    func pausedPositionBeatsStaleBridge() {
        let position = TuneNowPlayingLyricsController.linePosition(
            in: Self.timedLyrics(), bridgeLineIndex: 0, bridgeTimeMs: 200, progress: 5.2, isPlaying: false
        )
        #expect(position.lineIndex == 2)
    }

    @Test("Playing, the bridge's line is authoritative")
    func playingUsesBridge() {
        let position = TuneNowPlayingLyricsController.linePosition(
            in: Self.timedLyrics(), bridgeLineIndex: 0, bridgeTimeMs: 900, progress: 1.4, isPlaying: true
        )
        #expect(position.lineIndex == 0)
        #expect(position.timeMs == 900)
    }

    @Test("Playing without bridge data falls back to the position; gaps have no current line")
    func playingFallsBackAndKeepsGaps() {
        let lyrics = Self.timedLyrics()
        let early = TuneNowPlayingLyricsController.linePosition(
            in: lyrics, bridgeLineIndex: nil, bridgeTimeMs: nil, progress: 0.4, isPlaying: true
        )
        #expect(early.lineIndex == 0)
        let gap = TuneNowPlayingLyricsController.linePosition(
            in: lyrics, bridgeLineIndex: nil, bridgeTimeMs: nil, progress: 3, isPlaying: false
        )
        #expect(gap.lineIndex == nil)
        #expect(gap.timeMs == 3000)
        #expect(TuneSyncedLyricsField.focusIndex(in: lyrics, currentLineIndex: gap.lineIndex, displayTimeMs: gap.timeMs) == 1)
    }

    @Test("Non-finite progress never invents a line")
    func nonFiniteProgress() {
        let position = TuneNowPlayingLyricsController.linePosition(
            in: Self.timedLyrics(), bridgeLineIndex: nil, bridgeTimeMs: nil, progress: .nan, isPlaying: false
        )
        #expect(position.lineIndex == nil)
        #expect(position.timeMs == nil)
    }

    @Test("Out-of-range bridge index is ignored")
    func focusIgnoresStaleIndex() {
        let lyrics = Self.lyrics([0, 1000])
        #expect(TuneSyncedLyricsField.focusIndex(in: lyrics, currentLineIndex: 9, displayTimeMs: 1200) == 1)
    }

    @Test("Lyric opacity: past dimmer than upcoming, both bounded")
    func lyricOpacityRamp() {
        let past = TuneTheme.NowPlaying.pastLyricOpacity(distance: 1)
        let next = TuneTheme.NowPlaying.upcomingLyricOpacity(distance: 1)
        #expect(past < next)
        #expect(next < 1)
        #expect(TuneTheme.NowPlaying.pastLyricOpacity(distance: 50) > 0)
        #expect(TuneTheme.NowPlaying.upcomingLyricOpacity(distance: 50) > 0)
        #expect(TuneTheme.NowPlaying.activeLyricScale <= 1.4)
    }

    // MARK: Transport

    @Test("Time format handles minutes, hours and bad input")
    func timeFormat() {
        #expect(TuneNowPlayingTransport.format(50) == "0:50")
        #expect(TuneNowPlayingTransport.format(236) == "3:56")
        #expect(TuneNowPlayingTransport.format(3725) == "1:02:05")
        #expect(TuneNowPlayingTransport.format(-3) == "0:00")
        #expect(TuneNowPlayingTransport.format(.nan) == "0:00")
        #expect(TuneNowPlayingTransport.format(.infinity) == "0:00")
    }

    @Test("Scrub fraction clamps to the rail")
    func scrubFraction() {
        #expect(TuneNowPlayingTransport.fraction(x: 50, width: 200) == 0.25)
        #expect(TuneNowPlayingTransport.fraction(x: -10, width: 200) == 0)
        #expect(TuneNowPlayingTransport.fraction(x: 500, width: 200) == 1)
        #expect(TuneNowPlayingTransport.fraction(x: 10, width: 0) == 0)
    }

    @Test("Progress is clamped and finite")
    func clampedProgress() {
        var playback = TuneNowPlayingPlayback(isPlaying: true, progress: 300, duration: 236, isLiked: false, canLike: true, canSeek: true)
        #expect(playback.clampedProgress == 236)
        playback.progress = .nan
        #expect(playback.clampedProgress == 0)
        playback.progress = 10
        playback.duration = 0
        #expect(playback.clampedProgress == 0)
    }

    // MARK: Layout

    @Test("Side artwork fits beside the column and drops out when too narrow")
    func sideArtworkMetrics() {
        let wide = TuneNowPlayingMetrics(size: CGSize(width: 1440, height: 900))
        #expect(wide.sideArtworkEdge >= TuneTheme.NowPlaying.minimumSideArtwork)
        #expect(wide.sideArtworkCenter.x + wide.sideArtworkEdge / 2 <= 1440 - wide.columnLeading + 0.5)
        #expect(wide.sideArtworkCenter.x - wide.sideArtworkEdge / 2 >= wide.columnLeading + wide.columnWidth)

        let narrow = TuneNowPlayingMetrics(size: CGSize(width: 520, height: 500))
        #expect(narrow.sideArtworkEdge == 0)
        #expect(narrow.centeredArtworkEdge > 0)
    }

    @Test("Side artwork centers on the lyrics field, inside the title-to-transport band")
    func sideArtworkFollowsLyricsViewport() {
        let metrics = TuneNowPlayingMetrics(size: CGSize(width: 1360, height: 840))
        let viewport = CGRect(x: 91, y: 180, width: 580, height: 540)
        let center = metrics.sideArtworkCenter(lyricsViewport: viewport)
        let half = metrics.sideArtworkEdge / 2
        #expect(center.x == metrics.sideArtworkCenter.x)
        #expect(center.y - half >= TuneTheme.NowPlaying.headerTop)
        #expect(center.y + half <= 840 - TuneTheme.NowPlaying.footerBottom)
        #expect(abs(center.y - viewport.midY) < 40)
        #expect(metrics.sideArtworkCenter(lyricsViewport: nil) == metrics.sideArtworkCenter)
        #expect(metrics.lyricFocusY == 840 * TuneTheme.NowPlaying.lyricFocusWindowShare)
    }

    @Test("Only unavailable lyrics use the centered composition")
    func compositionChoice() {
        #expect(TuneNowPlayingLyrics.unavailable.usesLyricsLayout == false)
        #expect(TuneNowPlayingLyrics.loading.usesLyricsLayout)
        #expect(TuneNowPlayingLyrics.plain(["a"]).usesLyricsLayout)
    }

    // MARK: Up Next

    @Test("The open queue pane takes 360–400 pt on the right; the artwork moves left of it")
    func queueLayoutWide() {
        let metrics = TuneNowPlayingMetrics(size: CGSize(width: 1440, height: 900), showsQueue: true)
        #expect(TuneTheme.NowPlaying.queueWidthRange.contains(metrics.queueWidth))
        #expect(metrics.contentWidth == 1440 - metrics.queueWidth)
        #expect(metrics.sideArtworkEdge >= TuneTheme.NowPlaying.minimumSideArtwork)
        let artworkMaxX = metrics.sideArtworkCenter.x + metrics.sideArtworkEdge / 2
        #expect(artworkMaxX <= metrics.contentWidth - TuneTheme.Spacing.gutter + 0.5)
        #expect(metrics.sideArtworkCenter.x - metrics.sideArtworkEdge / 2 >= metrics.columnLeading + metrics.columnWidth)

        let closed = TuneNowPlayingMetrics(size: CGSize(width: 1440, height: 900))
        #expect(closed.queueWidth == 0)
        #expect(closed.contentWidth == 1440)
    }

    @Test("Under 1200 pt wide the open queue drops the artwork and the lyrics take its room")
    func queueLayoutNarrow() {
        let metrics = TuneNowPlayingMetrics(size: CGSize(width: 1100, height: 720), showsQueue: true)
        #expect(metrics.queueWidth == TuneTheme.NowPlaying.queueWidthRange.lowerBound)
        #expect(metrics.sideArtworkEdge == 0)
        #expect(metrics.columnLeading + metrics.columnWidth <= metrics.contentWidth - TuneTheme.Spacing.gutter + 0.5)
        #expect(metrics.columnWidth > TuneNowPlayingMetrics(size: CGSize(width: 1100, height: 720)).columnWidth)

        // Same window with the pane closed keeps its artwork.
        #expect(TuneNowPlayingMetrics(size: CGSize(width: 1100, height: 720)).sideArtworkEdge > 0)
    }

    @Test("The no-lyrics composition centers in the area left of the pane")
    func queueLayoutCentered() {
        let open = TuneNowPlayingMetrics(size: CGSize(width: 1360, height: 840), showsQueue: true)
        #expect(open.centeredArtworkEdge <= open.contentWidth - open.columnLeading * 2)
        #expect(open.centeredTransportWidth <= open.contentWidth - open.columnLeading * 2)
        #expect(open.centeredTransportWidth > 0)
    }

    private static func queue(count: Int, current: Int?) -> TuneNowPlayingQueue {
        TuneNowPlayingQueue(
            items: (0 ..< count).map { TuneNowPlayingQueue.Item(id: UUID(), title: "t\($0)", artist: "a") },
            currentIndex: current
        )
    }

    @Test("Up Next keeps played items (dimmed) above the playing one")
    func queueVisibleItems() {
        let queue = Self.queue(count: 5, current: 2)
        #expect(queue.visibleItems.map(\.title) == ["t0", "t1", "t2", "t3", "t4"])
        #expect(queue.items.map { queue.isPlayed($0.id) } == [true, true, false, false, false])
        #expect(queue.currentItemID == queue.items[2].id)
        #expect(queue.upNextCount == 2)

        let unowned = Self.queue(count: 3, current: nil)
        #expect(unowned.visibleItems.count == 3)
        #expect(unowned.upNextCount == 3)
        #expect(Self.queue(count: 3, current: 7).currentItemID == nil)
        #expect(TuneNowPlayingQueue.empty.upNextCount == 0)
    }

    @Test("Play Next moves an entry right after the playing one, and never the playing or next one")
    func queuePlayNextAnchor() {
        let queue = Self.queue(count: 5, current: 1)
        let ids = queue.items.map(\.id)
        #expect(queue.playNextAnchor(moving: ids[4]) == .some(ids[2]))
        #expect(queue.playNextAnchor(moving: ids[2]) == nil)
        #expect(queue.playNextAnchor(moving: ids[1]) == nil)
        #expect(queue.playNextAnchor(moving: UUID()) == nil)
        #expect(Self.queue(count: 3, current: nil).playNextAnchor(moving: ids[0]) == nil)
    }

    @Test("Drag to reorder: drops land above the target row, never above the playing row")
    func queueDropAnchor() {
        let queue = Self.queue(count: 6, current: 1)
        let ids = queue.items.map(\.id)
        // Drag t5 onto t3 → lands above t3.
        #expect(queue.dropAnchor(moving: ids[5], onto: ids[3]) == .some(ids[3]))
        // Drag t2 down onto t5 → lands above t5.
        #expect(queue.dropAnchor(moving: ids[2], onto: ids[5]) == .some(ids[5]))
        // Drop on the playing row → right after it (same as Play Next).
        #expect(queue.dropAnchor(moving: ids[4], onto: ids[1]) == .some(ids[2]))
        // Drop at the end → append.
        #expect(queue.dropAnchor(moving: ids[2], onto: nil) == .some(nil))
        // No-ops: onto itself, onto the row right below, last row to the end, the playing row.
        #expect(queue.dropAnchor(moving: ids[3], onto: ids[3]) == nil)
        #expect(queue.dropAnchor(moving: ids[3], onto: ids[4]) == nil)
        #expect(queue.dropAnchor(moving: ids[5], onto: nil) == nil)
        #expect(queue.dropAnchor(moving: ids[1], onto: ids[4]) == nil)
        #expect(queue.dropAnchor(moving: UUID(), onto: ids[3]) == nil)
    }

    @Test("Mouse drag: half a row or more moves one slot, clamped to the list")
    func queueDragDropTarget() {
        let items = Self.queue(count: 5, current: 0).items
        let ids = items.map(\.id)
        let h: CGFloat = 40
        // Not far enough to move.
        #expect(TuneNowPlayingQueue.dragDropTarget(items: items, sourceIndex: 2, translation: 15, rowHeight: h) == nil)
        // Up one row → above row 1.
        #expect(TuneNowPlayingQueue.dragDropTarget(items: items, sourceIndex: 2, translation: -30, rowHeight: h) == .some(ids[1]))
        // Down one row → below row 3 = above row 4.
        #expect(TuneNowPlayingQueue.dragDropTarget(items: items, sourceIndex: 2, translation: 41, rowHeight: h) == .some(ids[4]))
        // Down past the end → end of the list.
        #expect(TuneNowPlayingQueue.dragDropTarget(items: items, sourceIndex: 2, translation: 900, rowHeight: h) == .some(nil))
        // Far up → clamped to the top row.
        #expect(TuneNowPlayingQueue.dragDropTarget(items: items, sourceIndex: 3, translation: -900, rowHeight: h) == .some(ids[0]))
        #expect(TuneNowPlayingQueue.dragDropTarget(items: items, sourceIndex: 9, translation: 50, rowHeight: h) == nil)
    }

    // MARK: Repeat

    @Test("REPEAT cycles off → all → one: muted, then ink, then ink REPEAT 1")
    func repeatToggleLabels() {
        let cycle: [PlayerService.RepeatMode] = [.off, .all, .one]
        let states = cycle.map(TuneNowPlayingRepeatToggle.init(mode:))
        #expect(states.map(\.isOn) == [false, true, true])
        #expect(states.map(\.title) == ["Repeat", "Repeat", "Repeat 1"])
        #expect(states.map(\.accessibilityValue) == ["Off", "All", "One"])
        #expect(TuneNowPlayingRepeatToggle.widestTitle == "Repeat 1")
    }

    // MARK: Search

    @Test("Search selection starts on the top result, moves with the arrows and stops at the ends")
    func searchSelection() {
        var selection = TuneNowPlayingSearchSelection()
        #expect(selection.resolved(count: 0) == nil)
        #expect(selection.resolved(count: 3) == 0)

        selection.moveUp(count: 3)
        #expect(selection.resolved(count: 3) == 0)
        selection.moveDown(count: 3)
        selection.moveDown(count: 3)
        selection.moveDown(count: 3)
        #expect(selection.resolved(count: 3) == 2)
        selection.moveUp(count: 3)
        #expect(selection.resolved(count: 3) == 1)

        // Fewer results than the old selection: clamp, don't fall off.
        selection.select(7, count: 8)
        #expect(selection.resolved(count: 2) == 1)
        selection.moveDown(count: 0)
        #expect(selection.resolved(count: 0) == nil)

        selection.reset()
        #expect(selection.resolved(count: 5) == 0)
    }

    @Test("Esc dismisses the search first and only then closes the view")
    func escapeOrder() {
        #expect(TuneNowPlayingEscape.resolve(isSearchFocused: true, hasQuery: true) == .dismissSearch)
        #expect(TuneNowPlayingEscape.resolve(isSearchFocused: true, hasQuery: false) == .dismissSearch)
        #expect(TuneNowPlayingEscape.resolve(isSearchFocused: false, hasQuery: true) == .dismissSearch)
        #expect(TuneNowPlayingEscape.resolve(isSearchFocused: false, hasQuery: false) == .close)
    }
}
