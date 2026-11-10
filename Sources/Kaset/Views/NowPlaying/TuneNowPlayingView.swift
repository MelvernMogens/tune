import AppKit
import SwiftUI

// MARK: - TuneNowPlayingTrack

/// Track identity and display metadata for the fullscreen view.
struct TuneNowPlayingTrack: Equatable {
    var videoId: String
    var title: String
    var artist: String
    /// The thumbnail as the API delivered it (small; used for the blurred backdrop and palette).
    var thumbnailURL: URL?

    /// Same image, requested large enough to stay sharp at fullscreen size.
    var largeArtworkURL: URL? {
        self.thumbnailURL.map { Self.upscaled($0, edge: TuneTheme.NowPlaying.artworkRequestEdge) }
    }

    /// Rewrites YT image CDN size suffixes (`=w60-h60…`, `=s120`) to request `edge` px.
    /// Other hosts (e.g. `i.ytimg.com` video stills) are returned unchanged.
    static func upscaled(_ url: URL, edge: Int) -> URL {
        guard let host = url.host(), host.contains("googleusercontent.com") || host.contains("ggpht.com") else {
            return url
        }
        var string = url.absoluteString
        string = string.replacingOccurrences(
            of: #"=w\d+-h\d+"#,
            with: "=w\(edge)-h\(edge)",
            options: .regularExpression
        )
        string = string.replacingOccurrences(of: #"=s\d+(?=-|$)"#, with: "=s\(edge)", options: .regularExpression)
        return URL(string: string) ?? url
    }
}

// MARK: - TuneNowPlayingView

/// Fullscreen immersive Now Playing (direction C2): synced lyrics on a field tinted by the
/// artwork, the artwork itself large and softly rounded on the right, a minimal transport that
/// fades out when the pointer rests. With no lyrics it falls back to a centered artwork,
/// title, and artist composition.
///
/// Pure: everything comes in through properties so it renders from fixtures.
struct TuneNowPlayingView: View {
    let track: TuneNowPlayingTrack
    let lyrics: TuneNowPlayingLyrics
    let playback: TuneNowPlayingPlayback
    let actions: TuneNowPlayingActions
    /// The play queue for the Up Next pane.
    let queue: TuneNowPlayingQueue
    /// Whether the Up Next pane is open (persisted by the host).
    let showsQueue: Bool
    /// Song results for the search field's current query.
    let search: TuneNowPlayingSearchResults
    /// Bumped by ⌘K / ⌘F while the view is up: focus the search field.
    let searchFocusRequest: Int
    /// Bumped by the Esc key monitor: clear and leave the search field.
    let searchDismissalRequest: Int
    /// Bumped by the key monitor's Tab: flip SONGS · VIDEOS.
    let searchFilterToggleRequest: Int
    /// Reports whether Esc should clear the search (focused or holding text) rather than close.
    let onSearchEngagedChange: (Bool) -> Void
    /// Reports whether Tab should flip the search filter (field focused with a query).
    let onSearchFocusedWithQueryChange: (Bool) -> Void
    /// SONG · VIDEO state, and whether the artwork slot shows the playing video.
    let video: TuneNowPlayingVideo
    /// Test/preview hook: renders this image instead of loading `track.thumbnailURL`.
    let artworkOverride: NSImage?

    @State private var palette: ColorExtractor.ColorPalette?
    @State private var controlsVisible: Bool
    @State private var isPointerInside = false
    @State private var isPointerOverControls = false
    @State private var isScrubbing = false
    @State private var activity = TuneNowPlayingActivityClock()
    /// The lyrics field's frame in the view's coordinate space; positions the focus line and
    /// centers the artwork on it.
    @State private var lyricsViewport: CGRect = .zero
    @State private var searchQuery = ""
    /// Results as shown: keeps the last rows on screen while the next query is in flight.
    @State private var shownSearch = TuneNowPlayingSearchResults.empty
    @State private var searchSelection = TuneNowPlayingSearchSelection()
    @State private var searchFilter = TuneNowPlayingSearchFilter.songs
    /// Where the composition placed the video (named space); the one slot follows it, so the
    /// WebView is never remounted by a layout change.
    @State private var videoSlotFrame: CGRect = .zero
    /// Results added to the queue since the query last changed; their rows read QUEUED.
    @State private var queuedSearchIDs: Set<String> = []
    @State private var closeHintWidth: CGFloat = 0
    @FocusState private var focus: TuneNowPlayingFocus?

