import SwiftUI

// swiftlint:disable file_length

// MARK: - PlayerBarStatusLine

/// Tune's player: C2's thin full-width status line (docs/fork/design/c2/home.html `.status`).
///
/// `MainWindow` mounts it once under the sidebar and content. The left column lines up with
/// the sidebar and holds the transport; the rest lines up with the content gutter:
/// track art + title, `elapsed ── scrubber ── total`, then text toggles, a few glyphs, and the
/// volume meter. The only accent is the scrubber's playhead. Page-specific link routing comes
/// from the `PlayerBar()` anchors pages place where their bar used to be.
struct PlayerBarStatusLine: View { // swiftlint:disable:this type_body_length
    private static let accent = TuneTheme.Palette.accent

    @Environment(AuthService.self) private var authService
    @Environment(PlayerService.self) private var playerService
    @Environment(NowPlayingTracklistProvider.self) private var tracklistProvider: NowPlayingTracklistProvider?

    @State private var routeCenter = PlayerBarRouteCenter.shared
    @State private var nowPlaying = NowPlayingPresentation.shared

    /// Seek state for the progress-dependent leaf views. `body` must not read its
    /// properties, or every playback progress tick re-evaluates the whole bar.
    @State private var seekController = PlayerBarSeekController()

    /// Local volume value for smooth slider dragging.
    @State private var volumeValue: Double = 1.0
    @State private var isAdjustingVolume = false
    @State private var showsVolumeOverlay = false
    @State private var resolvedArtist: Artist?
    @State private var resolvedAlbum: Playlist?
    @State private var isResolvingArtist = false
    @State private var isResolvingAlbum = false
    @State private var artistResolutionTask: Task<Void, Never>?
    @State private var albumResolutionTask: Task<Void, Never>?
    @State private var airPlayAnchor = AirPlayPickerAnchor()

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < PlayerBarLayout.statusLineFullLayoutMinWidth

