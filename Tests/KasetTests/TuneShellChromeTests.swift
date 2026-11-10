import CoreGraphics
import Testing
@testable import Kaset

// MARK: - TuneShellChromeTests

/// Sidebar footer and toolbar command field rules for the C2 shell.
@Suite(.tags(.service))
@MainActor
struct TuneShellChromeTests {
    @Test("The sidebar never offers YouTube; the toggle only appears as the way back")
    func sourceToggleOnlyInYouTube() {
        #expect(!SidebarFooterView.showsSourceToggle(for: .music))
        #expect(SidebarFooterView.showsSourceToggle(for: .video))
    }

    @Test("Over the sidebar the command field ends before the divider")
    func commandFieldStaysInSidebar() {
        let sidebar = TuneTheme.Spacing.sidebarWidth
        for minX in [CGFloat(0), 12, 78, 88, 100] {
            let width = TuneCommandFieldMetrics.width(fieldMinX: minX, sidebarWidth: sidebar)
            #expect(minX + width <= sidebar - TuneCommandFieldMetrics.dividerClearance)
            #expect(width >= TuneCommandFieldMetrics.minimumWidth)
        }
        // Before the first measurement it assumes the slot just past the traffic lights.
        let unmeasured = TuneCommandFieldMetrics.width(fieldMinX: nil, sidebarWidth: sidebar)
        #expect(TuneCommandFieldMetrics.assumedMinX + unmeasured <= sidebar - TuneCommandFieldMetrics.dividerClearance)
        #expect(TuneCommandFieldMetrics.width(fieldMinX: .nan, sidebarWidth: sidebar) == unmeasured)
    }

    @Test("In the content column the command field keeps its C2 width")
    func commandFieldInContentColumn() {
        let sidebar = TuneTheme.Spacing.sidebarWidth
        #expect(TuneCommandFieldMetrics.width(fieldMinX: 700, sidebarWidth: sidebar) == TuneCommandFieldMetrics.preferredWidth)
        #expect(TuneCommandFieldMetrics.width(fieldMinX: sidebar, sidebarWidth: sidebar) == TuneCommandFieldMetrics.preferredWidth)
    }

    @Test("A cramped slot falls back to the minimum width rather than collapsing")
    func commandFieldMinimum() {
        let width = TuneCommandFieldMetrics.width(fieldMinX: 200, sidebarWidth: TuneTheme.Spacing.sidebarWidth)
        #expect(width == TuneCommandFieldMetrics.minimumWidth)
    }

    @Test("Sidebar rows: raised fill when selected, fainter on hover, none at rest")
    func sidebarRowFill() {
        #expect(KasetSidebarMetrics.fill(isSelected: true, isHovering: false) == TuneTheme.Palette.raised)
        #expect(KasetSidebarMetrics.fill(isSelected: true, isHovering: true) == TuneTheme.Palette.raisedStrong)
        #expect(KasetSidebarMetrics.fill(isSelected: false, isHovering: true) == TuneTheme.Palette.raised.opacity(0.6))
        #expect(KasetSidebarMetrics.fill(isSelected: false, isHovering: false) == .clear)
    }

    @Test("Now Playing artwork and video take hero corners when large, artwork corners when small")
    func nowPlayingArtworkRadius() {
        #expect(TuneNowPlayingArtworkShape.radius(forEdge: 480) == TuneTheme.Radius.hero)
        #expect(TuneNowPlayingArtworkShape.radius(forEdge: 300) == TuneTheme.Radius.artwork)
        #expect(TuneNowPlayingArtworkShape.radius(forEdge: 180) == TuneTheme.Radius.artwork)
        #expect(TuneNowPlayingArtworkShape.radius(forEdge: 0) == TuneTheme.Radius.artwork)
        #expect(TuneNowPlayingArtworkShape.radius(forEdge: .infinity) == TuneTheme.Radius.artwork)
    }
}
