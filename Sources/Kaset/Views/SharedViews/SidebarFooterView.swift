import SwiftUI

/// Shared bottom area for both sidebars: the account row.
///
/// Tune is a music app, so the sidebar offers no way into the YouTube experience. The
/// MUSIC / VIDEO toggle (C2 `.side .mode`) only appears while YouTube is showing — reached
/// from the menu (⇧⌘Y) or a YouTube link — as the way back to Music.
struct SidebarFooterView: View {
    @State private var settings = SettingsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SidebarProfileView()

            if Self.showsSourceToggle(for: self.settings.appSource) {
                SidebarSourceModeToggle()
            }
        }
        .padding(.leading, KasetSidebarMetrics.leadingInset)
        .padding(.trailing, KasetSidebarMetrics.trailingInset)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TuneTheme.Palette.panel)
    }

    /// The source toggle is only the way back from YouTube, never the way in.
    static func showsSourceToggle(for source: AppSource) -> Bool {
        source == .video
    }
}

// MARK: - SidebarSourceModeToggle

/// C2 source toggle: two uppercase tracked labels; the active source is ink with a
/// 1-point ink underline. Replaces the capsule `SourceToggleView` in the sidebar and keeps
/// its accessibility identifiers and switching behaviour.
struct SidebarSourceModeToggle: View {
    @Environment(YouTubePlayerService.self) private var youtubePlayer
    @State private var settings = SettingsManager.shared

    var body: some View {
        HStack(spacing: 16) {
            ForEach(AppSource.allCases) { source in
                self.segment(for: source)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.SourceToggle.container)
    }

    private func segment(for source: AppSource) -> some View {
        let isSelected = self.settings.appSource == source

        return Button {
            self.select(source)
        } label: {
            Text(Self.title(for: source))
                .font(TuneTheme.Typeface.label)
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundStyle(isSelected ? TuneTheme.Palette.ink : TuneTheme.Palette.inkDim)
                .lineLimit(1)
                .fixedSize()
                .padding(.bottom, 3)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isSelected ? TuneTheme.Palette.ink : .clear)
                        .frame(height: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.SourceToggle.segment(for: source))
        .accessibilityLabel(source.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(
            source == .music
                ? String(localized: "Switch to YouTube Music")
                : String(localized: "Switch to YouTube")
        )
    }

    /// Short C2 labels; the accessibility label keeps the full source name.
    static func title(for source: AppSource) -> String {
        switch source {
        case .music: String(localized: "Music")
        case .video: String(localized: "Video")
        }
    }

    private func select(_ source: AppSource) {
        guard self.settings.appSource != source else { return }

        if source == .music {
            // Pause a docked video in place — don't hand it to the pop-out.
            self.youtubePlayer.prepareForSourceSwitch()
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            self.settings.appSource = source
        }
        HapticService.navigation()
        DiagnosticsLogger.ui.info("Source toggled to \(source.rawValue)")
    }
}

#Preview {
    SidebarFooterView()
        .frame(width: TuneTheme.Spacing.sidebarWidth)
        .preferredColorScheme(.dark)
}
