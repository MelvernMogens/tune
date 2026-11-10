import AppKit
import SwiftUI

// MARK: - TuneNowPlayingSearchFilter

/// SONGS · VIDEOS above the results: YouTube Music's own Songs and Videos search filters.
enum TuneNowPlayingSearchFilter: CaseIterable, Equatable {
    case songs
    case videos

    init?(_ filter: SearchViewModel.SearchFilter) {
        switch filter {
        case .songs: self = .songs
        case .videos: self = .videos
        default: return nil
        }
    }

    var searchFilter: SearchViewModel.SearchFilter {
        switch self {
        case .songs: .songs
        case .videos: .videos
        }
    }

    /// Tab flips between the two.
    var toggled: Self {
        self == .songs ? .videos : .songs
    }

    /// Whether Tab (or ⇧Tab) in the overlay's window flips the filter instead of moving focus:
    /// only while the search field has focus and a query, and never mid-composition.
    static func tabSwitchesFilter(
        isPresented: Bool,
        isOverlayWindow: Bool,
        hasAttachedSheet: Bool,
        hasNonShiftModifiers: Bool,
        isComposingText: Bool,
        isSearchFocusedWithQuery: Bool
    ) -> Bool {
        isPresented && isOverlayWindow && !hasAttachedSheet && !hasNonShiftModifiers
            && !isComposingText && isSearchFocusedWithQuery
    }

    var title: LocalizedStringKey {
        switch self {
        case .songs: "Songs"
        case .videos: "Videos"
        }
    }

    var emptyStatus: LocalizedStringKey {
        switch self {
        case .songs: "No songs found"
        case .videos: "No videos found"
        }
    }
}

// MARK: - TuneNowPlayingSearchResults

/// Song or video results for the fullscreen search dropdown. Built by `TuneNowPlayingHost`
/// from the app's `SearchViewModel` (Songs / Videos filter); pure so it renders from fixtures.
struct TuneNowPlayingSearchResults: Equatable {
    struct Item: Equatable, Identifiable {
        /// The song's video id.
        let id: String
        var title: String
        var artist: String
        var thumbnailURL: URL?
        /// Seconds; nil when unknown.
        var duration: TimeInterval?
    }

    enum Phase: Equatable {
        case idle
        case searching
        case loaded
        case failed
    }

    var items: [Item] = []
    var phase: Phase = .idle
    /// Which filter produced `items`.
    var filter: TuneNowPlayingSearchFilter = .songs

    static let empty = TuneNowPlayingSearchResults()

    /// The dropdown lists at most this many results.
    static let maximumItems = 8

    /// While the next query is in flight, the rows already on screen stay up rather than
    /// flashing empty — but only rows of the same filter: a Songs list never sits under VIDEOS.
    static func keepsShownRows(shown: Self, incoming: Self) -> Bool {
        incoming.phase == .searching
            && incoming.items.isEmpty
            && !shown.items.isEmpty
            && incoming.filter == shown.filter
    }
}

// MARK: - TuneNowPlayingSearchSelection

/// Keyboard selection in the search dropdown. The top result is selected by default so
/// Return plays it; ↑/↓ move within the results and stop at the ends.
struct TuneNowPlayingSearchSelection: Equatable {
    private(set) var index = 0

    /// The selected row for `count` results; nil when there are none.
    func resolved(count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(max(self.index, 0), count - 1)
    }

    mutating func moveDown(count: Int) {
        guard let current = self.resolved(count: count) else { return }
        self.index = min(current + 1, count - 1)
    }

    mutating func moveUp(count: Int) {
        guard let current = self.resolved(count: count) else { return }
        self.index = max(current - 1, 0)
    }

    /// Selects `index` (the row under the pointer), clamped to the results.
    mutating func select(_ index: Int, count: Int) {
        guard count > 0 else { return }
        self.index = min(max(index, 0), count - 1)
    }

    /// Back to the top result (new query or new results).
    mutating func reset() {
        self.index = 0
    }
}

// MARK: - TuneNowPlayingEscape

/// What Esc does in the fullscreen view: first it dismisses the search (clears the text and
/// gives focus back), and only a second Esc closes the view.
enum TuneNowPlayingEscape: Equatable {
    case dismissSearch
    case close

    static func resolve(isSearchFocused: Bool, hasQuery: Bool) -> Self {
        isSearchFocused || hasQuery ? .dismissSearch : .close
    }

