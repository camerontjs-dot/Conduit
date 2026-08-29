import AppKit
import CryptoKit
import XCTest
@testable import ConduitCore

final class AgentSpriteCatalogTests: XCTestCase {
    func testCanonicalPoseFilenamesAreCompleteAndUnique() {
        XCTAssertEqual(
            AgentSpritePose.allCases.map(\.fileName),
            [
                "clipboard.png",
                "magnifying-glass.png",
                "pointing-warning.png",
                "skeptical.png",
                "shrug.png",
                "sleeping-coffee.png"
            ]
        )
        XCTAssertEqual(Set(AgentSpritePose.allCases.map(\.fileName)).count, 6)
    }

    func testLifecycleCuesResolveToTruthBoundPoses() {
        XCTAssertNil(AgentSpriteCue.available.pose)
        XCTAssertEqual(AgentSpriteCue.starting.pose, .clipboard)
        XCTAssertEqual(AgentSpriteCue.outputActive.pose, .magnifyingGlass)
        XCTAssertEqual(AgentSpriteCue.runningQuiet.pose, .skeptical)
        XCTAssertEqual(AgentSpriteCue.detached.pose, .shrug)
        XCTAssertEqual(AgentSpriteCue.exited.pose, .sleepingCoffee)
        XCTAssertEqual(AgentSpriteCue.failed.pose, .pointingWarning)

        XCTAssertNotEqual(
            AgentSpriteCue.available.accessibilityPhrase,
            AgentSpriteCue.exited.accessibilityPhrase
        )
        XCTAssertNotEqual(
            AgentSpriteCue.detached.accessibilityPhrase,
            AgentSpriteCue.failed.accessibilityPhrase
        )
        XCTAssertTrue(
            AgentSpriteCue.exited.accessibilityPhrase.contains("success is not implied")
        )
    }

    func testTerminalVisualStatesBridgeToTheExpectedCueAndPose() {
        let expected: [(TerminalVisualState, AgentSpriteCue, AgentSpritePose)] = [
            (.launching, .starting, .clipboard),
            (.working, .outputActive, .magnifyingGlass),
            (.running, .runningQuiet, .skeptical),
            (.detached, .detached, .shrug),
            (.exited, .exited, .sleepingCoffee),
            (.failed, .failed, .pointingWarning)
        ]

        XCTAssertEqual(expected.count, TerminalVisualState.allCases.count)
        for (state, cue, pose) in expected {
            XCTAssertEqual(state.spriteCue, cue)
            XCTAssertEqual(state.spriteCue.pose, pose)
        }
    }

    func testExactSignaturesRequireMatchingNameAndExecutable() {
        for profile in [
            AgentProfile(name: "Claude", command: "claude"),
            AgentProfile(name: "Claude Code", command: "/opt/bin/claude"),
            AgentProfile(name: " codex ", command: "/usr/local/bin/CODEX")
        ] {
            XCTAssertTrue(AgentSpriteResolver.resolve(profile).isExactMatch)
        }

        for profile in [
            AgentProfile(name: "Codex", command: "custom-agent"),
            AgentProfile(name: "Custom", command: "codex"),
            AgentProfile(name: "Co-dex", command: "codex"),
            AgentProfile(name: "Codexish", command: "codex"),
            AgentProfile(name: "Claude", command: "claude-beta"),
            AgentProfile(name: "Codex", command: "claude")
        ] {
            XCTAssertEqual(
                AgentSpriteResolver.resolve(profile),
                AgentSpriteResolution(skin: nil, isExactMatch: false)
            )
        }
    }

    func testEightOtherBuiltInsRemainGeneric() {
        let dedicatedNames = Set(["Claude", "Codex"])
        let genericProfiles = AgentProfile.defaults.filter {
            !dedicatedNames.contains($0.name)
        }
        XCTAssertEqual(genericProfiles.count, 8)
        for profile in genericProfiles {
            XCTAssertEqual(
                AgentSpriteResolver.resolve(profile),
                AgentSpriteResolution(skin: nil, isExactMatch: false),
                "\(profile.name) must remain generic until an approved set is registered"
            )
        }
    }

    func testCompleteInventoryEnablesDedicatedArtwork() {
        let inventory = completeInventory(for: .codex)
        XCTAssertEqual(
            AgentSpriteCatalog.artworkResolution(
                for: AgentProfile(name: "Codex", command: "codex"),
                inventory: inventory
            ),
            .dedicated(.codex)
        )
    }

