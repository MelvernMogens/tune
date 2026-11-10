import SwiftUI

// MARK: - PlayerBarVerticalSlider

struct PlayerBarVerticalSlider: View {
    @Binding var value: Double

    let accent: Color
    let accessibilityIdentifier: String?
    let accessibilityLabel: String
    let onEditingChanged: (Bool) -> Void
    let onValueChanged: (_ oldValue: Double, _ newValue: Double) -> Void
    /// C2 look: 2-point hard-edged track and a flat 12×4 handle instead of a capsule and round knob.
    var usesHardEdges = false

    @Environment(\.colorScheme) private var colorScheme
    @State private var isDragging = false
    @State private var isHovering = false

    private var clampedValue: CGFloat {
        CGFloat(min(max(0, self.value), 1))
    }

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let fillHeight = height * self.clampedValue
            let thumbDiameter = PlayerBarSliderVisuals.thumbDiameter(
                isHovering: self.isHovering,
                isDragging: self.isDragging
            )

            if self.usesHardEdges {
                self.hardEdgedTrack(height: height, fillHeight: fillHeight)
            } else {
                self.roundedTrack(height: height, fillHeight: fillHeight, thumbDiameter: thumbDiameter)
            }
        }
        .frame(width: 28, height: 122)
        .accessibilityElement(children: .ignore)
        .playerBarVerticalSliderAccessibilityIdentifier(self.accessibilityIdentifier)
        .accessibilityLabel(self.accessibilityLabel)
        .accessibilityValue("\(Int(self.clampedValue * 100))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                self.adjustValue(by: 0.05)
            case .decrement:
                self.adjustValue(by: -0.05)
            @unknown default:
                break
            }
        }
    }

    private func hardEdgedTrack(height: CGFloat, fillHeight: CGFloat) -> some View {
        let handleHeight: CGFloat = 4
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(self.isHovering || self.isDragging ? TuneTheme.Palette.inkDim : TuneTheme.Palette.rule)
                .frame(width: 2)

            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(self.accent)
                .frame(width: 2, height: fillHeight)

            RoundedRectangle(cornerRadius: handleHeight / 2, style: .continuous)
                .fill(self.accent)
                .frame(width: 12, height: handleHeight)
                .offset(y: -min(max(0, fillHeight - handleHeight / 2), max(0, height - handleHeight)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(self.dragModifier(height: height))
    }

    private func roundedTrack(height: CGFloat, fillHeight: CGFloat, thumbDiameter: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Capsule()
                .fill(self.trackColor)
                .frame(width: PlayerBarSliderVisuals.trackThickness)

                UnevenRoundedRectangle(
                    bottomLeadingRadius: 999,
                    bottomTrailingRadius: 999
                )
                .fill(self.accent)
                .frame(width: PlayerBarSliderVisuals.trackThickness, height: fillHeight)

                Circle()
                    .fill(self.accent)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                .offset(y: -min(max(0, fillHeight - thumbDiameter / 2), max(0, height - thumbDiameter)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(PlayerBarSliderVisuals.trackAnimation, value: self.isHovering)
        .animation(PlayerBarSliderVisuals.thumbAnimation, value: self.isDragging)
        .animation(PlayerBarSliderVisuals.thumbAnimation, value: self.isHovering)
        .modifier(self.dragModifier(height: height))
    }

    private func dragModifier(height: CGFloat) -> PlayerBarVerticalSliderDrag {
        PlayerBarVerticalSliderDrag(
            height: height,
            onDrag: { locationY in
                self.beginEditingIfNeeded()
                self.updateValue(from: locationY, height: height)
            },
            onEnd: { self.endEditingIfNeeded() },
            onHover: { self.isHovering = $0 }
        )
    }

    private func beginEditingIfNeeded() {
        guard !self.isDragging else { return }
        self.isDragging = true
        self.onEditingChanged(true)
    }

    private func endEditingIfNeeded() {
        guard self.isDragging else { return }
        self.isDragging = false
        self.onEditingChanged(false)
    }

    private func updateValue(from locationY: CGFloat, height: CGFloat) {
        guard height > 0 else { return }
        self.setValue(1 - Double(min(max(0, locationY / height), 1)))
    }

    private func adjustValue(by delta: Double) {
        let clamped = min(max(0, self.value + delta), 1)
        guard self.value != clamped else { return }
        self.beginEditingIfNeeded()
        self.setValue(clamped)
        self.endEditingIfNeeded()
    }

    private func setValue(_ newValue: Double) {
        let oldValue = self.value
        let clamped = min(max(0, newValue), 1)
        guard oldValue != clamped else { return }
        self.value = clamped
        self.onValueChanged(oldValue, clamped)
    }

    private var trackColor: Color {
        PlayerBarSliderVisuals.trackColor(
            colorScheme: self.colorScheme,
            isActive: self.isHovering || self.isDragging
        )
    }
}

// MARK: - PlayerBarVerticalSliderDrag

/// Expands the slider's hit target and maps drags to a track-relative y.
private struct PlayerBarVerticalSliderDrag: ViewModifier {
    let height: CGFloat
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    let onHover: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .padding(PlayerBarSliderVisuals.hitOutset)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        self.onDrag(drag.location.y - PlayerBarSliderVisuals.hitOutset)
                    }
                    .onEnded { _ in
                        self.onEnd()
                    }
            )
            .padding(-PlayerBarSliderVisuals.hitOutset)
            .onHover(perform: self.onHover)
    }
}

// MARK: - Accessibility Helpers

private extension View {
    @ViewBuilder
    func playerBarVerticalSliderAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            self.accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}
