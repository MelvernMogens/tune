import SwiftUI

/// View displaying all top songs for an artist.
struct TopSongsView: View {
    @State var viewModel: TopSongsViewModel
    @Environment(PlayerService.self) private var playerService
    @Environment(AuthService.self) private var authService

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                if self.viewModel.songs.isEmpty {
                    LoadingView(String(localized: "Loading songs..."), layout: .list)
                } else {
                    // Show existing songs while loading more
                    self.songsListView
                        .overlay(alignment: .top) {
                            if self.viewModel.loadingState == .loading {
                                ProgressView()
                                    .controlSize(.regular)
                                    .frame(width: 20, height: 20)
                                    .padding()
                            }
                        }
                }
            case .loaded, .loadingMore:
                self.songsListView
            case let .error(error):
                ErrorView(error: error) {
                    Task {
                        await self.viewModel.load()
                    }
                }
            }
        }
        .navigationTitle(self.viewModel.title)
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
        .topFade()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if case .error = self.viewModel.loadingState {} else {
                PlayerBar()
            }
        }
        .task {
            if self.viewModel.loadingState == .idle {
                await self.viewModel.load()
            }
        }
    }

    // MARK: - Views

    private var songsListView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(self.viewModel.songs.enumerated()), id: \.offset) { index, song in
                    self.songRow(song, index: index)
                }
            }
            .padding(.top, 28)
            .padding(.bottom, TuneTheme.Spacing.scrollEndInset)
            // Edge-to-edge with a resting inset so the list extends under the
            // floating glass sidebar; the accent backdrop refracts through it.
            .detailScrollContentInset()
        }
    }

    // MARK: - Song Row

    private func songRow(_ song: Song, index: Int) -> some View {
        HoverObservingRow { isHovered in
            Button {
                self.playSongInQueue(startingAt: index)
            } label: {
                let isCurrent = self.playerService.currentTrack?.videoId == song.videoId
                HStack(spacing: 14) {
                    // Thumbnail
                    SongThumbnailView(song: song, size: 32, cornerRadius: TuneTheme.Radius.small)

                    // Title (with optional explicit badge)
                    HStack(spacing: 6) {
                        Text(song.displayText.title)
                            .font(TuneTheme.Typeface.body)
                            .foregroundStyle(isCurrent ? TuneTheme.Palette.accent : TuneTheme.Palette.ink)
                            .lineLimit(1)
                        if song.isExplicit == true {
                            ExplicitBadge()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Artist column
                    Text(song.displayText.artist)
                        .font(TuneTheme.Typeface.body)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                        .lineLimit(1)
                        .frame(width: 180, alignment: .leading)

                    // Album column (if available)
                    if let album = song.album {
                        Text(album.title)
                            .font(TuneTheme.Typeface.body)
                            .foregroundStyle(TuneTheme.Palette.inkMuted)
                            .lineLimit(1)
                            .frame(width: 180, alignment: .leading)
                    } else {
                        Spacer()
                            .frame(width: 180)
                    }

                    // Favorite toggle
                    LikeButton(song: song, isRowHovered: isHovered, allowsActions: self.authService.hasPersonalAccount)

                    // Duration
                    Text(song.durationDisplay)
                        .font(TuneTheme.Typeface.data)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(.horizontal, 8)
                .frame(height: 44)
                .background {
                    if isHovered {
                        RoundedRectangle.tuneRounded(TuneTheme.Radius.control)
                            .fill(TuneTheme.Palette.raised)
                    }
                }
                .padding(.horizontal, -8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            SongContextMenu(
                song: song,
                client: self.viewModel.client,
                play: { self.playSongInQueue(startingAt: index) },
                showsGoToArtist: false
            )
        }
    }

    // MARK: - Actions

    private func playSongInQueue(startingAt index: Int) {
        Task {
            await self.playerService.playQueue(self.viewModel.songs, startingAt: index)
        }
    }
}

#Preview {
    let songs = (1 ... 10).map { i in
        Song(
            id: "song\(i)",
            title: "Song \(i)",
            artists: [Artist(id: "artist1", name: "Test Artist")],
            album: Album(id: "album1", title: "Test Album", artists: nil, thumbnailURL: nil, year: "2023", trackCount: 10),
            duration: TimeInterval(180 + i * 30),
            thumbnailURL: nil,
            videoId: "video\(i)"
        )
    }
    let destination = TopSongsDestination(
        artistId: "artist1",
        artistName: "Test Artist",
        songs: songs,
        songsBrowseId: nil,
        songsParams: nil
    )
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    TopSongsView(viewModel: TopSongsViewModel(destination: destination, client: client))
        .environment(PlayerService())
        .environment(authService)
        .environment(FavoritesManager.shared)
}
