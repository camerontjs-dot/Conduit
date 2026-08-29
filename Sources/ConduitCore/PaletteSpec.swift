import Foundation

// MARK: - Palette identity

/// Stable Focused Flow palette identifiers for R2.
/// Case order is product order: Harbor is first and the fresh-product default.
public enum PaletteID: String, CaseIterable, Codable, Hashable, Sendable {
    case harbor
    case sage
    case clay
    case heather
    case phosphor

    /// Fresh-product default. Harbor is preferred even though the recovered
    /// mockup boots Sage.
    public static let productDefault: PaletteID = .harbor
}

/// Light/dark appearance for a palette's base token set.
public enum PaletteVariant: String, CaseIterable, Codable, Hashable, Sendable {
    case light
    case dark
}

// MARK: - Base tokens

/// Optional light-variant shade RGB triple consumed by mockup `mk()` line/scan
/// derivation. Dark variants carry `nil`.
public struct PaletteShade: Equatable, Hashable, Codable, Sendable {
    public let red: Int
    public let green: Int
    public let blue: Int

    public init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Exact reviewed base inputs for one palette × light/dark pair.
/// Color literals are six-digit normalized hex (`#RRGGBB`) only.
public struct PaletteBaseTokens: Equatable, Hashable, Codable, Sendable {
    public let accent: String
    public let onAccent: String
    public let ink: String
    public let canvas: String
    public let app: String
    public let rail: String
    public let surface: String
    public let sink: String
    public let text: String
    public let dim: String
    public let faint: String
    /// Present only for light variants that feed a shade RGB into `mk()`.
    public let shade: PaletteShade?
    public let soft: Bool

    public init(
        accent: String,
        onAccent: String,
        ink: String,
        canvas: String,
        app: String,
        rail: String,
        surface: String,
        sink: String,
        text: String,
        dim: String,
        faint: String,
        shade: PaletteShade?,
        soft: Bool
    ) {
        self.accent = accent
        self.onAccent = onAccent
        self.ink = ink
        self.canvas = canvas
        self.app = app
        self.rail = rail
        self.surface = surface
        self.sink = sink
        self.text = text
        self.dim = dim
        self.faint = faint
        self.shade = shade
        self.soft = soft
    }
}

extension PaletteID {
    /// Returns the exact signed-off base tokens for this palette and variant.
    public func baseTokens(variant: PaletteVariant) -> PaletteBaseTokens {
        switch (self, variant) {
        case (.harbor, .light):
            return PaletteBaseTokens(
                accent: "#456881",
                onAccent: "#FFFFFF",
                ink: "#35566D",
                canvas: "#F2F5F7",
                app: "#E4E9ED",
                rail: "#EBEFF2",
                surface: "#FCFDFE",
                sink: "#DFE5EA",
                text: "#232A31",
                dim: "#5C6772",
                faint: "#93A0AB",
                shade: PaletteShade(red: 30, green: 48, blue: 62),
                soft: true
            )
        case (.harbor, .dark):
            return PaletteBaseTokens(
                accent: "#7FA8C8",
                onAccent: "#0D1417",
                ink: "#A3C4DD",
                canvas: "#0F1417",
                app: "#141A1E",
                rail: "#192025",
                surface: "#1E262B",
                sink: "#131A1E",
                text: "#E1E6EA",
                dim: "#93A0AA",
                faint: "#64707A",
                shade: nil,
                soft: true
            )
        case (.sage, .light):
            return PaletteBaseTokens(
                accent: "#4F6B49",
                onAccent: "#FFFFFF",
                ink: "#3F5740",
                canvas: "#F5F3EC",
                app: "#E9EBE2",
                rail: "#EEF0E7",
                surface: "#FCFCF8",
                sink: "#E4E7DC",
                text: "#2A2E27",
                dim: "#626B5D",
                faint: "#98A08D",
                shade: PaletteShade(red: 40, green: 50, blue: 32),
                soft: true
            )
        case (.sage, .dark):
            return PaletteBaseTokens(
                accent: "#8FB183",
                onAccent: "#14180F",
                ink: "#A9C99E",
                canvas: "#141A15",
                app: "#191E1A",
                rail: "#1E241F",
                surface: "#232924",
                sink: "#171C18",
                text: "#E4E7DD",
                dim: "#9AA393",
                faint: "#6B7365",
                shade: nil,
                soft: true
            )
        case (.clay, .light):
            return PaletteBaseTokens(
                accent: "#97583E",
                onAccent: "#FFFFFF",
                ink: "#7C4530",
                canvas: "#F5F0E9",
                app: "#EAE1D6",
                rail: "#F0E8DD",
                surface: "#FDFBF7",
                sink: "#E5DBCD",
                text: "#2E2620",
                dim: "#6D6055",
                faint: "#A0917F",
                shade: PaletteShade(red: 60, green: 42, blue: 28),
                soft: true
            )
        case (.clay, .dark):
            return PaletteBaseTokens(
                accent: "#CB8A6E",
                onAccent: "#17120E",
                ink: "#E0A888",
                canvas: "#17120E",
                app: "#1D1712",
                rail: "#221B15",
                surface: "#271F18",
                sink: "#1A140F",
                text: "#EAE2D8",
                dim: "#A3958A",
                faint: "#736659",
                shade: nil,
                soft: true
            )
        case (.heather, .light):
            return PaletteBaseTokens(
                accent: "#635B8C",
                onAccent: "#FFFFFF",
                ink: "#4F4874",
                canvas: "#F4F3F7",
                app: "#E7E5EE",
                rail: "#EDEBF3",
                surface: "#FCFCFE",
                sink: "#E2E0EB",
                text: "#2A2833",
                dim: "#625D70",
                faint: "#9A94A8",
                shade: PaletteShade(red: 40, green: 36, blue: 58),
                soft: true
            )
        case (.heather, .dark):
            return PaletteBaseTokens(
                accent: "#A79FCE",
                onAccent: "#141318",
                ink: "#C3BCE0",
                canvas: "#141318",
                app: "#1A181F",
                rail: "#201E27",
                surface: "#26232E",
                sink: "#18161D",
                text: "#E5E2EC",
                dim: "#9D97AC",
                faint: "#6D6879",
                shade: nil,
                soft: true
            )
        case (.phosphor, .light):
            return PaletteBaseTokens(
                accent: "#C97A16",
                onAccent: "#241A08",
                ink: "#8A5410",
                canvas: "#FAF8F4",
                app: "#ECE7DE",
                rail: "#F4F0E8",
                surface: "#FFFFFF",
                sink: "#E7E1D6",
                text: "#221E18",
                dim: "#6C665B",
                faint: "#9C9488",
                shade: PaletteShade(red: 40, green: 32, blue: 20),
                soft: false
            )
        case (.phosphor, .dark):
            return PaletteBaseTokens(
                accent: "#E8A13B",
                onAccent: "#201603",
                ink: "#F2BE6E",
                canvas: "#0B0E0C",
                app: "#101311",
                rail: "#181B18",
                surface: "#1E221F",
                sink: "#121614",
                text: "#E7E3DA",
                dim: "#9B978C",
                faint: "#6B675E",
                shade: nil,
                soft: false
            )
        }
    }

