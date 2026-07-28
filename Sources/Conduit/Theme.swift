#if os(macOS)
import ConduitCore
import SwiftUI

// MARK: - Hex parsing

/// Parses six-digit `#RRGGBB` / `RRGGBB` hex into sRGB components.
/// Invalid input yields a highly visible fallback rather than trapping.
enum ConduitHexColor {
    static let fallback = Color(red: 1, green: 0, blue: 1) // magenta fail-safe

    static func color(hex: String) -> Color {
        guard let rgb = rgb(hex: hex) else { return fallback }
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    static func rgb(hex: String) -> (r: Double, g: Double, b: Double)? {
        guard let channels = channels255(hex: hex) else { return nil }
        return (
            Double(channels.r) / 255.0,
            Double(channels.g) / 255.0,
            Double(channels.b) / 255.0
        )
    }

    /// Integer 0–255 channels from a six-digit hex literal.
    static func channels255(hex: String) -> (r: Int, g: Int, b: Int)? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") {
            s.removeFirst()
        }
        guard s.count == 6, let value = UInt64(s, radix: 16) else {
            return nil
        }
        let r = Int((value >> 16) & 0xFF)
        let g = Int((value >> 8) & 0xFF)
        let b = Int(value & 0xFF)
        return (r, g, b)
    }

    /// Mockup `darken(hex, amount)`: multiply each 0–255 channel by `(1 - amount)`,
    /// then `Math.round` (half away from zero) before converting to SwiftUI `Color`.
    static func darken(hex: String, by amount: Double) -> Color {
        guard let ch = channels255(hex: hex) else { return fallback }
        let factor = 1 - amount
        // Match JS Math.round on non-negative channel products.
        let r = Int((Double(ch.r) * factor).rounded(.toNearestOrAwayFromZero))
        let g = Int((Double(ch.g) * factor).rounded(.toNearestOrAwayFromZero))
        let b = Int((Double(ch.b) * factor).rounded(.toNearestOrAwayFromZero))
        return Color(
            red: Double(max(0, min(255, r))) / 255.0,
            green: Double(max(0, min(255, g))) / 255.0,
            blue: Double(max(0, min(255, b))) / 255.0
        )
    }
}

// MARK: - Shadow presets

/// One CSS box-shadow layer parsed from the exact mockup shadow strings.
/// Spread is retained for fidelity even though SwiftUI's `.shadow` cannot apply it.
struct ConduitShadowLayer: Equatable, Sendable {
    let x: CGFloat
    let y: CGFloat
    let blur: CGFloat
    let spread: CGFloat
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

/// SwiftUI-usable shadow representation derived from `PaletteMkConstants` CSS strings.
/// Values are not retuned — only structured for runtime application.
struct ConduitShadowPreset: Equatable, Sendable {
    /// Exact mockup CSS string preserved for reference and future export.
    let cssString: String
    let layers: [ConduitShadowLayer]

    static func from(cssString: String) -> ConduitShadowPreset {
        ConduitShadowPreset(cssString: cssString, layers: parseCSSShadow(cssString))
    }
}

/// Parses comma-separated CSS box-shadow layers of the form
/// `0 26px 70px -18px rgba(0,0,0,.7)`.
private func parseCSSShadow(_ css: String) -> [ConduitShadowLayer] {
    // Split on top-level commas (not those inside rgba(...)).
    var layers: [ConduitShadowLayer] = []
    var current = ""
    var depth = 0
    for ch in css {
        if ch == "(" { depth += 1 }
        if ch == ")" { depth = max(0, depth - 1) }
        if ch == "," && depth == 0 {
            if let layer = parseOneShadowLayer(current) {
                layers.append(layer)
            }
            current = ""
            continue
        }
        current.append(ch)
    }
    if let layer = parseOneShadowLayer(current) {
        layers.append(layer)
    }
    return layers
}

private func parseOneShadowLayer(_ raw: String) -> ConduitShadowLayer? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }

    // Match: [x][px?] [y]px [blur]px [spread?]px rgba(r,g,b,a)
    // Authoritative presets start with bare `0` (no unit) on the x offset;
    // remaining lengths use `px`. Accept optional `px` on every length token.
    // rgba alpha may use leading-dot (.7).
    let pattern =
        #"(-?\d+(?:\.\d+)?)(?:px)?\s+"# +
        #"(-?\d+(?:\.\d+)?)(?:px)?\s+"# +
        #"(-?\d+(?:\.\d+)?)(?:px)?\s+"# +
        #"(?:(-?\d+(?:\.\d+)?)(?:px)?\s+)?"# +
        #"rgba\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\.?\d+(?:\.\d+)?)\s*\)"#

    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return nil
    }
    let range = NSRange(s.startIndex..<s.endIndex, in: s)
    guard let match = regex.firstMatch(in: s, options: [], range: range), match.numberOfRanges >= 8 else {
        return nil
    }

    func group(_ i: Int) -> String? {
        let r = match.range(at: i)
        guard r.location != NSNotFound, let swiftRange = Range(r, in: s) else { return nil }
        return String(s[swiftRange])
    }

    guard
        let xStr = group(1), let x = Double(xStr),
        let yStr = group(2), let y = Double(yStr),
        let blurStr = group(3), let blur = Double(blurStr),
        let rStr = group(5), let ri = Double(rStr),
        let gStr = group(6), let gi = Double(gStr),
        let bStr = group(7), let bi = Double(bStr),
        let aStr = group(8)
    else { return nil }

    let spread: Double
    if let spStr = group(4), let sp = Double(spStr) {
        spread = sp
    } else {
        spread = 0
    }

    // Leading-dot alpha: ".7" → 0.7
    let alpha: Double
    if aStr.hasPrefix("."), let v = Double("0" + aStr) {
        alpha = v
    } else if let v = Double(aStr) {
        alpha = v
    } else {
        return nil
    }

    return ConduitShadowLayer(
        x: CGFloat(x),
        y: CGFloat(y),
        blur: CGFloat(blur),
        spread: CGFloat(spread),
        red: ri / 255.0,
        green: gi / 255.0,
        blue: bi / 255.0,
        alpha: alpha
    )
}

