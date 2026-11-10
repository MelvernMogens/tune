import SwiftUI

// MARK: - PlaylistBreakdown

/// Who and what a playlist is made of, from its loaded tracks: the C2 side
/// column's ARTISTS / ALBUMS lists with proportional bars.
struct PlaylistBreakdown: Equatable {
    struct Entry: Equatable {
        let name: String
        let count: Int
    }

    let artists: [Entry]
    let remainingArtists: Int
    let albums: [Entry]
    let remainingAlbums: Int
    let uniqueArtistCount: Int

    static func make(tracks: [Song], artistLimit: Int = 4, albumLimit: Int = 3) -> PlaylistBreakdown {
        let artists = Self.rank(tracks.compactMap { Self.clean($0.artists.first?.name) })
        let albums = Self.rank(tracks.compactMap { Self.clean($0.album?.title) })
        return PlaylistBreakdown(
            artists: Array(artists.prefix(artistLimit)),
            remainingArtists: max(0, artists.count - artistLimit),
            albums: Array(albums.prefix(albumLimit)),
            remainingAlbums: max(0, albums.count - albumLimit),
            uniqueArtistCount: artists.count
        )
    }

    /// Case-insensitive grouping (YouTube mixes "Ada Band" and "Ada band"),
    /// keeping the first spelling seen; ties keep first-appearance order.
    private static func rank(_ names: [String]) -> [Entry] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        for name in names {
            let key = name.lowercased()
            if counts[key] == nil {
                order.append(key)
                display[key] = name
            }
            counts[key, default: 0] += 1
        }
        return order.enumerated()
            .sorted { lhs, rhs in
                let left = counts[lhs.element] ?? 0
                let right = counts[rhs.element] ?? 0
                return left == right ? lhs.offset < rhs.offset : left > right
            }
            .map { Entry(name: display[$0.element] ?? $0.element, count: counts[$0.element] ?? 0) }
    }

    private static func clean(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: - PlaylistBreakdownList

/// One breakdown block: caps header with a trailing caps column label, rows
/// with a name, a thin proportional bar, and a mono count.
struct PlaylistBreakdownList: View {
    let title: String
    let entries: [PlaylistBreakdown.Entry]
    let remaining: Int

    private static let rowHeight: CGFloat = 32
    /// Short enough that names keep most of the slim side column.
    private static let barWidth: CGFloat = 40

    var body: some View {
        let maxCount = max(1, self.entries.map(\.count).max() ?? 1)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(self.title)
                Spacer(minLength: 0)
                Text(String(localized: "Songs"))
            }
            .tuneCapsLabel()
            .frame(height: Self.rowHeight)
            .overlay(alignment: .bottom) { Self.rule(TuneTheme.Palette.rule) }

            ForEach(Array(self.entries.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 10) {
                    Text(entry.name)
                        .font(TuneTheme.Typeface.body)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(entry.name)
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(TuneTheme.Palette.rule)
                        .frame(width: Self.barWidth, height: 2)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .fill(TuneTheme.Palette.inkSecondary)
                                .frame(width: Self.barWidth * CGFloat(entry.count) / CGFloat(maxCount), height: 2)
                        }
                    Text(verbatim: "\(entry.count)")
                        .font(TuneTheme.Typeface.data)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                        .frame(width: 24, alignment: .trailing)
                }
                .frame(height: Self.rowHeight)
                .overlay(alignment: .bottom) { Self.rule(TuneTheme.Palette.hairline) }
                .accessibilityElement(children: .combine)
            }

            if self.remaining > 0 {
                Text(verbatim: "+\(self.remaining) \(self.title)")
                    .font(TuneTheme.Typeface.data)
                    .textCase(.uppercase)
                    .foregroundStyle(TuneTheme.Palette.inkDim)
                    .frame(height: Self.rowHeight)
            }
        }
    }

    private static func rule(_ color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(height: 1)
    }
}

// MARK: - PlaylistBreakdownSection

/// The breakdown behind a quiet disclosure under the cover: open by default (it fills the
/// slim side column with who and what the playlist is made of), remembered once closed.
struct PlaylistBreakdownSection: View {
    let breakdown: PlaylistBreakdown

    @AppStorage("tune.playlist.showsBreakdown") private var isExpanded = true
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                withAnimation(AppAnimation.quick) {
                    self.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text(self.summary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(TuneTheme.Typeface.label)
                        .rotationEffect(.degrees(self.isExpanded ? 90 : 0))
                }
                .tuneCapsLabel()
                .foregroundStyle(self.isHovering ? TuneTheme.Palette.ink : TuneTheme.Palette.inkMuted)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { self.isHovering = $0 }
            .accessibilityAddTraits(self.isExpanded ? .isSelected : [])

            if self.isExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    if !self.breakdown.artists.isEmpty {
                        PlaylistBreakdownList(
                            title: String(localized: "Artists"),
                            entries: self.breakdown.artists,
                            remaining: self.breakdown.remainingArtists
                        )
                    }
                    if !self.breakdown.albums.isEmpty {
                        PlaylistBreakdownList(
                            title: String(localized: "Albums"),
                            entries: self.breakdown.albums,
                            remaining: self.breakdown.remainingAlbums
                        )
                    }
                }
                .transition(.opacity)
            }
        }
    }

    /// "ARTISTS · ALBUMS", naming only the lists that exist.
    private var summary: String {
        var parts: [String] = []
        if !self.breakdown.artists.isEmpty { parts.append(String(localized: "Artists")) }
        if !self.breakdown.albums.isEmpty { parts.append(String(localized: "Albums")) }
        return parts.joined(separator: " · ")
    }
}
