import FoundationModels
import SwiftUI

// MARK: - PlaylistDetailView

/// Detail view for a playlist showing its tracks.
@available(macOS 26.0, *)
struct PlaylistDetailView: View {
    let playlist: Playlist
    @State var viewModel: PlaylistDetailViewModel
    @Environment(PlayerService.self) var playerService
    @Environment(AuthService.self) private var authService
    @Environment(SidebarPinnedItemsManager.self) var sidebarPinnedItemsManager: SidebarPinnedItemsManager?
    @Environment(SongLikeStatusManager.self) private var likeStatusManager
    @Environment(\.libraryViewModel) var libraryViewModel: LibraryViewModel?
    @Environment(\.dismiss) var dismiss
    @Environment(\.onPlaylistDeleted) var onPlaylistDeleted
    /// Whether the refine playlist sheet is visible.
    @State var showRefineSheet: Bool = false
    /// Whether an add/remove Library request is currently in flight.
    @State var libraryMutationActivity = PlaylistDetailLibraryMutationActivity()
    /// AI-generated playlist changes.
    @State private var playlistChanges: PlaylistChanges?
    /// Partial playlist changes during streaming.
    @State private var partialChanges: PlaylistChanges.PartiallyGenerated?
    /// Whether AI is processing the refine request.
    @State private var isRefining: Bool = false
    /// Error message from refine operation.
    @State private var refineError: String?
    /// Measured page width; picks the two-column or stacked C2 layout.
    @State private var layoutWidth: CGFloat = 0
    /// Computed property to check if playlist is in library.
    var isInLibrary: Bool {
        if self.playlist.isAlbum {
            return self.libraryViewModel?.isInLibrary(
                albumId: self.playlist.id,
                targetPlaylistId: self.viewModel.playlistDetail?.libraryTargetId
            ) ?? false
        }
        return self.libraryViewModel?.isInLibrary(playlistId: self.playlist.id) ?? false
    }

    var isUpdatingLibrary: Bool {
        self.libraryMutationActivity.isActive
    }

    var hasPersonalAccount: Bool {
        self.authService.hasPersonalAccount
    }

    private let logger = DiagnosticsLogger.ai

    /// C2 side column (cover, description, breakdown) and its breakpoint. Slim, so the
    /// track table — the page's subject — gets the width and titles don't truncate.
    private static let sideColumnWidth: CGFloat = 220
    private static let twoColumnBreakpoint: CGFloat = 860
    /// The action buttons share this width evenly; wider would make them big buttons.
    private static let actionRowMaxWidth: CGFloat = 340
    private static let compactCoverSide: CGFloat = 168