    private static let coordinateSpace = "tuneNowPlaying"

    init(
        track: TuneNowPlayingTrack,
        lyrics: TuneNowPlayingLyrics,
        playback: TuneNowPlayingPlayback,
        actions: TuneNowPlayingActions,
        queue: TuneNowPlayingQueue = .empty,
        showsQueue: Bool = false,
        search: TuneNowPlayingSearchResults = .empty,
        searchFocusRequest: Int = 0,
        searchDismissalRequest: Int = 0,
        searchFilterToggleRequest: Int = 0,
        onSearchEngagedChange: @escaping (Bool) -> Void = { _ in },
        onSearchFocusedWithQueryChange: @escaping (Bool) -> Void = { _ in },
        video: TuneNowPlayingVideo = .unavailable,
        artworkOverride: NSImage? = nil,
        showsControls: Bool = true
    ) {
        self.track = track
        self.lyrics = lyrics
        self.playback = playback
        self.actions = actions
        self.queue = queue
        self.showsQueue = showsQueue
        self.search = search
        self.searchFocusRequest = searchFocusRequest
        self.searchDismissalRequest = searchDismissalRequest
        self.searchFilterToggleRequest = searchFilterToggleRequest
        self.onSearchEngagedChange = onSearchEngagedChange
        self.onSearchFocusedWithQueryChange = onSearchFocusedWithQueryChange
        self.video = video
        self.artworkOverride = artworkOverride
        self._controlsVisible = State(initialValue: showsControls)
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = TuneNowPlayingMetrics(size: proxy.size, showsQueue: self.showsQueue)
            ZStack(alignment: .topLeading) {
                self.backdrop
                    .id(self.track.videoId)
                    .transition(.opacity)

                if self.lyrics.usesLyricsLayout {
                    self.lyricsComposition(metrics)
                } else {
                    self.centeredComposition(metrics)
                }

                if self.video.showsVideo {
                    self.videoSlot
                }

                if self.showsQueue {
                    self.queuePanel
                        .frame(width: metrics.queueWidth)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                self.closeHint
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { width in
                        self.closeHintWidth = width
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, TuneTheme.NowPlaying.topBarTop)
                    .padding(.trailing, metrics.columnLeading)

                self.searchBar(metrics)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, TuneTheme.NowPlaying.topBarTop)
                    .padding(.trailing, self.searchTrailing(metrics))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(.named(Self.coordinateSpace))
        }
        .animation(TuneTheme.NowPlaying.trackChangeAnimation, value: self.track.videoId)
        .animation(TuneTheme.NowPlaying.trackChangeAnimation, value: self.lyrics.usesLyricsLayout)
        .animation(TuneTheme.NowPlaying.controlsAnimation, value: self.showsQueue)
        .background(TuneTheme.Palette.background)
        .ignoresSafeArea()
        .contentShape(.rect)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if !self.isPointerInside {
                    self.isPointerInside = true
                }
                self.noteActivity()
            case .ended:
                self.isPointerInside = false
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused(self.$focus, equals: .root)
        .onKeyPress(.escape) {
            self.handleEscape()
            return .handled
        }
        .onKeyPress(keys: ["/"]) { press in
            guard press.modifiers.isEmpty, self.focus != .search else { return .ignored }
            self.focus = .search
            return .handled
        }
        .onKeyPress(keys: ["k"]) { press in
            // Fallback when no ⌘K menu item claims the key (command bar unavailable).
            guard press.modifiers == .command else { return .ignored }
            self.focus = .search
            return .handled
        }
        .onAppear {
            self.focus = .root
        }
        .onChange(of: self.focus) { _, _ in
            NotificationCenter.default.post(name: TextInputFocusState.focusDidChangeNotification, object: nil)
        }
        .onChange(of: self.searchFocusRequest) { _, _ in
            self.focus = .search
        }
        .onChange(of: self.searchDismissalRequest) { _, _ in
            self.dismissSearch()
        }
        .onChange(of: self.isSearchFocused || !self.searchQuery.isEmpty, initial: true) { _, isEngaged in
            self.onSearchEngagedChange(isEngaged)
        }
        .onChange(of: self.isSearchFocused && self.hasSearchText, initial: true) { _, isFocusedWithQuery in
            self.onSearchFocusedWithQueryChange(isFocusedWithQuery)
        }
        .onChange(of: self.searchFilterToggleRequest) { _, _ in
            self.searchFilter = self.searchFilter.toggled
        }
        .onChange(of: self.searchQuery) { _, query in
            self.searchSelection.reset()
            self.queuedSearchIDs = []
            self.actions.search(query)
        }
        .onChange(of: self.searchFilter) { _, filter in
            self.searchSelection.reset()
            self.actions.selectSearchFilter(filter)
        }
        .onChange(of: self.search, initial: true) { _, results in
            // While the next query is in flight, keep the last rows rather than flashing empty.
            if TuneNowPlayingSearchResults.keepsShownRows(shown: self.shownSearch, incoming: results) {
                self.shownSearch.phase = .searching
            } else {
                if results.items.map(\.id) != self.shownSearch.items.map(\.id) {
                    self.searchSelection.reset()
                }
                self.shownSearch = results
            }
        }
        .task(id: self.paletteSourceURL) {
            await self.loadPalette()
        }
        .onChange(of: self.playback.isPlaying, initial: true) { _, isPlaying in
            // The auto-hide loop captured this struct at start; hand it live state by reference.
            self.activity.isPlaying = isPlaying
        }
        .task {
            await self.runAutoHide()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Now Playing"))
        .accessibilityIdentifier(TuneNowPlayingAccessibilityID.root)
    }

    // MARK: Compositions

    private func lyricsComposition(_ metrics: TuneNowPlayingMetrics) -> some View {
        let viewport = self.lyricsViewport.isEmpty ? nil : self.lyricsViewport
        let placement = metrics.videoPlacement(showsVideo: self.video.showsVideo)
        return ZStack(alignment: .topLeading) {
            switch placement {
            case .none:
                if metrics.sideArtworkEdge > 0 {
                    let artworkCenter = metrics.sideArtworkCenter(lyricsViewport: viewport)
                    self.sharpArtwork(edge: metrics.sideArtworkEdge)
                        .position(x: artworkCenter.x, y: artworkCenter.y)
                }
            case let .side(size):
                let center = metrics.sideSlotCenter(height: size.height, lyricsViewport: viewport)
                self.videoFrame(size)
                    .position(x: center.x, y: center.y)
            case .stacked:
                EmptyView()
            }

            VStack(alignment: .leading, spacing: 0) {
                self.titleBlock(alignment: .leading)
                    .padding(.top, TuneTheme.NowPlaying.headerTop)

                if case let .stacked(size) = placement {
                    // No room beside the lyrics: the video leads the column, under the title.
                    self.videoFrame(size)
                        .padding(.top, TuneTheme.Spacing.gutter / 2)
                }

                // A stacked video pushes the field down; it centers its own focus line then.
                self.lyricsField(focusAnchorY: placement.isStacked ? nil : viewport.map { metrics.lyricFocusY - $0.minY })
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(Self.coordinateSpace))
                    } action: { frame in
                        self.lyricsViewport = frame
                    }
                    .padding(.top, TuneTheme.Spacing.gutter)
                    .padding(.bottom, TuneTheme.Spacing.unit * 6)
                    .frame(maxHeight: .infinity)

                self.transport(width: metrics.columnWidth)
                    .padding(.bottom, TuneTheme.NowPlaying.footerBottom)
            }
            .frame(width: metrics.columnWidth, alignment: .leading)
            .frame(maxHeight: .infinity)
            .padding(.leading, metrics.columnLeading)
        }
        .transition(.opacity)
    }

