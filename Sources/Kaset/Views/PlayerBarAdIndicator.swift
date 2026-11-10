import SwiftUI

/// Replaces the content timeline while either playback WebView is showing an ad.
struct PlayerBarAdIndicator: View {
    /// C2 status-line variant: a flat `AD` label on a 2-point rule, no pill.
    var isInline = false

    var body: some View {
        if self.isInline {
            self.inlineBody
        } else {
            self.stackedBody
        }
    }

    private var inlineBody: some View {
        HStack(spacing: 10) {
            Text("Ad", comment: "Compact badge shown during an advertisement")
                .font(TuneTheme.Typeface.label)
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundStyle(TuneTheme.Palette.ink)
                .fixedSize()

            RoundedRectangle(cornerRadius: PlayerBarProgressLane.inlineTrackThickness / 2, style: .continuous)
                .fill(TuneTheme.Palette.inkDim)
                .frame(height: PlayerBarProgressLane.inlineTrackThickness)
        }
        .frame(height: PlayerBarProgressLane.inlineBarHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Advertisement"))
        .accessibilityIdentifier(AccessibilityID.PlayerBar.adIndicator)
    }

    private var stackedBody: some View {
        HStack(spacing: 8) {
            Text("Ad", comment: "Compact badge shown during an advertisement")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.yellow, in: .capsule)
                .fixedSize()

            Capsule()
                .fill(.yellow)
                .frame(height: PlayerBarSliderVisuals.trackThickness)
        }
        .frame(height: 30, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Advertisement"))
        .accessibilityIdentifier(AccessibilityID.PlayerBar.adIndicator)
    }
}