    /// Esc as the overlay's key monitor sees it, before AppKit dispatches it. Unclaimed, Esc
    /// in a native full-screen window reaches `NSWindow.cancelOperation(_:)` and exits full
    /// screen; so while the overlay is up its window's Esc is always taken here. Anything
    /// else — no overlay, another window or a sheet, a modifier, text being composed by an
    /// input method — passes through untouched (nil).
    static func route(
        isPresented: Bool,
        isOverlayWindow: Bool,
        hasAttachedSheet: Bool,
        hasModifiers: Bool,
        isComposingText: Bool,
        isSearchEngaged: Bool
    ) -> Self? {
        guard isPresented, isOverlayWindow, !hasAttachedSheet, !hasModifiers, !isComposingText else {
            return nil
        }
        return Self.resolve(isSearchFocused: isSearchEngaged, hasQuery: false)
    }
}

// MARK: - TuneNowPlayingEscapeKeyCatcher

/// Claims Esc for the overlay's window while the overlay is mounted (see
/// `TuneNowPlayingEscape.route`). The monitor lives with this view: installed for the
/// window it joins, moved when the window changes, removed when the overlay closes.
struct TuneNowPlayingEscapeKeyCatcher: NSViewRepresentable {
    func makeNSView(context _: Context) -> TuneNowPlayingEscapeKeyView {
        TuneNowPlayingEscapeKeyView()
    }

    func updateNSView(_: TuneNowPlayingEscapeKeyView, context _: Context) {}

    static func dismantleNSView(_ view: TuneNowPlayingEscapeKeyView, coordinator _: ()) {
        view.stopMonitoring()
    }
}

/// Invisible anchor that owns the overlay's key-down monitor for its window: Esc, and Tab
/// for the search filter (a text field's own Tab handling would move focus first).
final class TuneNowPlayingEscapeKeyView: NSView {
    nonisolated static let escapeKeyCode: UInt16 = 53
    nonisolated static let tabKeyCode: UInt16 = 48

    private var monitor: Any?

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.stopMonitoring()
        guard self.window != nil else { return }
        self.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            guard keyCode == Self.escapeKeyCode || keyCode == Self.tabKeyCode else { return event }
            let handled = MainActor.assumeIsolated {
                keyCode == Self.escapeKeyCode
                    ? self?.handleEscape(event) ?? false
                    : self?.handleTab(event) ?? false
            }
            return handled ? nil : event
        }
    }

    func stopMonitoring() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    isolated deinit {
        self.stopMonitoring()
    }

    private func handleTab(_ event: NSEvent) -> Bool {
        guard let window = self.window else { return false }
        let presentation = NowPlayingPresentation.shared
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function, .shift])
        guard TuneNowPlayingSearchFilter.tabSwitchesFilter(
            isPresented: presentation.isPresented,
            isOverlayWindow: event.window === window,
            hasAttachedSheet: window.attachedSheet != nil,
            hasNonShiftModifiers: !modifiers.isEmpty,
            isComposingText: (window.firstResponder as? NSTextView)?.hasMarkedText() == true,
            isSearchFocusedWithQuery: presentation.isSearchFocusedWithQuery
        ) else { return false }
        presentation.requestSearchFilterToggle()
        return true
    }

    private func handleEscape(_ event: NSEvent) -> Bool {
        guard let window = self.window else { return false }
        let presentation = NowPlayingPresentation.shared
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let route = TuneNowPlayingEscape.route(
            isPresented: presentation.isPresented,
            isOverlayWindow: event.window === window,
            hasAttachedSheet: window.attachedSheet != nil,
            hasModifiers: !modifiers.isEmpty,
            isComposingText: (window.firstResponder as? NSTextView)?.hasMarkedText() == true,
            isSearchEngaged: presentation.isSearchEngaged
        )
        switch route {
        case .dismissSearch:
            presentation.requestSearchDismissal()
            return true
        case .close:
            presentation.isPresented = false
            return true
        case nil:
            return false
        }
    }
}

// MARK: - TuneNowPlayingFocus

/// Keyboard focus inside the fullscreen view: the view itself (Esc, `/`) or the search field.
enum TuneNowPlayingFocus: Hashable {
    case root
    case search
}

// MARK: - TuneNowPlayingSearchField

/// C2 `.cmd` field: a quiet rounded control-radius fill; the edge brightens while focused.
struct TuneNowPlayingSearchField: View {
    @Binding var query: String
    var focus: FocusState<TuneNowPlayingFocus?>.Binding

    private var isFocused: Bool {
        self.focus.wrappedValue == .search
    }