    private func centeredComposition(_ metrics: TuneNowPlayingMetrics) -> some View {
        // One centered unit: artwork, then title and artist, then the transport.
        VStack(spacing: TuneTheme.Spacing.gutter / 2) {
            if self.video.showsVideo {
                self.videoFrame(metrics.centeredVideoSize)
            } else {
                self.sharpArtwork(edge: metrics.centeredArtworkEdge)
            }
            self.titleBlock(alignment: .center)
                .frame(maxWidth: max(metrics.centeredArtworkEdge, metrics.centeredTransportWidth))
            self.transport(width: metrics.centeredTransportWidth)
                .padding(.top, TuneTheme.Spacing.unit * 2)
        }
        .padding(.vertical, TuneTheme.NowPlaying.headerTop)
        // Centered in the area left of the Up Next pane.
        .frame(width: metrics.contentWidth)
        .frame(maxHeight: .infinity)
        .transition(.opacity)
    }

    // MARK: Pieces

    private func titleBlock(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: TuneTheme.Spacing.unit * 2.5) {
            Text(self.track.title)
                .font(TuneTheme.Typeface.display.weight(.bold))
                .tracking(-0.5)
                .foregroundStyle(TuneTheme.Palette.ink)
            Text(self.track.artist)
                .font(TuneTheme.Typeface.section.weight(.regular))
                .foregroundStyle(TuneTheme.Palette.inkSecondary)
        }
        .lineLimit(2)
        .multilineTextAlignment(alignment == .center ? .center : .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func lyricsField(focusAnchorY: CGFloat?) -> some View {
        switch self.lyrics {
        case let .synced(synced, currentLineIndex, displayTimeMs):
            TuneSyncedLyricsField(
                lyrics: synced,
                currentLineIndex: currentLineIndex,
                displayTimeMs: displayTimeMs,
                onSeek: self.playback.canSeek ? { ms in self.actions.seek(Double(ms) / 1000) } : nil,
                focusAnchorY: focusAnchorY
            )
            .id(self.track.videoId)
            .accessibilityIdentifier(TuneNowPlayingAccessibilityID.lyrics)
        case let .plain(lines):
            TunePlainLyricsField(lines: lines)
                .id(self.track.videoId)
                .accessibilityIdentifier(TuneNowPlayingAccessibilityID.lyrics)
        case .loading, .unavailable:
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func transport(width: CGFloat) -> some View {
        TuneNowPlayingTransport(
            playback: self.playback,
            actions: self.actions,
            onScrubbingChanged: { self.isScrubbing = $0 },
            width: width,
            isQueueShown: self.showsQueue,
            video: self.video.toggle
        )
        .onHover { self.isPointerOverControls = $0 }
        .opacity(self.controlsVisible ? 1 : 0)
        .allowsHitTesting(self.controlsVisible)
        .animation(TuneTheme.NowPlaying.controlsAnimation, value: self.controlsVisible)
    }

    private var closeHint: some View {
        // Clicking always closes; the Esc key goes through `handleEscape` (search first).
        Button(action: self.actions.close) {
            HStack(spacing: TuneTheme.Spacing.unit * 2) {
                Text(verbatim: "esc")
                    .font(TuneTheme.Typeface.data)
                    .foregroundStyle(TuneTheme.Palette.inkSecondary)
                    .padding(.horizontal, TuneTheme.Spacing.unit)
                    .padding(.vertical, 1)
                    .overlay {
                        RoundedRectangle(cornerRadius: TuneTheme.Radius.keycap, style: .continuous)
                            .strokeBorder(TuneTheme.Palette.rule, lineWidth: 1)
                    }
                Text("Close")
                    .tuneCapsLabel()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .frame(height: TuneTheme.NowPlaying.searchFieldHeight)
        .onHover { self.isPointerOverControls = $0 }
        .opacity(self.controlsVisible ? 1 : 0)
        .animation(TuneTheme.NowPlaying.controlsAnimation, value: self.controlsVisible)
        .background {
            // Esc wherever focus is (even with none): dismiss the search first, then close.
            Button(action: self.handleEscape) {
                EmptyView()
            }
            .keyboardShortcut(.cancelAction)
            .focusable(false)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .accessibilityIdentifier(TuneNowPlayingAccessibilityID.closeButton)
    }

    // MARK: Search

    private var isSearchFocused: Bool {
        self.focus == .search
    }

    private var hasSearchText: Bool {
        !self.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The field stays up while it's in use, even after the transport fades.
    private var isSearchVisible: Bool {
        self.controlsVisible || self.isSearchFocused || !self.searchQuery.isEmpty
    }

    private var showsSearchDropdown: Bool {
        self.isSearchFocused
            && !self.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
            && (self.shownSearch.phase != .idle || !self.shownSearch.items.isEmpty)
    }

    /// Left of the close hint; with Up Next open, a gutter short of the pane so the results
    /// hang over the lyrics side, never over the queue.
    private func searchTrailing(_ metrics: TuneNowPlayingMetrics) -> CGFloat {
        if self.showsQueue {
            return metrics.queueWidth + TuneTheme.Spacing.gutter
        }
        return metrics.columnLeading + self.closeHintWidth + TuneTheme.Spacing.gutter
    }

    private func searchBar(_ metrics: TuneNowPlayingMetrics) -> some View {
        let selected = self.searchSelection.resolved(count: self.shownSearch.items.count)
        return VStack(alignment: .trailing, spacing: TuneTheme.Spacing.unit * 2) {
            TuneNowPlayingSearchField(query: self.$searchQuery, focus: self.$focus)
                .onKeyPress(.downArrow) {
                    guard !self.shownSearch.items.isEmpty else { return .ignored }
                    self.searchSelection.moveDown(count: self.shownSearch.items.count)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard !self.shownSearch.items.isEmpty else { return .ignored }
                    self.searchSelection.moveUp(count: self.shownSearch.items.count)
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    guard self.showsSearchDropdown,
                          let index = self.searchSelection.resolved(count: self.shownSearch.items.count)
                    else { return .ignored }
                    let id = self.shownSearch.items[index].id
                    if press.modifiers.contains(.command) {
                        self.addSearchResultToQueue(id)
                    } else if press.modifiers.contains(.option) {
                        self.playSearchResultNext(id)
                    } else {
                        self.playSearchResult(id)
                    }
                    return .handled
                }
                .onKeyPress(.escape) {
                    self.handleEscape()
                    return .handled
                }
                // Tab flips SONGS · VIDEOS through the overlay's key monitor (the field's own
                // Tab would move focus first). ⌘←/→ stay next/previous track and line moves.

            if self.showsSearchDropdown {
                TuneNowPlayingSearchDropdown(
                    results: self.shownSearch,
                    filter: self.searchFilter,
                    selectedIndex: selected,
                    queuedIDs: self.queuedSearchIDs,
                    tint: self.fieldTint,
                    onPlay: self.playSearchResult,
                    onPlayNext: self.playSearchResultNext,
                    onAddToQueue: self.addSearchResultToQueue,
                    onHover: { index in
                        // Pointer and arrows share one selection.
                        self.searchSelection.select(index, count: self.shownSearch.items.count)
                    },
                    onSelectFilter: { self.searchFilter = $0 }
                )
                .frame(maxHeight: max(0, metrics.size.height - TuneTheme.NowPlaying.headerTop * 2), alignment: .top)
                .transition(.opacity)
            }
        }
        .onHover { self.isPointerOverControls = $0 }
        .opacity(self.isSearchVisible ? 1 : 0)
        .allowsHitTesting(self.isSearchVisible)
        .animation(TuneTheme.NowPlaying.controlsAnimation, value: self.isSearchVisible)
        .animation(TuneTheme.NowPlaying.controlsAnimation, value: self.showsSearchDropdown)
    }

    private func playSearchResult(_ id: String) {
        self.actions.playSearchResult(id)
        self.dismissSearch()
    }

    private func playSearchResultNext(_ id: String) {
        self.actions.playSearchResultNext(id)
        self.queuedSearchIDs.insert(id)
    }

    private func addSearchResultToQueue(_ id: String) {
        self.actions.addSearchResultToQueue(id)
        self.queuedSearchIDs.insert(id)
    }

    private func dismissSearch() {
        self.searchQuery = ""
        self.focus = .root
    }

    private func handleEscape() {
        switch TuneNowPlayingEscape.resolve(isSearchFocused: self.isSearchFocused, hasQuery: !self.searchQuery.isEmpty) {
        case .dismissSearch:
            self.dismissSearch()
        case .close:
            self.actions.close()
        }
    }

    // MARK: Up Next

    private var queuePanel: some View {
        TuneNowPlayingQueuePanel(
            queue: self.queue,
            tint: self.fieldTint,
            onPlay: self.actions.playQueueEntry,
            onPlayNext: self.actions.playQueueEntryNext,
            onRemove: self.actions.removeQueueEntry,
            onMove: self.actions.moveQueueEntry
        )
    }

    // MARK: Video

    /// Where the video sits in a composition: black 16:9 with the artwork's lift. Reports its
    /// frame so the single `videoSlot` can follow it.
    private func videoFrame(_ size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: TuneNowPlayingArtworkShape.radius(forEdge: size.width), style: .continuous)
            .fill(.black)
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.45), radius: 40, y: 18)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Self.coordinateSpace))
            } action: { frame in
                self.videoSlotFrame = frame
            }
            .accessibilityHidden(true)
    }

    /// The playing video itself (the playback WebView), laid over `videoFrame`. One instance
    /// for every composition so moving between them never reparents the WebView.
    private var videoSlot: some View {
        TuneNowPlayingVideoSlot(cornerRadius: TuneNowPlayingArtworkShape.radius(forEdge: self.videoSlotFrame.width))
            .frame(width: self.videoSlotFrame.width, height: self.videoSlotFrame.height)
            .position(x: self.videoSlotFrame.midX, y: self.videoSlotFrame.midY)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(Text("Video"))
            .accessibilityIdentifier(TuneNowPlayingAccessibilityID.videoSlot)
    }

    // MARK: Artwork

    /// The artwork itself: sharp, with soft continuous corners. No hairline here — on the
    /// tinted field a light edge reads as a frame; the soft shadow lifts it instead.
    private func sharpArtwork(edge: CGFloat) -> some View {
        self.artworkImage(url: self.track.largeArtworkURL, decodeSize: CGSize(width: edge, height: edge))
            .frame(width: edge, height: edge)
            .clipShape(.rect(cornerRadius: TuneNowPlayingArtworkShape.radius(forEdge: edge), style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 40, y: 18)
            .id(self.track.videoId)
            .transition(.opacity)
            .accessibilityHidden(true)
    }

    /// Artwork colors bled across the whole field: the cover blurred far past recognition,
    /// over a dark tinted from its own palette, then shaded toward the lyrics side.
    private var backdrop: some View {
        let tint = self.fieldTint
        return ZStack {
            tint

            // Overlay on a greedy base so the aspect-filled image can't grow the stack past the window.
            // Saturation, darkening and the blur are baked into a 256 px bitmap
            // (`TuneNowPlayingBackdropRenderer`) instead of a live full-window drawingGroup.
            Color.clear
                .overlay {
                    TuneNowPlayingBackdropArtwork(url: self.track.thumbnailURL, artworkOverride: self.artworkOverride)
                }
                .clipped()

            // Darken toward the text column with the artwork's own dark, never neutral grey.
            LinearGradient(
                stops: [
                    .init(color: tint.opacity(0.92), location: 0),
                    .init(color: tint.opacity(0.86), location: 0.34),
                    .init(color: tint.opacity(0.66), location: 0.5),
                    .init(color: tint.opacity(0.5), location: 0.65),
                    .init(color: tint.opacity(0.42), location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            LinearGradient(
                stops: [
                    .init(color: tint.opacity(0.35), location: 0),
                    .init(color: .clear, location: 0.3),
                    .init(color: .clear, location: 0.75),
                    .init(color: tint.opacity(0.6), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func artworkImage(url: URL?, decodeSize: CGSize) -> some View {
        if let artworkOverride {
            Image(nsImage: artworkOverride)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            CachedAsyncImage(url: url, targetSize: decodeSize) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                TuneTheme.Palette.raised.opacity(0.4)
            }
        }
    }

    // MARK: Palette

    /// The artwork-tinted dark every surface on the field derives from.
    private var fieldTint: Color {
        TuneNowPlayingTint.deepDark(from: (self.palette ?? self.overridePalette)?.primary)
    }

    private var paletteSourceURL: URL? {
        self.track.thumbnailURL
    }

    /// Synchronous palette for `artworkOverride` (renders never run `.task`).
    private var overridePalette: ColorExtractor.ColorPalette? {
        self.artworkOverride.map { ColorExtractor.extractPalette(from: $0) }
    }

    private func loadPalette() async {
        guard self.artworkOverride == nil else { return }
        guard let url = self.paletteSourceURL else {
            self.palette = nil
            return
        }
        let extracted = await ColorExtractor.cachedPalette(for: url)
        guard !Task.isCancelled else { return }
        withAnimation(TuneTheme.NowPlaying.trackChangeAnimation) {
            self.palette = extracted
        }
    }

    // MARK: Auto-hide

    private func noteActivity() {
        self.activity.lastActivity = .now
        if !self.controlsVisible {
            self.controlsVisible = true
        }
    }

    /// Hides the transport (and the pointer) after a rest; keeps it while paused,
    /// scrubbing, or hovering a control.
    private func runAutoHide() async {
        let clock = ContinuousClock()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, self.controlsVisible else { continue }
            let pinned = !self.activity.isPlaying || self.isScrubbing || self.isPointerOverControls
            if pinned {
                self.activity.lastActivity = clock.now
                continue
            }
            if clock.now - self.activity.lastActivity >= TuneTheme.NowPlaying.controlsAutoHideDelay {
                self.controlsVisible = false
                if self.isPointerInside {
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            }
        }
    }
}

// MARK: - TuneNowPlayingTint

/// The field's base dark: the artwork's hue at a fixed deep brightness, so pale covers don't
/// wash the field out to slate and dark covers don't sink it to neutral black.
enum TuneNowPlayingTint {
    static func deepDark(from color: Color?) -> Color {
        guard let color, let rgb = NSColor(color).usingColorSpace(.sRGB) else {
            return TuneTheme.Palette.background
        }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // Near-grey art stays near-neutral; anything with a hue keeps a clear cast.
        let deepSaturation = saturation < 0.08 ? saturation : min(max(saturation, 0.5), 0.75)
        return Color(nsColor: NSColor(
            colorSpace: .sRGB,
            hue: hue,
            saturation: deepSaturation,
            brightness: TuneTheme.NowPlaying.fieldBrightness,
            alpha: 1
        ))
    }
}

// MARK: - TuneNowPlayingActivityClock

/// Last pointer activity and play state for the auto-hide loop. A plain reference so pointer
/// moves don't invalidate the view and the long-lived loop reads current values.
@MainActor
final class TuneNowPlayingActivityClock {
    var lastActivity = ContinuousClock.now
    var isPlaying = false
}

// MARK: - TuneNowPlayingMetrics

/// Window-relative geometry for both compositions. With the Up Next pane open, everything
/// left of it lays out in the narrower content area; narrow windows drop the side artwork so
/// the lyrics keep a full column.
struct TuneNowPlayingMetrics: Equatable {
    let size: CGSize
    var showsQueue = false

    private typealias Tokens = TuneTheme.NowPlaying

    /// Up Next pane width; 0 when closed.
    var queueWidth: CGFloat {
        guard self.showsQueue else { return 0 }
        let share = self.size.width * Tokens.queueWidthShare
        return min(max(share, Tokens.queueWidthRange.lowerBound), Tokens.queueWidthRange.upperBound).rounded(.down)
    }

    /// Width left of the Up Next pane (the whole window when it's closed).
    var contentWidth: CGFloat {
        max(0, self.size.width - self.queueWidth)
    }

    /// With the pane open, a window this narrow gives the artwork's room to the lyrics.
    private var queueCrowdsArtwork: Bool {
        self.showsQueue && self.size.width < Tokens.queueArtworkMinimumWindowWidth
    }

    var columnLeading: CGFloat {
        min(Tokens.columnLeading, self.size.width * 0.067)
    }

    var columnWidth: CGFloat {
        let width: CGFloat = if self.queueCrowdsArtwork {
            // No artwork: the column runs to a gutter short of the pane.
            self.contentWidth - self.columnLeading - TuneTheme.Spacing.gutter
        } else if self.showsQueue {
            self.contentWidth * Tokens.columnWidthShareBesideQueue
        } else {
            self.size.width * Tokens.columnWidthShare
        }
        return max(0, min(Tokens.columnMaxWidth, width)).rounded(.down)
    }

    /// Region right of the text column that holds the artwork: up to the window margin, or a
    /// gutter short of the Up Next pane.
    private var sideRegion: CGRect {
        let minX = self.columnLeading + self.columnWidth + TuneTheme.Spacing.gutter
        let maxX = self.showsQueue
            ? self.contentWidth - TuneTheme.Spacing.gutter
            : self.size.width - self.columnLeading
        return CGRect(x: minX, y: 0, width: max(0, maxX - minX), height: self.size.height)
    }

    /// Side artwork edge; 0 when the window is too narrow to show it well.
    var sideArtworkEdge: CGFloat {
        guard !self.queueCrowdsArtwork else { return 0 }
        let edge = min(self.sideRegion.width, self.size.height - Tokens.headerTop * 2)
        return edge >= Tokens.minimumSideArtwork ? edge.rounded(.down) : 0
    }

    var sideArtworkCenter: CGPoint {
        CGPoint(x: self.sideRegion.midX, y: self.size.height / 2)
    }

    // MARK: Video

    /// Where the video goes in the lyrics composition.
    enum VideoPlacement: Equatable {
        /// No video: the artwork (or nothing) as before.
        case none
        /// Beside the lyrics, in the artwork's region.
        case side(CGSize)
        /// Over the lyrics in the text column, when the side region is too narrow (or the
        /// Up Next pane crowds the artwork out under 1200 pt).
        case stacked(CGSize)

        var isStacked: Bool {
            if case .stacked = self { return true }
            return false
        }
    }

    func videoPlacement(showsVideo: Bool) -> VideoPlacement {
        guard showsVideo else { return .none }
        let side = self.sideVideoSize
        return side == .zero ? .stacked(self.stackedVideoSize) : .side(side)
    }

    /// 16:9 video filling the artwork region's width (kept inside the title-to-transport
    /// band); `.zero` when that region can't hold a worthwhile one.
    var sideVideoSize: CGSize {
        guard !self.queueCrowdsArtwork else { return .zero }
        let fitted = Self.videoSize(fitting: CGSize(
            width: self.sideRegion.width,
            height: self.size.height - Tokens.headerTop - Tokens.footerBottom
        ))
        return fitted.width >= Tokens.minimumSideVideoWidth ? fitted : .zero
    }

    /// 16:9 video across the text column, capped in height so the lyrics keep room.
    var stackedVideoSize: CGSize {
        Self.videoSize(fitting: CGSize(
            width: self.columnWidth,
            height: self.size.height * Tokens.stackedVideoHeightShare
        ))
    }

    /// The no-lyrics composition's video: the square artwork's height budget, 16:9.
    var centeredVideoSize: CGSize {
        Self.videoSize(fitting: CGSize(
            width: self.contentWidth - self.columnLeading * 2,
            height: self.size.height * Tokens.centeredArtworkShare
        ))
    }

    /// Largest 16:9 rect inside `bounds`, on whole points; `.zero` for empty or non-finite input.
    static func videoSize(fitting bounds: CGSize) -> CGSize {
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        let width = min(bounds.width, bounds.height * 16 / 9).rounded(.down)
        return CGSize(width: width, height: (width * 9 / 16).rounded(.down))
    }

    /// Center of a side slot `height` tall: on the lyrics field when it's known, kept between
    /// the title's top and the transport's bottom.
    func sideSlotCenter(height: CGFloat, lyricsViewport: CGRect?) -> CGPoint {
        let fallback = self.sideArtworkCenter
        guard let lyricsViewport, lyricsViewport.height > 0 else { return fallback }
        let half = height / 2
        let top = Tokens.headerTop + half
        let bottom = self.size.height - Tokens.footerBottom - half
        guard top <= bottom else { return fallback }
        return CGPoint(x: fallback.x, y: min(max(lyricsViewport.midY, top), bottom))
    }

    /// Window y of the active lyric line's center.
    var lyricFocusY: CGFloat {
        self.size.height * Tokens.lyricFocusWindowShare
    }

    /// Side artwork center, vertically centered on the lyrics field when it's known, but kept
    /// between the title's top and the transport's bottom.
    func sideArtworkCenter(lyricsViewport: CGRect?) -> CGPoint {
        self.sideSlotCenter(height: self.sideArtworkEdge, lyricsViewport: lyricsViewport)
    }

    /// Artwork edge of the no-lyrics composition, centered in the content area.
    var centeredArtworkEdge: CGFloat {
        let byHeight = self.size.height * Tokens.centeredArtworkShare
        let byWidth = self.contentWidth - self.columnLeading * 2
        return max(0, min(byHeight, byWidth)).rounded(.down)
    }

    /// Transport width of the no-lyrics composition: wide enough for the toggles to leave the
    /// scrubber real room, never past the content area's margins.
    var centeredTransportWidth: CGFloat {
        max(0, min(Tokens.transportWidth, self.contentWidth - self.columnLeading * 2))
    }
}

// MARK: - TuneNowPlayingArtworkShape

/// Corner radius of Now Playing's artwork and video: hero corners on the big composition,
/// artwork corners once a narrow window shrinks it to card size.
enum TuneNowPlayingArtworkShape {
    static let heroThreshold: CGFloat = 300

    static func radius(forEdge edge: CGFloat) -> CGFloat {
        guard edge.isFinite, edge > 0 else { return TuneTheme.Radius.artwork }
        return edge > self.heroThreshold ? TuneTheme.Radius.hero : TuneTheme.Radius.artwork
    }
}
