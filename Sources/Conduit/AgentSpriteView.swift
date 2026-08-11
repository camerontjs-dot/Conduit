#if os(macOS)
import AppKit
import ConduitCore
import SwiftUI

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    private var cue: AgentSpriteCue {
        switch presentation {
        case .available:
            return .available
        case .launched(let state):
            return state.spriteCue
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
        .transaction { transaction in
            if !AgentSpriteMotionPolicy.shouldAnimatePoseChange(
                reduceMotion: reduceMotion
            ) {
                transaction.disablesAnimations = true
            }
        }
        .accessibilityHidden(true)
    }

    private var image: NSImage? {
        guard let pose = cue.pose else { return nil }
        return AgentSpriteResources.image(profile: profile, pose: pose)
    }
}

/// Resource-aware half of the insertion seam. It accepts a dedicated skin only
/// when all six files decode and their manifest/provenance entries are present.
/// A partial set therefore falls back atomically instead of changing character
/// as lifecycle poses change.
enum AgentSpriteResources {
    private struct Snapshot {
        let inventory: AgentSpriteResourceInventory
        let images: [AgentSpriteSkin: [AgentSpritePose: NSImage]]
    }

    private static let bundle: Bundle? = {
        let bundleName = "Conduit_Conduit.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName)
        ]
        return candidates.compactMap { $0 }.compactMap(Bundle.init(url:)).first
    }()

    private static let snapshot: Snapshot = makeSnapshot()

    static func artworkResolution(
        for profile: AgentProfile
    ) -> AgentSpriteArtworkResolution {
        AgentSpriteCatalog.artworkResolution(
            for: profile,
            inventory: snapshot.inventory
        )
    }

    static func accessibilityDescription(for profile: AgentProfile) -> String {
        artworkResolution(for: profile)
            .accessibilityDescription(profileName: profile.name)
    }

    static func visibleFallbackLabel(for profile: AgentProfile) -> String? {
        artworkResolution(for: profile).visibleFallbackLabel
    }

    static func image(profile: AgentProfile, pose: AgentSpritePose) -> NSImage? {
        guard case .dedicated(let skin) = artworkResolution(for: profile) else {
            return nil
        }
        return snapshot.images[skin]?[pose]
    }

    private static func makeSnapshot() -> Snapshot {
        guard let bundle else {
            return Snapshot(inventory: .empty, images: [:])
        }

        var readableRelativePaths = Set<String>()
        var candidateImages: [AgentSpriteSkin: [AgentSpritePose: NSImage]] = [:]
        for skin in AgentSpriteSkin.allCases {
            var images: [AgentSpritePose: NSImage] = [:]
            for pose in AgentSpritePose.allCases {
                guard let url = bundle.url(
                    forResource: pose.rawValue,
                    withExtension: "png",
                    subdirectory: "AgentSprites/\(skin.rawValue)"
                ), let image = NSImage(contentsOf: url) else {
                    continue
                }
                images[pose] = image
                readableRelativePaths.insert("\(skin.rawValue)/\(pose.fileName)")
            }
            candidateImages[skin] = images
        }

        let manifestText = textResource(
            name: "SHA256SUMS",
            extension: nil,
            bundle: bundle
        )
        let provenanceText = textResource(
            name: "README",
            extension: "md",
            bundle: bundle
        )
        let inventory = AgentSpriteResourceInventory(
            readableRelativePaths: readableRelativePaths,
            manifestHashes: AgentSpriteHashManifest.parse(manifestText),
            provenanceText: provenanceText
        )

        let completeImages = candidateImages.filter { skin, _ in
            AgentSpriteCatalog.validation(
                for: skin,
                inventory: inventory
            ).isComplete
        }
        return Snapshot(inventory: inventory, images: completeImages)
    }

    private static func textResource(
        name: String,
        extension fileExtension: String?,
        bundle: Bundle
    ) -> String {
        guard let url = bundle.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: "AgentSprites"
        ) else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
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
