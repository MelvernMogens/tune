import SwiftUI

@available(macOS 26.0, *)
extension PlaylistDetailView {
    private func makeFallbackAlbum(from detail: PlaylistDetail) -> Album {
        Album(
            id: detail.id,
            title: detail.title,
            artists: detail.author.map { [$0] },
            thumbnailURL: detail.thumbnailURL,
            year: nil,
            trackCount: detail.trackCount ?? detail.tracks.count
        )
    }

    /// C2 action row: PLAY (the one filled button), SHUFFLE, LIBRARY, and a
    /// square overflow menu for the less frequent actions. Small, hard-edged,
    /// uppercase text buttons — no glass, no pills.
    func headerButtons(_ detail: PlaylistDetail) -> some View {
        let fallbackAlbum = self.makeFallbackAlbum(from: detail)
        let playableTracks = self.playableTracks(
            detail.tracks,
            fallbackArtist: detail.author?.name,
            fallbackAlbum: fallbackAlbum
        )

        return HStack(spacing: 8) {
            Button {
                self.playAll(
                    detail.tracks, fallbackArtist: detail.author?.name,
                    fallbackAlbum: fallbackAlbum
                )
            } label: {
                PlaylistActionLabel(title: String(localized: "Play"), systemImage: "play.fill")
            }
            .buttonStyle(PlaylistActionButtonStyle(isPrimary: true))
            .disabled(playableTracks.isEmpty)

            Button {
                self.shufflePlay(detail.tracks, fallbackArtist: detail.author?.name, fallbackAlbum: fallbackAlbum)
            } label: {
                PlaylistActionLabel(title: String(localized: "Shuffle"), systemImage: "shuffle")
            }
            .buttonStyle(PlaylistActionButtonStyle())
            .disabled(playableTracks.isEmpty)

            self.libraryButton(detail)

            self.moreMenu(detail, playableTracks: playableTracks, fallbackAlbum: fallbackAlbum)
        }
        .frame(height: 41)
    }

    @ViewBuilder
    private func libraryButton(_ detail: PlaylistDetail) -> some View {
        if detail.supportsLibraryToggle, self.hasPersonalAccount {
            let currentlyInLibrary = self.isInLibrary
            Button {
                self.toggleLibrary(detail)
            } label: {
                PlaylistActionLabel(
                    title: String(localized: "Library"),
                    systemImage: currentlyInLibrary ? "checkmark" : "plus"
                )
            }
            .buttonStyle(PlaylistActionButtonStyle())
            .disabled(self.isUpdatingLibrary || (detail.isAlbum && detail.libraryTargetId == nil))
            .accessibilityLabel(
                currentlyInLibrary
                    ? String(localized: "Added to Library")
                    : String(localized: "Add to Library")
            )
            .help(
                currentlyInLibrary
                    ? String(localized: "Added to Library")
                    : String(localized: "Add to Library")
            )
        }
    }

    private func moreMenu(_ detail: PlaylistDetail, playableTracks: [Song], fallbackAlbum: Album) -> some View {
        Menu {
            Button {
                SongActionsHelper.addSongsToQueueNext(
                    playableTracks,
                    playerService: self.playerService,
                    fallbackArtist: detail.author?.name,
                    fallbackAlbum: fallbackAlbum
                )
            } label: {
                Label(String(localized: "Play Next"), systemImage: "text.insert")
            }
            .disabled(playableTracks.isEmpty)

            Button {
                SongActionsHelper.addSongsToQueueLast(
                    playableTracks,
                    playerService: self.playerService,
                    fallbackArtist: detail.author?.name,
                    fallbackAlbum: fallbackAlbum
                )
            } label: {
                Label(String(localized: "Add to Queue"), systemImage: "text.append")
            }
            .disabled(playableTracks.isEmpty)

            self.sidebarMenuItem(detail)
            self.playlistManagementMenuItems(detail)
        } label: {
            Image(systemName: "ellipsis")
                .font(TuneTheme.Typeface.label)
                .foregroundStyle(TuneTheme.Palette.ink)
                .frame(width: 28, height: 28)
                .overlay {
                    RoundedRectangle.tuneRounded(TuneTheme.Radius.control)
                        .strokeBorder(TuneTheme.Palette.rule, lineWidth: 1)
                }
                .contentShape(.tuneRounded(TuneTheme.Radius.control))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(String(localized: "More"))
    }

    @ViewBuilder
    private func sidebarMenuItem(_ detail: PlaylistDetail) -> some View {
        if self.hasPersonalAccount, let sidebarItem = SidebarPinnedItem.from(detail) {
            let isPinnedToSidebar = self.sidebarPinnedItemsManager?.isPinned(sidebarItem) ?? false
            Divider()
            Button {
                self.sidebarPinnedItemsManager?.toggle(sidebarItem)
            } label: {
                Label(
                    isPinnedToSidebar ? String(localized: "Remove from Sidebar") : String(localized: "Add to Sidebar"),
                    systemImage: isPinnedToSidebar ? "checkmark.circle.fill" : "sidebar.left"
                )
            }
        }
    }

    @ViewBuilder
    private func playlistManagementMenuItems(_ detail: PlaylistDetail) -> some View {
        if !detail.isAlbum, !detail.isUploadedSongs {
            Divider()
            Button {
                self.showRefineSheet = true
            } label: {
                Label(String(localized: "Refine"), systemImage: "sparkles")
            }
            .requiresIntelligence()

            if detail.canDelete {
                Button(role: .destructive) {
                    SongActionsHelper.confirmDeletePlaylist(
                        Playlist(
                            id: detail.id,
                            title: detail.title,
                            description: detail.description,
                            thumbnailURL: detail.thumbnailURL,
                            trackCount: detail.trackCount,
                            author: detail.author,
                            canDelete: detail.canDelete
                        ),
                        client: self.viewModel.client,
                        libraryViewModel: self.libraryViewModel,
                        playerService: self.playerService
                    ) {
                        if let onPlaylistDeleted = self.onPlaylistDeleted {
                            onPlaylistDeleted()
                        } else {
                            self.dismiss()
                        }
                    }
                } label: {
                    Label(String(localized: "Delete Playlist"), systemImage: "trash")
                }
            }
        }
    }
}

// MARK: - PlaylistActionLabel

/// Glyph + uppercase tracked title, filling its share of the action row. Drops
/// the glyph, then the title, when the share is too narrow to show both.
struct PlaylistActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                self.glyph
                self.text
            }
            self.text
            self.glyph
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.title)
    }

    private var glyph: some View {
        Image(systemName: self.systemImage)
            .font(TuneTheme.Typeface.label)
    }

    private var text: some View {
        Text(self.title)
            .font(TuneTheme.Typeface.label)
            .tracking(0.9)
            .textCase(.uppercase)
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - PlaylistActionButtonStyle

/// C2 `.btn`: 28 pt tall, soft continuous corners (rounded rectangles, never
/// capsules). The primary button is filled ink with dark text; the rest are a
/// hairline outline.
struct PlaylistActionButtonStyle: ButtonStyle {
    var isPrimary = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(self.isPrimary ? TuneTheme.Palette.background : TuneTheme.Palette.ink)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(self.isPrimary ? TuneTheme.Palette.ink : Color.clear, in: .tuneRounded(TuneTheme.Radius.control))
            .overlay {
                RoundedRectangle.tuneRounded(TuneTheme.Radius.control)
                    .strokeBorder(self.isPrimary ? TuneTheme.Palette.ink : TuneTheme.Palette.rule, lineWidth: 1)
            }
            .contentShape(.tuneRounded(TuneTheme.Radius.control))
            .opacity(self.isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}
