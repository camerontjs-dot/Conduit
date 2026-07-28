#if os(macOS)
import AppKit
import ConduitCore
import SwiftUI

enum AgentSpritePose: String, CaseIterable {
    case clipboard
    case magnifyingGlass = "magnifying-glass"
    case pointingWarning = "pointing-warning"
    case shrug
    case skeptical
    case sleepingCoffee = "sleeping-coffee"
}

extension TerminalVisualState {
    /// Poses describe only the terminal lifecycle Conduit can observe. None of
    /// these represents task completion, validation, or agent intent.
    var spritePose: AgentSpritePose {
        switch self {
        case .launching: return .clipboard
        case .working: return .magnifyingGlass
        case .running: return .skeptical
        case .detached: return .shrug
        case .exited: return .sleepingCoffee
        case .failed: return .pointingWarning
        }
    }
}

/// Explicit seat/sprite presentation. Keeps unlaunched agents off the
/// `TerminalVisualState` enum so "available" never masquerades as ready/running.
enum AgentSpritePresentation: Equatable {
    /// Enabled agent with no matching project runtime. Neutral inactive look only.
    case available
    /// Matching runtime; pose and mark follow observed terminal state only.
    case launched(TerminalVisualState)
}

struct AgentSpriteView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let profile: AgentProfile
    let presentation: AgentSpritePresentation
    /// Default matches the session-pill chrome; operator seats pass a smaller size.
    var frameSize: CGSize = CGSize(width: 38, height: 44)

    init(
        profile: AgentProfile,
        state: TerminalVisualState,
        frameSize: CGSize = CGSize(width: 38, height: 44)
    ) {
        self.profile = profile
        self.presentation = .launched(state)
        self.frameSize = frameSize
    }

    init(
        profile: AgentProfile,
        presentation: AgentSpritePresentation,
        frameSize: CGSize = CGSize(width: 38, height: 44)
    ) {
        self.profile = profile
        self.presentation = presentation
        self.frameSize = frameSize
    }

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var resolution: AgentSpriteResolution {
        AgentSpriteResolver.resolve(profile)
    }

    /// Available uses the idle sleeping pose without claiming an exited runtime.
    private var pose: AgentSpritePose {
        switch presentation {
        case .available:
            return .sleepingCoffee
        case .launched(let state):
            return state.spritePose
        }
    }

    /// Lifecycle mark for the generic fallback and soft background wash.
    /// Available uses faint — never the ready/running ramp entry.
    private var markColor: Color {
        switch presentation {
        case .available:
            return palette.faint
        case .launched(let state):
            return palette.color(forTerminalState: state)
        }
    }

    private var washOpacity: Double {
        switch presentation {
        case .available: return 0.04
        case .launched: return 0.08
        }
    }

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .antialiased(false)
                    .scaledToFit()
            } else {
                GenericPixelOperator(mark: markColor, palette: palette, side: min(frameSize.width, frameSize.height) * 0.78)
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .padding(.horizontal, 2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(markColor.opacity(washOpacity))
        )
        .accessibilityHidden(true)
    }

    private var image: NSImage? {
        guard let skin = resolution.skin else { return nil }
        return AgentSpriteResources.image(skin: skin, pose: pose)
    }
}

private enum AgentSpriteResources {
    private static let cache = NSCache<NSString, NSImage>()

    static let bundle: Bundle? = {
        let bundleName = "Conduit_Conduit.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName)
        ]
        return candidates.compactMap { $0 }.compactMap(Bundle.init(url:)).first
    }()

    static func image(skin: AgentSpriteSkin, pose: AgentSpritePose) -> NSImage? {
        let key = "\(skin.rawValue)/\(pose.rawValue)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let url = bundle?.url(
            forResource: pose.rawValue,
            withExtension: "png",
            subdirectory: "AgentSprites/\(skin.rawValue)"
        ), let image = NSImage(contentsOf: url) else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

private struct GenericPixelOperator: View {
    let mark: Color
    let palette: ConduitPalette
    var side: CGFloat = 30

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width / 8, size.height / 8)
            func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: Color) {
                context.fill(
                    Path(CGRect(
                        x: CGFloat(x) * unit,
                        y: CGFloat(y) * unit,
                        width: CGFloat(w) * unit,
                        height: CGFloat(h) * unit
                    )),
                    with: .color(color)
                )
            }
            rect(3, 0, 1, 1, mark)
            rect(3, 1, 1, 1, palette.dim)
            rect(1, 2, 6, 4, palette.dim.opacity(0.85))
            rect(2, 3, 4, 2, palette.surface)
            rect(2, 3, 1, 1, mark)
            rect(5, 3, 1, 1, mark)
            rect(0, 4, 1, 2, palette.dim)
            rect(7, 4, 1, 2, palette.dim)
            rect(2, 6, 1, 2, palette.dim)
            rect(5, 6, 1, 2, palette.dim)
        }
        .frame(width: side, height: side)
    }
}
#endif
