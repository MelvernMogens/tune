// swiftlint:disable file_length

import SwiftUI

/// Detail view for an artist showing their songs and albums.
struct ArtistDetailView: View { // swiftlint:disable:this type_body_length
    let artist: Artist
    @State var viewModel: ArtistDetailViewModel
    @Environment(PlayerService.self) private var playerService
    @Environment(AuthService.self) private var authService

    init(artist: Artist, viewModel: ArtistDetailViewModel) {
        self.artist = artist
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                LoadingView(String(localized: "Loading artist..."), layout: .list)
            case .loaded, .loadingMore:
                if let detail = viewModel.artistDetail {
                    self.contentView(detail)
                } else {
                    ErrorView(title: String(localized: "Unable to load artist"), message: String(localized: "Artist not found")) {
                        Task { await self.viewModel.load() }
                    }
                }
            case let .error(error):
                ErrorView(error: error) {
                    Task { await self.viewModel.load() }
                }
            }
        }
        .accentBackground(from: self.viewModel.artistDetail?.thumbnailURL?.highQualityThumbnailURL)
        .navigationTitle(self.artist.name)
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if case .error = self.viewModel.loadingState {} else {
                PlayerBar()
                    .environment(\.playerBarCurrentArtistID, self.artist.id)
            }
        }
        .task {
            if self.viewModel.loadingState == .idle {
                await self.viewModel.load()
            }
        }
        .refreshable {
            await self.viewModel.refresh()
        }
    }

    // MARK: - Views

    private func contentView(_ detail: ArtistDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                // Header
                self.headerView(detail)
                    .padding(.horizontal, DetailContentLayout.horizontalInset)

                // Songs section (vertical list — inset like other non-shelf content)
                if !detail.songs.isEmpty {
                    self.songsSection()
                        .padding(.horizontal, DetailContentLayout.horizontalInset)
                }

                // Latest episodes (includes live radio streams). Episodes are
                // kept out of orderedSections because they use their own card
                // layout and route.
                if !detail.episodes.isEmpty {
                    self.episodesSection(detail.episodes)
                }

                if !detail.orderedSections.isEmpty {
                    ForEach(detail.orderedSections) { section in
                        switch section.content {
                        case let .albums(albums):
                            self.albumsSection(
                                albums,
                                title: section.title,
                                shelfKind: self.albumShelfKind(for: section.title)
                            )
                        case let .artists(artists):
                            self.artistsSection(artists, title: section.title)
                        case let .playlists(playlists):
                            self.playlistsSection(playlists, title: section.title)
                        }
                    }
                } else {
                    // Fallback for older/parser-test ArtistDetail values that do
                    // not populate orderedSections.
                    if !detail.albums.isEmpty {
                        self.albumsSection(detail.albums)
                    }

                    if !detail.singles.isEmpty {
                        self.singlesSection(detail.singles)
                    }

                    if !detail.playlistsByArtist.isEmpty {
                        self.playlistsByArtistSection(detail.playlistsByArtist)
                    }

                    if !detail.relatedArtists.isEmpty {
                        self.relatedArtistsSection(detail.relatedArtists)
                    }
                }

                // Podcast shows owned by this artist.
                if !detail.podcasts.isEmpty {
                    self.podcastsSection(detail.podcasts)
                }
            }
            .padding(.top, 28)
            .padding(.bottom, TuneTheme.Spacing.scrollEndInset)
        }
        // The ScrollView stays edge-to-edge: non-scrolling content is inset via
        // padding above, while horizontal shelves pass `contentInset` so their
        // tracks reach the under-sidebar band and slide under the floating glass
        // on macOS 26. The accent backdrop (ignores safe area) refracts through.
        .topFade(style: .contentMask)
    }

    /// C2 header: the artist photo at the playlist cover size beside a caps kind label,
    /// the name at headline size, a mono audience line, and small rounded-square actions.
    private func headerView(_ detail: ArtistDetail) -> some View {
        HStack(alignment: .bottom, spacing: TuneTheme.Spacing.gutter) {
            CachedAsyncImage(url: detail.thumbnailURL?.highQualityThumbnailURL, targetSize: CGSize(width: Self.headerArtSide, height: Self.headerArtSide)) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Rectangle()
                    .fill(TuneTheme.Palette.raised)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(TuneTheme.Typeface.display)
                            .foregroundStyle(TuneTheme.Palette.inkDim)
                    }
            }
            .frame(width: Self.headerArtSide, height: Self.headerArtSide)
            .clipShape(.rect(cornerRadius: TuneTheme.Radius.hero, style: .continuous))
            .overlay {
                RoundedRectangle.tuneRounded(TuneTheme.Radius.hero)
                    .strokeBorder(TuneTheme.Palette.artworkEdge, lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 0) {
                if let headerTypeLabel = self.headerTypeLabel(for: detail) {
                    Text(headerTypeLabel)
                        .tuneCapsLabel()
                        .padding(.bottom, 12)
                }

                Text(detail.name)
                    .font(TuneTheme.Typeface.headline)
                    .tracking(-1)
                    .foregroundStyle(TuneTheme.Palette.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .textSelection(.enabled)

                if let monthlyAudience = detail.monthlyAudience {
                    Text(monthlyAudience)
                        .font(TuneTheme.Typeface.data)
                        .textCase(.uppercase)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                        .lineLimit(1)
                        .padding(.top, 12)
                }

                if let description = detail.description, !description.isEmpty {
                    Text(description)
                        .font(TuneTheme.Typeface.body)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                        .lineLimit(3)
                        .frame(maxWidth: 560, alignment: .leading)
                        .padding(.top, 12)
                }

                HStack(spacing: 8) {
                    if detail.profileKind == .artist {
                        // Shuffle button - shuffles all artist's songs (fetches if needed)
                        Button {
                            let intent = self.playerService.beginMusicPlaybackIntent()
                            Task {
                                await self.shuffleAllSongs(intent: intent)
                            }
                        } label: {
                            Self.actionLabel(String(localized: "Shuffle"), systemImage: "shuffle")
                        }
                        .buttonStyle(PlaylistActionButtonStyle(isPrimary: true))
                        .disabled(detail.songs.isEmpty && !detail.hasMoreSongs)
                    }

                    // Mix button - plays personalized radio with mix of artists
                    // Only shown if mix data is available from the API
                    // Passing nil for startVideoId lets the API pick a random starting point on the server
                    // in addition to client-side shuffling applied when the mix tracks are played
                    if let mixPlaylistId = detail.mixPlaylistId {
                        Button {
                            self.playMix(playlistId: mixPlaylistId, startVideoId: nil)
                        } label: {
                            Self.actionLabel(String(localized: "Mix"), systemImage: "dot.radiowaves.left.and.right")
                        }
                        .buttonStyle(PlaylistActionButtonStyle())
                    }

                    // Subscribe button
                    if detail.channelId != nil, self.hasPersonalAccount {
                        self.subscribeButton(detail)
                    }
                }
                .padding(.top, 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let headerArtSide: CGFloat = 220

    private static func actionLabel(_ title: String, systemImage: String) -> some View {
        PlaylistActionLabel(title: title, systemImage: systemImage)
            .fixedSize()
            .padding(.horizontal, 4)
    }

    /// Returns the text for the subscribe button.
    private func subscribeButtonText(_ detail: ArtistDetail) -> String {
        let baseText = detail.isSubscribed
            ? (detail.subscribedButtonText ?? String(localized: "Subscribed"))
            : (detail.unsubscribedButtonText ?? String(localized: "Subscribe"))

        if let subscriberCount = detail.subscriberCount, !subscriberCount.isEmpty {
            return "\(baseText) \(subscriberCount)"
        }
        return baseText
    }

    private func headerTypeLabel(for detail: ArtistDetail) -> String? {
        switch detail.profileKind {
        case .artist:
            String(localized: "Artist")
        case .profile:
            String(localized: "Profile")
        case .unknown:
            nil
        }
    }

    private func subscribeButton(_ detail: ArtistDetail) -> some View {
        Button {
            HapticService.toggle()
            Task {
                await self.viewModel.toggleSubscription()
            }
        } label: {
            if self.viewModel.isSubscribing {
                FixedProgressView(controlSize: .small, scale: 0.7)
                    .padding(.horizontal, 12)
            } else {
                Self.actionLabel(
                    self.subscribeButtonText(detail),
                    systemImage: detail.isSubscribed ? "checkmark" : "plus"
                )
            }
        }
        .buttonStyle(PlaylistActionButtonStyle())
        .disabled(self.viewModel.isSubscribing)
    }

    private func songsSection() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .lastTextBaseline) {
                Text(self.viewModel.artistDetail?.songsSectionTitle ?? String(localized: "Top songs"))
                    .font(TuneTheme.Typeface.section)
                    .foregroundStyle(TuneTheme.Palette.ink)

                Spacer()

                // See all button - navigates to full top songs view
                if self.viewModel.hasMoreSongs, let detail = viewModel.artistDetail {
                    NavigationLink(value: TopSongsDestination(
                        artistId: detail.id,
                        artistName: detail.name,
                        title: detail.songsSectionTitle ?? String(localized: "Top songs"),
                        songs: detail.songs,
                        songsBrowseId: detail.songsBrowseId,
                        songsParams: detail.songsParams
                    )) {
                        Self.seeAllLabel
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 10)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(TuneTheme.Palette.rule)
                    .frame(height: 1)
            }

            VStack(spacing: 0) {
                ForEach(Array(self.viewModel.displayedSongs.enumerated()), id: \.offset) { index, song in
                    self.topSongRow(song, index: index)
                }
            }
        }
    }

    /// Song row for top songs section - fetches all songs and plays as queue.
    private func topSongRow(_ song: Song, index: Int) -> some View {
        HoverObservingRow { isHovered in
            Button {
                self.playTopSong(song, displayedIndex: index)
            } label: {
                let isCurrent = self.playerService.currentTrack?.videoId == song.videoId
                HStack(spacing: 14) {
                    // Thumbnail
                    SongThumbnailView(song: song, size: 32)

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
                        .frame(minWidth: 80, maxWidth: 180, alignment: .leading)

                    // Album column (if available)
                    if let album = song.album {
                        Text(album.title)
                            .font(TuneTheme.Typeface.body)
                            .foregroundStyle(TuneTheme.Palette.inkMuted)
                            .lineLimit(1)
                            .frame(minWidth: 80, maxWidth: 180, alignment: .leading)
                    } else {
                        Color.clear
                            .frame(minWidth: 80, maxWidth: 180, maxHeight: 1)
                    }

                    // Favorite toggle
                    LikeButton(song: song, isRowHovered: isHovered, allowsActions: self.hasPersonalAccount)

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
                play: { self.playTopSong(song, displayedIndex: index) },
                showsGoToArtist: false
            )
        }
    }

    private func playTopSong(_ song: Song, displayedIndex: Int) {
        let intent = self.playerService.beginMusicPlaybackIntent()
        let exactOrdinal = self.viewModel.displayedSongs
            .prefix(displayedIndex)
            .count(where: { $0.id == song.id && $0.videoId == song.videoId })
        let videoOrdinal = self.viewModel.displayedSongs
            .prefix(displayedIndex)
            .count(where: { $0.videoId == song.videoId })
        Task {
            let allSongs = await self.viewModel.getAllSongs()
            guard self.playerService.acceptsMusicPlaybackIntent(intent) else { return }
            let exactMatches = allSongs.indices.filter {
                allSongs[$0].id == song.id && allSongs[$0].videoId == song.videoId
            }
            let videoMatches = allSongs.indices.filter { allSongs[$0].videoId == song.videoId }
            let startIndex = exactMatches[safe: exactOrdinal]
                ?? videoMatches[safe: videoOrdinal]
                ?? (allSongs.indices.contains(displayedIndex) ? displayedIndex : 0)
            await self.playerService.playQueue(
                allSongs,
                startingAt: startIndex,
                deferringSmartShuffleFill: false,
                intent: intent
            )
        }
    }

    private func albumsSection(
        _ albums: [Album],
        title: String = "Albums",
        shelfKind: ArtistShelfKind = .albums
    ) -> some View {
        CarouselShelfSection(
            accessibilityLabel: title,
            items: albums,
            contentInset: DetailContentLayout.horizontalInset
        ) {
            self.sectionHeader(title: title, shelfKind: shelfKind)
        } itemContent: { album in
            NavigationLink(value: self.playlistFromAlbum(album)) {
                self.albumCard(album)
            }
            .buttonStyle(.plain)
            .contextMenu {
                AlbumContextMenu(album: album, client: self.viewModel.client)
            }
        }
    }

    private func playlistsSection(_ playlists: [Playlist], title: String) -> some View {
        CarouselShelfSection(
            accessibilityLabel: title,
            items: playlists,
            contentInset: DetailContentLayout.horizontalInset
        ) {
            self.sectionHeader(title: title, shelfKind: .playlistsByArtist)
        } itemContent: { playlist in
            NavigationLink(value: playlist) {
                self.playlistCard(playlist)
            }
            .buttonStyle(.plain)
            .contextMenu {
                PlaylistContextMenu(playlist: playlist, client: self.viewModel.client)
            }
        }
    }

    private func artistsSection(_ artists: [Artist], title: String) -> some View {
        CarouselShelfSection(
            accessibilityLabel: title,
            items: artists,
            contentInset: DetailContentLayout.horizontalInset
        ) {
            self.sectionHeader(title: title, shelfKind: .relatedArtists)
        } itemContent: { artist in
            NavigationLink(value: artist) {
                self.artistCard(artist)
            }
            .buttonStyle(.plain)
            .contextMenu {
                ArtistContextMenu(artist: artist)
            }
        }
    }

    private func playlistFromAlbum(_ album: Album) -> Playlist {
        Playlist(
            id: album.id,
            title: album.title,
            description: nil,
            thumbnailURL: album.thumbnailURL,
            trackCount: album.trackCount,
            author: Artist.inline(name: album.artistsDisplay, namespace: "album-artist")
        )
    }

    private func albumCard(_ album: Album) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thumbnail
            CachedAsyncImage(url: album.thumbnailURL?.highQualityThumbnailURL, targetSize: CGSize(width: 140, height: 140)) { image in
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
            .frame(width: 140, height: 140)
            .clipShape(.rect(cornerRadius: TuneTheme.Radius.artwork, style: .continuous))

            // Title
            Text(album.title)
                .font(TuneTheme.Typeface.body.weight(.medium))
                .foregroundStyle(TuneTheme.Palette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 140, alignment: .leading)

            // Year
            if let year = album.year {
                Text(year)
                    .font(TuneTheme.Typeface.body)
                    .foregroundStyle(TuneTheme.Palette.inkMuted)
                    .frame(width: 140, alignment: .leading)
            }
        }
    }

    private func playlistCard(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: playlist.thumbnailURL?.highQualityThumbnailURL, targetSize: CGSize(width: 140, height: 140)) { image in
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
            .frame(width: 140, height: 140)
            .clipShape(.rect(cornerRadius: TuneTheme.Radius.artwork, style: .continuous))

            Text(playlist.title)
                .font(TuneTheme.Typeface.body.weight(.medium))
                .foregroundStyle(TuneTheme.Palette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 140, alignment: .leading)

            if let authorName = playlist.author?.name, !authorName.isEmpty {
                Text(authorName)
                    .font(TuneTheme.Typeface.body)
                    .foregroundStyle(TuneTheme.Palette.inkMuted)
                    .lineLimit(1)
                    .frame(width: 140, alignment: .leading)
            } else if let trackCount = playlist.trackCount {
                Text(trackCount == 1 ? "1 song" : "\(trackCount) songs")
                    .font(TuneTheme.Typeface.body)
                    .foregroundStyle(TuneTheme.Palette.inkMuted)
                    .frame(width: 140, alignment: .leading)
            }
        }
    }

    private func artistCard(_ artist: Artist) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: artist.thumbnailURL?.highQualityThumbnailURL, targetSize: CGSize(width: 140, height: 140)) { image in
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
            .frame(width: 140, height: 140)
            .clipShape(.rect(cornerRadius: TuneTheme.Radius.artwork, style: .continuous))

            Text(artist.name)
                .font(TuneTheme.Typeface.body.weight(.medium))
                .foregroundStyle(TuneTheme.Palette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 140, alignment: .leading)

            if let subtitle = artist.subtitle {
                Text(subtitle)
                    .font(TuneTheme.Typeface.body)
                    .foregroundStyle(TuneTheme.Palette.inkMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 140, alignment: .leading)
            }
        }
    }

    // MARK: - Actions

    private func playMix(playlistId: String, startVideoId: String?) {
        let intent = self.playerService.beginMusicPlaybackIntent()
        Task {
            await self.playerService.playWithMix(
                playlistId: playlistId,
                startVideoId: startVideoId,
                intent: intent
            )
        }
    }

    private func playAll(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        let intent = self.playerService.beginMusicPlaybackIntent()
        Task {
            await self.playerService.playQueue(
                songs,
                startingAt: 0,
                deferringSmartShuffleFill: false,
                intent: intent
            )
        }
    }

    /// Fetches all artist songs and plays them shuffled.
    private func shuffleAllSongs(intent: MusicPlaybackIntent) async {
        let allSongs = await self.viewModel.getAllSongs()
        guard !allSongs.isEmpty,
              self.playerService.acceptsMusicPlaybackIntent(intent)
        else { return }
        let shuffledSongs = allSongs.shuffled()
        await self.playerService.playQueue(
            shuffledSongs,
            startingAt: 0,
            deferringSmartShuffleFill: false,
            intent: intent
        )
    }

    // MARK: - Episodes Section (Latest episodes / live radios)

    private func episodesSection(_ episodes: [ArtistEpisode]) -> some View {
        CarouselShelfSection(
            accessibilityLabel: String(localized: "Latest episodes"),
            items: episodes,
            contentInset: DetailContentLayout.horizontalInset
        ) {
            self.sectionHeader(title: "Latest episodes", shelfKind: .episodes)
        } itemContent: { episode in
            Button {
                let intent = self.playerService.beginMusicPlaybackIntent()
                Task {
                    await self.playerService.playEpisode(episode, intent: intent)
                }
            } label: {
                self.episodeCard(episode)
            }
            .buttonStyle(.plain)
        }
    }

    private func episodeCard(_ episode: ArtistEpisode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                CachedAsyncImage(url: episode.thumbnailURL?.highQualityThumbnailURL, targetSize: CGSize(width: 220, height: 124)) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Rectangle()
                        .fill(TuneTheme.Palette.raised)
                        .overlay {
                            Image(systemName: "play.rectangle")
                                .font(TuneTheme.Typeface.section)
                                .foregroundStyle(TuneTheme.Palette.inkDim)
                        }
                }
                .frame(width: 220, height: 124)
                .clipShape(.rect(cornerRadius: TuneTheme.Radius.artwork, style: .continuous))

                if episode.isLive {
                    Text("LIVE", comment: "Live badge on artist episode card")
                        .font(TuneTheme.Typeface.data)
                        .tracking(0.6)
                        .foregroundStyle(TuneTheme.Palette.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(TuneTheme.Palette.background.opacity(0.82), in: .tuneRounded(TuneTheme.Radius.small))
                        .padding(8)
                }
            }

            Text(episode.title)
                .font(TuneTheme.Typeface.body.weight(.medium))
                .foregroundStyle(TuneTheme.Palette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 220, alignment: .leading)

            if let subtitle = episode.subtitle {
                Text(subtitle)
                    .font(TuneTheme.Typeface.body)
                    .foregroundStyle(TuneTheme.Palette.inkMuted)
                    .frame(width: 220, alignment: .leading)
            }
        }
    }

    // MARK: - Singles & EPs Section

    private func singlesSection(_ singles: [Album]) -> some View {
        CarouselShelfSection(
            accessibilityLabel: String(localized: "Singles & EPs"),
            items: singles,
            contentInset: DetailContentLayout.horizontalInset
        ) {
            self.sectionHeader(title: "Singles & EPs", shelfKind: .singles)
        } itemContent: { album in
            NavigationLink(value: self.playlistFromAlbum(album)) {
                self.albumCard(album)
            }
            .buttonStyle(.plain)
            .contextMenu {
                AlbumContextMenu(album: album, client: self.viewModel.client)
            }
        }
    }

    // MARK: - Playlists by Artist Section

    private func playlistsByArtistSection(_ playlists: [Playlist]) -> some View {
        CarouselShelfSection(
            accessibilityLabel: String(localized: "Playlists"),
            items: playlists,
            contentInset: DetailContentLayout.horizontalInset
        ) {
            self.sectionHeader(title: "Playlists", shelfKind: .playlistsByArtist)
        } itemContent: { playlist in
            NavigationLink(value: playlist) {
                VStack(alignment: .leading, spacing: 8) {
                    CachedAsyncImage(url: playlist.thumbnailURL?.highQualityThumbnailURL, targetSize: CGSize(width: 140, height: 140)) { image in
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
                    .frame(width: 140, height: 140)
                    .clipShape(.rect(cornerRadius: TuneTheme.Radius.artwork, style: .continuous))

                    Text(playlist.title)
                        .font(TuneTheme.Typeface.body.weight(.medium))
                        .foregroundStyle(TuneTheme.Palette.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(width: 140, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                PlaylistContextMenu(playlist: playlist, client: self.viewModel.client)
            }
        }
    }

    // MARK: - Podcasts Section

    private func podcastsSection(_ podcasts: [PodcastShow]) -> some View {
        CarouselShelfSection(
            accessibilityLabel: String(localized: "Podcasts"),
            items: podcasts,
            contentInset: DetailContentLayout.horizontalInset
        ) {
            self.sectionHeader(title: "Podcasts", shelfKind: .podcasts)
        } itemContent: { show in
            NavigationLink(value: show) {
                self.podcastCard(show)
            }
            .buttonStyle(.plain)
            .contextMenu {
                PodcastShowContextMenu(show: show)
            }
        }
    }

    private func podcastCard(_ show: PodcastShow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: show.thumbnailURL?.highQualityThumbnailURL, targetSize: CGSize(width: 140, height: 140)) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Rectangle()
                    .fill(TuneTheme.Palette.raised)
                    .overlay {
                        Image(systemName: "mic")
                            .font(TuneTheme.Typeface.section)
                            .foregroundStyle(TuneTheme.Palette.inkDim)
                    }
            }
            .frame(width: 140, height: 140)
            .clipShape(.rect(cornerRadius: TuneTheme.Radius.artwork, style: .continuous))

            Text(show.title)
                .font(TuneTheme.Typeface.body.weight(.medium))
                .foregroundStyle(TuneTheme.Palette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 140, alignment: .leading)
        }
    }

    // MARK: - Related Artists Section

    private func relatedArtistsSection(_ artists: [Artist]) -> some View {
        CarouselShelfSection(
            accessibilityLabel: String(localized: "Fans might also like"),
            items: artists,
            contentInset: DetailContentLayout.horizontalInset
        ) {
            self.sectionHeader(title: "Fans might also like", shelfKind: .relatedArtists)
        } itemContent: { artist in
            NavigationLink(value: artist) {
                self.relatedArtistCard(artist)
            }
            .buttonStyle(.plain)
            .contextMenu {
                ArtistContextMenu(artist: artist)
            }
        }
    }

    private func relatedArtistCard(_ artist: Artist) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: artist.thumbnailURL?.highQualityThumbnailURL, targetSize: CGSize(width: 120, height: 120)) { image in
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
            .frame(width: 120, height: 120)
            .clipShape(.rect(cornerRadius: TuneTheme.Radius.artwork, style: .continuous))

            Text(artist.name)
                .font(TuneTheme.Typeface.body.weight(.medium))
                .foregroundStyle(TuneTheme.Palette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 120, alignment: .leading)
        }
    }

    private func albumShelfKind(for title: String) -> ArtistShelfKind {
        let lowercasedTitle = title.lowercased()
        return lowercasedTitle.contains("single")
            || lowercasedTitle.contains(" ep")
            || lowercasedTitle.hasPrefix("ep")
            ? .singles
            : .albums
    }

    private var hasPersonalAccount: Bool {
        self.authService.hasPersonalAccount
    }

    // MARK: - Section Header with Optional See-all

    private func sectionHeader(title: String, shelfKind: ArtistShelfKind) -> some View {
        HStack(alignment: .lastTextBaseline) {
            Text(LocalizedStringKey(title))
                .font(TuneTheme.Typeface.section)
                .foregroundStyle(TuneTheme.Palette.ink)

            Spacer()

            if let detail = viewModel.artistDetail,
               let more = detail.moreEndpoints[shelfKind]
            {
                self.seeAllLink(more: more, sectionTitle: title, artistName: detail.name)
            }
        }
        // The C2 section rule, as on Home's shelves.
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TuneTheme.Palette.rule)
                .frame(height: 1)
        }
    }

    /// Quiet caps link (the accent is reserved for now playing).
    private static var seeAllLabel: some View {
        Text(String(localized: "See all"))
            .tuneCapsLabel()
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func seeAllLink(
        more: ShelfMoreEndpoint,
        sectionTitle: String,
        artistName: String
    ) -> some View {
        switch more.pageType {
        case .playlist:
            // Playlist-backed See-all destinations reuse the existing
            // `Playlist` navigation route so `PlaylistDetailView` can render
            // the full list.
            NavigationLink(value: Playlist(
                id: more.browseId,
                title: sectionTitle,
                description: nil,
                thumbnailURL: nil,
                trackCount: nil,
                author: Artist.inline(name: artistName, namespace: "playlist-author")
            )) {
                Self.seeAllLabel
            }
            .buttonStyle(.plain)
        case .artist, .discography:
            NavigationLink(value: ArtistSeeAllDestination(
                artistName: artistName,
                sectionTitle: sectionTitle,
                endpoint: more
            )) {
                Self.seeAllLabel
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    let artist = Artist(
        id: "test",
        name: "Test Artist",
        thumbnailURL: nil
    )
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    ArtistDetailView(
        artist: artist,
        viewModel: ArtistDetailViewModel(
            artist: artist,
            client: client
        )
    )
    .environment(PlayerService())
}