    func testEveryOneFileMissingPermutationFallsBackAtomically() {
        let profile = AgentProfile(name: "Claude", command: "claude")
        let required = AgentSpriteCatalog.requiredRelativePaths(for: .claude)
        for missingPath in required {
            var inventory = completeInventory(for: .claude)
            inventory = AgentSpriteResourceInventory(
                readableRelativePaths: inventory.readableRelativePaths
                    .subtracting([missingPath]),
                manifestHashes: inventory.manifestHashes,
                provenanceText: inventory.provenanceText
            )
            XCTAssertEqual(
                AgentSpriteCatalog.artworkResolution(
                    for: profile,
                    inventory: inventory
                ),
                .genericPlaceholder(.incompleteSet),
                "Missing \(missingPath) must reject the entire set"
            )
        }
    }

    func testEmptyMissingHashAndMissingProvenanceInventoriesFallBack() {
        let profile = AgentProfile(name: "Codex", command: "codex")
        XCTAssertEqual(
            AgentSpriteCatalog.artworkResolution(
                for: profile,
                inventory: .empty
            ),
            .genericPlaceholder(.incompleteSet)
        )

        let complete = completeInventory(for: .codex)
        let claudeMarker = AgentSpriteCatalog.registrations
            .first(where: { $0.skin == .claude })!
            .provenanceMarker
        XCTAssertEqual(
            AgentSpriteCatalog.artworkResolution(
                for: profile,
                inventory: AgentSpriteResourceInventory(
                    readableRelativePaths: complete.readableRelativePaths,
                    manifestHashes: complete.manifestHashes,
                    provenanceText: claudeMarker
                )
            ),
            .genericPlaceholder(.incompleteSet)
        )

        let missingHashPath = AgentSpriteCatalog.requiredRelativePaths(for: .codex)[0]
        var hashes = complete.manifestHashes
        hashes.removeValue(forKey: missingHashPath)
        XCTAssertEqual(
            AgentSpriteCatalog.artworkResolution(
                for: profile,
                inventory: AgentSpriteResourceInventory(
                    readableRelativePaths: complete.readableRelativePaths,
                    manifestHashes: hashes,
                    provenanceText: complete.provenanceText
                )
            ),
            .genericPlaceholder(.incompleteSet)
        )
        XCTAssertEqual(
            AgentSpriteCatalog.artworkResolution(
                for: profile,
                inventory: AgentSpriteResourceInventory(
                    readableRelativePaths: complete.readableRelativePaths,
                    manifestHashes: complete.manifestHashes,
                    provenanceText: ""
                )
            ),
            .genericPlaceholder(.incompleteSet)
        )
    }

    func testAccessibilityDescriptionsDiscloseDedicatedAndFallbackArtwork() {
        XCTAssertEqual(
            AgentSpriteArtworkResolution.dedicated(.claude)
                .accessibilityDescription(profileName: "Claude"),
            "Dedicated Claude companion character"
        )
        XCTAssertEqual(
            AgentSpriteArtworkResolution.genericPlaceholder(.unmappedIdentity)
                .accessibilityDescription(profileName: "Grok"),
            "Generic placeholder companion; no approved dedicated sprite can be matched to this exact Grok profile identity"
        )
        XCTAssertEqual(
            AgentSpriteArtworkResolution.genericPlaceholder(.incompleteSet)
                .accessibilityDescription(profileName: "Codex"),
            "Generic placeholder companion; Codex's registered sprite set is incomplete or unavailable"
        )
    }

    func testPoseChangesRemainImmediateWithAndWithoutReduceMotion() {
        XCTAssertFalse(
            AgentSpriteMotionPolicy.shouldAnimatePoseChange(reduceMotion: false)
        )
        XCTAssertFalse(
            AgentSpriteMotionPolicy.shouldAnimatePoseChange(reduceMotion: true)
        )
    }

    func testHashManifestParserRejectsMalformedEntries() {
        let hash = String(repeating: "a", count: 64)
        let uppercaseHash = String(repeating: "A", count: 64)
        let parsed = AgentSpriteHashManifest.parse("""
        # comment
        \(hash)  codex/clipboard.png
        short  codex/shrug.png
        \(uppercaseHash)  codex/skeptical.png
        \(hash)  codex/shrug.png
        \(hash)  codex/shrug.png
        \(hash)
        """)
        XCTAssertEqual(parsed, ["codex/clipboard.png": hash])
    }