    private typealias Tokens = TuneTheme.NowPlaying

    var body: some View {
        HStack(spacing: TuneTheme.Spacing.unit * 2.5) {
            TextField(
                "",
                text: self.$query,
                prompt: Text("Search").foregroundStyle(TuneTheme.Palette.inkMuted)
            )
            .textFieldStyle(.plain)
            .focused(self.focus, equals: .search)
            .font(TuneTheme.Typeface.body)
            .foregroundStyle(TuneTheme.Palette.ink)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            if !self.isFocused, self.query.isEmpty {
                Text(verbatim: "/")
                    .font(TuneTheme.Typeface.data)
                    .foregroundStyle(TuneTheme.Palette.inkDim)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, TuneTheme.Spacing.unit * 2.5)
        .frame(width: Tokens.searchFieldWidth, height: Tokens.searchFieldHeight)
        .background(
            TuneTheme.Palette.ink.opacity(0.06),
            in: .rect(cornerRadius: TuneTheme.Radius.control, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: TuneTheme.Radius.control, style: .continuous)
                .strokeBorder(self.isFocused ? TuneTheme.Palette.inkMuted : TuneTheme.Palette.rule, lineWidth: 1)
        }
        .contentShape(.rect(cornerRadius: TuneTheme.Radius.control, style: .continuous))
        .accessibilityIdentifier(TuneNowPlayingAccessibilityID.searchField)
    }
}

// MARK: - TuneNowPlayingSearchDropdown

/// Hard-edged results panel under the search field: a deeper scrim of the field's own dark,
/// a SONGS · VIDEOS switch, up to eight rows. Status lines are quiet caps; no spinners.
struct TuneNowPlayingSearchDropdown: View {
    let results: TuneNowPlayingSearchResults
    /// The switch's selected filter (may lead `results.filter` while the search runs).
    var filter: TuneNowPlayingSearchFilter = .songs
    let selectedIndex: Int?
    /// Video ids added to the queue from this dropdown; their rows read QUEUED.
    let queuedIDs: Set<String>
    let tint: Color
    var onPlay: (String) -> Void = { _ in }
    var onPlayNext: (String) -> Void = { _ in }
    var onAddToQueue: (String) -> Void = { _ in }
    var onHover: (Int) -> Void = { _ in }
    var onSelectFilter: (TuneNowPlayingSearchFilter) -> Void = { _ in }

    private typealias Tokens = TuneTheme.NowPlaying

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TuneNowPlayingSearchFilterSwitch(selected: self.filter, onSelect: self.onSelectFilter)

            if self.results.items.isEmpty {
                self.status
            } else {
                ForEach(Array(self.results.items.enumerated()), id: \.element.id) { index, item in
                    TuneNowPlayingSearchRow(
                        item: item,
                        isVideo: self.results.filter == .videos,
                        isSelected: index == self.selectedIndex,
                        isQueued: self.queuedIDs.contains(item.id),
                        onPlay: { self.onPlay(item.id) },
                        onPlayNext: { self.onPlayNext(item.id) },
                        onAddToQueue: { self.onAddToQueue(item.id) },
                        onHover: { self.onHover(index) }
                    )
                }
            }
        }
        .padding(.vertical, TuneTheme.Spacing.unit * 2)
        .frame(width: Tokens.searchDropdownWidth, alignment: .leading)
        .background {
            // The field's dark, near-opaque: lyrics underneath must not read through.
            RoundedRectangle(cornerRadius: TuneTheme.Radius.panel, style: .continuous)
                .fill(self.tint.opacity(Tokens.searchScrimOpacity))
                .background(
                    TuneTheme.Palette.background,
                    in: .rect(cornerRadius: TuneTheme.Radius.panel, style: .continuous)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: TuneTheme.Radius.panel, style: .continuous)
                .strokeBorder(TuneTheme.Palette.ink.opacity(Tokens.queueRuleOpacity), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Search results"))
        .accessibilityIdentifier(TuneNowPlayingAccessibilityID.searchResults)
    }

    @ViewBuilder
    private var status: some View {
        let text: Text? = switch self.results.phase {
        case .idle: nil
        case .searching: Text("Searching")
        case .loaded: Text(self.filter.emptyStatus)
        case .failed: Text("Search failed")
        }
        if let text {
            text
                .tuneCapsLabel()
                .padding(.horizontal, Tokens.queueInset)
                .frame(height: Tokens.queueRowHeight)
        }
    }
}

// MARK: - TuneNowPlayingSearchRow

// MARK: - TuneNowPlayingSearchFilterSwitch

/// `SONGS · VIDEOS` header of the dropdown: caps, the active filter ink and underlined, the
/// other muted; a quiet `tab` keycap names the key that flips it.
struct TuneNowPlayingSearchFilterSwitch: View {
    let selected: TuneNowPlayingSearchFilter
    var onSelect: (TuneNowPlayingSearchFilter) -> Void = { _ in }