            HStack(spacing: 0) {
                self.transport
                    .frame(width: TuneTheme.Spacing.sidebarWidth, alignment: .leading)

                HStack(spacing: isCompact ? 12 : 20) {
                    // The track column takes its natural width (title + artist, never less
                    // than a stable floor) before the scrubber, which keeps a usable minimum;
                    // a long title or artist uses the room instead of truncating beside it.
                    PlayerBarTrackTimeLayout(
                        spacing: isCompact ? 12 : 20,
                        trackFloor: isCompact
                            ? PlayerBarStatusMetrics.compactTrackColumnWidth
                            : PlayerBarStatusMetrics.trackColumnFloor,
                        timeMinimum: PlayerBarStatusMetrics.timeSectionMinWidth,
                        timeMaximum: PlayerBarStatusMetrics.scrubberMaxWidth + 80
                    ) {
                        self.trackSection
                        self.timeSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    self.optionsSection(isCompact: isCompact)
                        .fixedSize()
                }
                .padding(.horizontal, isCompact ? TuneTheme.Spacing.gutter / 2 : TuneTheme.Spacing.gutter)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: TuneTheme.Spacing.statusLineHeight)
        .frame(maxWidth: .infinity)
        .background(TuneTheme.Palette.background)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TuneTheme.Palette.rule)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .lineLimit(1)
        .task(id: self.navigationTargetsTaskID) {
            await self.prepareCurrentNavigationTargets()
        }
        .onChange(of: self.routeCenter.currentToken) { _, _ in
            // A lookup that finishes after the user left would push onto a stack they no longer see.
            self.cancelNavigationResolution()
        }
        .onChange(of: self.currentSeekIdentity) { _, _ in
            self.seekController.clearHold(playerService: self.playerService)
        }
        .onChange(of: self.playerService.isShowingAd) { _, isShowingAd in
            if isShowingAd {
                self.seekController.clearHold(playerService: self.playerService)
            }
        }
        .onChange(of: self.playerService.volume) { _, newValue in
            if !self.isAdjustingVolume {
                self.volumeValue = newValue
            }
        }
        .onAppear {
            self.volumeValue = self.playerService.volume
        }
        .onDisappear {
            self.cancelNavigationResolution()
        }
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 4) {
            PlayerBarStatusGlyphButton(
                accessibilityID: AccessibilityID.PlayerBar.previousButton,
                accessibilityLabel: String(localized: "Previous track"),
                isActive: true,
                action: self.previousTrack
            ) {
                PlayerBarGlyph.previous.view
            }
            .disabled(self.playerService.currentEpisode != nil)

            PlayerBarStatusGlyphButton(
                accessibilityID: AccessibilityID.PlayerBar.playPauseButton,
                accessibilityLabel: self.playerService.isPlaying ? String(localized: "Pause") : String(localized: "Play"),
                isActive: true,
                action: self.playPause
            ) {
                (self.playerService.isPlaying ? PlayerBarGlyph.pause : PlayerBarGlyph.play).view
            }

            PlayerBarStatusGlyphButton(
                accessibilityID: AccessibilityID.PlayerBar.nextButton,
                accessibilityLabel: String(localized: "Next track"),
                isActive: true,
                action: self.nextTrack
            ) {
                PlayerBarGlyph.next.view
            }
            .disabled(self.playerService.currentEpisode != nil)
        }
        .padding(.leading, 14)
    }

    // MARK: - Track

    private var trackSection: some View {
        HStack(spacing: 10) {
            self.thumbnailView

            Text(self.playerService.currentTrack?.displayText.title ?? String(localized: "Not Playing"))
                .font(TuneTheme.Typeface.bodyEmphasis)
                .foregroundStyle(
                    self.playerService.currentTrack == nil ? TuneTheme.Palette.inkMuted : TuneTheme.Palette.ink
                )
                .truncationMode(.tail)
                .layoutPriority(1)
                .accessibilityIdentifier(AccessibilityID.PlayerBar.trackTitle)

            if self.playerService.currentTrack != nil {
                PlayerBarMetadataButton(
                    text: self.artistName,
                    isEnabled: self.canOpenCurrentArtist,
                    isLoading: self.isResolvingArtist,
                    accessibilityIdentifier: AccessibilityID.PlayerBar.trackArtist,
                    action: self.openCurrentArtist
                )
            }
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .contextMenu {
            if let track = self.playerService.currentTrack {
                self.currentSongContextMenu(for: track)
            }
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let track = self.playerService.currentTrack {
            if self.canOpenCurrentAlbum {
                Button {
                    self.openCurrentAlbum()
                } label: {
                    self.trackArtwork(for: track)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.PlayerBar.thumbnail)
                .accessibilityLabel(Text(String(localized: "Go to Album")))
            } else {
                self.trackArtwork(for: track)
                    .accessibilityIdentifier(AccessibilityID.PlayerBar.thumbnail)
            }
        } else {
            RoundedRectangle(cornerRadius: TuneTheme.Radius.small, style: .continuous)
                .fill(TuneTheme.Palette.raised)
                .frame(width: PlayerBarStatusMetrics.artworkSize, height: PlayerBarStatusMetrics.artworkSize)
                .overlay { self.artworkEdge }
                .accessibilityIdentifier(AccessibilityID.PlayerBar.thumbnail)
        }
    }

    private func trackArtwork(for track: Song) -> some View {
        PlayerBarArtworkView(
            width: PlayerBarStatusMetrics.artworkSize,
            height: PlayerBarStatusMetrics.artworkSize,
            cornerRadius: TuneTheme.Radius.small,
            showsHoverOverlay: self.canOpenCurrentAlbum || self.showsCurrentAlbumHoverOnly,
            isLoading: self.isResolvingAlbum
        ) {
            SongThumbnailView(song: track, size: PlayerBarStatusMetrics.artworkSize, cornerRadius: TuneTheme.Radius.small)
        }
        .overlay { self.artworkEdge }
    }

    /// C2 `.art::after`: a 1-point inset hairline that keeps dark covers off the black.
    private var artworkEdge: some View {
        RoundedRectangle(cornerRadius: TuneTheme.Radius.small, style: .continuous)
            .strokeBorder(TuneTheme.Palette.ink.opacity(PlayerBarStatusMetrics.artworkEdgeOpacity), lineWidth: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - Time

    @ViewBuilder
    private var timeSection: some View {
        if case let .error(message) = playerService.state {
            self.errorView(message: message)
        } else if self.playerService.isShowingAd {
            PlayerBarAdIndicator(isInline: true)
        } else {
            PlayerBarTimelineLane(
                seekController: self.seekController,
                segments: self.progressSegments,
                accent: Self.accent,
                layout: .inline
            )
            // Keeps the segment tooltip above neighbouring controls; the tooltip itself is
            // non-hit-testable so the controls stay clickable.
            .zIndex(1)
        }
    }

    /// Sub-track segments for the seek bar. Depends on duration, never on progress.
    private var progressSegments: [PlayerBarProgressSegment] {
        PlayerBarSeekController.progressSegments(
            tracklist: self.tracklistProvider?.tracklist,
            duration: self.playerService.duration,
            isLive: self.playerService.isCurrentItemLive
        )
    }

    private func errorView(message: String) -> some View {
        HStack(spacing: 10) {
            Text(message)
                .font(TuneTheme.Typeface.body)
                .foregroundStyle(TuneTheme.Palette.inkMuted)
                .truncationMode(.tail)

            PlayerBarStatusToggle(
                title: String(localized: "Retry"),
                isOn: false,
                accessibilityLabel: String(localized: "Retry"),
                action: {
                    Task {
                        if let track = playerService.currentTrack {
                            await self.playerService.play(song: track)
                        }
                    }
                }
            )
        }
    }

    // MARK: - Options

    private func optionsSection(isCompact: Bool) -> some View {
        HStack(spacing: isCompact ? 8 : 16) {
            let segments = self.progressSegments
            if !segments.isEmpty {
                PlayerBarMixTracksMenu(seekController: self.seekController, segments: segments)
                    .frame(width: 24, height: 24)
            }

            self.lyricsToggle(isCompact: isCompact)
            self.queueToggle(isCompact: isCompact)
            self.videoToggle(isCompact: isCompact)

            PlayerBarStatusSeparator()

            self.shuffleToggle(isCompact: isCompact)
            self.repeatToggle(isCompact: isCompact)

            PlayerBarStatusSeparator()

            HStack(spacing: 4) {
                if self.hasPersonalAccount {
                    self.likeButton
                }
                self.airPlayButton
            }

            self.volumeButton
            self.moreMenu
            self.nowPlayingButton
        }
    }

    private func lyricsToggle(isCompact: Bool) -> some View {
        @Bindable var player = self.playerService

        return PlayerBarStatusToggle(
            title: String(localized: "Lyrics"),
            isOn: self.playerService.showLyrics,
            accessibilityID: AccessibilityID.PlayerBar.lyricsButton,
            accessibilityLabel: String(localized: "Lyrics"),
            accessibilityValue: self.playerService.showLyrics ? String(localized: "Showing") : String(localized: "Hidden"),
            compactSystemImage: isCompact ? "quote.bubble" : nil,
            action: {
                HapticService.toggle()
                withAnimation(AppAnimation.standard) {
                    player.showLyrics.toggle()
                }
            }
        )
    }

    private func queueToggle(isCompact: Bool) -> some View {
        @Bindable var player = self.playerService

        return PlayerBarStatusToggle(
            title: String(localized: "Queue"),
            isOn: self.playerService.showQueue,
            accessibilityID: AccessibilityID.PlayerBar.queueButton,
            accessibilityLabel: String(localized: "Queue"),
            accessibilityValue: self.playerService.showQueue ? String(localized: "Showing") : String(localized: "Hidden"),
            compactSystemImage: isCompact ? "list.bullet" : nil,
            action: {
                HapticService.toggle()
                withAnimation(AppAnimation.standard) {
                    player.showQueue.toggle()
                }
            }
        )
    }

    /// Always present (UI tests rely on it); dimmed and disabled when the track has no video.
    private func videoToggle(isCompact: Bool) -> some View {
        PlayerBarStatusToggle(
            title: String(localized: "Video"),
            isOn: self.playerService.showVideo,
            accessibilityID: AccessibilityID.PlayerBar.videoButton,
            accessibilityLabel: String(localized: "Video"),
            accessibilityValue: self.playerService.showVideo ? String(localized: "Playing") : String(localized: "Off"),
            compactSystemImage: isCompact ? "play.rectangle" : nil,
            action: { self.toggleVideo() }
        )
        .keyboardShortcut("v", modifiers: [.command, .shift])
        .disabled(!self.canShowCurrentTrackVideo)
    }

    private func shuffleToggle(isCompact: Bool) -> some View {
        PlayerBarStatusToggle(
            title: self.playerService.shuffleMode == .smart ? String(localized: "Smart Shuffle") : String(localized: "Shuffle"),
            isOn: self.playerService.shuffleEnabled,
            accessibilityID: AccessibilityID.PlayerBar.shuffleButton,
            accessibilityLabel: String(localized: "Shuffle"),
            accessibilityValue: self.shuffleAccessibilityValue,
            compactSystemImage: isCompact ? "shuffle" : nil,
            action: self.cycleShuffle
        )
        .opacity(self.playerService.isApplyingSmartShuffle ? 0.5 : 1)
        .disabled(self.playerService.currentTrack == nil)
    }

    private func repeatToggle(isCompact: Bool) -> some View {
        PlayerBarStatusToggle(
            title: self.playerService.repeatMode == .one ? String(localized: "Repeat 1") : String(localized: "Repeat"),
            isOn: self.playerService.repeatMode != .off,
            accessibilityID: AccessibilityID.PlayerBar.repeatButton,
            accessibilityLabel: String(localized: "Repeat"),
            accessibilityValue: self.repeatAccessibilityValue,
            compactSystemImage: isCompact ? (self.playerService.repeatMode == .one ? "repeat.1" : "repeat") : nil,
            action: self.cycleRepeatMode
        )
        .disabled(self.playerService.currentTrack == nil)
    }

    private var likeButton: some View {
        let isLiked = self.playerService.currentTrackLikeStatus == .like
        return PlayerBarStatusGlyphButton(
            accessibilityID: AccessibilityID.PlayerBar.likeButton,
            accessibilityLabel: String(localized: "Like"),
            accessibilityValue: isLiked ? String(localized: "Liked") : String(localized: "Not liked"),
            isActive: isLiked,
            action: self.likeCurrentTrack
        ) {
            (isLiked ? PlayerBarGlyph.heartFilled : PlayerBarGlyph.heart).view
        }
        .disabled(self.playerService.currentTrack == nil)
    }

    private var airPlayButton: some View {
        PlayerBarStatusGlyphButton(
            accessibilityID: AccessibilityID.PlayerBar.airplayButton,
            accessibilityLabel: self.playerService.isAirPlayConnected ? String(localized: "AirPlay Connected") : String(localized: "AirPlay"),
            isActive: self.playerService.isAirPlayConnected,
            action: self.showAirPlayPicker
        ) {
            PlayerBarGlyph.airplay.view
        }
        .background {
            AirPlayPickerAnchorView(anchor: self.airPlayAnchor)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .disabled(self.playerService.currentTrack == nil)
    }

    /// The meter is the volume control: click to open the vertical slider.
    private var volumeButton: some View {
        Button(action: self.toggleVolumePopover) {
            PlayerBarVolumeMeter(level: self.displayedVolume)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerBarStatusPressStyle())
        .accessibilityLabel(String(localized: "Volume"))
        .accessibilityValue("\(Int(self.displayedVolume * 100))%")
        .help(String(localized: "Volume"))
        .playerBarVolumeOverlay(isPresented: self.$showsVolumeOverlay) {
            self.volumeOverlay
        }
    }

    private var volumeOverlay: some View {
        PlayerBarVerticalSlider(
            value: self.$volumeValue,
            accent: TuneTheme.Palette.ink,
            accessibilityIdentifier: AccessibilityID.PlayerBar.volumeSlider,
            accessibilityLabel: String(localized: "Volume"),
            onEditingChanged: { editing in
                self.isAdjustingVolume = editing
                if !editing {
                    self.playerService.setVolumeImmediately(self.volumeValue)
                }
            },
            onValueChanged: { oldValue, newValue in
                if self.isAdjustingVolume {
                    if (oldValue > 0 && newValue == 0) || (oldValue < 1 && newValue == 1) {
                        HapticService.sliderBoundary()
                    }
                    self.playerService.setVolumeImmediately(newValue)
                }
            },
            usesHardEdges: true
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 14)
        .frame(width: 44, height: 150)
        .background(
            TuneTheme.Palette.raised,
            in: .rect(cornerRadius: TuneTheme.Radius.panel, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: TuneTheme.Radius.panel, style: .continuous)
                .strokeBorder(TuneTheme.Palette.rule, lineWidth: 1)
        }
    }

    /// Rarely used controls, kept reachable without spending status-line space.
    private var moreMenu: some View {
        Menu {
            if self.hasPersonalAccount {
                Button(
                    self.playerService.currentTrackLikeStatus == .dislike
                        ? String(localized: "Remove Dislike")
                        : String(localized: "Dislike"),
                    action: self.dislikeCurrentTrack
                )
                .accessibilityIdentifier(AccessibilityID.PlayerBar.dislikeButton)
                .disabled(self.playerService.currentTrack == nil)
            }

            Button(
                self.playerService.isMiniPlayerVisible
                    ? String(localized: "Return to Tune")
                    : String(localized: "Switch to Mini Player"),
                action: self.toggleMiniPlayer
            )
            .accessibilityIdentifier(AccessibilityID.PlayerBar.miniPlayerButton)
        } label: {
            Image(systemName: "ellipsis")
                .font(TuneTheme.Typeface.label)
                .foregroundStyle(TuneTheme.Palette.inkSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(String(localized: "More"))
        .help(String(localized: "More"))
    }

    /// Opens Tune's fullscreen Now Playing view (⇧⌘F, Apple Music's Full Screen Player shortcut).
    private var nowPlayingButton: some View {
        PlayerBarStatusGlyphButton(
            accessibilityID: AccessibilityID.PlayerBar.nowPlayingButton,
            accessibilityLabel: String(localized: "Now Playing"),
            accessibilityValue: self.nowPlaying.isPresented ? String(localized: "Showing") : String(localized: "Hidden"),
            isActive: self.nowPlaying.isPresented,
            action: {
                HapticService.toggle()
                self.nowPlaying.toggle()
            }
        ) {
            Image(systemName: self.nowPlaying.isPresented
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right")
                .font(TuneTheme.Typeface.label)
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .help(String(localized: "Now Playing (⇧⌘F)"))
    }

    private var canShowCurrentTrackVideo: Bool {
        self.playerService.canShowCurrentTrackVideo
    }

    private var currentSeekIdentity: String {
        self.playerService.currentTrack?.videoId ?? "none"
    }

    private func toggleVideo() {
        guard self.canShowCurrentTrackVideo else { return }
        HapticService.toggle()
        // Over fullscreen Now Playing, ⇧⌘V flips that view's SONG · VIDEO switch instead of
        // opening the separate video window behind it.
        if NowPlayingPresentation.shared.isPresented {
            TuneNowPlayingHost.toggleVideoPreference()
            return
        }
        DiagnosticsLogger.player.debug(
            "Video button clicked, toggling showVideo from \(self.playerService.showVideo)"
        )
        withAnimation(AppAnimation.standard) {
            self.playerService.showVideo.toggle()
        }
    }

    private func toggleMiniPlayer() {
        HapticService.toggle()
        _ = self.playerService.toggleMiniPlayer(mode: .switchFromMainWindow)
    }

    // MARK: - Route

    private var navigationAction: PlayerBarNavigationAction {
        self.routeCenter.current?.navigationAction ?? .disabled
    }

    private var currentRouteAlbumIDs: Set<String> {
        self.routeCenter.current?.albumIDs ?? []
    }

    private var currentRouteArtistID: String? {
        self.routeCenter.current?.artistID
    }

    /// Re-resolve link targets when the track changes or the hosting page gains/loses routing.
    private var navigationTargetsTaskID: String {
        let canNavigate = self.navigationAction.openArtist != nil || self.navigationAction.openAlbum != nil
        return "\(self.currentTitleIdentity)|\(canNavigate)"
    }

    private var currentTitleIdentity: String {
        [
            self.playerService.currentTrack?.videoId ?? "none",
            self.playerService.currentTrack?.title ?? "none",
        ].joined(separator: "|")
    }

    private var canOpenCurrentArtist: Bool {
        self.playerService.currentTrack != nil
            && self.navigationAction.openArtist != nil
            && (self.currentArtistTarget != nil || (self.currentArtistSearchName != nil && self.playerService.ytMusicClient != nil))
            && !self.isCurrentArtistTarget
    }

    private var canOpenCurrentAlbum: Bool {
        self.playerService.currentTrack != nil
            && self.navigationAction.openAlbum != nil
            && (self.currentAlbumTarget != nil || (self.currentArtistSearchName != nil && self.playerService.ytMusicClient != nil))
            && !self.isCurrentAlbumTarget
            && !self.isResolvingCurrentRouteAlbum
    }

    private var currentArtistTarget: Artist? {
        self.primaryNavigableArtist ?? self.resolvedArtist
    }

    private var currentAlbumTarget: Playlist? {
        self.currentAlbumPlaylist ?? self.resolvedAlbum
    }

    private var isCurrentAlbumTarget: Bool {
        guard let album = self.currentAlbumTarget else { return false }
        return PlayerBarCurrentRoute.isAlbum(album, in: self.currentRouteAlbumIDs)
    }

    private var showsCurrentAlbumHoverOnly: Bool {
        self.isCurrentAlbumTarget || self.isResolvingCurrentRouteAlbum
    }

    private var isResolvingCurrentRouteAlbum: Bool {
        !self.currentRouteAlbumIDs.isEmpty && self.currentAlbumTarget == nil
    }

    private var isCurrentArtistTarget: Bool {
        guard let artist = self.currentArtistTarget else { return false }
        return PlayerBarCurrentRoute.isArtist(artist, routeArtistID: self.currentRouteArtistID)
    }

    private var currentAlbumPlaylist: Playlist? {
        guard let track = self.playerService.currentTrack,
              let album = track.album,
              album.hasNavigableId
        else { return nil }

        return self.playlist(from: album, track: track)
    }

    private var primaryNavigableArtist: Artist? {
        self.playerService.currentTrack?.artists.first(where: { $0.hasNavigableId })
    }

    private var currentArtistSearchName: String? {
        guard let track = self.playerService.currentTrack else { return nil }
        return self.primaryArtistName(in: track)
    }

    private var artistName: String {
        guard let track = self.playerService.currentTrack else {
            return MainWindowLayout.windowTitle
        }
        let artist = track.displayText.artist
        return artist.isEmpty ? String(localized: "Unknown Artist") : artist
    }

    private func playlist(from album: Album, track: Song) -> Playlist {
        Playlist(
            id: album.id,
            title: album.title,
            description: nil,
            thumbnailURL: album.thumbnailURL ?? track.thumbnailURL,
            trackCount: album.trackCount,
            author: Artist.inline(name: album.artistsDisplay, namespace: "album-artist"),
            libraryTargetId: album.libraryTargetId
        )
    }

    // MARK: - Current Song Context Menu

    private func currentSongContextMenu(for track: Song) -> some View {
        SongContextMenu(
            song: track,
            client: self.playerService.ytMusicClient,
            libraryToggle: SongLibraryToggle(
                isInLibrary: self.playerService.currentTrackInLibrary,
                toggle: { self.playerService.toggleLibraryStatus() }
            ),
            showsGoToArtist: self.showsGoToArtist(for: track),
            showsGoToAlbum: self.showsGoToAlbum(for: track),
            navigate: { destination in
                if let artist = destination as? Artist {
                    self.openArtist(artist)
                } else if let album = destination as? Playlist {
                    self.openAlbum(album)
                }
            }
        )
    }

    // MARK: - Actions

    /// Whether the context menu offers the track's artist: not when the player bar can't navigate
    /// or that artist's page is already showing.
    private func showsGoToArtist(for track: Song) -> Bool {
        guard self.navigationAction.openArtist != nil else { return false }
        guard let artist = track.artists.first(where: { $0.hasNavigableId }) else { return true }
        return !PlayerBarCurrentRoute.isArtist(artist, routeArtistID: self.currentRouteArtistID)
    }

    /// Whether the context menu offers the track's album: not when the player bar can't navigate
    /// or that album's page is already showing.
    private func showsGoToAlbum(for track: Song) -> Bool {
        guard self.navigationAction.openAlbum != nil else { return false }
        guard let album = track.album else { return true }
        return !PlayerBarCurrentRoute.isAlbum(album.detailPlaylist(), in: self.currentRouteAlbumIDs)
    }

    private var hasPersonalAccount: Bool {
        self.authService.hasPersonalAccount
    }

    private func likeCurrentTrack() {
        guard self.hasPersonalAccount else { return }
        HapticService.toggle()
        self.playerService.likeCurrentTrack()
    }

    private func prepareCurrentNavigationTargets() async {
        self.resolvedArtist = nil
        self.resolvedAlbum = nil
        self.isResolvingArtist = false
        self.isResolvingAlbum = false

        guard self.playerService.currentTrack != nil,
              let client = self.playerService.ytMusicClient
        else { return }

        let identity = self.currentTitleIdentity

        if self.navigationAction.openArtist != nil,
           self.primaryNavigableArtist == nil,
           let artistName = self.currentArtistSearchName
        {
            let artist = await self.resolveArtist(named: artistName, client: client)
            guard !Task.isCancelled, self.currentTitleIdentity == identity else { return }
            self.resolvedArtist = artist
        }

        if self.navigationAction.openAlbum != nil,
           self.currentAlbumPlaylist == nil,
           self.currentArtistSearchName != nil,
           let track = self.playerService.currentTrack
        {
            let album = await self.resolveAlbum(for: track, client: client)
            guard !Task.isCancelled, self.currentTitleIdentity == identity else { return }
            self.resolvedAlbum = album
        }
    }

    private func openCurrentArtist() {
        guard self.canOpenCurrentArtist else { return }
        guard !self.isResolvingArtist else { return }
        HapticService.toggle()

        if let artist = self.currentArtistTarget {
            self.openArtist(artist, playsHaptic: false)
            return
        }

        guard let query = self.currentArtistSearchName else { return }
        guard let client = self.playerService.ytMusicClient else { return }
        let identity = self.currentTitleIdentity

        self.isResolvingArtist = true

        self.artistResolutionTask = Task {
            let artist = await self.resolveArtist(named: query, client: client)
            guard !Task.isCancelled, self.currentTitleIdentity == identity else { return }
            self.resolvedArtist = artist
            self.isResolvingArtist = false

            guard let artist, !self.isCurrentArtistTarget else { return }
            self.openArtist(artist, playsHaptic: false)
        }
    }

    private func openCurrentAlbum() {
        guard self.canOpenCurrentAlbum else { return }
        guard !self.isResolvingAlbum else { return }
        HapticService.toggle()

        if let album = self.currentAlbumTarget {
            self.openAlbum(album, playsHaptic: false)
            return
        }

        guard let track = self.playerService.currentTrack,
              let client = self.playerService.ytMusicClient
        else { return }

        let identity = self.currentTitleIdentity
        self.isResolvingAlbum = true

        self.albumResolutionTask = Task {
            let album = await self.resolveAlbum(for: track, client: client)
            guard !Task.isCancelled, self.currentTitleIdentity == identity else { return }
            self.resolvedAlbum = album
            self.isResolvingAlbum = false

            guard let album else { return }
            self.openAlbum(album, playsHaptic: false)
        }
    }

    private func cancelNavigationResolution() {
        self.artistResolutionTask?.cancel()
        self.albumResolutionTask?.cancel()
        self.artistResolutionTask = nil
        self.albumResolutionTask = nil
        self.isResolvingArtist = false
        self.isResolvingAlbum = false
    }

    private func openArtist(_ artist: Artist, playsHaptic: Bool = true) {
        if playsHaptic {
            HapticService.toggle()
        }
        self.navigationAction.openArtist?(artist)
    }

    private func openAlbum(_ album: Playlist, playsHaptic: Bool = true) {
        if playsHaptic {
            HapticService.toggle()
        }
        self.navigationAction.openAlbum?(album)
    }

    private func resolveArtist(named name: String, client: any YTMusicClientProtocol) async -> Artist? {
        guard let query = self.trimmedNonEmpty(name) else { return nil }

        do {
            let response = try await client.searchArtists(query: query)
            return response.artists.first { artist in
                artist.hasNavigableId && self.matchesSearchResultTitle(artist.name, query: query)
            }
        } catch {
            DiagnosticsLogger.ui.error("Failed to resolve player bar artist: \(error.localizedDescription)")
            return nil
        }
    }

    private func resolveAlbum(for track: Song, client: any YTMusicClientProtocol) async -> Playlist? {
        if let album = track.album,
           let playlist = await self.resolveAlbum(named: album.title, fallbackTrack: track, client: client)
        {
            return playlist
        }

        do {
            guard let query = self.searchQuery(parts: [track.title, self.primaryArtistName(in: track)]) else { return nil }

            let response = try await client.searchSongsWithPagination(query: query)
            let matchedSong = response.songs.first { $0.videoId == track.videoId }
                ?? response.songs.first { song in
                    self.matchesSearchResultTitle(song.title, query: track.title)
                        && self.matchesTrackArtist(song, fallbackTrack: track)
                }

            guard let album = matchedSong?.album, album.hasNavigableId else { return nil }
            return self.playlist(from: album, track: matchedSong ?? track)
        } catch {
            DiagnosticsLogger.ui.error("Failed to resolve player bar album from song search: \(error.localizedDescription)")
            return nil
        }
    }

    private func resolveAlbum(
        named title: String,
        fallbackTrack track: Song,
        client: any YTMusicClientProtocol
    ) async -> Playlist? {
        guard let query = self.searchQuery(parts: [title, self.primaryArtistName(in: track)]),
              let artistName = self.primaryArtistName(in: track)
        else { return nil }

        do {
            let response = try await client.searchAlbums(query: query)
            guard let album = response.albums.first(where: { album in
                album.hasNavigableId
                    && self.matchesSearchResultTitle(album.title, query: title)
                    && self.matchesAlbumArtist(album, artistName: artistName)
            }) else {
                return nil
            }

            return self.playlist(from: album, track: track)
        } catch {
            DiagnosticsLogger.ui.error("Failed to resolve player bar album: \(error.localizedDescription)")
            return nil
        }
    }

    private func primaryArtistName(in track: Song) -> String? {
        track.artists.lazy.compactMap { self.trimmedNonEmpty($0.name) }.first
    }

    private func searchQuery(parts: [String?]) -> String? {
        let query = parts.compactMap { part in
            part.flatMap(self.trimmedNonEmpty)
        }.joined(separator: " ")

        return self.trimmedNonEmpty(query)
    }

    private func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func matchesTrackArtist(_ song: Song, fallbackTrack track: Song) -> Bool {
        guard let artistName = self.primaryArtistName(in: track) else { return false }
        return song.artists.contains { self.matchesSearchResultTitle($0.name, query: artistName) }
    }

    private func matchesAlbumArtist(_ album: Album, artistName: String) -> Bool {
        guard let artists = album.artists else { return false }
        return artists.contains { self.matchesSearchResultTitle($0.name, query: artistName) }
    }

    private func matchesSearchResultTitle(_ title: String, query: String) -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(query)
        return normalizedTitle == .orderedSame
    }

    private func dislikeCurrentTrack() {
        guard self.hasPersonalAccount else { return }
        HapticService.toggle()
        self.playerService.dislikeCurrentTrack()
    }

    private func showAirPlayPicker() {
        HapticService.toggle()
        self.playerService.showAirPlayPicker(at: self.airPlayAnchor.screenPoint)
    }

    private func previousTrack() {
        HapticService.playback()
        Task {
            await self.playerService.previous()
        }
    }

    private func playPause() {
        HapticService.playback()
        Task {
            await self.playerService.playPause()
        }
    }

    private func nextTrack() {
        HapticService.playback()
        Task {
            await self.playerService.next()
        }
    }

    private var shuffleAccessibilityValue: String {
        switch self.playerService.shuffleMode {
        case .off: String(localized: "Off")
        case .on: String(localized: "On")
        case .smart: String(localized: "Smart")
        }
    }

    private func cycleShuffle() {
        HapticService.toggle()
        self.playerService.cycleShuffleMode()
    }

    private func cycleRepeatMode() {
        HapticService.toggle()
        self.playerService.cycleRepeatMode()
    }

    private func toggleVolumePopover() {
        HapticService.toggle()
        withAnimation(AppAnimation.quick) {
            self.showsVolumeOverlay.toggle()
        }
    }

    private var displayedVolume: Double {
        self.isAdjustingVolume ? self.volumeValue : self.playerService.volume
    }

    private var repeatIconName: String {
        self.playerService.repeatMode == .one ? "repeat.1" : "repeat"
    }

    private var repeatAccessibilityValue: String {
        switch self.playerService.repeatMode {
        case .off:
            String(localized: "Off")
        case .all:
            String(localized: "All")
        case .one:
            String(localized: "One")
        }
    }
}

// MARK: - AccessibilityID.PlayerBar + Now Playing

extension AccessibilityID.PlayerBar {
    static let nowPlayingButton = "playerBar.nowPlaying"
}

#Preview {
    PlayerBarStatusLine()
        .environment(PlayerService())
        .environment(AuthService())
        .environment(FavoritesManager.shared)
        .environment(SongLikeStatusManager.shared)
        .frame(width: 1440)
        .preferredColorScheme(.dark)
}
