import AppKit

/// A persisted appearance preference, independent of the macOS setting.
///
/// Tune is dark-only (redesign direction C2): `apply()` always forces Dark Aqua. The
/// preference is still persisted so upstream settings data stays readable.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String {
        self.rawValue
    }

    var displayName: String {
        switch self {
        case .system:
            String(
                localized: "Match System",
                bundle: AppLocalization.bundle,
                comment: "Appearance option that follows the macOS light or dark setting"
            )
        case .light: String(localized: "Light Mode")
        case .dark: String(localized: "Dark Mode")
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// The appearance Tune runs in regardless of the saved preference.
    static let tuneAppearanceName: NSAppearance.Name = .darkAqua

    /// Applies Tune's forced dark appearance app-wide.
    @MainActor
    func apply() {
        NSApplication.shared.appearance = NSAppearance(named: Self.tuneAppearanceName)
    }
}