    private typealias Tokens = TuneTheme.NowPlaying

    var body: some View {
        HStack(spacing: TuneTheme.Spacing.unit * 1.5) {
            ForEach(Array(TuneNowPlayingSearchFilter.allCases.enumerated()), id: \.element) { index, filter in
                if index > 0 {
                    Text(verbatim: "·")
                        .font(TuneTheme.Typeface.label)
                        .foregroundStyle(TuneTheme.Palette.inkDim)
                        .accessibilityHidden(true)
                }
                TuneNowPlayingTextToggle(
                    title: Text(filter.title),
                    isOn: filter == self.selected,
                    action: { self.onSelect(filter) }
                )
            }
            Spacer(minLength: 0)
            Text(verbatim: "tab")
                .font(TuneTheme.Typeface.data)
                .foregroundStyle(TuneTheme.Palette.inkDim)
                .padding(.horizontal, TuneTheme.Spacing.unit)
                .padding(.vertical, 1)
                .overlay {
                    RoundedRectangle(cornerRadius: TuneTheme.Radius.keycap, style: .continuous)
                        .strokeBorder(TuneTheme.Palette.rule, lineWidth: 1)
                }
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Tokens.queueInset)
        .help(Text("Songs or videos (Tab)"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Search filter"))
        .accessibilityIdentifier(TuneNowPlayingAccessibilityID.searchFilter)
    }
}

// MARK: - TuneNowPlayingSearchRow

private struct TuneNowPlayingSearchRow: View {
    let item: TuneNowPlayingSearchResults.Item
    /// Video rows get a 16:9 thumb.
    var isVideo = false
    let isSelected: Bool
    let isQueued: Bool
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onHover: () -> Void

    private typealias Tokens = TuneTheme.NowPlaying

    var body: some View {
        Button(action: self.onPlay) {
            HStack(spacing: TuneTheme.Spacing.unit * 3) {
                TuneNowPlayingThumbnail(url: self.item.thumbnailURL, isWide: self.isVideo)

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

                if self.isQueued {
                    Text("Queued")
                        .font(TuneTheme.Typeface.data)
                        .textCase(.uppercase)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                } else if let duration = self.item.duration, duration > 0 {
                    Text(TuneNowPlayingTransport.format(duration))
                        .font(TuneTheme.Typeface.data)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                }
            }
            .padding(.horizontal, Tokens.queueInset)
            .frame(height: Tokens.queueRowHeight)
            .background {
                if self.isSelected {
                    RoundedRectangle(cornerRadius: TuneTheme.Radius.control, style: .continuous)
                        .fill(TuneTheme.Palette.ink.opacity(Tokens.searchSelectionOpacity))
                        .padding(.horizontal, Tokens.queueRowFillInset)
                }
            }
            .contentShape(.rect(cornerRadius: TuneTheme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            if hovering {
                self.onHover()
            }
        }
        .contextMenu {
            Button("Play Now", action: self.onPlay)
            Button("Play Next", action: self.onPlayNext)
            Button("Add to Queue", action: self.onAddToQueue)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }
}

// MARK: - TuneNowPlayingThumbnail

/// 32 pt square thumb with small rounded corners and the 1 px artwork edge (queue and search
/// rows); 57 × 32 (16:9) for video rows.
struct TuneNowPlayingThumbnail: View {
    let url: URL?
    var isWide = false

    private typealias Tokens = TuneTheme.NowPlaying

    private var width: CGFloat {
        self.isWide ? Tokens.videoThumbWidth : Tokens.queueThumbEdge
    }

    var body: some View {
        CachedAsyncImage(
            url: self.url,
            targetSize: CGSize(width: self.width, height: Tokens.queueThumbEdge)
        ) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            TuneTheme.Palette.raised.opacity(0.6)
        }
        .frame(width: self.width, height: Tokens.queueThumbEdge)
        .clipShape(.rect(cornerRadius: TuneTheme.Radius.small, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: TuneTheme.Radius.small, style: .continuous)
                .strokeBorder(TuneTheme.Palette.artworkEdge, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}
