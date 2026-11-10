import Observation
import SwiftUI

// MARK: - PlayerBar

/// Per-page anchor for the C2 status line.
///
/// Tune shows one full-width player status line under the whole window (mounted once by
/// `MainWindow`), so pages no longer each draw their own bar. Pages still place
/// `PlayerBar()` where the bar used to sit: the anchor takes no space and publishes the
/// page's player-bar navigation context (artist/album link routing and the album or
/// artist the page is showing) to `PlayerBarRouteCenter`, which the status line reads.
struct PlayerBar: View {
    @Environment(\.playerBarNavigationAction) private var navigationAction
    @Environment(\.playerBarCurrentAlbumIDs) private var currentAlbumIDs
    @Environment(\.playerBarCurrentArtistID) private var currentArtistID

    @State private var token = UUID()

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                PlayerBarRouteCenter.shared.register(self.token, route: self.route)
            }
            .onChange(of: self.routeKey) { _, _ in
                PlayerBarRouteCenter.shared.update(self.token, route: self.route)
            }
            .onDisappear {
                PlayerBarRouteCenter.shared.unregister(self.token)
            }
    }

    private var route: PlayerBarRouteCenter.Route {
        PlayerBarRouteCenter.Route(
            navigationAction: self.navigationAction,
            albumIDs: self.currentAlbumIDs,
            artistID: self.currentArtistID
        )
    }

    /// Equatable digest of the route; the navigation closures themselves are not comparable.
    private var routeKey: PlayerBarRouteCenter.RouteKey {
        self.route.key
    }
}

// MARK: - PlayerBarRouteCenter

/// Tracks which page's player-bar context the window-level status line should use.
///
/// Every visible page anchor registers on appear and unregisters on disappear. The most
/// recently registered anchor wins, so a page pushed onto a stack overrides the stack root,
/// and popping it falls back to whatever is still on screen.
@MainActor
@Observable
final class PlayerBarRouteCenter {
    static let shared = PlayerBarRouteCenter()

    struct Route {
        var navigationAction: PlayerBarNavigationAction
        var albumIDs: Set<String>
        var artistID: String?

        var key: RouteKey {
            RouteKey(
                canOpenArtist: self.navigationAction.openArtist != nil,
                canOpenAlbum: self.navigationAction.openAlbum != nil,
                albumIDs: self.albumIDs,
                artistID: self.artistID
            )
        }
    }

    struct RouteKey: Hashable {
        let canOpenArtist: Bool
        let canOpenAlbum: Bool
        let albumIDs: Set<String>
        let artistID: String?
    }

    private struct Entry {
        let token: UUID
        var route: Route
    }

    private var entries: [Entry] = []

    /// The route of the most recently registered visible page, if any.
    var current: Route? {
        self.entries.last?.route
    }

    /// Identity of the active registration; changes whenever the user lands on another page.
    var currentToken: UUID? {
        self.entries.last?.token
    }

    func register(_ token: UUID, route: Route) {
        self.entries.removeAll { $0.token == token }
        self.entries.append(Entry(token: token, route: route))
    }

    func update(_ token: UUID, route: Route) {
        guard let index = self.entries.firstIndex(where: { $0.token == token }) else { return }
        self.entries[index].route = route
    }

    func unregister(_ token: UUID) {
        self.entries.removeAll { $0.token == token }
    }

    /// Drops every registration. Tests only.
    func reset() {
        self.entries.removeAll()
    }
}