    init(playlist: Playlist, viewModel: PlaylistDetailViewModel) {
        self.playlist = playlist
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                LoadingView(String(localized: "Loading playlist..."), layout: .list)
            case .loaded, .loadingMore:
                if let detail = viewModel.playlistDetail {
                    self.contentView(detail)
                } else {
                    ErrorView(
                        title: String(localized: "Unable to load playlist"),
                        message: String(localized: "Playlist not found")
                    ) {
                        Task { await self.viewModel.load() }
                    }
                }
            case let .error(error):
                ErrorView(error: error) {
                    Task { await self.viewModel.load() }
                }
            }
        }
        // C2: a flat near-black page; the cover carries the color.
        .background(TuneTheme.Palette.background)
        .navigationTitle(self.playlist.title)
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if case .error = self.viewModel.loadingState {
            } else {
                PlayerBar()
                    .environment(
                        \.playerBarCurrentAlbumIDs,
                        PlayerBarCurrentRoute.albumIDs(for: self.playlist, detail: self.viewModel.playlistDetail)
                    )
            }
        }
        // Keyed on `.idle` so the load re-runs when the view model drops back to it
        // (e.g. a like-status scope change invalidates Liked Music pagination);
        // a plain `.task` runs once and would leave the loading spinner up forever.
        .task(id: self.viewModel.loadingState == .idle) {
            guard self.viewModel.loadingState == .idle else { return }
            await self.viewModel.ensureLoaded()
        }
        .refreshable {
            await self.viewModel.refresh()
        }
        .onChange(of: self.likeStatusManager.lastLikeEventBatch) { _, batch in
            guard let batch, batch.accountID == self.likeStatusManager.activeAccountID else { return }
            for event in batch.events {
                guard LikedMusicPlaylist.matches(id: self.playlist.id) else { return }
                self.viewModel.handleLikeStatusChange(event)
            }
        }
        .sheet(isPresented: self.$showRefineSheet) {
            if let detail = viewModel.playlistDetail {
                RefinePlaylistSheet(
                    tracks: detail.tracks,
                    isProcessing: self.$isRefining,
                    changes: self.$playlistChanges,
                    partialChanges: self.$partialChanges,
                    errorMessage: self.$refineError,
                    onRefine: { prompt in
                        await self.refinePlaylist(tracks: detail.tracks, prompt: prompt)
                    },
                    onApply: {
                        // Playlist modification via API not yet implemented
                        // For now, just close the sheet
                        self.showRefineSheet = false
                    }
                )
            }
        }
    }

    // MARK: - Views

    private func contentView(_ detail: PlaylistDetail) -> some View {
        let fallbackAlbum = Album(
            id: detail.id,
            title: detail.title,
            artists: detail.author.map { [$0] },
            thumbnailURL: detail.thumbnailURL,
            year: nil,
            trackCount: detail.trackCount ?? detail.tracks.count
        )
        let gutter = TuneTheme.Spacing.gutter
        let isTwoColumn = self.layoutWidth >= Self.twoColumnBreakpoint
        let tableWidth = max(
            0,
            self.layoutWidth - 2 * gutter - (isTwoColumn ? Self.sideColumnWidth + gutter : 0)
        )
        let columns = PlaylistTrackColumns(
            width: tableWidth,
            showsThumbnail: !detail.isAlbum,
            wantsAlbumColumn: !detail.isAlbum
        )

        let breakdown = detail.isAlbum ? nil : PlaylistBreakdown.make(tracks: detail.tracks)

        return ZStack {
            // Laid out only once the width is known, so the first pass doesn't
            // build the stacked layout (and zero-width columns) just to replace it.
            if self.layoutWidth > 0 {
                self.columnsLayout(
                    detail, isTwoColumn: isTwoColumn, columns: columns, breakdown: breakdown,
                    fallbackAlbum: fallbackAlbum
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            self.layoutWidth = width
        }
        // The window recomputes its minimum size on every layout pass, and without a
        // flexible frame that query measured the scroll content — a cost that grew
        // with every loaded page of tracks.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private func columnsLayout(
        _ detail: PlaylistDetail, isTwoColumn: Bool, columns: PlaylistTrackColumns,
        breakdown: PlaylistBreakdown?, fallbackAlbum: Album
    ) -> some View {
        let gutter = TuneTheme.Spacing.gutter
        return HStack(alignment: .top, spacing: 0) {
            if isTwoColumn {
                // The side column stays put while the track list scrolls.
                ScrollView {
                    self.sideColumn(detail, breakdown: breakdown)
                        .padding(.top, 28)
                        .padding(.bottom, TuneTheme.Spacing.scrollEndInset)
                }
                .scrollIndicators(.never)
                .frame(width: Self.sideColumnWidth)
                .padding(.leading, gutter)
                .padding(.trailing, gutter)
            }

            ScrollView {
                // One lazy stack as the scroll view's direct content: wrapping a LazyVStack
                // in a VStack made every layout pass size the whole track list.
                LazyVStack(alignment: .leading, spacing: 0) {
                    if isTwoColumn {
                        self.titleBlock(detail, breakdown: breakdown)
                        // Actions sit under the title in the wide column: the slim side
                        // column has no room for the full row.
                        self.headerButtons(detail)
                            .frame(maxWidth: Self.actionRowMaxWidth, alignment: .leading)
                            .padding(.bottom, 24)
                    } else {
                        self.compactHeader(detail, breakdown: breakdown)
                            .padding(.bottom, 24)
                    }

                    PlaylistTrackHeader(columns: columns)

                    self.trackRows(
                        detail.tracks, isAlbum: detail.isAlbum, author: detail.author?.name,
                        columns: columns, fallbackAlbum: fallbackAlbum
                    )
                }
                .padding(.top, 28)
                .padding(.bottom, TuneTheme.Spacing.scrollEndInset)
                .padding(.leading, isTwoColumn ? 0 : gutter)
                .padding(.trailing, gutter)
            }
            .topFade(style: .contentMask)
        }
    }

    // MARK: - C2 header pieces

    /// Side column: the one big hard-edged cover, the action row, the
    /// description, and (for playlists) who and what the playlist is made of.
    private func sideColumn(_ detail: PlaylistDetail, breakdown: PlaylistBreakdown?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            self.cover(detail, side: Self.sideColumnWidth)

            self.descriptionText(detail)

            if let breakdown, !breakdown.artists.isEmpty || !breakdown.albums.isEmpty {
                PlaylistBreakdownSection(breakdown: breakdown)
            }
        }
        .frame(width: Self.sideColumnWidth, alignment: .leading)
    }

    /// Narrow windows: cover beside the title block, actions underneath.
    private func compactHeader(_ detail: PlaylistDetail, breakdown: PlaylistBreakdown?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 24) {
                self.cover(detail, side: Self.compactCoverSide)
                VStack(alignment: .leading, spacing: 0) {
                    self.titleBlock(detail, breakdown: breakdown, titleFont: TuneTheme.Typeface.display, showsStats: false)
                    Text(self.statsText(for: detail, breakdown: breakdown))
                        .font(TuneTheme.Typeface.data)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                        .lineLimit(1)
                }
            }
            self.headerButtons(detail)
                .frame(maxWidth: Self.actionRowMaxWidth, alignment: .leading)
            self.descriptionText(detail)
        }
    }

    private func cover(_ detail: PlaylistDetail, side: CGFloat) -> some View {
        let highQuality = detail.thumbnailURL?.highQualityThumbnailURL
        var seen = Set<URL>()
        let urls = [highQuality?.tuneArtworkURL(side: side), highQuality].compactMap(\.self).filter { seen.insert($0).inserted }
        // No `.fadeIn`: CachedAsyncImage already fades in a fresh load.
        // The header cover is the page's hero art: it takes the hero step.
        return TuneArtworkView(
            urls: urls,
            size: CGSize(width: side, height: side),
            placeholderSymbol: "music.note.list",
            cornerRadius: side >= Self.sideColumnWidth ? TuneTheme.Radius.hero : nil
        )
    }

    @ViewBuilder
    private func descriptionText(_ detail: PlaylistDetail) -> some View {
        if let description = detail.description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty,
           !description.hasPrefix("#")
        {
            Text(description)
                .font(TuneTheme.Typeface.body)
                .foregroundStyle(TuneTheme.Palette.inkMuted)
                .lineLimit(4)
                .textSelection(.enabled)
        }
    }

    /// Kind eyebrow, the big title, then the author line with mono stats on the right.
    private func titleBlock(
        _ detail: PlaylistDetail,
        breakdown: PlaylistBreakdown?,
        titleFont: Font = TuneTheme.Typeface.headline,
        showsStats: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(self.contentKindText(for: detail))
                .tuneCapsLabel()
                .padding(.bottom, 12)

            Text(detail.title)
                .font(titleFont)
                .tracking(-1)
                .foregroundStyle(TuneTheme.Palette.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                self.headerAuthorView(detail)
                Spacer(minLength: 0)
                if showsStats {
                    Text(self.statsText(for: detail, breakdown: breakdown))
                        .font(TuneTheme.Typeface.data)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
    }

    @ViewBuilder
    private func headerAuthorView(_ detail: PlaylistDetail) -> some View {
        let artists = self.headerArtists(for: detail)

        if !artists.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(artists.enumerated()), id: \.offset) { index, artist in
                    if artist.hasNavigableId {
                        NavigationLink(value: artist) {
                            HeaderArtistLinkLabel(name: artist.name)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(artist.name)
                            .font(TuneTheme.Typeface.bodyEmphasis)
                            .foregroundStyle(TuneTheme.Palette.ink)
                    }

                    if index < artists.count - 1 {
                        Text(verbatim: ", ")
                            .font(TuneTheme.Typeface.bodyEmphasis)
                            .foregroundStyle(TuneTheme.Palette.inkSecondary)
                    }
                }
            }
            .lineLimit(1)
        }
    }

    /// "40 SONGS · 2:55:03 · 19 ARTISTS" (artists for playlists only).
    private func statsText(for detail: PlaylistDetail, breakdown: PlaylistBreakdown?) -> String {
        var parts = [detail.trackCountDisplay]
        if let duration = detail.duration, !duration.isEmpty {
            parts.append(duration)
        }
        if let artistCount = breakdown?.uniqueArtistCount, artistCount > 1 {
            parts.append("\(artistCount) \(String(localized: "Artists"))")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ").uppercased(with: .current)
    }

    private func contentKindText(for detail: PlaylistDetail) -> String {
        if detail.isUploadedSongs {
            return String(localized: "Uploads")
        }
        return detail.isAlbum ? String(localized: "Album") : String(localized: "Playlist")
    }

    @ViewBuilder
    private func trackRows(
        _ tracks: [Song], isAlbum: Bool, author: String?, columns: PlaylistTrackColumns,
        fallbackAlbum: Album? = nil
    ) -> some View {
        ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
            // Each row draws its own hairline, so the lazy stack places one view per track.
            self.trackRow(
                track, index: index, tracks: tracks, isAlbum: isAlbum, author: author,
                columns: columns, fallbackAlbum: fallbackAlbum
            )
            .onAppear {
                self.viewModel.loadMoreIfNeeded(appearingAt: index)
            }
        }

        // Loading indicator for pagination
        if self.viewModel.loadingState == .loadingMore {
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .tint(TuneTheme.Palette.inkMuted)
                    .padding()
                Spacer()
            }
        }
    }

    private func trackRow(
        _ track: Song, index: Int, tracks: [Song], isAlbum: Bool, author: String?,
        columns: PlaylistTrackColumns, fallbackAlbum: Album? = nil
    ) -> some View {
        let play = {
            self.playTrackInQueue(
                tracks: tracks, startingAt: index, fallbackArtist: author,
                fallbackAlbum: fallbackAlbum
            )
        }
        return PlaylistTrackRow(
            track: track,
            index: index,
            isAlbum: isAlbum,
            subtitle: self.trackArtistsDisplay(for: track, fallbackAuthor: author),
            artists: self.trackArtists(for: track, fallbackAuthor: author),
            allowsLikeActions: self.hasPersonalAccount,
            columns: columns,
            onPlay: play,
            menu: {
                self.trackContextMenu(track, play: play)
            }
        )
        .staggeredAppearance(index: min(index, 10))
    }

    private func headerArtists(for detail: PlaylistDetail) -> [Artist] {
        if let author = self.cleanedArtist(detail.author) {
            return [author]
        }

        return self.uniqueArtists(from: detail.tracks.flatMap(\.artists))
    }

    private func trackArtistsDisplay(for track: Song, fallbackAuthor: String?) -> String? {
        let artists = self.uniqueArtists(from: track.artists)
        if !artists.isEmpty {
            return artists.map(\.name).joined(separator: ", ")
        }

        guard let fallbackArtist = self.cleanedArtistName(fallbackAuthor) else { return nil }
        return fallbackArtist
    }

    private func trackArtists(for track: Song, fallbackAuthor: String?) -> [Artist]? {
        let artists = self.uniqueArtists(from: track.artists)
        if !artists.isEmpty {
            return artists
        }

        guard let fallbackName = self.cleanedArtistName(fallbackAuthor),
              let author = self.cleanedArtist(self.viewModel.playlistDetail?.author),
              author.hasNavigableId,
              author.name == fallbackName
        else { return nil }

        return [author]
    }

    private func uniqueArtists(from artists: [Artist]) -> [Artist] {
        var seen = Set<String>()
        var uniqueArtists: [Artist] = []

        for artist in artists {
            guard let cleanedArtist = self.cleanedArtist(artist) else { continue }
            let key = cleanedArtist.hasNavigableId ? cleanedArtist.id : cleanedArtist.name.lowercased()
            guard seen.insert(key).inserted else { continue }
            uniqueArtists.append(cleanedArtist)
        }

        return uniqueArtists
    }

    private func cleanedArtist(_ artist: Artist?) -> Artist? {
        guard let artist,
              let name = self.cleanedArtistName(artist.name)
        else { return nil }

        return Artist(
            id: artist.id,
            name: name,
            thumbnailURL: artist.thumbnailURL,
            subtitle: artist.subtitle,
            profileKind: artist.profileKind
        )
    }

    private func cleanedArtistName(_ name: String?) -> String? {
        guard var cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleanName.isEmpty
        else { return nil }

        if cleanName == "Album" {
            return nil
        }

        if cleanName.hasPrefix("Album, ") {
            cleanName = String(cleanName.dropFirst(7))
        } else if cleanName.contains("Album,") {
            let parts = cleanName.split(separator: ",", maxSplits: 1)
            if parts.count > 1 {
                cleanName = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return cleanName.isEmpty ? nil : cleanName
    }

    // MARK: - Actions

    @ViewBuilder
    private func trackContextMenu(_ track: Song, play: @escaping () -> Void) -> some View {
        if track.isPlayable {
            SongContextMenu(
                song: track,
                client: self.viewModel.client,
                play: play,
                showsGoToAlbum: self.viewModel.playlistDetail?.isAlbum != true
            )
        }

        if self.canRemoveTrack(track) {
            if track.isPlayable {
                Divider()
            }

            Button(role: .destructive) {
                Task {
                    await LibraryMutationActions.removeSongFromPlaylist(track, from: self.viewModel, client: self.viewModel.client)
                }
            } label: {
                Label(String(localized: "Remove from Playlist"), systemImage: "minus.circle")
            }
        }
    }

    /// Whether `track` can be removed from the currently loaded playlist: the user must
    /// own the playlist (not an album, not the uploaded-songs surface), and the track
    /// must carry the playlist-item identifier a removal call requires.
    private func canRemoveTrack(_ track: Song) -> Bool {
        guard let detail = self.viewModel.playlistDetail else { return false }
        return !self.viewModel.isRemovingTrack
            && detail.canDelete
            && !detail.isAlbum
            && !detail.isUploadedSongs
            && track.playlistSetVideoId != nil
    }

    private func playTrackInQueue(
        tracks: [Song], startingAt index: Int, fallbackArtist: String? = nil,
        fallbackAlbum: Album? = nil
    ) {
        guard tracks.indices.contains(index), tracks[index].isPlayable else { return }

        let playableIndex = tracks[...index].filter(\.isPlayable).count - 1
        let cleanedTracks = self.playableTracks(
            tracks, fallbackArtist: fallbackArtist, fallbackAlbum: fallbackAlbum
        )
        self.playAndLoadFullPlaylist(
            initial: cleanedTracks, startingAt: playableIndex,
            fallbackArtist: fallbackArtist, fallbackAlbum: fallbackAlbum
        )
    }

    /// SHUFFLE: turns shuffle on (if it isn't) and starts from a random playable
    /// track; the queue install shuffles the rest around it.
    func shufflePlay(
        _ tracks: [Song], fallbackArtist: String? = nil, fallbackAlbum: Album? = nil
    ) {
        let cleanedTracks = self.playableTracks(
            tracks, fallbackArtist: fallbackArtist, fallbackAlbum: fallbackAlbum
        )
        guard !cleanedTracks.isEmpty else { return }
        if !self.playerService.shuffleEnabled {
            self.playerService.toggleShuffle()
        }
        self.playAndLoadFullPlaylist(
            initial: cleanedTracks, startingAt: Int.random(in: 0 ..< cleanedTracks.count),
            fallbackArtist: fallbackArtist, fallbackAlbum: fallbackAlbum
        )
    }

    func playAll(
        _ tracks: [Song], fallbackArtist: String? = nil, fallbackAlbum: Album? = nil
    ) {
        let cleanedTracks = self.playableTracks(
            tracks, fallbackArtist: fallbackArtist, fallbackAlbum: fallbackAlbum
        )
        guard !cleanedTracks.isEmpty else { return }
        self.playAndLoadFullPlaylist(
            initial: cleanedTracks, startingAt: 0,
            fallbackArtist: fallbackArtist, fallbackAlbum: fallbackAlbum
        )
    }

    /// Plays the currently-loaded tracks immediately, then — if the playlist is still loading —
    /// grows the queue to the full set before Smart Shuffle generates suggestions, re-shuffling
    /// the complete set when shuffling. Reuses the data the detail view is already paging.
    private func playAndLoadFullPlaylist(
        initial cleanedTracks: [Song], startingAt index: Int,
        fallbackArtist: String?, fallbackAlbum: Album?
    ) {
        let intent = self.playerService.beginMusicPlaybackIntent()
        Task { @MainActor in
            let willDeferLoad = self.viewModel.hasMore
            let loadGeneration = await self.playerService.playQueue(
                cleanedTracks,
                startingAt: index,
                deferringSmartShuffleFill: willDeferLoad,
                intent: intent
            )
            // Not deferring (playlist already fully loaded): playQueue filled suggestions itself.
            guard let loadGeneration else { return }

            await self.viewModel.loadAllRemaining()
            await self.viewModel.waitForTrackRemovalToFinish()

            // Stand down if a *different* playback superseded this load while it paged. (User edits
            // such as removing a track keep the same load generation, so loading continues.)
            guard self.playerService.isCurrentQueueLoad(loadGeneration) else { return }

            let fullTracks = self.playableTracks(
                self.viewModel.playlistDetail?.tracks ?? [],
                fallbackArtist: fallbackArtist, fallbackAlbum: fallbackAlbum
            )
            let remaining = PlaylistPlaybackActions.remainingTracks(
                after: cleanedTracks,
                in: fullTracks
            )
            self.playerService.appendOriginalTracks(remaining)
            await self.playerService.endQueueLoading(loadGeneration)
        }
    }

    func playableTracks(
        _ tracks: [Song], fallbackArtist: String?, fallbackAlbum: Album? = nil
    ) -> [Song] {
        QueueSongMetadata.songsForQueue(
            tracks.filter(\.isPlayable), fallbackArtist: fallbackArtist,
            fallbackAlbum: fallbackAlbum
        )
    }

    private func refinePlaylist(tracks: [Song], prompt: String) async {
        self.isRefining = true
        self.refineError = nil
        self.playlistChanges = nil
        self.partialChanges = nil

        self.logger.info("Refining playlist with prompt: \(prompt)")

        let promptVersion = FoundationModelsPromptVersion.current
        let instructions = FoundationModelsPromptLibrary.playlistRefinementInstructions(
            version: promptVersion
        )
        self.logger.debug("Using Foundation Models playlist prompt version \(promptVersion.logDescription)")

        // Use analysis session for creative playlist curation
        guard let session = FoundationModelsService.shared.createAnalysisSession(
            instructions: instructions
        )
        else {
            self.refineError = "Apple Intelligence is not available"
            self.isRefining = false
            return
        }

        // Build track list - start with 25 and trim further on 26.4+ if token budget requires it.
        let initialTrackLimit = min(tracks.count, 25)
        let trackLines = FoundationModelsPromptLibrary.playlistTrackLines(
            from: tracks,
            limit: initialTrackLimit
        )
        let trackLimit = await FoundationModelsService.shared.fittedLineCount(
            context: "playlist refinement",
            instructions: instructions,
            lines: trackLines,
            generationSchema: PlaylistChanges.generationSchema
        ) { candidateLines in
            FoundationModelsPromptLibrary.playlistRefinementPrompt(
                trackList: candidateLines.joined(separator: "\n"),
                totalTracks: tracks.count,
                shownTracks: candidateLines.count,
                request: prompt,
                version: promptVersion
            )
        }
        let trackList = Array(trackLines.prefix(trackLimit)).joined(separator: "\n")
        let fittedRequest = await FoundationModelsService.shared.fittedPromptContent(
            context: "playlist refinement request",
            instructions: instructions,
            content: prompt,
            generationSchema: PlaylistChanges.generationSchema
        ) { candidateRequest in
            FoundationModelsPromptLibrary.playlistRefinementPrompt(
                trackList: trackList,
                totalTracks: tracks.count,
                shownTracks: trackLimit,
                request: candidateRequest,
                version: promptVersion
            )
        }

        let userPrompt = FoundationModelsPromptLibrary.playlistRefinementPrompt(
            trackList: trackList,
            totalTracks: tracks.count,
            shownTracks: trackLimit,
            request: fittedRequest,
            version: promptVersion
        )

        do {
            // Use streaming for progressive UI updates
            let stream = session.streamResponse(
                to: userPrompt,
                generating: PlaylistChanges.self
            )

            for try await snapshot in stream {
                // Update partial content for streaming UI
                self.partialChanges = snapshot.content
            }

            // Stream complete - convert final partial to complete changes
            if let final = self.partialChanges,
               let removals = final.removals,
               let reasoning = final.reasoning
            {
                let normalizedChanges = PlaylistChanges(
                    removals: removals,
                    reorderedIds: final.reorderedIds,
                    reasoning: reasoning
                )
                .normalized(forOriginalTrackIds: tracks.map(\.videoId))
                self.playlistChanges = normalizedChanges
                self.logger.info(
                    """
                    Got playlist changes: \(removals.count) removals, \
                    reordered=\(normalizedChanges.reorderedIds != nil)
                    """
                )
            }
        } catch {
            // Use centralized error handler for consistent messaging
            if let message = AIErrorHandler.handleAndMessage(error, context: "playlist refinement") {
                self.refineError = message
            }
        }

        self.partialChanges = nil
        self.isRefining = false
    }
}

// MARK: - HeaderArtistLinkLabel

private struct HeaderArtistLinkLabel: View {
    let name: String

    @State private var isHovering = false

    var body: some View {
        Text(self.name)
            .font(TuneTheme.Typeface.bodyEmphasis)
            .foregroundStyle(TuneTheme.Palette.ink)
            .underline(self.isHovering)
            .animation(.easeInOut(duration: 0.15), value: self.isHovering)
            .onHover { hovering in
                self.isHovering = hovering
            }
    }
}

@available(macOS 26.0, *)
#Preview {
    let playlist = Playlist(
        id: "test",
        title: "Test Playlist",
        description: nil,
        thumbnailURL: nil,
        trackCount: 10,
        author: Artist.inline(name: "Test Author", namespace: "playlist-author")
    )
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    PlaylistDetailView(
        playlist: playlist,
        viewModel: PlaylistDetailViewModel(
            playlist: playlist,
            client: client
        )
    )
    .environment(PlayerService())
    .environment(FavoritesManager(skipLoad: true))
    .environment(SidebarPinnedItemsManager(skipLoad: true))
}
