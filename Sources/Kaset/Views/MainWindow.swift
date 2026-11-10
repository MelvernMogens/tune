// swiftlint:disable file_length

import SwiftUI

// MARK: - MainWindow

/// Main application window with sidebar navigation and player bar.
struct MainWindow: View { // swiftlint:disable:this type_body_length
    private static let accountResolutionGateTimeout: Duration = .seconds(2)

    private struct PresentedWhatsNew: Identifiable {
        let whatsNew: WhatsNew
        let requestedVersion: WhatsNew.Version

        var id: String {
            "\(self.requestedVersion.description)::\(self.whatsNew.version.description)"
        }
    }

    private struct PodcastsProbeTaskID: Hashable {
        let authGeneration: UInt64
        let accountID: String
    }

    nonisolated static func shouldMountPersistentPlayer(
        isLoggedIn: Bool,
        pendingVideoId: String?,
        isPendingRestoredLoadDeferred: Bool,
        showVideo: Bool,
        showsNowPlayingVideo: Bool = false
    ) -> Bool {
        !showVideo && !showsNowPlayingVideo
            && (isLoggedIn || (!isPendingRestoredLoadDeferred && pendingVideoId != nil))
    }

    @Environment(AuthService.self) private var authService
    @Environment(PlayerService.self) private var playerService
    @Environment(YouTubePlayerService.self) private var youtubePlayerService
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(AccountService.self) private var accountService
    @Environment(SongLikeStatusManager.self) private var likeStatusManager
    @Environment(SidebarPinnedItemsManager.self) private var sidebarPinnedItemsManager
    @Environment(PodcastsAvailabilityService.self) private var podcastsAvailability
    @Environment(\.searchFocusTrigger) private var searchFocusTrigger
    @Environment(\.sidebarNavigationReselectGenerations) private var sidebarNavigationReselectGenerations
    @Environment(\.showCommandBar) private var showCommandBar
    @Environment(\.showWhatsNew) private var showWhatsNew
    @Environment(\.usesLegacyMacOS15UI) private var usesLegacyMacOS15UI

    /// Binding to navigation selection for keyboard shortcut control from parent.
    @Binding var navigationSelection: NavigationItem?

    /// Binding to the YouTube (video) experience's navigation selection.
    @Binding var youtubeNavigationSelection: YouTubeNavigationItem?

    /// Monotonic request from the View menu to refresh the active Home feed.
    @Binding var homeRefreshRequestID: Int

    /// Whether startup guest playback cleanup has completed.
    @Binding var didCompleteStartupPlaybackCleanup: Bool

    /// Shared API client used by all views and services.
    let client: any YTMusicClientProtocol

    /// Shared YouTube (video) API client.
    let youtubeClient: any YouTubeClientProtocol

    /// App-wide settings; drives the active content source (music vs. video).
    @State private var settings = SettingsManager.shared

    /// View models for the YouTube experience (persist across source toggles).
    @State private var youtubeStore: YouTubeViewModelStore

    @State private var showLoginSheet = false
    @State private var isCommandBarPresented = false
    /// Window x of the toolbar command field's leading edge, measured once it's placed.
    @State private var commandFieldMinX: CGFloat?
    /// The fullscreen Now Playing overlay; the toolbar's command field hides under it.
    @State private var nowPlayingPresentation = NowPlayingPresentation.shared
    @State private var whatsNewToPresent: PresentedWhatsNew?
    @State private var selectedSidebarPinnedItem: SidebarPinnedItem?
    @State private var contentResetID = UUID()
    @State private var guestRefreshTask: Task<Void, Never>?
    @State private var accountResolutionFailOpenGeneration: UInt64?
    /// Whether authenticated content has been shown for the current signed-in
    /// identity. Distinguishes the first account-scope resolution at startup
    /// (nothing fetched yet) from a real switch away from content that was
    /// already rendered under the unresolved primary scope.
    @State private var hasRenderedAuthenticatedContent = false

    // MARK: - Cached ViewModels (persist across tab switches)

    @State private var homeViewModel: HomeViewModel?
    @State private var exploreViewModel: ExploreViewModel?
    @State private var searchViewModel: SearchViewModel?
    @State private var chartsViewModel: ChartsViewModel?
    @State private var moodsAndGenresViewModel: MoodsAndGenresViewModel?
    @State private var newReleasesViewModel: NewReleasesViewModel?
    @State private var podcastsViewModel: PodcastsViewModel?
    @State private var likedMusicViewModel: PlaylistDetailViewModel?
    @State private var libraryViewModel: LibraryViewModel?
    @State private var historyViewModel: HistoryViewModel?

    /// Navigation path for the Liked Music route.
    @State private var likedMusicNavigationPath = NavigationPath()

    /// Navigation paths for pinned sidebar playlists/albums keyed by content ID.
    @State private var pinnedNavigationPaths: [String: NavigationPath] = [:]

    init(
        navigationSelection: Binding<NavigationItem?>,
        youtubeNavigationSelection: Binding<YouTubeNavigationItem?>,
        homeRefreshRequestID: Binding<Int>,
        didCompleteStartupPlaybackCleanup: Binding<Bool>,
        client: any YTMusicClientProtocol,
        youtubeClient: any YouTubeClientProtocol
    ) {
        self._navigationSelection = navigationSelection
        self._youtubeNavigationSelection = youtubeNavigationSelection
        self._homeRefreshRequestID = homeRefreshRequestID
        self._didCompleteStartupPlaybackCleanup = didCompleteStartupPlaybackCleanup
        self.client = client
        self.youtubeClient = youtubeClient
        _youtubeStore = State(initialValue: YouTubeViewModelStore(client: youtubeClient))
        _homeViewModel = State(initialValue: HomeViewModel(client: client))
        _exploreViewModel = State(initialValue: ExploreViewModel(client: client))
        _searchViewModel = State(initialValue: SearchViewModel(client: client))
        _chartsViewModel = State(initialValue: ChartsViewModel(client: client))
        _moodsAndGenresViewModel = State(initialValue: MoodsAndGenresViewModel(client: client))
        _newReleasesViewModel = State(initialValue: NewReleasesViewModel(client: client))
        _podcastsViewModel = State(initialValue: PodcastsViewModel(client: client))
        _likedMusicViewModel = State(
            initialValue: PlaylistDetailViewModel(
                playlist: LikedMusicPlaylist.playlist,
                client: client
            )
        )
        _libraryViewModel = State(initialValue: LibraryViewModel(client: client))
        _historyViewModel = State(initialValue: HistoryViewModel(client: client))
    }

    /// Access to the app delegate for persistent WebView.
    private var appDelegate: AppDelegate? {
        NSApplication.shared.delegate as? AppDelegate
    }

