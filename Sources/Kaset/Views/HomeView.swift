import SwiftUI

/// Home view displaying personalized content sections in YouTube Music's shelf
/// order, laid out in the C2 editorial style: the first shelf ("Listen again")
/// as a big hero, song lists as compact row grids, everything else as shelves
/// of hard-edged artwork.
struct HomeView: View {
    @State var viewModel: HomeViewModel
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager
    @Environment(AuthService.self) private var authService
    @State private var navigationPath = NavigationPath()
    @State private var networkMonitor = NetworkMonitor.shared
    /// Width of the scroll view, for the hero and song-grid layouts.
    @State private var contentWidth: CGFloat = 0
    /// Height of the scroll view's visible region (under the toolbar band), for the hero cap.
    @State private var visibleHeight: CGFloat = 0

    /// Page gutters (C2: 40 pt on both sides).
    private static let gutter = TuneTheme.Spacing.gutter

    var body: some View {
        NavigationStack(path: self.$navigationPath) {
            Group {
                if !self.networkMonitor.isConnected {
                    ErrorView(
                        title: String(localized: "No Connection"),
                        message: String(localized: "Please check your internet connection and try again.")
                    ) {
                        Task { await self.viewModel.refresh() }
                    }
                } else {
                    switch self.viewModel.loadingState {
                    case .idle, .loading:
                        HomeLoadingView()
                    case .loaded, .loadingMore:
                        self.contentView
                    case let .error(error):
                        ErrorView(error: error) {
                            Task { await self.viewModel.refresh() }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .localizedNavigationTitle("Home")
            .navigationDestinations(client: self.viewModel.client)
            .playerBarMusicNavigation(path: self.$navigationPath)
        }
        .playerBarMusicNavigation(path: self.$navigationPath)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
                .playerBarMusicNavigation(path: self.$navigationPath)
        }
        .onAppear {
            if self.viewModel.loadingState == .idle {
                Task {
                    await self.viewModel.load()
                }
            }
        }
        .popsNavigationStackOnSidebarReselect(path: self.$navigationPath, for: .home)
    }

    // MARK: - Views

    private var contentView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 48) {
                // Favorites section (hidden when empty)
                if self.authService.hasPersonalAccount, self.favoritesManager.isVisible {
                    FavoritesSection(
                        onNavigate: { destination in
                            if let playlist = destination as? Playlist {
                                self.navigationPath.append(playlist)
                            } else if let artist = destination as? Artist {
                                self.navigationPath.append(artist)
                            } else if let podcastShow = destination as? PodcastShow {
                                self.navigationPath.append(podcastShow)
                            }
                        },
                        contentInset: Self.gutter
                    )
                    .staggeredAppearance(index: 0)
                }

                // API sections, in YouTube Music's order. A short shelf (e.g.
                // "Recaps") shares a row with the shelf before it, as in C2.
                // Laid out only once the width is known, so the first pass
                // doesn't build shelves that the real layout throws away.
                ForEach(self.contentWidth > 0 ? HomeSectionRow.rows(for: self.viewModel.sections, width: self.innerWidth) : []) { row in
                    self.rowView(row)
                        .task {
                            // Resolve sections now: a refresh may replace them before the task runs.
                            let sections = self.viewModel.sections
                            for index in row.indices where sections.indices.contains(index) {
                                await self.prefetchImagesAsync(for: sections[index], at: index)
                            }
                        }
                }

                if self.viewModel.hasMoreSections || self.viewModel.loadingState == .loadingMore {
                    self.loadMoreControl
                }
            }
            // The ScrollView fills the detail column edge-to-edge; shelves
            // restore the gutter via `contentInset`, the SwiftUI sections via
            // padding. Only the vertical inset stays on the stack.
            .padding(.top, 32)
            .padding(.bottom, TuneTheme.Spacing.scrollEndInset)
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            CGSize(width: proxy.size.width, height: proxy.size.height - proxy.safeAreaInsets.top)
        } action: { size in
            self.contentWidth = size.width
            self.visibleHeight = size.height
        }
        .background(TuneTheme.Palette.background)
        .accessibilityIdentifier(AccessibilityID.Home.scrollView)
        .pullToRefresh {
            await self.viewModel.refresh()
        }
    }

    private var loadMoreControl: some View {
        LoadMoreFooter(
            isLoading: self.viewModel.loadingState == .loadingMore,
            title: "Load More",
            loadingTitle: "Loading more...",
            autoLoad: true,
            autoLoadTrigger: self.viewModel.sections.count
        ) {
            await self.viewModel.loadMore()
        }
    }

    /// Width inside the gutters; the SwiftUI sections lay out to this.
    private var innerWidth: CGFloat {
        max(0, self.contentWidth - 2 * Self.gutter)
    }