// MARK: - Resolved palette

/// Fully resolved Focused Flow palette: base tokens as `Color` plus
/// `mk()`-derived accents, lines, scan, desk surfaces, and shadow presets.
struct ConduitPalette: Equatable {
    // Base tokens
    let accent: Color
    let onAccent: Color
    let ink: Color
    let canvas: Color
    let app: Color
    let rail: Color
    let surface: Color
    let sink: Color
    let text: Color
    let dim: Color
    let faint: Color
    let soft: Bool

    // Derived via PaletteMkConstants (exact mockup mk() numerics)
    let accentSoft: Color
    let accentGlow: Color
    let line: Color
    let lineSoft: Color
    let scan: Color
    let desk1: Color
    let desk2: Color

    let shadow: ConduitShadowPreset
    let popShadow: ConduitShadowPreset

    let paletteID: PaletteID
    let variant: PaletteVariant

    /// Observable terminal lifecycle indicator only.
    ///
    /// Maps launching / working / ready (running) / detached / exited onto a
    /// distinct neutral ramp derived from `dim`, `faint`, `text`, `line`, and
    /// `lineSoft`. Failed may use a restrained system error tone.
    ///
    /// Never returns palette accent — accent is reserved for active-session and
    /// primary-action chrome. Ready means the terminal is quiet/running, not
    /// verified task completion.
    func color(forTerminalState state: TerminalVisualState) -> Color {
        switch state {
        case .launching:
            // Starting — soft neutral presence (faint).
            return faint
        case .working:
            // Output active — strongest neutral (text).
            return text
        case .running:
            // Ready / quiet running — mid neutral (dim). Not task completion.
            return dim
        case .detached:
            // Out of direct view — dim stepped toward line weight, still legible.
            return dim.opacity(0.55)
        case .exited:
            // Process ended — faint stepped toward lineSoft weight.
            return faint.opacity(0.42)
        case .failed:
            // Restrained system/error tone; never palette accent.
            return Color.red.opacity(0.70)
        }
    }

    /// Resolve every token from ConduitCore base data + mk constants for the
    /// given palette identity and system color scheme.
    static func resolved(id: PaletteID, colorScheme: ColorScheme) -> ConduitPalette {
        let variant: PaletteVariant = colorScheme == .dark ? .dark : .light
        return resolved(id: id, variant: variant)
    }