    var body: some View {
        self.accountLifecycleContent
            .task {
                NowPlayingManager.shared.configure(playerService: self.playerService)
            }
            .task(id: self.accountService.currentAccount?.id) {
                // Keep PodcastsViewModel in sync with the active account so
                // 404 / empty results are recorded against the right account.
                let accountId = self.accountService.currentAccount?.id
                if let accountId {
                    self.podcastsAvailability.activateAccount(accountId)
                }
                self.podcastsViewModel?.configure(
                    availabilityService: self.podcastsAvailability,
                    accountId: accountId
                )
            }
            .task(id: self.podcastsProbeTaskID) {
                // Probe podcasts availability in the background when the
                // initial account resolves for an authenticated session.
                guard self.podcastsProbeTaskID != nil else { return }
                // Brief delay so post-login cookies have a chance to settle
                // into the data store the API client reads from. This does not
                // block content rendering.
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                await self.podcastsAvailability.probe(
                    for: self.accountService.currentAccount?.id,
                    using: self.client
                )
            }
            .task(id: self.accountResolutionGateTaskID) {
                self.accountResolutionFailOpenGeneration = nil
                guard let authGeneration = self.accountResolutionGateTaskID else { return }

                do {
                    try await Task.sleep(for: Self.accountResolutionGateTimeout)
                } catch {
                    return
                }
                guard self.accountResolutionGateTaskID == authGeneration else { return }
                self.accountResolutionFailOpenGeneration = authGeneration
            }
            .onChange(of: self.likeStatusManager.lastLikeEventBatch) { _, batch in
                guard let batch, batch.accountID == self.likeStatusManager.activeAccountID else { return }
                for event in batch.events {
                    // Global sync 1: keep PlayerService.currentTrackLikeStatus in sync
                    if let currentVideoId = self.playerService.currentTrack?.videoId,
                       event.videoId == currentVideoId
                    {
                        self.playerService.currentTrackLikeStatus = event.status
                    }

                    // Global sync 2: keep Liked Music list in sync when the active
                    // Liked Music detail view is not already forwarding this event.
                    if self.navigationSelection != .likedMusic {
                        self.likedMusicViewModel?.handleLikeStatusChange(event)
                    }
                }
            }
            .onChange(of: self.appIntentsLibrary, initial: true) { _, library in
                guard let library else { return }
                AppIntentsBridge.shared.updateLibrary(library)
            }
            .onChange(of: self.libraryViewModel?.currentAccountScopeGeneration) { oldGeneration, _ in
                // An account switch empties the Library, possibly mid-load. Drop the previous
                // account's snapshot now rather than when the new account's Library loads.
                guard oldGeneration != nil else { return }
                AppIntentsBridge.shared.updateLibrary(.empty)
            }
    }

    /// The Library as Shortcuts, Siri, and Spotlight should see it: empty when no personal
    /// account is signed in, and nil (keep the last snapshot) while it is still loading.
    private var appIntentsLibrary: AppIntentsLibrary? {
        guard !self.authService.state.isInitializing else { return nil }
        guard self.authService.hasPersonalAccount else { return .empty }
        guard let libraryViewModel = self.libraryViewModel, libraryViewModel.loadingState == .loaded else {
            return nil
        }
        return AppIntentsLibrary(playlists: libraryViewModel.playlists, albums: libraryViewModel.albums)
    }

