import SwiftUI

extension View {
    /// C2 settings surface: the grouped form sits on the app's near-black page instead of
    /// the system window gray, so Settings reads as part of Tune.
    func tuneSettingsSurface() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(TuneTheme.Palette.background)
    }
}
