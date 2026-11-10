import SwiftUI

/// View displaying the user's YouTube Music listening history.
/// Fetches history from the API and displays songs grouped by time period.
struct HistoryView: View {
    @State var viewModel: HistoryViewModel
    @Environment(PlayerService.self) private var playerService
    @State private var navigationPath = NavigationPath()
    @State private var networkMonitor = NetworkMonitor.shared
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack(path: self.$navigationPath) {
            Group {
                if !self.networkMonitor.isConnected {
                    ErrorView(
                        title: String(localized: "No Connection"),
                        message: String(localized: "Please check your internet connection and try again.")
                    ) {
                        Task { await self.performRefresh() }
                    }
                } else {
                    switch self.viewModel.loadingState {
                    case .idle, .loading:
                        LoadingView(String(localized: "Loading..."), layout: .list)
                    case .loaded, .loadingMore:
                        self.contentView
                    case let .error(error):
                        ErrorView(error: error) {
                            Task { await self.performRefresh() }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .localizedNavigationTitle("Listening History")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { await self.performRefresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(self.isRefreshing ? 360 : 0))
                            .animation(
                                self.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                                value: self.isRefreshing
                            )
                    }
                    .help(String(localized: "Refresh"))
                    .disabled(self.isRefreshing)
                }
            }
            .navigationDestinations(client: self.viewModel.client)
            .playerBarMusicNavigation(path: self.$navigationPath)
        }
        .playerBarMusicNavigation(path: self.$navigationPath)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
                .playerBarMusicNavigation(path: self.$navigationPath)
        }
        .task {
            if self.viewModel.loadingState == .idle {
                await self.viewModel.load()
                self.viewModel.syncObservedPlayback(videoId: self.playerService.currentTrack?.videoId)
            }
        }
        .onAppear {
            self.viewModel.schedulePlaybackRefreshIfNeeded(for: self.playerService.currentTrack?.videoId)
        }
        .onChange(of: self.playerService.currentTrack?.videoId) { _, newVideoId in
            self.viewModel.schedulePlaybackRefreshIfNeeded(for: newVideoId)
        }
        .refreshable {
            await self.performRefresh()
        }
        .popsNavigationStackOnSidebarReselect(path: self.$navigationPath, for: .history)
    }

    /// Refreshes with visual feedback: spinning icon → data swap.
    @discardableResult
    private func performRefresh() async -> Bool {
        self.isRefreshing = true
        let changed = await self.viewModel.refresh()
        self.isRefreshing = false
        return changed
    }

    // MARK: - Content

    /// C2 header: caps eyebrow, the page title, and one mono stat. No gradient tile.
    private var headerView: some View {
        let todayCount = self.viewModel.sections.first?.items.count ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "Library"))
                .tuneCapsLabel()
                .padding(.bottom, 12)
            Text(String(localized: "History"))
                .font(TuneTheme.Typeface.headline)
                .tracking(-1)
                .foregroundStyle(TuneTheme.Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Text(String(localized: "\(todayCount) songs listened today"))
                .font(TuneTheme.Typeface.data)
                .textCase(.uppercase)
                .foregroundStyle(TuneTheme.Palette.inkMuted)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var contentView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                self.headerView
                    .padding(.bottom, 12)

                ForEach(self.viewModel.sections) { section in
                    Text(section.title)
                        .font(TuneTheme.Typeface.section)
                        .foregroundStyle(TuneTheme.Palette.ink)
                        .lineLimit(1)
                        .padding(.top, 32)
                        .padding(.bottom, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(TuneTheme.Palette.rule)
                                .frame(height: 1)
                        }
                        .padding(.bottom, 6)
                        .accessibilityAddTraits(.isHeader)

                    let songs = section.items.compactMap { item -> Song? in
                        if case let .song(song) = item {
                            return song
                        }
                        return nil
                    }

                    ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                        self.songRow(song, allSongs: songs, index: index)
                            .id("\(section.id)-\(index)")
                    }
                }

                if self.viewModel.hasMoreSections || self.viewModel.loadingState == .loadingMore {
                    LoadMoreFooter(
                        isLoading: self.viewModel.loadingState == .loadingMore || self.viewModel.isRefreshingHistory,
                        title: "Load More History",
                        loadingTitle: "Loading more history...",
                        autoLoad: true,
                        autoLoadTrigger: self.viewModel.sections.count
                    ) {
                        await self.viewModel.loadMore()
                    }
                }
            }
            .padding(.top, 28)
            .padding(.bottom, TuneTheme.Spacing.scrollEndInset)
            .detailScrollContentInset()
        }
        .accessibilityIdentifier(AccessibilityID.History.scrollView)
    }

    // MARK: - Song Row

    private static let thumbnailSide: CGFloat = 32
    /// Hover fill bleed past the text edge, as on playlist rows.
    private static let rowBleed: CGFloat = 8

    private func songRow(_ song: Song, allSongs: [Song], index: Int) -> some View {
        let display = song.displayText
        let isCurrent = self.playerService.currentTrack?.videoId == song.videoId
        return HoverObservingRow { isHovered in
            Button {
                Task {
                    await self.playerService.playQueue(allSongs, startingAt: index)
                }
            } label: {
                HStack(spacing: 14) {
                    SongThumbnailView(song: song, size: Self.thumbnailSide)

                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        HStack(spacing: 6) {
                            Text(display.title)
                                .font(TuneTheme.Typeface.body)
                                .foregroundStyle(isCurrent ? TuneTheme.Palette.accent : TuneTheme.Palette.ink)
                                .lineLimit(1)
                            if song.isExplicit == true {
                                ExplicitBadge()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(display.artist)
                            .font(TuneTheme.Typeface.body)
                            .foregroundStyle(TuneTheme.Palette.inkMuted)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    LikeButton(song: song, isRowHovered: isHovered)

                    Text(song.durationDisplay)
                        .font(TuneTheme.Typeface.data)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(.horizontal, Self.rowBleed)
                .frame(height: 44)
                .background {
                    if isHovered {
                        RoundedRectangle.tuneRounded(TuneTheme.Radius.control)
                            .fill(TuneTheme.Palette.raised)
                    }
                }
                .padding(.horizontal, -Self.rowBleed)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            SongContextMenu(
                song: song,
                client: self.viewModel.client,
                play: { Task { await self.playerService.playQueue(allSongs, startingAt: index) } }
            )
        }
    }
}
