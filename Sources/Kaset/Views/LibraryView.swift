import SwiftUI

// MARK: - LibraryFilter

/// Filter options for the Library view.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case playlists = "Playlists"
    case albums = "Albums"
    case uploads = "Uploads"
    case artists = "Artists"
    case podcasts = "Podcasts"

    var id: String {
        self.rawValue
    }

    var icon: String {
        switch self {
        case .all: "square.grid.2x2"
        case .playlists: "music.note.list"
        case .albums: "square.stack"
        case .uploads: "tray.and.arrow.up.fill"
        case .artists: "person.fill"
        case .podcasts: "mic.fill"
        }
    }

    var displayName: String {
        switch self {
        case .all:
            String(localized: "All")
        case .playlists:
            String(localized: "Playlists")
        case .albums:
            String(localized: "Albums")
        case .uploads:
            String(localized: "Uploads")
        case .artists:
            String(localized: "Artists")
        case .podcasts:
            String(localized: "Podcasts")
        }
    }
}

// MARK: - LibraryView

/// Library view displaying the user's saved music and followed content.
struct LibraryView: View {
    @State var viewModel: LibraryViewModel
    @Environment(PlayerService.self) private var playerService
    @Environment(\.usesLegacyMacOS15UI) private var usesLegacyMacOS15UI
    @State private var networkMonitor = NetworkMonitor.shared

    @State private var navigationPath = NavigationPath()
    @State private var selectedFilter: LibraryFilter = .all

