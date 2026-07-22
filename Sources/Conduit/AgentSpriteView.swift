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

struct AgentSpriteView: View {
    let profile: AgentProfile
    let state: TerminalVisualState

    private var resolution: AgentSpriteResolution {
        AgentSpriteResolver.resolve(profile)
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
                GenericPixelOperator(state: state)
            }
        }
        .frame(width: 38, height: 44)
        .padding(.horizontal, 2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(state.indicatorColor.opacity(0.08))
        )
        .accessibilityHidden(true)
    }

    private var image: NSImage? {
        guard let skin = resolution.skin else { return nil }
        return AgentSpriteResources.image(skin: skin, pose: state.spritePose)
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
    let state: TerminalVisualState

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
            rect(3, 0, 1, 1, state.indicatorColor)
            rect(3, 1, 1, 1, .secondary)
            rect(1, 2, 6, 4, .secondary.opacity(0.85))
            rect(2, 3, 4, 2, Color(nsColor: .windowBackgroundColor))
            rect(2, 3, 1, 1, state.indicatorColor)
            rect(5, 3, 1, 1, state.indicatorColor)
            rect(0, 4, 1, 2, .secondary)
            rect(7, 4, 1, 2, .secondary)
            rect(2, 6, 1, 2, .secondary)
            rect(5, 6, 1, 2, .secondary)
        }
        .frame(width: 30, height: 30)
    }
}
#endif