    private var windowChrome: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if self.authService.isCookieRestoreUnavailable {
                    SignInRequiredView(
                        title: String(localized: "Sign-In Temporarily Unavailable"),
                        message: String(localized: "Tune could not read saved sign-in data. Retry to restore your session.")
                    )
                } else if self.authService.state.isInitializing {
                    // Show loading while checking login status to avoid guest-content flash
                    self.initializingView
                } else if self.authService.hasPersonalAccount {
                    if self.canRenderAuthenticatedContent {
                        self.mainContent
                            .onAppear { self.hasRenderedAuthenticatedContent = true }
                    } else {
                        // Give the initial account fetch a bounded chance to restore
                        // the selected primary or brand account before requests start.
                        self.initializingView
                    }
                } else if self.didCompleteStartupPlaybackCleanup {
                    // Guest mode: public browsing/search/playback remains available
                    // without login. Personal routes render sign-in prompts below.
                    self.mainContent
                } else {
                    // Hold restored account playback/queue metadata out of the
                    // guest shell until startup cleanup has finished.
                    self.initializingView
                }
            }
            .onAppear {
                DiagnosticsLogger.app.info("MainWindow: UI appeared")
            }

            // Persistent WebView - eager once logged in, and mounted on demand for guest playback.
            // Uses a SINGLETON WebView instance that persists for the app lifetime.
            // Keep it as a hidden 1×1 anchor for audio playback; do not reveal a mini overlay.
            // Keep authenticated Home available while restoration defers watch loading.
            // Let the video or mini-player window, or fullscreen Now Playing's video slot,
            // own the WebView while visible.
            if !self.authService.isCookieRestoreUnavailable,
               !self.playerService.shouldHostPlaybackInMiniPlayer,
               Self.shouldMountPersistentPlayer(
                   isLoggedIn: self.authService.state.isLoggedIn,
                   pendingVideoId: self.playerService.pendingPlayVideoId,
                   isPendingRestoredLoadDeferred: self.playerService.isPendingRestoredLoadDeferred,
                   showVideo: self.playerService.showVideo,
                   showsNowPlayingVideo: self.playerService.isNowPlayingVideoVisible
               )
            {
                PersistentPlayerView(videoId: self.playerService.pendingPlayVideoId, isExpanded: false)
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
            }
        }
        // Tune: fullscreen Now Playing (toggled from the status line, ⇧⌘F).
        .tuneNowPlayingOverlay()
        .background { self.searchShortcutAlias }
        .sheet(isPresented: self.$showLoginSheet) {
            LoginSheet()
        }
        .sheet(item: self.$whatsNewToPresent) { presentedWhatsNew in
            WhatsNewView(whatsNew: presentedWhatsNew.whatsNew) {
                self.dismissWhatsNew(presentedWhatsNew)
            }
        }
        .overlay {
            // Command bar overlay - dismisses when clicking outside
            if self.supportsCommandBarUI, self.isCommandBarPresented {
                ZStack {
                    // Background tap area to dismiss
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .accessibilityIdentifier(AccessibilityID.MainWindow.commandBarOverlay)
                        .onTapGesture {
                            self.isCommandBarPresented = false
                        }

                    VStack(spacing: 0) {
                        self.commandBar
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, MainWindowLayout.aiTaskSurfaceTopPadding)
                }
                .animation(.easeInOut(duration: 0.15), value: self.isCommandBarPresented)
            }
        }
        .overlay(alignment: .top) {
            // Error toast for account switching failures
            AccountErrorToast()
                .padding(.top, 60)
        }
        .frame(minWidth: MainWindowLayout.minimumWidth, minHeight: MainWindowLayout.minimumHeight)
    }

    private var podcastsProbeTaskID: PodcastsProbeTaskID? {
        guard self.authService.hasPersonalAccount,
              self.accountService.didCompleteAccountResolution
        else { return nil }
        return PodcastsProbeTaskID(
            authGeneration: self.authService.accountIdentityGeneration,
            accountID: self.accountService.currentAccount?.id ?? "primary"
        )
    }

    private var accountResolutionGateTaskID: UInt64? {
        guard self.authService.hasPersonalAccount,
              !self.accountService.didCompleteAccountResolution
        else { return nil }
        return self.authService.accountIdentityGeneration
    }

    private var canRenderAuthenticatedContent: Bool {
        UITestConfig.isUITestMode
            || self.accountService.didCompleteAccountResolution
            || self.accountResolutionFailOpenGeneration == self.authService.accountIdentityGeneration
    }

    private var appLifecycleContent: some View {
        self.windowChrome
            .onChange(of: self.showCommandBar.wrappedValue) { _, newValue in
                if newValue {
                    self.presentCommandBarIfAvailable()
                    self.showCommandBar.wrappedValue = false
                }
            }
            .onChange(of: self.homeRefreshRequestID) { _, _ in
                Task { await self.refreshActiveHome() }
            }
            .onChange(of: self.usesLegacyMacOS15UI) { _, usesLegacyUI in
                if usesLegacyUI {
                    self.isCommandBarPresented = false
                    self.showCommandBar.wrappedValue = false
                }
            }
            .onChange(of: self.showWhatsNew.wrappedValue) { _, newValue in
                if newValue {
                    // Manual trigger from Help menu — fetch exact-version release notes, bypass version store
                    Task { @MainActor in
                        await self.presentCurrentWhatsNew(respectingPresentedVersions: false)
                    }
                    self.showWhatsNew.wrappedValue = false
                }
            }
            .modifier(PinnedNavigationPathLifecycleModifier(
                navigationSelection: self.$navigationSelection,
                selectedPinnedItem: self.$selectedSidebarPinnedItem,
                navigationPaths: self.$pinnedNavigationPaths,
                committedRemovalGenerations: self.sidebarPinnedItemsManager.committedRemovalGenerations
            ))
            .onChange(of: self.authService.state) { oldState, newState in
                self.handleAuthStateChange(oldState: oldState, newState: newState)
            }
            .onChange(of: self.authService.isGuestModeEnabled) { _, isGuestModeEnabled in
                self.handleGuestModeChange(isGuestModeEnabled: isGuestModeEnabled)
            }
            .onChange(of: self.authService.needsReauth) { _, needsReauth in
                if needsReauth {
                    self.showLoginSheet = true
                }
            }
            .onChange(of: self.authService.loginCleanupRequired) { _, cleanupRequired in
                guard cleanupRequired else { return }
                self.playerService.reloadCurrentTrackForAuthDataStoreChange(usesCookieFreeDataStore: true)
                self.youtubePlayerService.reloadCurrentVideoForAuthDataStoreChange(usesCookieFreeDataStore: true)
            }
            .onChange(of: self.playerService.showVideo) { _, showVideo in
                DiagnosticsLogger.player.debug("showVideo onChange triggered: \(showVideo)")
                if showVideo {
                    VideoWindowController.shared.show(
                        playerService: self.playerService,
                        webKitManager: self.webKitManager,
                        authService: self.authService
                    )
                } else {
                    VideoWindowController.shared.close()
                }
            }
    }

    private var accountLifecycleContent: some View {
        self.appLifecycleContent
            .onChange(of: self.accountService.currentAccountScopeID) { oldAccountScope, newAccountScope in
                self.handleAccountScopeChange(oldAccountScope: oldAccountScope, newAccountScope: newAccountScope)
            }
            .onChange(of: self.accountService.verifiedIdentitySequence) { _, _ in
                // Re-point in-flight playback ONLY once the new session identity is
                // verified (DATASYNC_ID confirmed). Driving this off the verified
                // signal — rather than `currentAccount?.id` — avoids reloading the
                // player under an unverified/primary identity on cold-launch brand
                // restore, where `currentAccount` is set before its session pin lands.
                // History is recorded by the playback WebViews' own stats pings, so a
                // track/video still loaded under the previous identity must reload to
                // record to the new account. The shared cookie session covers both.
                guard let verifiedAccountId = self.accountService.verifiedAccountId else { return }
                // Re-verifying the account already in use (every launch re-pins it) keeps
                // the like scope: an account switch already invalidated like state through
                // the account-scope change, and other content loaded before verification
                // is kept too. Bumping it here only made Liked Music drop its pages mid-scroll.
                let isReverification = self.accountService.currentAccount?.id == verifiedAccountId
                self.playerService.reloadCurrentTrackForIdentitySwitch(invalidatesLikeSession: !isReverification)
                if self.youtubePlayerService.currentVideo != nil {
                    self.youtubePlayerService.reloadCurrentVideoForIdentitySwitch()
                }
            }
            .onChange(of: self.podcastsAvailability.availability) { oldValue, newValue in
                // If the user is sitting on the Podcasts tab when it flips
                // unavailable, redirect to Home so they don't end up on a
                // sidebar row that no longer exists.
                if newValue == .unavailable, self.navigationSelection == .podcasts {
                    self.navigationSelection = .home
                }

                // Switching back from an unavailable account keeps the
                // Podcasts VM reset/idle until the probe confirms the new
                // account is available. Eagerly refresh then so the tab does
                // not remain on the prior account's loaded-empty state.
                if oldValue == .unavailable, newValue == .available {
                    Task { @MainActor in
                        await self.podcastsViewModel?.refresh()
                    }
                }
            }
    }

    // MARK: - Main Content

    private func handleAccountScopeChange(oldAccountScope: String?, newAccountScope: String?) {
        let currentAccount = self.accountService.currentAccount
        let newAccountId = self.accountService.currentAccount?.id
        // The first resolution after startup/login goes `nil -> scope` before
        // any authenticated view has rendered, so nothing was fetched under a
        // wrong scope: wire the scope up below but skip the switch teardown
        // (cache wipe + refresh of every surface), which otherwise reloads
        // Home right after its initial page and discards its continuation.
        // Content rendered under the unresolved scope (fail-open timeout, or a
        // retried account fetch) is a real switch and still refreshes.
        let isInitialScopeResolution = oldAccountScope == nil
            && newAccountScope != nil
            && !self.hasRenderedAuthenticatedContent
        if !isInitialScopeResolution {
            self.client.resetSessionStateForAccountSwitch()
            self.youtubeClient.resetSessionStateForAccountSwitch()
            self.likeStatusManager.clearCache()
            LibraryMutationActions.cancelAllPendingLibraryMutations()
        }
        self.libraryViewModel?.activateAccountScope(
            newAccountScope,
            isPrimary: currentAccount?.isPrimary == true
        )
        self.playerService.resetTrackStatus()
        self.searchViewModel?.clear()
        self.podcastsViewModel?.configure(
            availabilityService: self.podcastsAvailability,
            accountId: newAccountId
        )
        if let newAccountId {
            self.podcastsAvailability.activateAccount(newAccountId)
        }
        Task { @MainActor in
            if isInitialScopeResolution {
                guard self.authService.hasPersonalAccount,
                      self.accountService.currentAccountScopeID == newAccountScope
                else { return }

                // These models also supply like and Library status to other views.
                // Seed them without restarting Home or an already-visible tab.
                async let likedMusicLoad: Void? = self.likedMusicViewModel?.ensureLoaded()
                if let libraryViewModel = self.libraryViewModel,
                   libraryViewModel.loadingState == .idle
                {
                    await libraryViewModel.load()
                }
                _ = await likedMusicLoad
                return
            }

            APICache.shared.invalidateAll()
            URLCache.shared.removeAllCachedResponses()

            guard newAccountId != nil else { return }

            self.historyViewModel?.reset()
            // YouTube surfaces are account-scoped too.
            self.youtubeStore.resetForAccountChange()

            // Brand accounts can have a different region than the
            // primary. Re-probe in the background so the sidebar
            // reflects the new account. The sidebar may briefly show
            // the prior account's tab state until the probe lands.
            DiagnosticsLogger.auth.info("Account switched, refreshing content and current track metadata...")

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await self.refreshAllContent()
                }

                if let currentVideoId = self.playerService.currentTrack?.videoId {
                    group.addTask {
                        await self.playerService.fetchSongMetadata(videoId: currentVideoId)
                    }
                }
            }
        }
    }

    private func refreshActiveHome() async {
        switch self.settings.appSource {
        case .music:
            guard self.navigationSelection == .home, let homeViewModel else { return }
            await homeViewModel.refresh()
        case .video:
            guard self.youtubeNavigationSelection == .home else { return }
            await self.youtubeStore.home.refresh()
        }
    }

    /// C2 shell (docs/fork/design/c2): a flat 220-point sidebar column and the content column
    /// side by side, with the player status line running the full window width beneath both.
    /// No `NavigationSplitView`: its floating Liquid Glass sidebar can't be made flat.
    private var mainContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                self.sidebarColumn

                ZStack(alignment: .trailing) {
                    self.detailColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Right sidebar overlay - either lyrics or queue (mutually exclusive)
                    self.rightSidebarOverlay(client: self.client)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(TuneHardScrollEdgeModifier())
                .overlay(alignment: .topLeading) {
                    TuneCrumb(title: self.crumbTitle)
                }
            }
            .id(self.contentResetID)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if self.settings.appSource == .music {
                PlayerBarStatusLine()
            }
        }
        .background(TuneTheme.Palette.background.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.25), value: self.playerService.showLyrics)
        .animation(.easeInOut(duration: 0.25), value: self.playerService.showQueue)
        .frame(minWidth: MainWindowLayout.minimumWidth, minHeight: MainWindowLayout.minimumHeight)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            // The toolbar draws above window content, so the overlay can't cover the field:
            // drop it while Now Playing is up (the traffic lights stay).
            if self.settings.appSource == .music, !self.nowPlayingPresentation.isPresented {
                TuneCommandFieldToolbarItem {
                    self.commandField
                }
            }
        }
    }

    /// Section name for the C2 top-bar crumb. Replaces the toolbar title removed above, so the
    /// page name stays visible (and in the accessibility tree) without system title chrome.
    private var crumbTitle: String? {
        switch self.settings.appSource {
        case .music:
            self.selectedSidebarPinnedItem?.title ?? self.navigationSelection?.displayName
        case .video:
            self.youtubeNavigationSelection?.displayName
        }
    }

    /// Sidebar for the active source on the flat `panel` surface, with a hairline on its right.
    private var sidebarColumn: some View {
        Group {
            if self.settings.appSource == .music {
                Sidebar(
                    selection: self.$navigationSelection,
                    pinnedSelection: self.$selectedSidebarPinnedItem,
                    client: self.client,
                    libraryViewModel: self.libraryViewModel,
                    onReselectNavigationItem: { item in
                        self.sidebarNavigationReselectGenerations.wrappedValue[item, default: 0] += 1
                        if item == .search {
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(100))
                                self.searchFocusTrigger.wrappedValue = true
                            }
                        }
                    },
                    onReselectPinnedItem: { item in
                        guard !(self.pinnedNavigationPaths[item.contentId]?.isEmpty ?? true) else { return }
                        self.pinnedNavigationPaths[item.contentId] = NavigationPath()
                    }
                )
            } else {
                YouTubeSidebar(
                    selection: self.$youtubeNavigationSelection,
                    onReselect: { _ in
                        self.youtubeStore.navigationPath = NavigationPath()
                    }
                )
            }
        }
        .frame(width: TuneTheme.Spacing.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(TuneTheme.Palette.panel.ignoresSafeArea(edges: .top))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(TuneTheme.Palette.hairline)
                .frame(width: 1)
                .ignoresSafeArea(edges: .top)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if self.settings.appSource == .music {
            self.detailView(
                for: self.navigationSelection,
                pinnedItem: self.selectedSidebarPinnedItem,
                client: self.client
            )
        } else {
            YouTubeContentView(
                selection: self.youtubeNavigationSelection,
                store: self.youtubeStore
            )
        }
    }

    /// C2 `.cmd`: the "Search ⌘K" field, styled as a quiet rounded field rather than a toolbar
    /// button. It opens the Search page with its field focused — the same destination, hint,
    /// and shortcut as the sidebar's Search row (⌘K, menu-owned; ⌘F is an alias). The toolbar
    /// places it right after the traffic lights, so it sizes itself to end before the sidebar
    /// divider (`TuneCommandFieldMetrics`) and truncates the placeholder instead of spilling
    /// into the content column.
    private var commandField: some View {
        Button {
            self.activateSearch()
        } label: {
            HStack(spacing: 8) {
                Text(String(localized: "Search"))
                    .font(TuneTheme.Typeface.body)
                    .foregroundStyle(TuneTheme.Palette.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(verbatim: "⌘K")
                    .font(TuneTheme.Typeface.data)
                    .foregroundStyle(TuneTheme.Palette.inkDim)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(width: self.commandFieldWidth, height: 26)
            .background(
                RoundedRectangle(cornerRadius: TuneTheme.Radius.control, style: .continuous)
                    .fill(TuneTheme.Palette.raised.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: TuneTheme.Radius.control, style: .continuous)
                    .strokeBorder(TuneTheme.Palette.hairline, lineWidth: 1)
            )
            .contentShape(.rect(cornerRadius: TuneTheme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            WindowMinXReader { minX in
                guard self.commandFieldMinX != minX else { return }
                self.commandFieldMinX = minX
            }
        )
        .help(Self.searchHelp)
        .accessibilityLabel(Self.searchHelp)
        .accessibilityIdentifier(AccessibilityID.MainWindow.aiButton)
    }

    private static var searchHelp: String {
        "\(String(localized: "Search")) (⌘K)"
    }

    /// ⌘F: an alias of the menu's Search command (⌘K). Zero-size and invisible, so it only
    /// contributes the key equivalent.
    private var searchShortcutAlias: some View {
        Button {
            self.activateSearch()
        } label: {
            EmptyView()
        }
        .buttonStyle(.plain)
        .keyboardShortcut("f", modifiers: .command)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// Search from the toolbar field or ⌘F: over fullscreen Now Playing, focus its search
    /// field; otherwise open the active source's Search page with the field focused.
    private func activateSearch() {
        if NowPlayingPresentation.shared.isPresented {
            NowPlayingPresentation.shared.requestSearchFocus()
            return
        }
        if self.settings.appSource == .video {
            self.youtubeNavigationSelection = .search
            return
        }
        let alreadyOnSearch = self.navigationSelection == .search && self.selectedSidebarPinnedItem == nil
        self.selectedSidebarPinnedItem = nil
        self.navigationSelection = .search
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            if alreadyOnSearch {
                self.sidebarNavigationReselectGenerations.wrappedValue[.search, default: 0] += 1
            }
            self.searchFocusTrigger.wrappedValue = true
        }
    }

    private var commandFieldWidth: CGFloat {
        TuneCommandFieldMetrics.width(
            fieldMinX: self.commandFieldMinX,
            sidebarWidth: TuneTheme.Spacing.sidebarWidth
        )
    }

    private func presentCommandBarIfAvailable() {
        if NowPlayingPresentation.shared.isPresented {
            // ⌘K over fullscreen Now Playing focuses its own search field; the command bar
            // would open hidden underneath.
            NowPlayingPresentation.shared.requestSearchFocus()
            return
        }
        guard self.supportsCommandBarUI else { return }
        self.isCommandBarPresented = true
    }

    private var supportsCommandBarUI: Bool {
        // The command bar is a music/AI feature; it has no role in the
        // YouTube experience, so the sparkle button hides there.
        PlatformCapabilities.supportsCommandBar(usesLegacyMacOS15UI: self.usesLegacyMacOS15UI)
            && self.settings.appSource == .music
            && self.hasPersonalAccount
    }

    /// Right sidebar overlay showing either lyrics or queue as glass panels (mutually exclusive).
    @ViewBuilder
    private func rightSidebarOverlay(client: any YTMusicClientProtocol) -> some View {
        let showRightSidebar = self.playerService.showLyrics || self.playerService.showQueue

        if showRightSidebar {
            VStack {
                Spacer()

                Group {
                    if self.playerService.showLyrics {
                        if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
                            LyricsView(client: client)
                        } else {
                            SimpleLyricsView(client: client)
                        }
                    } else if self.playerService.showQueue {
                        if self.playerService.queueDisplayMode == .sidepanel {
                            QueueSidePanelView()
                        } else {
                            QueueView()
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .padding(.top, 12)
                // The status line sits below this column, so only a gutter is needed.
                .padding(.bottom, 12)
                .transition(.move(edge: .trailing).combined(with: .opacity))

                Spacer()
            }
            .padding(.trailing, 16)
        }
    }

    private func detailView(
        for item: NavigationItem?,
        pinnedItem: SidebarPinnedItem?,
        client: any YTMusicClientProtocol
    ) -> some View {
        Group {
            if let pinnedItem {
                self.viewForSidebarPinnedItem(pinnedItem, client: client)
            } else if let item {
                self.viewForNavigationItem(item)
            } else {
                Text("Select an item from the sidebar", comment: "Placeholder shown when no sidebar item is selected")
                    .font(TuneTheme.Typeface.body)
                    .foregroundStyle(TuneTheme.Palette.inkMuted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var commandBar: some View {
        if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
            CommandBarView(
                client: self.client,
                playerService: self.playerService,
                isPresented: self.$isCommandBarPresented,
                navigationSelection: self.$navigationSelection,
                searchFocusTrigger: self.searchFocusTrigger,
                sidebarNavigationReselectGenerations: self.sidebarNavigationReselectGenerations,
                searchViewModel: self.searchViewModel
            )
        }
    }

    /// Returns the view for a specific navigation item.
    private func viewForNavigationItem(_ item: NavigationItem) -> some View { // swiftlint:disable:this cyclomatic_complexity
        Group {
            switch item {
            case .home:
                if let vm = homeViewModel {
                    HomeView(viewModel: vm)
                }
            case .explore:
                if let vm = exploreViewModel {
                    ExploreView(viewModel: vm)
                }
            case .search:
                if let vm = searchViewModel {
                    SearchView(viewModel: vm, focusTrigger: self.searchFocusTrigger)
                }
            case .charts:
                if let vm = chartsViewModel {
                    ChartsView(viewModel: vm)
                }
            case .moodsAndGenres:
                if let vm = moodsAndGenresViewModel {
                    MoodsAndGenresView(viewModel: vm)
                }
            case .newReleases:
                if let vm = newReleasesViewModel {
                    NewReleasesView(viewModel: vm)
                }
            case .podcasts:
                if let vm = podcastsViewModel {
                    PodcastsView(viewModel: vm)
                }
            case .likedMusic:
                if self.requiresSignIn(item) {
                    self.signInRequiredView(for: item)
                } else if let vm = likedMusicViewModel {
                    NavigationStack(path: self.$likedMusicNavigationPath) {
                        Group {
                            if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
                                PlaylistDetailView(playlist: LikedMusicPlaylist.playlist, viewModel: vm)
                                    .environment(\.libraryViewModel, self.libraryViewModel)
                            } else {
                                SimplePlaylistDetailView(playlist: LikedMusicPlaylist.playlist, viewModel: vm)
                                    .environment(\.libraryViewModel, self.libraryViewModel)
                            }
                        }
                        .navigationDestinations(client: self.client)
                    }
                    .playerBarMusicNavigation(path: self.$likedMusicNavigationPath)
                    .popsNavigationStackOnSidebarReselect(
                        path: self.$likedMusicNavigationPath,
                        for: .likedMusic
                    )
                }
            case .library:
                if self.requiresSignIn(item) {
                    self.signInRequiredView(for: item)
                } else if let vm = libraryViewModel {
                    LibraryView(viewModel: vm)
                }
            case .history:
                if self.requiresSignIn(item) {
                    self.signInRequiredView(for: item)
                } else if let vm = historyViewModel {
                    HistoryView(viewModel: vm)
                }
            }
        }
        .environment(\.libraryViewModel, self.libraryViewModel)
    }

    private var hasPersonalAccount: Bool {
        self.authService.hasPersonalAccount
    }

    private func requiresSignIn(_ item: NavigationItem) -> Bool {
        item.requiresSignIn && !self.hasPersonalAccount
    }

    private func signInRequiredView(for item: NavigationItem) -> some View {
        SignInRequiredView(
            title: String(localized: "Sign in to use \(item.displayName)"),
            message: String(localized: "Tune works without login for public browsing, search, and playback. Sign in to access personal music collections.")
        )
    }

    private func viewForSidebarPinnedItem(
        _ item: SidebarPinnedItem,
        client: any YTMusicClientProtocol
    ) -> some View {
        let path = Binding(
            get: { self.pinnedNavigationPaths[item.contentId, default: NavigationPath()] },
            set: { self.pinnedNavigationPaths[item.contentId] = $0 }
        )
        return NavigationStack(path: path) {
            Group {
                if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
                    PlaylistDetailView(
                        playlist: item.playlistRoute,
                        viewModel: PlaylistDetailViewModel(
                            playlist: item.playlistRoute,
                            client: client
                        )
                    )
                    .environment(\.libraryViewModel, self.libraryViewModel)
                } else {
                    SimplePlaylistDetailView(
                        playlist: item.playlistRoute,
                        viewModel: PlaylistDetailViewModel(
                            playlist: item.playlistRoute,
                            client: client
                        )
                    )
                    .environment(\.libraryViewModel, self.libraryViewModel)
                }
            }
            .id(item.contentId)
            .navigationDestinations(client: client)
        }
        .playerBarMusicNavigation(path: path)
        .environment(\.libraryViewModel, self.libraryViewModel)
        .environment(\.onPlaylistDeleted) {
            self.selectedSidebarPinnedItem = nil
            self.navigationSelection = .home
        }
    }

    /// View shown while checking initial login status.
    private var initializingView: some View {
        VStack(spacing: 16) {
            CassetteIcon(size: 60)
                .foregroundStyle(TuneTheme.Palette.inkDim)
            ProgressView()
                .controlSize(.regular)
                .frame(width: 20, height: 20)
        }
        .frame(minWidth: MainWindowLayout.minimumWidth, minHeight: MainWindowLayout.minimumHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TuneTheme.Palette.background.ignoresSafeArea())
    }

    private func handleAuthStateChange(oldState: AuthService.State, newState: AuthService.State) {
        self.accountService.authenticationIdentityDidChange()
        switch newState {
        case .initializing:
            // Still checking login status, do nothing
            break
        case .loggedOut:
            self.hasRenderedAuthenticatedContent = false
            let isReauthTransition = self.authService.needsReauth
            let crossedSignOutBoundary = oldState.isLoggedIn && !isReauthTransition
            let shouldRefreshGuestContent = crossedSignOutBoundary || oldState.isInitializing || isReauthTransition
            if crossedSignOutBoundary {
                self.playerService.clearPlaybackForSignOut()
                self.youtubePlayerService.stop()
            }
            if shouldRefreshGuestContent {
                self.client.resetSessionStateForAccountSwitch()
                self.youtubeClient.resetSessionStateForAccountSwitch()
                self.rebuildMusicViewModels()
                self.youtubeStore.resetForAccountChange()
                // Reset podcasts availability so the next sign-in re-probes
                // the endpoint.
                self.podcastsAvailability.reset()
            }
            if !isReauthTransition {
                self.normalizeGuestSelections()
                self.accountService.clearAccounts()
            }
            if shouldRefreshGuestContent {
                self.scheduleGuestContentRefresh()
            }
        case .loggingIn:
            self.showLoginSheet = true
        case .loggedIn:
            self.guestRefreshTask?.cancel()
            self.guestRefreshTask = nil
            let shouldRefreshAuthenticatedContent = oldState == .loggingIn || oldState == .loggedOut
            if shouldRefreshAuthenticatedContent {
                // Replace any mounted guest/expired models so in-flight responses
                // cannot populate the authenticated shell after login or reauth.
                self.client.resetSessionStateForAccountSwitch()
                self.youtubeClient.resetSessionStateForAccountSwitch()
                self.rebuildMusicViewModels(accountId: self.accountService.currentAccount?.id)
                self.youtubeStore.resetForAccountChange()
                self.playerService.reloadCurrentTrackForAuthDataStoreChange(usesCookieFreeDataStore: false)
                self.youtubePlayerService.reloadCurrentVideoForAuthDataStoreChange(usesCookieFreeDataStore: false)
            }
            self.showLoginSheet = false
            // Auto-present "What's New" — fetch from GitHub release notes
            if self.whatsNewToPresent == nil {
                Task { @MainActor in
                    await self.presentCurrentWhatsNew()
                }
            }
            // KasetApp's state-keyed root task owns account loading for every
            // authenticated transition, after startup playback cleanup.
            // If we just completed login/reauth, refresh content. This handles
            // the case where cookies were unavailable during initial load and
            // preserved views that may currently hold auth-expired state.
            if shouldRefreshAuthenticatedContent {
                let authGeneration = self.authService.accountIdentityGeneration
                Task {
                    guard await self.waitForAuthenticatedRefreshReadiness(
                        authGeneration: authGeneration
                    ) else { return }
                    await self.refreshAuthenticatedContent()
                }
            }
        }
    }

    private func waitForAuthenticatedRefreshReadiness(authGeneration: UInt64) async -> Bool {
        let clock = ContinuousClock()
        let accountResolutionDeadline = clock.now + Self.accountResolutionGateTimeout

        do {
            // Keep the existing post-login cookie propagation delay.
            try await Task.sleep(for: .milliseconds(500))
            while !self.accountService.didCompleteAccountResolution,
                  clock.now < accountResolutionDeadline
            {
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            return false
        }

        return !Task.isCancelled
            && self.authService.hasPersonalAccount
            && self.authService.accountIdentityGeneration == authGeneration
    }

    private func handleGuestModeChange(isGuestModeEnabled: Bool) {
        guard self.authService.state.isLoggedIn else { return }
        self.guestRefreshTask?.cancel()
        self.guestRefreshTask = nil
        self.youtubeStore.resetForAccountChange()
        self.podcastsAvailability.reset()

        if isGuestModeEnabled {
            self.client.resetSessionStateForAccountSwitch()
            self.youtubeClient.resetSessionStateForAccountSwitch()
            self.rebuildMusicViewModels()
            self.playerService.clearPlaybackForGuestStartup()
            self.youtubePlayerService.stop()
            self.normalizeGuestSelections()
            self.scheduleGuestContentRefresh()
        } else {
            self.client.resetSessionStateForAccountSwitch()
            self.youtubeClient.resetSessionStateForAccountSwitch()
            self.rebuildMusicViewModels(accountId: self.accountService.currentAccount?.id)
            self.playerService.reloadCurrentTrackForAuthDataStoreChange(usesCookieFreeDataStore: false)
            self.youtubePlayerService.reloadCurrentVideoForAuthDataStoreChange(usesCookieFreeDataStore: false)
            Task { @MainActor in
                await self.accountService.fetchAccounts()
                await self.refreshAuthenticatedContent()
            }
        }
    }

    private func rebuildMusicViewModels(accountId: String? = nil) {
        LibraryMutationActions.cancelAllPendingLibraryMutations()
        self.homeViewModel = HomeViewModel(client: self.client)
        self.exploreViewModel = ExploreViewModel(client: self.client)
        self.searchViewModel = SearchViewModel(client: self.client)
        self.chartsViewModel = ChartsViewModel(client: self.client)
        self.moodsAndGenresViewModel = MoodsAndGenresViewModel(client: self.client)
        self.newReleasesViewModel = NewReleasesViewModel(client: self.client)
        let podcastsViewModel = PodcastsViewModel(client: self.client)
        podcastsViewModel.configure(availabilityService: self.podcastsAvailability, accountId: accountId)
        self.podcastsViewModel = podcastsViewModel
        self.likedMusicViewModel = PlaylistDetailViewModel(
            playlist: LikedMusicPlaylist.playlist,
            client: self.client
        )
        let libraryViewModel = LibraryViewModel(client: self.client)
        let currentAccount = self.accountService.currentAccount
        libraryViewModel.activateAccountScope(
            self.accountService.currentAccountScopeID,
            isPrimary: currentAccount?.isPrimary == true
        )
        self.libraryViewModel = libraryViewModel
        self.historyViewModel = HistoryViewModel(client: self.client)
        self.likedMusicNavigationPath = NavigationPath()
        self.pinnedNavigationPaths = [:]
        self.contentResetID = UUID()
    }

    private func scheduleGuestContentRefresh() {
        self.guestRefreshTask?.cancel()
        self.guestRefreshTask = Task { @MainActor in
            await self.refreshGuestContent()
            if !Task.isCancelled {
                self.guestRefreshTask = nil
            }
        }
    }

    private func normalizeGuestSelections() {
        if self.navigationSelection?.requiresSignIn == true {
            self.navigationSelection = .home
        }
        if self.youtubeNavigationSelection?.requiresSignIn == true {
            self.youtubeNavigationSelection = .home
        }
        self.selectedSidebarPinnedItem = nil
    }

    private func refreshAuthenticatedContent() async {
        // Parallel initial data fetch for ~40% faster app launch. The podcasts
        // probe is driven separately by the account-keyed task.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.homeViewModel?.refresh() }
            // Explore loads when first visited (its view's `.task`); refreshing it here
            // fetched and kept a page most sessions never open.
            if let exploreViewModel = self.exploreViewModel, exploreViewModel.loadingState != .idle {
                group.addTask { await exploreViewModel.refresh() }
            }
            group.addTask { await self.libraryViewModel?.load() }
        }
    }

    /// Tune builds use their own bundle identifier; upstream Kaset uses com.sertacozercan.*.
    private static var isPersonalForkBuild: Bool {
        Bundle.main.bundleIdentifier?.hasPrefix("com.melvernmogens.") == true
    }

    @MainActor
    private func dismissWhatsNew(_ whatsNew: PresentedWhatsNew) {
        WhatsNewVersionStore().markPresented(whatsNew.requestedVersion)
        self.whatsNewToPresent = nil
    }

    @MainActor
    private func presentCurrentWhatsNew(respectingPresentedVersions: Bool = true) async {
        // Tune (personal fork): upstream Kaset release notes don't describe this build,
        // and fetching them contacts the upstream author's GitHub on every launch.
        guard !Self.isPersonalForkBuild else { return }
        let currentVersion = WhatsNew.Version.current()
        let whatsNew = await WhatsNewProvider.fetchWhatsNew(
            for: currentVersion,
            respectingPresentedVersions: respectingPresentedVersions
        )

        guard let whatsNew else { return }

        self.whatsNewToPresent = PresentedWhatsNew(
            whatsNew: whatsNew,
            requestedVersion: currentVersion
        )
    }

    /// Refreshes only public guest-safe surfaces after sign-out so prior
    /// account-personalized content is not left visible in the guest shell.
    private func refreshGuestContent() async {
        // These view models are main-actor-bound observable UI state. Keep the
        // refresh calls on the main actor instead of spawning task-group child
        // tasks that capture `self` and mutate UI state off actor.
        await self.homeViewModel?.refresh()
        // Browse pages (and the YouTube side) refresh only if they were ever loaded; the
        // rest load on first visit, so sign-out doesn't fetch pages nobody opened.
        if let exploreViewModel = self.exploreViewModel, exploreViewModel.loadingState != .idle {
            await exploreViewModel.refresh()
        }
        if let chartsViewModel = self.chartsViewModel, chartsViewModel.loadingState != .idle {
            await chartsViewModel.refresh()
        }
        if let moodsAndGenresViewModel = self.moodsAndGenresViewModel, moodsAndGenresViewModel.loadingState != .idle {
            await moodsAndGenresViewModel.refresh()
        }
        if let newReleasesViewModel = self.newReleasesViewModel, newReleasesViewModel.loadingState != .idle {
            await newReleasesViewModel.refresh()
        }
        await self.youtubeStore.refreshGuestContent()
        self.podcastsAvailability.activateAccount(nil)
        if self.podcastsAvailability.availability != .unavailable {
            await self.podcastsViewModel?.refresh()
        }
    }

    /// Refreshes all content when switching accounts.
    ///
    /// This method is called when the user switches between their primary account
    /// and brand accounts, ensuring all views display content for the new account.
    private func refreshAllContent() async {
        // Parallel refresh of all content views.
        // The podcasts refresh is gated on the latest availability
        // signal so a brand-account switch into a region without
        // podcasts doesn't fire the spurious 404 the bug is about. The
        // account-keyed task re-evaluates availability separately.
        let podcastsAvailable = self.podcastsAvailability.availability != .unavailable
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.homeViewModel?.refresh() }
            // Browse pages refresh only if they were ever loaded; the rest load on first visit.
            if let exploreViewModel = self.exploreViewModel, exploreViewModel.loadingState != .idle {
                group.addTask { await exploreViewModel.refresh() }
            }
            if let chartsViewModel = self.chartsViewModel, chartsViewModel.loadingState != .idle {
                group.addTask { await chartsViewModel.refresh() }
            }
            if let moodsAndGenresViewModel = self.moodsAndGenresViewModel, moodsAndGenresViewModel.loadingState != .idle {
                group.addTask { await moodsAndGenresViewModel.refresh() }
            }
            if let newReleasesViewModel = self.newReleasesViewModel, newReleasesViewModel.loadingState != .idle {
                group.addTask { await newReleasesViewModel.refresh() }
            }
            if podcastsAvailable {
                group.addTask { await self.podcastsViewModel?.refresh() }
            }
            group.addTask { await self.likedMusicViewModel?.refresh() }
            group.addTask { await self.historyViewModel?.load() }
            group.addTask { await self.libraryViewModel?.refresh() }
        }
    }
}

// MARK: - PinnedNavigationPathLifecycleModifier

private struct PinnedNavigationPathLifecycleModifier: ViewModifier {
    @Binding var navigationSelection: NavigationItem?
    @Binding var selectedPinnedItem: SidebarPinnedItem?
    @Binding var navigationPaths: [String: NavigationPath]
    let committedRemovalGenerations: [String: UInt]

    func body(content: Content) -> some View {
        content
            .onChange(of: self.navigationSelection) { _, newValue in
                if newValue != nil {
                    self.selectedPinnedItem = nil
                }
            }
            .onChange(of: self.selectedPinnedItem?.contentId) { oldContentId, newContentId in
                guard oldContentId != newContentId, let oldContentId else { return }
                self.navigationPaths.removeValue(forKey: oldContentId)
            }
            .onChange(of: self.committedRemovalGenerations) { oldValue, newValue in
                for (contentId, generation) in newValue where oldValue[contentId] != generation {
                    self.navigationPaths.removeValue(forKey: contentId)
                }
            }
    }
}

// MARK: - TuneCrumb

/// C2 `.crumb`: the current section as an 11-point caps label, drawn in the toolbar band above
/// the content column at the content gutter. Non-interactive.
private struct TuneCrumb: View {
    let title: String?

    var body: some View {
        GeometryReader { proxy in
            if let title, !title.isEmpty, proxy.safeAreaInsets.top > 0 {
                Text(title)
                    .font(TuneTheme.Typeface.label)
                    .tracking(0.9)
                    .textCase(.uppercase)
                    .foregroundStyle(TuneTheme.Palette.ink)
                    .lineLimit(1)
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(.isHeader)
                    .frame(height: proxy.safeAreaInsets.top)
                    .padding(.leading, TuneTheme.Spacing.gutter)
            }
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}

// MARK: - TuneCommandFieldMetrics

/// Width of the toolbar command field. The toolbar puts it right after the traffic lights,
/// i.e. over the sidebar, so it ends a little before the sidebar divider whatever the window
/// width; placed in the content column instead, it takes its C2 width.
enum TuneCommandFieldMetrics {
    /// C2 `.cmd` width.
    static let preferredWidth: CGFloat = 300
    /// Narrowest useful field: a few placeholder characters and the ⌘K hint.
    static let minimumWidth: CGFloat = 96
    /// Gap kept between the field's trailing edge and the sidebar divider.
    static let dividerClearance: CGFloat = 12
    /// Leading edge assumed before the first measurement (just past the traffic lights).
    static let assumedMinX: CGFloat = 88

    static func width(fieldMinX: CGFloat?, sidebarWidth: CGFloat) -> CGFloat {
        let minX = fieldMinX.flatMap { $0.isFinite ? $0 : nil } ?? self.assumedMinX
        guard minX < sidebarWidth else { return self.preferredWidth }
        let available = sidebarWidth - self.dividerClearance - max(minX, 0)
        return min(max(available, self.minimumWidth), self.preferredWidth)
    }
}

// MARK: - WindowMinXReader

/// Reports the window x of its own leading edge (toolbar items live outside the SwiftUI
/// content's coordinate space, so a GeometryReader can't place them against the sidebar).
private struct WindowMinXReader: NSViewRepresentable {
    let onChange: @MainActor (CGFloat) -> Void

    func makeNSView(context _: Context) -> MinXReportingView {
        let view = MinXReportingView()
        view.onChange = self.onChange
        return view
    }

    func updateNSView(_ view: MinXReportingView, context _: Context) {
        view.onChange = self.onChange
        view.reportIfNeeded()
    }

    final class MinXReportingView: NSView {
        var onChange: (@MainActor (CGFloat) -> Void)?
        private var lastReported: CGFloat?

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.reportIfNeeded()
        }

        override func layout() {
            super.layout()
            self.reportIfNeeded()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            self.reportIfNeeded()
        }

        func reportIfNeeded() {
            guard self.window != nil else { return }
            let minX = self.convert(self.bounds, to: nil).minX.rounded()
            guard minX.isFinite, minX != self.lastReported else { return }
            self.lastReported = minX
            // Out of the current layout/update pass before touching SwiftUI state.
            Task { @MainActor [weak self] in
                self?.onChange?(minX)
            }
        }
    }
}

// MARK: - TuneCommandFieldToolbarItem

/// Primary-action toolbar slot for the C2 command field, without the macOS 26 shared
/// Liquid Glass capsule behind it.
private struct TuneCommandFieldToolbarItem<Content: View>: ToolbarContent {
    @ViewBuilder var content: () -> Content

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) {
                self.content()
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
                self.content()
            }
        }
    }
}

// MARK: - TuneHardScrollEdgeModifier

/// Replaces the macOS 26 soft (blurred) scroll edge under the toolbar with the hard edge,
/// so content meets a crisp line instead of material blur.
private struct TuneHardScrollEdgeModifier: ViewModifier {
    @Environment(\.usesLegacyMacOS15UI) private var usesLegacyMacOS15UI

    func body(content: Content) -> some View {
        if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
        }
    }
}

// MARK: - NavigationItem

enum NavigationItem: String, Hashable, CaseIterable, Identifiable {
    case home = "Home"
    case explore = "Explore"
    case search = "Search"
    case charts = "Charts"
    case moodsAndGenres = "Moods & Genres"
    case newReleases = "New Releases"
    case podcasts = "Podcasts"
    case likedMusic = "Liked Music"
    case library = "Library"
    case history = "History"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .home:
            String(localized: "Home")
        case .explore:
            String(localized: "Explore")
        case .search:
            String(localized: "Search")
        case .charts:
            String(localized: "Charts")
        case .moodsAndGenres:
            String(localized: "Moods & Genres")
        case .newReleases:
            String(localized: "New Releases")
        case .podcasts:
            String(localized: "Podcasts")
        case .likedMusic:
            String(localized: "Liked Music")
        case .library:
            String(localized: "Library")
        case .history:
            String(localized: "History")
        }
    }

    var icon: String {
        switch self {
        case .home:
            "house"
        case .explore:
            "globe"
        case .search:
            "magnifyingglass"
        case .charts:
            "chart.line.uptrend.xyaxis"
        case .moodsAndGenres:
            "theatermask.and.paintbrush"
        case .newReleases:
            "sparkles"
        case .podcasts:
            "mic.fill"
        case .likedMusic:
            "heart.fill"
        case .library:
            "square.stack.fill"
        case .history:
            "clock.arrow.circlepath"
        }
    }

    var requiresSignIn: Bool {
        switch self {
        case .home, .explore, .search, .charts, .moodsAndGenres, .newReleases, .podcasts:
            false
        case .likedMusic, .library, .history:
            true
        }
    }
}

#Preview {
    @Previewable @State var navSelection: NavigationItem? = .home
    @Previewable @State var youtubeNavSelection: YouTubeNavigationItem? = .home
    @Previewable @State var homeRefreshRequestID = 0
    let authService = AuthService()
    let ytMusicClient = YTMusicClient(authService: authService)
    let accountService = AccountService(ytMusicClient: ytMusicClient, authService: authService)
    MainWindow(
        navigationSelection: $navSelection,
        youtubeNavigationSelection: $youtubeNavSelection,
        homeRefreshRequestID: $homeRefreshRequestID,
        didCompleteStartupPlaybackCleanup: .constant(true),
        client: ytMusicClient,
        youtubeClient: YouTubeClient(authService: authService)
    )
    .environment(authService)
    .environment(PlayerService())
    .environment(WebKitManager.shared)
    .environment(accountService)
}