    @ViewBuilder
    private func rowView(_ row: HomeSectionRow) -> some View {
        let sections = self.viewModel.sections
        if let trailing = row.trailing {
            if sections.indices.contains(row.leading), sections.indices.contains(trailing) {
                HStack(alignment: .top, spacing: HomeSectionRow.pairGap) {
                    self.shelfView(sections[row.leading], contentInset: 0)
                        .frame(width: max(0, self.innerWidth - row.trailingWidth - HomeSectionRow.pairGap))
                    self.shelfView(sections[trailing], contentInset: 0)
                        .frame(width: row.trailingWidth)
                }
                .padding(.horizontal, Self.gutter)
            }
        } else if sections.indices.contains(row.leading) {
            self.sectionView(sections[row.leading], at: row.leading)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: HomeSection, at index: Int) -> some View {
        switch HomeShelfStyle.style(for: section, at: index) {
        case .hero:
            HomeHeroSection(
                section: section,
                width: self.innerWidth,
                maxHeight: HomeHeroLayout.maxHeight(forVisibleHeight: self.visibleHeight),
                action: { item, itemIndex in self.playItem(item, in: section, at: itemIndex) },
                contextMenu: { item, itemIndex in self.contextMenuItems(for: item, in: section, at: itemIndex) }
            )
            .padding(.horizontal, Self.gutter)
        case .songGrid:
            HomeSongGridSection(
                section: section,
                width: self.innerWidth,
                action: { item, itemIndex in self.playItem(item, in: section, at: itemIndex) },
                contextMenu: { item, itemIndex in self.contextMenuItems(for: item, in: section, at: itemIndex) }
            )
            .padding(.horizontal, Self.gutter)
        default:
            self.shelfView(section)
        }
    }

    private func shelfView(_ section: HomeSection, contentInset: CGFloat = Self.gutter) -> some View {
        HomeItemShelfSection(
            accessibilityLabel: section.title,
            items: section.items,
            isChart: section.isChart,
            contentInset: contentInset,
            action: { item, index in
                self.playItem(item, in: section, at: index)
            },
            playlistPlayAction: { item in
                self.playlistPlayAction(for: item)
            },
            header: {
                HomeSectionTitleText(title: section.title)
            },
            contextMenu: { item, index in
                self.contextMenuItems(for: item, in: section, at: index)
            }
        )
    }

    // MARK: - Context Menu

    private func playlistPlayAction(for item: HomeSectionItem) -> (() -> Void)? {
        guard case let .playlist(playlist) = item,
              SongActionsHelper.canQuickPlayPlaylist(playlist)
        else {
            return nil
        }

        return {
            SongActionsHelper.playPlaylist(
                playlist,
                client: self.viewModel.client,
                playerService: self.playerService
            )
        }
    }

    private func contextMenuItems(for item: HomeSectionItem, in section: HomeSection, at index: Int) -> some View {
        HomeSectionItemContextMenu(
            item: item,
            client: self.viewModel.client,
            play: { self.playItem(item, in: section, at: index) },
            navigate: { self.navigationPath.append($0) }
        )
    }

    // MARK: - Image Prefetching

    private func prefetchImagesAsync(for section: HomeSection, at index: Int) async {
        guard !Task.isCancelled else { return }
        // Warm exactly what the shelf cells will request (same URL and decode size),
        // otherwise the prefetch decodes a different URL at a different size that no
        // view ever reads — wasted downloads and ~0.4 MB of bitmap per item.
        // Hero and song-grid sections size their own artwork, so they load on display.
        guard HomeShelfStyle.style(for: section, at: index) == .shelf else { return }
        let requests = HomeItemCell.prefetchRequests(for: section.items.prefix(6))
        for (targetSize, urls) in requests {
            guard !Task.isCancelled else { return }
            await ImageCache.shared.prefetch(urls: urls, targetSize: targetSize, maxConcurrent: 2)
        }
    }

    // MARK: - Actions

    private func playItem(_ item: HomeSectionItem, in _: HomeSection, at _: Int) {
        switch item {
        case let .song(song):
            // Play the song and fetch similar songs (radio queue) in the background
            Task {
                await self.playerService.playWithRadio(song: song)
            }
        case let .playlist(playlist):
            // Navigate to playlist detail
            self.navigationPath.append(playlist)
        case let .album(album):
            // For now, we'll create a playlist-like navigation for albums
            // In a full implementation, we'd have an AlbumDetailView
            let playlist = Playlist(
                id: album.id,
                title: album.title,
                description: nil,
                thumbnailURL: album.thumbnailURL,
                trackCount: album.trackCount,
                author: Artist.inline(name: album.artistsDisplay, namespace: "album-artist")
            )
            self.navigationPath.append(playlist)
        case let .artist(artist):
            // Navigate to artist detail
            self.navigationPath.append(artist)
        }
    }
}

#Preview {
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    HomeView(viewModel: HomeViewModel(client: client))
        .environment(PlayerService())
        .environment(authService)
        .environment(FavoritesManager.shared)
}
