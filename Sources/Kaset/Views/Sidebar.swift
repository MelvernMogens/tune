import SwiftUI

/// Sidebar navigation for the main window (C2: docs/fork/design/c2/home.html `.side`).
///
/// Text-only rows grouped under BROWSE / LIBRARY / PINNED / YOUR PLAYLISTS caps labels on the
/// flat `panel` surface. The playlists group lists the signed-in user's library playlists with
/// 20-point square covers and track counts.
struct Sidebar: View {
    private enum SidebarSelection: Hashable {
        case navigation(NavigationItem)
        case pinned(SidebarPinnedItem)
    }

    @Binding var selection: NavigationItem?
    @Binding var pinnedSelection: SidebarPinnedItem?
    let client: any YTMusicClientProtocol
    /// Source of the YOUR PLAYLISTS group. Nil hides the group (previews, guest shells).
    var libraryViewModel: LibraryViewModel?
    /// Playlist currently feeding playback, if known; its row gets the orange now-playing marker.
    var nowPlayingPlaylistID: String?
    var onReselectNavigationItem: ((NavigationItem) -> Void)?
    var onReselectPinnedItem: ((SidebarPinnedItem) -> Void)?
    @Environment(AuthService.self) private var authService
    @Environment(PlayerService.self) private var playerService
    @Environment(SidebarPinnedItemsManager.self) private var sidebarPinnedItemsManager
    @Environment(PodcastsAvailabilityService.self) private var podcastsAvailability
    @State private var isCreatingPlaylist = false
    @State private var isHoveringPlaylistsHeader = false