    private func completeInventory(
        for skin: AgentSpriteSkin
    ) -> AgentSpriteResourceInventory {
        let paths = AgentSpriteCatalog.requiredRelativePaths(for: skin)
        let marker = AgentSpriteCatalog.registrations
            .first(where: { $0.skin == skin })!
            .provenanceMarker
        return AgentSpriteResourceInventory(
            readableRelativePaths: Set(paths),
            manifestHashes: Dictionary(
                uniqueKeysWithValues: paths.map {
                    ($0, String(repeating: "a", count: 64))
                }
            ),
            provenanceText: marker
        )
    }
}

final class AgentSpriteBundledResourceTests: XCTestCase {
    func testRegisteredSourceSetsAreCompleteManifestedAndDecodable() throws {
        let root = resourceRoot
        let provenance = try String(
            contentsOf: root.appendingPathComponent(
                AgentSpriteCatalog.provenanceFileName
            ),
            encoding: .utf8
        )
        let manifestText = try String(
            contentsOf: root.appendingPathComponent(
                AgentSpriteCatalog.hashManifestFileName
            ),
            encoding: .utf8
        )
        let manifest = AgentSpriteHashManifest.parse(manifestText)

        // Both asset classes ship and both render, so both are pinned: the
        // six-pose runtime sets and the one-file-per-identity display masters.
        var readablePaths = Set<String>()
        let actualPNGPaths = try allPNGRelativePaths(in: root)
        for relativePath in AgentSpriteCatalog.manifestedRelativePaths {
            let url = root.appendingPathComponent(relativePath)
            let data = try Data(contentsOf: url)
            XCTAssertNotNil(NSImage(contentsOf: url), "Cannot decode \(relativePath)")
            let bitmap = NSBitmapImageRep(data: data)
            XCTAssertNotNil(bitmap, "Cannot decode bitmap data for \(relativePath)")
            XCTAssertEqual(bitmap?.hasAlpha, true, "Alpha channel missing for \(relativePath)")
            readablePaths.insert(relativePath)
            XCTAssertEqual(
                manifest[relativePath],
                sha256Hex(data),
                "Hash drift for \(relativePath)"
            )
        }

        let inventory = AgentSpriteResourceInventory(
            readableRelativePaths: readablePaths,
            manifestHashes: manifest,
            provenanceText: provenance
        )
        for skin in AgentSpriteSkin.allCases {
            XCTAssertTrue(
                AgentSpriteCatalog.validation(
                    for: skin,
                    inventory: inventory
                ).isComplete,
                "\(skin.rawValue) must remain an atomic six-pose set"
            )
        }
        XCTAssertEqual(Set(manifest.keys), actualPNGPaths)
        XCTAssertEqual(actualPNGPaths, Set(AgentSpriteCatalog.manifestedRelativePaths))
        XCTAssertEqual(
            actualPNGPaths.count,
            AgentSpriteSkin.allCases.count * AgentSpritePose.allCases.count
                + AgentCompanionMaster.allCases.count
        )
        XCTAssertEqual(
            Set(AgentSpriteCatalog.registrations.map(\.skin)),
            Set(AgentSpriteSkin.allCases)
        )

        // Every built-in identity has master art, and no master is ever mistaken
        // for part of a six-pose set. That distinction is the reason a master
        // may not claim lifecycle completion.
        let poseSetPaths = Set(
            AgentSpriteSkin.allCases.flatMap {
                AgentSpriteCatalog.requiredRelativePaths(for: $0)
            }
        )
        for master in AgentCompanionMaster.allCases {
            let path = AgentSpriteCatalog.masterRelativePath(for: master)
            XCTAssertTrue(
                actualPNGPaths.contains(path),
                "Missing bundled master art for \(master.rawValue)"
            )
            XCTAssertFalse(
                poseSetPaths.contains(path),
                "\(path) must not count as part of a six-pose runtime set"
            )
        }
    }

    private var resourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Conduit/Resources/AgentSprites")
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func allPNGRelativePaths(in root: URL) throws -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var paths = Set<String>()
        for case let url as URL in enumerator
        where url.pathExtension.lowercased() == "png" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relativeComponents = url.pathComponents.dropFirst(root.pathComponents.count)
            paths.insert(relativeComponents.joined(separator: "/"))
        }
        return paths
    }
}