    /// All ten palette × variant base pairs in product case order, light then dark.
    public static var allBaseVariants: [(id: PaletteID, variant: PaletteVariant, tokens: PaletteBaseTokens)] {
        allCases.flatMap { id in
            PaletteVariant.allCases.map { variant in
                (id: id, variant: variant, tokens: id.baseTokens(variant: variant))
            }
        }
    }
}

// MARK: - mk() derivation constants

/// Exact numeric and shadow-string constants from the Focused Flow mockup
/// `function mk(o)`. Foundation-only; no SwiftUI/AppKit color types.
public enum PaletteMkConstants {
    // accent-soft alpha
    public static let accentSoftAlphaDark: Double = 0.17
    public static let accentSoftAlphaLight: Double = 0.13

    // soft accent-glow
    public static let softAccentGlowDark: Double = 0.20
    public static let softAccentGlowLight: Double = 0.13

    // non-soft accent-glow
    public static let nonSoftAccentGlowDark: Double = 0.42
    public static let nonSoftAccentGlowLight: Double = 0.30

    // line
    public static let lineDarkWhite: Double = 0.10
    public static let lineLightShade: Double = 0.13

    // line-soft
    public static let lineSoftDarkWhite: Double = 0.05
    public static let lineSoftLightShade: Double = 0.06

    // soft scan
    public static let softScanDarkWhite: Double = 0.008
    public static let softScanLightShade: Double = 0.006

    // non-soft scan
    public static let nonSoftScanDarkWhite: Double = 0.022
    public static let nonSoftScanLightShade: Double = 0.015

    // desk1 / desk2 darkening
    public static let desk1DarkeningDark: Double = 0.35
    public static let desk1DarkeningLight: Double = 0.05
    public static let desk2DarkeningDark: Double = 0.15
    public static let desk2DarkeningLight: Double = 0.13

    // shadow presets (exact mockup CSS strings)
    public static let shadowDark =
        "0 26px 70px -18px rgba(0,0,0,.7),0 2px 10px rgba(0,0,0,.5)"
    public static let shadowLight =
        "0 22px 60px -18px rgba(30,22,10,.3),0 2px 8px rgba(30,22,10,.1)"
    public static let popShadowDark =
        "0 18px 46px -8px rgba(0,0,0,.66)"
    public static let popShadowLight =
        "0 14px 40px -10px rgba(20,15,5,.3)"
}