    var body: some View {
        List {
            KasetSidebarSectionHeader(title: String(localized: "Browse"))

            self.navigationRow(.home, shortcut: "⌘1")
                .accessibilityIdentifier(AccessibilityID.Sidebar.homeItem)

            self.navigationRow(.search, shortcut: "⌘K")
                .accessibilityIdentifier(AccessibilityID.Sidebar.searchItem)

            self.navigationRow(.explore, shortcut: "⌘2")
                .accessibilityIdentifier(AccessibilityID.Sidebar.exploreItem)

            self.navigationRow(.charts)
                .accessibilityIdentifier(AccessibilityID.Sidebar.chartsItem)

            self.navigationRow(.moodsAndGenres)
                .accessibilityIdentifier(AccessibilityID.Sidebar.moodsAndGenresItem)

            self.navigationRow(.newReleases)
                .accessibilityIdentifier(AccessibilityID.Sidebar.newReleasesItem)

            if self.podcastsAvailability.availability != .unavailable {
                self.navigationRow(.podcasts)
                    .accessibilityIdentifier(AccessibilityID.Sidebar.podcastsItem)
            }

            if self.hasPersonalAccount {
                KasetSidebarSectionHeader(title: String(localized: "Library"))
                    .padding(.top, KasetSidebarMetrics.groupGap)

                self.navigationRow(.library, shortcut: "⌘3")
                    .accessibilityIdentifier(AccessibilityID.Sidebar.libraryItem)

                self.navigationRow(.likedMusic)
                    .accessibilityIdentifier(AccessibilityID.Sidebar.likedMusicItem)

                self.navigationRow(.history)
                    .accessibilityIdentifier(AccessibilityID.Sidebar.historyItem)

                if !self.sidebarPinnedItemsManager.items.isEmpty {
                    KasetSidebarSectionHeader(title: String(localized: "Pinned"))
                        .padding(.top, KasetSidebarMetrics.groupGap)

                    ForEach(self.sidebarPinnedItemsManager.items) { item in
                        self.sidebarPinnedRow(item)
                    }
                    .onMove { source, destination in
                        self.sidebarPinnedItemsManager.move(from: source, to: destination)
                    }
                }

                self.playlistsSectionHeader
                    .padding(.top, KasetSidebarMetrics.groupGap)

                ForEach(self.libraryPlaylists) { playlist in
                    self.libraryPlaylistRow(playlist)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .accessibilityIdentifier(AccessibilityID.Sidebar.container)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Account row (shared with YouTubeSidebar).
            SidebarFooterView()
        }
        .background(TuneTheme.Palette.panel)
    }

    private var hasPersonalAccount: Bool {
        self.authService.hasPersonalAccount
    }

    private var currentSidebarSelection: SidebarSelection? {
        if let pinnedSelection {
            return .pinned(pinnedSelection)
        }

        if let selection {
            return .navigation(selection)
        }

        return nil
    }

    // MARK: - Library Playlists

    private var libraryPlaylists: [Playlist] {
        Self.sidebarLibraryPlaylists(
            from: self.libraryViewModel?.playlists ?? [],
            excludingPinned: self.sidebarPinnedItemsManager.items
        )
    }

    /// Library playlists worth a sidebar row: the user's own and saved playlists, minus
    /// account-generated collections that already have a destination (Liked Music, Episodes
    /// for Later, uploads), duplicates, and anything pinned above.
    static func sidebarLibraryPlaylists(
        from playlists: [Playlist],
        excludingPinned pinnedItems: [SidebarPinnedItem]
    ) -> [Playlist] {
        let pinnedKeys = Set(pinnedItems.map { LibraryContentIdentity.playlistKey(for: $0.contentId) })
        var seen = Set<String>()
        return playlists.filter { playlist in
            let key = LibraryContentIdentity.playlistKey(for: playlist.id)
            guard Playlist.supportsLibraryToggle(id: playlist.id),
                  !pinnedKeys.contains(key)
            else { return false }
            return seen.insert(key).inserted
        }
    }

    private func isNowPlaying(contentId: String) -> Bool {
        guard let nowPlayingPlaylistID else { return false }
        return LibraryContentIdentity.playlistKey(for: nowPlayingPlaylistID)
            == LibraryContentIdentity.playlistKey(for: contentId)
    }

    private func libraryPlaylistRow(_ playlist: Playlist) -> some View {
        let item = SidebarPinnedItem.from(playlist)
        return KasetSidebarRow(
            title: playlist.title,
            systemImage: item.systemImage,
            isSelected: self.pinnedSelection?.contentId == playlist.id,
            trailingText: playlist.trackCount.map(String.init),
            showsTrailingTextOnHover: true,
            artwork: KasetSidebarRowArtwork(url: playlist.thumbnailURL),
            isNowPlaying: self.isNowPlaying(contentId: playlist.id)
        ) {
            self.selectPinnedItem(item)
        }
        .accessibilityIdentifier(AccessibilityID.Sidebar.libraryPlaylist(playlist.id))
        .contextMenu {
            Button {
                self.sidebarPinnedItemsManager.add(item)
            } label: {
                Label(String(localized: "Pin to Sidebar"), systemImage: "pin")
            }
        }
    }

    // MARK: - Rows

    private func navigationRow(_ item: NavigationItem, shortcut: String? = nil) -> some View {
        KasetSidebarRow(
            title: item.displayName,
            systemImage: item.icon,
            isSelected: self.currentSidebarSelection == .navigation(item),
            trailingText: shortcut
        ) {
            self.selectNavigationItem(item)
        }
    }

    private func selectNavigationItem(_ item: NavigationItem) {
        let newSelection = SidebarSelection.navigation(item)
        if self.currentSidebarSelection == newSelection {
            self.onReselectNavigationItem?(item)
            HapticService.navigation()
            return
        }
        self.selection = item
        self.pinnedSelection = nil
        HapticService.navigation()
    }

    private func selectPinnedItem(_ item: SidebarPinnedItem) {
        if self.pinnedSelection?.contentId == item.contentId {
            self.onReselectPinnedItem?(item)
            HapticService.navigation()
            return
        }
        self.selection = nil
        self.pinnedSelection = item
        HapticService.navigation()
    }

    private var playlistsSectionHeader: some View {
        KasetSidebarSectionHeader(title: String(localized: "Your Playlists")) {
            if self.isCreatingPlaylist {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Button {
                    self.presentCreatePlaylistDialog()
                } label: {
                    Image(systemName: "plus")
                        .font(TuneTheme.Typeface.label)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                        .frame(width: 16, height: 16, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(self.isHoveringPlaylistsHeader ? 1 : 0)
                .help(String(localized: "Create Playlist"))
                .accessibilityLabel(String(localized: "Create Playlist"))
            }
        }
        .onHover { hovering in
            withAnimation(AppAnimation.quick) {
                self.isHoveringPlaylistsHeader = hovering
            }
        }
    }

    private func presentCreatePlaylistDialog() {
        guard !self.isCreatingPlaylist else { return }
        let owner = self.playerService.currentAccountMutationOwner

        SongActionsHelper.presentCreatePlaylistDialog(
            informativeText: "Create a new playlist.",
            request: SongActionsHelper.PlaylistCreationRequest(
                client: self.client,
                videoIds: [],
                whileValid: { self.playerService.acceptsAccountMutationOwner(owner) }
            ),
            onWillCreate: {
                guard !self.isCreatingPlaylist else { return false }
                self.isCreatingPlaylist = true
                return true
            },
            completion: { result in
                self.isCreatingPlaylist = false
                guard self.playerService.acceptsAccountMutationOwner(owner) else { return }

                switch result {
                case let .success(playlist):
                    let pinnedItem = SidebarPinnedItem.from(playlist)
                    self.sidebarPinnedItemsManager.add(pinnedItem)
                    self.selectPinnedItem(pinnedItem)
                case let .failure(failure):
                    SongActionsHelper.presentPlaylistCreationError(failure)
                }
            }
        )
    }

    private func sidebarPinnedRow(_ item: SidebarPinnedItem) -> some View {
        KasetSidebarRow(
            title: item.title,
            systemImage: item.systemImage,
            isSelected: self.pinnedSelection?.contentId == item.contentId,
            artwork: KasetSidebarRowArtwork(url: item.playlistRoute.thumbnailURL),
            isNowPlaying: self.isNowPlaying(contentId: item.contentId)
        ) {
            self.selectPinnedItem(item)
        }
        .contextMenu {
            Button {
                self.sidebarPinnedItemsManager.moveUp(contentId: item.contentId)
            } label: {
                Label(String(localized: "Move Up"), systemImage: "chevron.up")
            }

            Button {
                self.sidebarPinnedItemsManager.moveDown(contentId: item.contentId)
            } label: {
                Label(String(localized: "Move Down"), systemImage: "chevron.down")
            }

            Button {
                self.sidebarPinnedItemsManager.moveToTop(contentId: item.contentId)
            } label: {
                Label(String(localized: "Move to Top"), systemImage: "arrow.up.to.line")
            }

            Button {
                self.sidebarPinnedItemsManager.moveToEnd(contentId: item.contentId)
            } label: {
                Label(String(localized: "Move to End"), systemImage: "arrow.down.to.line")
            }

            Divider()

            Button(role: .destructive) {
                if self.pinnedSelection?.contentId == item.contentId {
                    self.pinnedSelection = nil
                }
                self.sidebarPinnedItemsManager.remove(contentId: item.contentId)
            } label: {
                Label(String(localized: "Remove from Sidebar"), systemImage: "sidebar.left")
            }
        }
    }
}

// MARK: - AccessibilityID.Sidebar + Library Playlists

extension AccessibilityID.Sidebar {
    static func libraryPlaylist(_ playlistID: String) -> String {
        "sidebar.playlist.\(playlistID)"
    }
}

#Preview {
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    Sidebar(selection: .constant(.home), pinnedSelection: .constant(nil), client: client)
        .frame(width: TuneTheme.Spacing.sidebarWidth)
        .environment(authService)
        .environment(PlayerService())
        .environment(SidebarPinnedItemsManager(skipLoad: true))
        .environment(PodcastsAvailabilityService())
        .preferredColorScheme(.dark)
}
