import SwiftUI

// MARK: - SearchView

/// Search view for finding music.
struct SearchView: View {
    @State var viewModel: SearchViewModel
    @Environment(PlayerService.self) private var playerService
    @Environment(AuthService.self) private var authService
    @State private var navigationPath = NavigationPath()
    @State private var networkMonitor = NetworkMonitor.shared

    /// External trigger for focusing the search field (from keyboard shortcut).
    @Binding var focusTrigger: Bool

    @FocusState private var isSearchFieldFocused: Bool

    /// Index of currently selected suggestion for keyboard navigation.
    @State private var selectedSuggestionIndex: Int = -1

    /// Initializes SearchView with optional focus trigger binding.
    init(viewModel: SearchViewModel, focusTrigger: Binding<Bool> = .constant(false)) {
        _viewModel = State(initialValue: viewModel)
        _focusTrigger = focusTrigger
    }

    var body: some View {
        NavigationStack(path: self.$navigationPath) {
            VStack(spacing: 0) {
                // Search bar
                self.searchBar
                    .zIndex(1)

                // Content
                self.contentView
            }
            .localizedNavigationTitle("Search")
            .navigationDestinations(client: self.viewModel.client)
            .playerBarMusicNavigation(path: self.$navigationPath)
        }
        .playerBarMusicNavigation(path: self.$navigationPath)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
                .playerBarMusicNavigation(path: self.$navigationPath)
        }
        .onAppear {
            self.isSearchFieldFocused = true
        }
        .onChange(of: self.focusTrigger) { _, newValue in
            if newValue {
                self.isSearchFieldFocused = true
                self.focusTrigger = false
            }
        }
        .popsNavigationStackOnSidebarReselect(path: self.$navigationPath, for: .search)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        VStack(spacing: 12) {
            // Keep suggestions as an overlay of the field itself. If the dropdown participates
            // in the search bar's layout, macOS 26 glass materialization can render a
            // second transient plate during updates. Anchoring it as an overlay gives the
            // autocomplete menu a single visual owner and prevents duplicate dropdowns.
            self.searchField
                .overlay(alignment: .top) {
                    if self.viewModel.showSuggestions {
                        self.suggestionsDropdown
                            .padding(.top, 42) // Below search field
                    }
                }
                .zIndex(1)

            // Filter chips
            if self.viewModel.shouldShowFilters {
                self.filterChips
            }
        }
        .padding(.horizontal, TuneTheme.Spacing.gutter)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .onChange(of: self.viewModel.query) { _, _ in
            self.selectedSuggestionIndex = -1
            self.viewModel.fetchSuggestions()
        }
        .onChange(of: self.viewModel.suggestions) { _, _ in
            self.selectedSuggestionIndex = -1
        }
    }

    /// C2 field: a quiet rounded rectangle on a raised fill with a hairline (the toolbar
    /// field's look, larger) — no glass capsule.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(TuneTheme.Typeface.body)
                .foregroundStyle(TuneTheme.Palette.inkMuted)

            TextField(String(localized: "Search songs, albums, artists..."), text: self.$viewModel.query)
                .textFieldStyle(.plain)
                .font(TuneTheme.Typeface.body)
                .foregroundStyle(TuneTheme.Palette.ink)
                .focused(self.$isSearchFieldFocused)
                .onSubmit {
                    HapticService.success()
                    if self.selectedSuggestionIndex >= 0,
                       self.selectedSuggestionIndex < self.viewModel.suggestions.count
                    {
                        self.viewModel.selectSuggestion(self.viewModel.suggestions[self.selectedSuggestionIndex])
                    } else {
                        self.viewModel.search()
                    }
                }
                .onKeyPress(.downArrow) {
                    if self.viewModel.showSuggestions {
                        self.selectedSuggestionIndex = min(
                            self.selectedSuggestionIndex + 1,
                            self.viewModel.suggestions.count - 1
                        )
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.upArrow) {
                    if self.viewModel.showSuggestions {
                        self.selectedSuggestionIndex = max(self.selectedSuggestionIndex - 1, -1)
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.escape) {
                    if self.viewModel.showSuggestions {
                        self.viewModel.clearSuggestions()
                        return .handled
                    }
                    return .ignored
                }
                .accessibilityIdentifier(AccessibilityID.Search.searchField)

            if !self.viewModel.query.isEmpty {
                Button {
                    self.viewModel.clear()
                } label: {
                    Image(systemName: "xmark")
                        .font(TuneTheme.Typeface.label)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                        .frame(width: 20, height: 20)
                        .contentShape(.tuneRounded(TuneTheme.Radius.small))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear search"))
                .accessibilityIdentifier(AccessibilityID.Search.clearButton)
            }

            Text(verbatim: "⌘K")
                .font(TuneTheme.Typeface.data)
                .foregroundStyle(TuneTheme.Palette.inkDim)
                .fixedSize()
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(TuneTheme.Palette.raised.opacity(0.7), in: .tuneRounded(TuneTheme.Radius.control))
        .overlay {
            RoundedRectangle.tuneRounded(TuneTheme.Radius.control)
                .strokeBorder(self.isSearchFieldFocused ? TuneTheme.Palette.rule : TuneTheme.Palette.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var suggestionsDropdown: some View {
        VStack(spacing: 0) {
            ForEach(Array(self.viewModel.suggestions.prefix(7).enumerated()), id: \.element.id) { index, suggestion in
                self.suggestionRow(suggestion, index: index)
            }
        }
        .padding(6)
        .background(TuneTheme.Palette.panel, in: .tuneRounded(TuneTheme.Radius.panel))
        .overlay {
            RoundedRectangle.tuneRounded(TuneTheme.Radius.panel)
                .strokeBorder(TuneTheme.Palette.rule, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(AccessibilityID.Search.suggestionsContainer)
    }

    private func suggestionRow(_ suggestion: SearchSuggestion, index: Int) -> some View {
        Button {
            self.viewModel.selectSuggestion(suggestion)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(TuneTheme.Typeface.label)
                    .foregroundStyle(TuneTheme.Palette.inkDim)
                    .frame(width: 16)

                Text(suggestion.query)
                    .font(TuneTheme.Typeface.body)
                    .foregroundStyle(TuneTheme.Palette.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.up.left")
                    .font(TuneTheme.Typeface.label)
                    .foregroundStyle(TuneTheme.Palette.inkDim)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                index == self.selectedSuggestionIndex ? TuneTheme.Palette.raised : Color.clear,
                in: .tuneRounded(TuneTheme.Radius.control)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.Search.suggestion(index: index))
    }

    /// C2 filter row: caps text, the selected filter ink and underlined, the rest muted. No pills.
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TuneTheme.Spacing.unit * 5) {
                ForEach(SearchViewModel.SearchFilter.allCases) { filter in
                    self.filterChip(filter)
                }
            }
            .padding(.vertical, TuneTheme.Spacing.unit)
        }
    }

    private func filterChip(_ filter: SearchViewModel.SearchFilter) -> some View {
        TuneNowPlayingTextToggle(
            title: Text(filter.displayName),
            isOn: self.viewModel.selectedFilter == filter,
            action: {
                withAnimation(AppAnimation.spring) {
                    self.viewModel.selectedFilter = filter
                }
            }
        )
        .accessibilityLabel(Text(filter.displayName))
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        if !self.networkMonitor.isConnected {
            ErrorView(
                title: String(localized: "No Connection"),
                message: String(localized: "Please check your internet connection and try again.")
            ) {
                self.viewModel.search()
            }
        } else {
            switch self.viewModel.loadingState {
            case .idle:
                self.emptyStateView
            case .loading:
                LoadingView(String(localized: "Searching..."), layout: .list)
            case .loaded, .loadingMore:
                if self.viewModel.filteredItems.isEmpty {
                    self.noResultsView
                } else {
                    self.resultsView
                }
            case let .error(error):
                ErrorView(error: error) {
                    self.viewModel.search()
                }
            }
        }
    }

    private var emptyStateView: some View {
        TuneEmptyState(
            title: self.viewModel.query.isEmpty ? String(localized: "Search for your favorite music") : String(localized: "Press Enter to search"),
            message: String(localized: "Find songs, albums, artists, and playlists")
        )
    }

    private var noResultsView: some View {
        TuneEmptyState(
            title: String(localized: "No results found"),
            message: String(localized: "Try searching for something else")
        )
    }

    private var resultsView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(self.viewModel.filteredItems.enumerated()), id: \.element.id) { index, item in
                    self.resultRow(item, index: index)
                }

                // Load more indicator / button
                if self.viewModel.hasMoreResults {
                    self.loadMoreView
                }
            }
            .padding(.horizontal, TuneTheme.Spacing.gutter - Self.rowInset)
            .padding(.top, 8)
            .padding(.bottom, TuneTheme.Spacing.scrollEndInset)
        }
    }

    /// Rows inset their content by this much so the hover fill bleeds past the text edge.
    private static let rowInset: CGFloat = 8
    private static let thumbnailSide: CGFloat = 40
    /// Fits the longest kind ("AUDIOBOOK") in 11 pt mono.
    private static let kindSlotWidth: CGFloat = 68

    /// Load more view that triggers pagination when visible.
    @ViewBuilder
    private var loadMoreView: some View {
        if self.viewModel.loadingState == .loadingMore {
            HStack(spacing: 8) {
                FixedProgressView(controlSize: .small, scale: 0.7)
                Text("Loading more...", comment: "Shown while loading more search results")
                    .font(TuneTheme.Typeface.data)
                    .textCase(.uppercase)
                    .foregroundStyle(TuneTheme.Palette.inkMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else {
            Button {
                Task { await self.viewModel.loadMore() }
            } label: {
                Text("Load More", comment: "Button to load more search results")
                    .font(TuneTheme.Typeface.data)
                    .textCase(.uppercase)
                    .foregroundStyle(TuneTheme.Palette.inkMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.plain)
            .onAppear {
                // Auto-load more when this view appears (infinite scroll)
                Task { await self.viewModel.loadMore() }
            }
        }
    }

    private func resultRow(_ item: SearchResultItem, index: Int) -> some View {
        HoverObservingRow { isHovered in
            Button {
                self.handleItemTap(item)
            } label: {
                let side = Self.thumbnailSide
                let text = Self.displayText(for: item)
                HStack(spacing: 14) {
                    // Thumbnail
                    CachedAsyncImage(url: item.thumbnailURL?.highQualityThumbnailURL, targetSize: CGSize(width: side, height: side)) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        TuneTheme.Palette.raised
                            .overlay {
                                Image(systemName: self.iconForItem(item))
                                    .font(TuneTheme.Typeface.label)
                                    .foregroundStyle(TuneTheme.Palette.inkDim)
                            }
                    }
                    .frame(width: side, height: side)
                    // Artists get the same soft square as everything else (as in Library).
                    .clipShape(.rect(cornerRadius: TuneTheme.Radius.small, style: .continuous))

                    // Info
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(text.title)
                                .font(TuneTheme.Typeface.body)
                                .foregroundStyle(TuneTheme.Palette.ink)
                                .lineLimit(1)
                            if let song = self.songResultPayload(for: item), song.isExplicit == true {
                                ExplicitBadge()
                            }
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            // A fixed slot, so subtitles start on one edge whatever the kind.
                            Text(item.resultType)
                                .font(TuneTheme.Typeface.data)
                                .textCase(.uppercase)
                                .foregroundStyle(TuneTheme.Palette.inkDim)
                                .lineLimit(1)
                                .frame(minWidth: Self.kindSlotWidth, alignment: .leading)
                                .fixedSize()

                            if !text.subtitle.isEmpty {
                                Text(text.subtitle)
                                    .font(TuneTheme.Typeface.body)
                                    .foregroundStyle(TuneTheme.Palette.inkMuted)
                                    .lineLimit(1)
                            }
                        }
                    }

                    Spacer(minLength: 0)

                    // Favorite toggle for songs
                    if let song = self.songResultPayload(for: item) {
                        LikeButton(song: song, isRowHovered: isHovered, allowsActions: self.authService.hasPersonalAccount)
                    }
                }
                .padding(.horizontal, Self.rowInset)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.interactiveRow(cornerRadius: TuneTheme.Radius.control))
            .accessibilityIdentifier(AccessibilityID.Search.resultRow(index: index))
        }
        .contextMenu {
            SearchResultItemContextMenu(
                item: item,
                client: self.viewModel.client,
                play: { self.handleItemTap(item) },
                navigate: { self.navigationPath.append($0) }
            )
        }
    }

    // MARK: - Helpers

    /// Display title and subtitle: songs and videos get the cleaned title/artist (see
    /// `TrackDisplayText`); every subtitle drops separators around empty fields.
    static func displayText(for item: SearchResultItem) -> (title: String, subtitle: String) {
        switch item {
        case let .song(song), let .video(song):
            let display = song.displayText
            return (display.title, display.artist)
        default:
            return (item.title, TrackDisplayText.cleanByline(item.subtitle ?? ""))
        }
    }

    private func iconForItem(_ item: SearchResultItem) -> String {
        switch item {
        case .song:
            "music.note"
        case .video:
            "play.rectangle"
        case .album:
            "square.stack"
        case .audiobook:
            "books.vertical"
        case .artist:
            "person"
        case .profile:
            "person.crop.circle"
        case .playlist:
            "music.note.list"
        case .podcastShow:
            "mic.fill"
        case .podcastEpisode:
            "mic.badge.plus"
        }
    }

    private func handleItemTap(_ item: SearchResultItem) {
        switch item {
        case let .song(song), let .video(song):
            // Play the song and fetch similar songs (radio queue) in the background
            Task {
                await self.playerService.playWithRadio(song: song)
            }
        case let .artist(artist), let .profile(artist):
            self.navigationPath.append(artist)
        case let .album(album), let .audiobook(album):
            // Navigate as playlist for now
            let playlist = Playlist(
                id: album.id,
                title: album.title,
                description: nil,
                thumbnailURL: album.thumbnailURL,
                trackCount: album.trackCount,
                author: Artist.inline(name: album.artistsDisplay, namespace: "album-artist")
            )
            self.navigationPath.append(playlist)
        case let .playlist(playlist):
            self.navigationPath.append(playlist)
        case let .podcastShow(show):
            self.navigationPath.append(show)
        case let .podcastEpisode(episode):
            Task {
                await self.playerService.play(song: episode.playbackSong)
            }
        }
    }

    private func songResultPayload(for item: SearchResultItem) -> Song? {
        switch item {
        case let .song(song), let .video(song):
            song
        default:
            nil
        }
    }
}

#Preview {
    @Previewable @State var focusTrigger = false
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    SearchView(viewModel: SearchViewModel(client: client), focusTrigger: $focusTrigger)
        .environment(PlayerService())
        .environment(FavoritesManager.shared)
}