    static func resolved(id: PaletteID, variant: PaletteVariant) -> ConduitPalette {
        let tokens = id.baseTokens(variant: variant)
        let isDark = variant == .dark

        let accent = ConduitHexColor.color(hex: tokens.accent)
        let onAccent = ConduitHexColor.color(hex: tokens.onAccent)
        let ink = ConduitHexColor.color(hex: tokens.ink)
        let canvas = ConduitHexColor.color(hex: tokens.canvas)
        let app = ConduitHexColor.color(hex: tokens.app)
        let rail = ConduitHexColor.color(hex: tokens.rail)
        let surface = ConduitHexColor.color(hex: tokens.surface)
        let sink = ConduitHexColor.color(hex: tokens.sink)
        let text = ConduitHexColor.color(hex: tokens.text)
        let dim = ConduitHexColor.color(hex: tokens.dim)
        let faint = ConduitHexColor.color(hex: tokens.faint)

        // accent-soft
        let softAlpha = isDark
            ? PaletteMkConstants.accentSoftAlphaDark
            : PaletteMkConstants.accentSoftAlphaLight
        let accentSoft = accent.opacity(softAlpha)

        // accent-glow (soft vs non-soft branches)
        let glowAlpha: Double
        if tokens.soft {
            glowAlpha = isDark
                ? PaletteMkConstants.softAccentGlowDark
                : PaletteMkConstants.softAccentGlowLight
        } else {
            glowAlpha = isDark
                ? PaletteMkConstants.nonSoftAccentGlowDark
                : PaletteMkConstants.nonSoftAccentGlowLight
        }
        let accentGlow = accent.opacity(glowAlpha)

        // line / line-soft / scan: dark uses white; light uses shade RGB
        let line: Color
        let lineSoft: Color
        let scan: Color
        if isDark {
            line = Color.white.opacity(PaletteMkConstants.lineDarkWhite)
            lineSoft = Color.white.opacity(PaletteMkConstants.lineSoftDarkWhite)
            let scanAlpha = tokens.soft
                ? PaletteMkConstants.softScanDarkWhite
                : PaletteMkConstants.nonSoftScanDarkWhite
            scan = Color.white.opacity(scanAlpha)
        } else {
            let shadeColor: Color
            if let shade = tokens.shade {
                shadeColor = Color(
                    red: Double(shade.red) / 255.0,
                    green: Double(shade.green) / 255.0,
                    blue: Double(shade.blue) / 255.0
                )
            } else {
                // Light variants always carry shade in the signed-off tables;
                // fall back visibly if data is ever incomplete.
                shadeColor = ConduitHexColor.fallback
            }
            line = shadeColor.opacity(PaletteMkConstants.lineLightShade)
            lineSoft = shadeColor.opacity(PaletteMkConstants.lineSoftLightShade)
            let scanAlpha = tokens.soft
                ? PaletteMkConstants.softScanLightShade
                : PaletteMkConstants.nonSoftScanLightShade
            scan = shadeColor.opacity(scanAlpha)
        }

        // desk1 / desk2: mockup mk() darkens o.app (not canvas) by signed-off factors
        let desk1Amount = isDark
            ? PaletteMkConstants.desk1DarkeningDark
            : PaletteMkConstants.desk1DarkeningLight
        let desk2Amount = isDark
            ? PaletteMkConstants.desk2DarkeningDark
            : PaletteMkConstants.desk2DarkeningLight
        let desk1 = ConduitHexColor.darken(hex: tokens.app, by: desk1Amount)
        let desk2 = ConduitHexColor.darken(hex: tokens.app, by: desk2Amount)

        let shadowCSS = isDark
            ? PaletteMkConstants.shadowDark
            : PaletteMkConstants.shadowLight
        let popShadowCSS = isDark
            ? PaletteMkConstants.popShadowDark
            : PaletteMkConstants.popShadowLight

        return ConduitPalette(
            accent: accent,
            onAccent: onAccent,
            ink: ink,
            canvas: canvas,
            app: app,
            rail: rail,
            surface: surface,
            sink: sink,
            text: text,
            dim: dim,
            faint: faint,
            soft: tokens.soft,
            accentSoft: accentSoft,
            accentGlow: accentGlow,
            line: line,
            lineSoft: lineSoft,
            scan: scan,
            desk1: desk1,
            desk2: desk2,
            shadow: .from(cssString: shadowCSS),
            popShadow: .from(cssString: popShadowCSS),
            paletteID: id,
            variant: variant
        )
    }
}

// MARK: - Palette presentation

extension PaletteID {
    /// Human-readable product name (capitalized case name).
    var displayName: String {
        switch self {
        case .harbor: return "Harbor"
        case .sage: return "Sage"
        case .clay: return "Clay"
        case .heather: return "Heather"
        case .phosphor: return "Phosphor"
        }
    }

    /// Signed-off mood line for Settings and picker chrome.
    var mood: String {
        switch self {
        case .harbor: return "cool & serene — dusty blue, low-stimulation"
        case .sage: return "quiet & natural — soft moss on warm paper"
        case .clay: return "warm & cozy — muted terracotta, grounded"
        case .heather: return "soft & unhurried — muted lavender-grey"
        case .phosphor: return "the original — energetic amber on carbon"
        }
    }
}

// MARK: - Theme store

/// Persisted palette selection and live resolution against the system color scheme.
/// Uses `@AppStorage("conduit.palette")` and falls back to Harbor for missing/invalid values.
/// Compatible with macOS 13 (`ObservableObject`, no Observation macros).
@MainActor
final class ThemeStore: ObservableObject {
    static let storageKey = "conduit.palette"

    @AppStorage(ThemeStore.storageKey) private var storedRaw: String = PaletteID.productDefault.rawValue

    /// Currently selected palette. Invalid stored strings resolve as Harbor.
    var selectedPalette: PaletteID {
        get { Self.resolvedID(from: storedRaw) }
        set {
            objectWillChange.send()
            storedRaw = newValue.rawValue
        }
    }

    /// Select a palette (same as assigning `selectedPalette`).
    func select(_ id: PaletteID) {
        selectedPalette = id
    }

    /// Re-resolve the full palette for the current SwiftUI color scheme.
    /// Call sites should pass `@Environment(\.colorScheme)` so system light/dark
    /// changes re-resolve immediately.
    func palette(for colorScheme: ColorScheme) -> ConduitPalette {
        ConduitPalette.resolved(id: selectedPalette, colorScheme: colorScheme)
    }

    /// Accent swatch for a palette under the current system scheme (toolbar / Settings).
    func accentSwatch(for id: PaletteID, colorScheme: ColorScheme) -> Color {
        ConduitPalette.resolved(id: id, colorScheme: colorScheme).accent
    }

    private static func resolvedID(from raw: String) -> PaletteID {
        PaletteID(rawValue: raw) ?? .harbor
    }
}
#endif