    private let libraryItemSize: CGFloat = 160
    /// Decode size for grid artwork: the tile's own size (the cache adds the 2× for Retina).
    /// The 320 pt default decoded 640 px bitmaps for 160 pt tiles — 4× the pixels shown.
    private var libraryArtworkSize: CGSize {
        CGSize(width: self.libraryItemSize, height: self.libraryItemSize)
    }
    private let libraryItemSpacing: CGFloat = 18
    private let libraryItemCardHeight: CGFloat = 222

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
                        LoadingView(String(localized: "Loading your library..."), layout: .grid)
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
            .localizedNavigationTitle("Library")
            .navigationDestination(for: Playlist.self) { playlist in
                if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
                    PlaylistDetailView(
                        playlist: playlist,
                        viewModel: PlaylistDetailViewModel(
                            playlist: playlist,
                            client: self.viewModel.client
                        )
                    )
                    .environment(\.libraryViewModel, self.viewModel)
                } else {
                    SimplePlaylistDetailView(
                        playlist: playlist,
                        viewModel: PlaylistDetailViewModel(
                            playlist: playlist,
                            client: self.viewModel.client
                        )
                    )
                    .environment(\.libraryViewModel, self.viewModel)
                }
            }
            .navigationDestination(for: Artist.self) { artist in
                ArtistDetailView(
                    artist: artist,
                    viewModel: ArtistDetailViewModel(
                        artist: artist,
                        client: self.viewModel.client,
                        libraryViewModel: self.viewModel
                    )
                )
            }
            .navigationDestination(for: TopSongsDestination.self) { destination in
                TopSongsView(
                    viewModel: TopSongsViewModel(
                        destination: destination,
                        client: self.viewModel.client
                    )
                )
            }
            .navigationDestination(for: PodcastShow.self) { show in
                PodcastShowView(show: show, client: self.viewModel.client)
            }
            .playerBarMusicNavigation(path: self.$navigationPath)
        }
        .playerBarMusicNavigation(path: self.$navigationPath)
        .environment(\.libraryViewModel, self.viewModel)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
                .playerBarMusicNavigation(path: self.$navigationPath)
        }
        .task {
            if self.viewModel.loadingState == .idle {
                await self.viewModel.load()
            }
            await self.viewModel.reloadIfNeededOnActivation()
        }
        .task(id: "\(self.navigationPath.count)-\(self.viewModel.activationReloadGeneration)") {
            guard self.navigationPath.isEmpty else { return }
            await self.viewModel.reloadIfNeededOnActivation()
        }
        .refreshable {
            await self.viewModel.refresh()
        }
        .popsNavigationStackOnSidebarReselect(path: self.$navigationPath, for: .library)
    }

    // MARK: - Views

    private var contentView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                // Filter chips
                self.filterChips

                // Combined grid with filtered content
                self.libraryGrid
            }
            .padding(.vertical, 20)
            // Inset the resting content while the scroll view stays edge-to-edge,
            // so the grid extends under the floating glass sidebar.
            .detailScrollContentInset()
        }
    }

    /// C2 filter row (as on Search): caps text toggles, the selected one ink and underlined.
    /// No filled chips.
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TuneTheme.Spacing.unit * 5) {
                ForEach(LibraryFilter.allCases) { filter in
                    self.filterChip(filter)
                }
            }
            .padding(.vertical, TuneTheme.Spacing.unit)
        }
    }

    private func filterChip(_ filter: LibraryFilter) -> some View {
        TuneNowPlayingTextToggle(
            title: Text(filter.displayName),
            isOn: self.selectedFilter == filter,
            action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.selectedFilter = filter
                }
            }
        )
        .accessibilityLabel(Text(filter.displayName))
    }

    /// All library items combined and filtered.
    private var filteredItems: [LibraryItem] {
        var items: [LibraryItem] = []

        switch self.selectedFilter {
        case .all:
            items = self.uploadItems
                + self.viewModel.playlists.map { .playlist($0) }
                + self.viewModel.albums.map { .album($0) }
                + self.viewModel.artists.map { .artist($0) }
                + self.viewModel.podcastShows.map { .podcast($0) }
        case .playlists:
            items = self.viewModel.playlists.map { .playlist($0) }
        case .albums:
            items = self.viewModel.albums.map { .album($0) }
        case .uploads:
            items = self.uploadItems
        case .artists:
            items = self.viewModel.artists.map { .artist($0) }
        case .podcasts:
            items = self.viewModel.podcastShows.map { .podcast($0) }
        }

        return items
    }

    private var uploadItems: [LibraryItem] {
        guard let uploadedSongsPlaylist = self.viewModel.uploadedSongsPlaylist else {
            return []
        }
        return [.uploadedSongs(uploadedSongsPlaylist)]
    }

    @ViewBuilder
    private var libraryGrid: some View {
        if self.filteredItems.isEmpty {
            self.emptyStateView
        } else {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: self.libraryItemSize, maximum: 200), spacing: self.libraryItemSpacing),
            ], spacing: 24) {
                ForEach(self.filteredItems) { item in
                    switch item {
                    case let .playlist(playlist):
                        self.playlistCard(playlist)
                    case let .album(album):
                        self.albumCard(album)
                    case let .uploadedSongs(playlist):
                        self.uploadedSongsCard(playlist)
                    case let .artist(artist):
                        self.artistCard(artist)
                    case let .podcast(show):
                        self.podcastCard(show)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyStateView: some View {
        TuneEmptyState(title: self.emptyStateTitle, message: self.emptyStateMessage)
            .frame(minHeight: 320)
    }

    private var emptyStateTitle: String {
        switch self.selectedFilter {
        case .all:
            String(localized: "Your library is empty")
        case .playlists:
            String(localized: "No playlists yet")
        case .albums:
            String(localized: "No albums yet")
        case .uploads:
            String(localized: "No uploaded songs yet")
        case .artists:
            String(localized: "No artists yet")
        case .podcasts:
            String(localized: "No podcasts yet")
        }
    }

    private var emptyStateMessage: String {
        switch self.selectedFilter {
        case .all:
            String(localized: "Save playlists, follow artists, and subscribe to podcasts on YouTube Music to see them here.")
        case .playlists:
            String(localized: "Create or save playlists on YouTube Music to see them here.")
        case .albums:
            String(localized: "Save albums on YouTube Music to see them here.")
        case .uploads:
            String(localized: "Upload songs to YouTube Music to browse them here.")
        case .artists:
            String(localized: "Follow artists on YouTube Music to see them here.")
        case .podcasts:
            String(localized: "Subscribe to podcasts on YouTube Music to see them here.")
        }
    }

    private func playlistCard(_ playlist: Playlist) -> some View {
        Button {
            self.navigationPath.append(playlist)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail
                CachedAsyncImage(url: playlist.thumbnailURL?.highQualityThumbnailURL, targetSize: self.libraryArtworkSize) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Rectangle()
                        .fill(TuneTheme.Palette.raised)
                        .overlay {
                            Image(systemName: "music.note.list")
                                .font(TuneTheme.Typeface.section)
                                .foregroundStyle(TuneTheme.Palette.inkDim)
                        }
                }
                .frame(width: self.libraryItemSize, height: self.libraryItemSize)
                .clipShape(.rect(cornerRadius: TuneTheme.Radius.artwork, style: .continuous))

                // Title
                Text(playlist.title)
                    .font(TuneTheme.Typeface.body.weight(.medium))
                    .foregroundStyle(TuneTheme.Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: self.libraryItemSize, alignment: .topLeading)

                // Track count
                if let count = playlist.trackCount {
                    Text("\(count) songs", comment: "Playlist track count")
                        .font(TuneTheme.Typeface.body)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                        .frame(width: self.libraryItemSize, alignment: .leading)
                }
            }
            .frame(width: self.libraryItemSize, height: self.libraryItemCardHeight, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .contextMenu {
            PlaylistContextMenu(
                playlist: playlist,
                client: self.viewModel.client,
                navigate: { self.navigationPath.append($0) }
            )

            if playlist.canDelete {
                Divider()

                Button(role: .destructive) {
                    SongActionsHelper.confirmDeletePlaylist(
                        playlist,
                        client: self.viewModel.client,
                        libraryViewModel: self.viewModel,
                        playerService: self.playerService
                    )
                } label: {
                    Label(String(localized: "Delete Playlist…"), systemImage: "trash")
                }
            }
        }
    }

    private func albumCard(_ album: Album) -> some View {
        let metadata = [album.artistsDisplay.isEmpty ? nil : album.artistsDisplay, album.year]
            .compactMap(\.self)
            .joined(separator: " · ")

        return Button {
            self.navigationPath.append(self.playlist(from: album))
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                CachedAsyncImage(url: album.thumbnailURL?.highQualityThumbnailURL, targetSize: self.libraryArtworkSize) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Rectangle()
                        .fill(TuneTheme.Palette.raised)
                        .overlay {
                            Image(systemName: "square.stack")
                                .font(TuneTheme.Typeface.section)
                                .foregroundStyle(TuneTheme.Palette.inkDim)
                        }
                }
                .frame(width: self.libraryItemSize, height: self.libraryItemSize)
                .clipShape(.rect(cornerRadius: TuneTheme.Radius.artwork, style: .continuous))

                Text(album.title)
                    .font(TuneTheme.Typeface.body.weight(.medium))
                    .foregroundStyle(TuneTheme.Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: self.libraryItemSize, alignment: .topLeading)

                Text(metadata.isEmpty ? String(localized: "Album") : metadata)
                    .font(TuneTheme.Typeface.body)
                    .foregroundStyle(TuneTheme.Palette.inkMuted)
                    .lineLimit(1)
                    .frame(width: self.libraryItemSize, alignment: .leading)
            }
            .frame(width: self.libraryItemSize, height: self.libraryItemCardHeight, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .contextMenu {
            AlbumContextMenu(
                album: album,
                client: self.viewModel.client,
                navigate: { self.navigationPath.append($0) }
            )
        }
    }

    private func playlist(from album: Album) -> Playlist {
        Playlist(
            id: album.id,
            title: album.title,
            description: nil,
            thumbnailURL: album.thumbnailURL,
            trackCount: album.trackCount,
            author: album.artistsDisplay.isEmpty
                ? nil
                : Artist.inline(name: album.artistsDisplay, namespace: "album-artist"),
            libraryTargetId: album.libraryTargetId
        )
    }

    private func uploadedSongsCard(_ playlist: Playlist) -> some View {
        Button {
            self.navigationPath.append(playlist)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                CachedAsyncImage(url: playlist.thumbnailURL?.highQualityThumbnailURL, targetSize: self.libraryArtworkSize) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Rectangle()
                        .fill(TuneTheme.Palette.raised)
                        .overlay {
                            Image(systemName: "tray.and.arrow.up.fill")
                                .font(TuneTheme.Typeface.section)
                                .foregroundStyle(TuneTheme.Palette.inkDim)
                        }
                }
                .frame(width: self.libraryItemSize, height: self.libraryItemSize)
                .clipShape(.rect(cornerRadius: TuneTheme.Radius.artwork, style: .continuous))

                Text(playlist.title)
                    .font(TuneTheme.Typeface.body.weight(.medium))
                    .foregroundStyle(TuneTheme.Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: self.libraryItemSize, alignment: .topLeading)

                if let count = playlist.trackCount {
                    Text("\(count) songs", comment: "Uploaded songs count")
                        .font(TuneTheme.Typeface.body)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                        .frame(width: self.libraryItemSize, alignment: .leading)
                } else {
                    Text(String(localized: "Uploads"))
                        .font(TuneTheme.Typeface.body)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                        .frame(width: self.libraryItemSize, alignment: .leading)
                }
            }
            .frame(width: self.libraryItemSize, height: self.libraryItemCardHeight, alignment: .topLeading)
        }
        .buttonStyle(.plain)
    }

    private func podcastCard(_ show: PodcastShow) -> some View {
        Button {
            self.navigationPath.append(show)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail
                CachedAsyncImage(url: show.thumbnailURL, targetSize: self.libraryArtworkSize) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Rectangle()
                        .fill(TuneTheme.Palette.raised)
                        .overlay {
                            Image(systemName: "mic.fill")
                                .font(TuneTheme.Typeface.section)
                                .foregroundStyle(TuneTheme.Palette.inkDim)
                        }
                }
                .frame(width: self.libraryItemSize, height: self.libraryItemSize)
                .clipShape(.rect(cornerRadius: TuneTheme.Radius.artwork, style: .continuous))

                // Title
                Text(show.title)
                    .font(TuneTheme.Typeface.body.weight(.medium))
                    .foregroundStyle(TuneTheme.Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: self.libraryItemSize, alignment: .topLeading)

                // Author
                if let author = show.author {
                    Text(author)
                        .font(TuneTheme.Typeface.body)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                        .lineLimit(1)
                        .frame(width: self.libraryItemSize, alignment: .leading)
                }
            }
            .frame(width: self.libraryItemSize, height: self.libraryItemCardHeight, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .contextMenu {
            PodcastShowContextMenu(show: show, navigate: { self.navigationPath.append($0) })
        }
    }

    private func artistCard(_ artist: Artist) -> some View {
        Button {
            self.navigationPath.append(artist)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                CachedAsyncImage(url: artist.thumbnailURL?.highQualityThumbnailURL, targetSize: self.libraryArtworkSize) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Rectangle()
                        .fill(TuneTheme.Palette.raised)
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(TuneTheme.Typeface.section)
                                .foregroundStyle(TuneTheme.Palette.inkDim)
                        }
                }
                .frame(width: self.libraryItemSize, height: self.libraryItemSize)
                .clipShape(.rect(cornerRadius: TuneTheme.Radius.artwork, style: .continuous))

                Text(artist.name)
                    .font(TuneTheme.Typeface.body.weight(.medium))
                    .foregroundStyle(TuneTheme.Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: self.libraryItemSize, alignment: .topLeading)

                Text(String(localized: "Artist"))
                    .font(TuneTheme.Typeface.body)
                    .foregroundStyle(TuneTheme.Palette.inkMuted)
                    .frame(width: self.libraryItemSize, alignment: .leading)
            }
            .frame(width: self.libraryItemSize, height: self.libraryItemCardHeight, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .contextMenu {
            ArtistContextMenu(artist: artist, navigate: { self.navigationPath.append($0) })
        }
    }
}

// MARK: - LibraryItem

/// Represents a tile displayed in the combined Library grid.
enum LibraryItem: Identifiable {
    case playlist(Playlist)
    case album(Album)
    case uploadedSongs(Playlist)
    case artist(Artist)
    case podcast(PodcastShow)

    var id: String {
        switch self {
        case let .playlist(playlist):
            "playlist-\(playlist.id)"
        case let .album(album):
            "album-\(album.id)"
        case let .uploadedSongs(playlist):
            "uploads-\(playlist.id)"
        case let .artist(artist):
            "artist-\(artist.id)"
        case let .podcast(show):
            "podcast-\(show.id)"
        }
    }
}

#Preview {
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    LibraryView(viewModel: LibraryViewModel(client: client))
        .environment(PlayerService())
        .environment(FavoritesManager.shared)
}
