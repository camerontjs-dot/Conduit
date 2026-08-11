import Foundation

/// App-facing activity presentation derived from the existing terminal
/// controller. This is observed state only; it is not task or verification
/// authority.
public enum TerminalVisualState: String, CaseIterable, Sendable {
    case launching
    case working
    case running
    case detached
    case exited
    case failed

    public var label: String {
        switch self {
        case .launching: return "starting"
        case .working: return "output active"
        case .running: return "running"
        case .detached: return "detached"
        case .exited: return "exited"
        case .failed: return "failed"
        }
    }
}

/// The complete resource vocabulary for one dedicated companion skin.
/// Filenames are deliberately fixed so a future approved set never requires
/// a SwiftUI or layout change.
public enum AgentSpritePose: String, Codable, CaseIterable, Hashable, Sendable {
    case clipboard
    case magnifyingGlass = "magnifying-glass"
    case pointingWarning = "pointing-warning"
    case skeptical
    case shrug
    case sleepingCoffee = "sleeping-coffee"

    public var fileName: String { "\(rawValue).png" }
}

/// Presentation cues remain separate from terminal authority. They describe
/// only an observed lifecycle/activity condition, never task success or intent.
public enum AgentSpriteCue: String, CaseIterable, Sendable {
    case available
    case starting
    case outputActive
    case runningQuiet
    case detached
    case exited
    case failed

    /// Available deliberately has no launched pose. It uses Conduit's neutral
    /// generic character so it cannot be confused with the exited pose.
    public var pose: AgentSpritePose? {
        switch self {
        case .available: return nil
        case .starting: return .clipboard
        case .outputActive: return .magnifyingGlass
        case .runningQuiet: return .skeptical
        case .detached: return .shrug
        case .exited: return .sleepingCoffee
        case .failed: return .pointingWarning
        }
    }

    public var accessibilityPhrase: String {
        switch self {
        case .available: return "Available profile; no session is attached"
        case .starting: return "Starting; attach pending"
        case .outputActive: return "Attached; output active"
        case .runningQuiet: return "Attached; output quiet"
        case .detached: return "Detached; reconnect required"
        case .exited: return "Ended; success is not implied"
        case .failed: return "Failed; inspect Raw"
        }
    }
}

public extension TerminalVisualState {
    /// Poses describe only the terminal lifecycle/activity Conduit can observe.
    /// None represents task completion, validation, or agent intent.
    var spriteCue: AgentSpriteCue {
        switch self {
        case .launching: return .starting
        case .working: return .outputActive
        case .running: return .runningQuiet
        case .detached: return .detached
        case .exited: return .exited
        case .failed: return .failed
        }
    }
}

public enum AgentSpriteSkin: String, Codable, CaseIterable, Hashable, Sendable {
    case claude
    case codex
}

/// Locked companion **master** identities for interim display when a full
/// six-pose runtime set is not yet bundled. Soft-matched by profile name or
/// executable only — never treated as exact six-pose provenance.
public enum AgentCompanionMaster: String, Codable, CaseIterable, Hashable, Sendable {
    case claude
    case codex
    case localShell = "local-shell"
    case grok
    case antigravity
    case opencode
    case geminiCli = "gemini-cli"
    case ollama

    public var resourceDirectory: String { rawValue }

    /// Conservative soft map for display art. Prefer exact name, then executable.
    public static func resolve(for profile: AgentProfile) -> AgentCompanionMaster? {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let executable = URL(fileURLWithPath: profile.command)
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch name {
        case "claude", "claude code": return .claude
        case "codex": return .codex
        case "shell", "local", "local/shell", "zsh": return .localShell
        case "grok": return .grok
        case "antigravity", "agy": return .antigravity
        case "opencode", "open code": return .opencode
        case "gemini", "gemini cli", "gemini-cli": return .geminiCli
        case "ollama": return .ollama
        default: break
        }

        switch executable {
        case "claude": return .claude
        case "codex": return .codex
        case "zsh", "bash", "sh", "fish": return .localShell
        case "grok": return .grok
        case "agy", "antigravity": return .antigravity
        case "opencode": return .opencode
        case "gemini": return .geminiCli
        case "ollama": return .ollama
        default: return nil
        }
    }
}

/// One conservative, provenance-gated identity mapping. Both the full profile
/// name and executable basename must match the same signature.
public struct AgentSpriteRegistration: Equatable, Sendable {
    public let skin: AgentSpriteSkin
    public let profileName: String
    public let executableName: String
    public let provenanceMarker: String

    public init(
        skin: AgentSpriteSkin,
        profileName: String,
        executableName: String,
        provenanceMarker: String
    ) {
        self.skin = skin
        self.profileName = profileName
        self.executableName = executableName
        self.provenanceMarker = provenanceMarker
    }
}

/// Identity-only result retained for callers that need to know whether a
/// profile is registered. Rendering must additionally validate the resource
/// inventory through ``AgentSpriteCatalog/artworkResolution(for:inventory:)``.
public struct AgentSpriteResolution: Equatable, Sendable {
    public let skin: AgentSpriteSkin?
    public let isExactMatch: Bool

    public init(skin: AgentSpriteSkin?, isExactMatch: Bool) {
        self.skin = skin
        self.isExactMatch = isExactMatch
    }
}

public enum AgentSpriteFallbackReason: String, Equatable, Sendable {
    case unmappedIdentity
    case incompleteSet
}

/// Resource-aware result used by the app. A registered identity is still a
/// generic placeholder unless its entire six-pose set is readable, manifested,
/// and named in the provenance record.
public enum AgentSpriteArtworkResolution: Equatable, Sendable {
    case dedicated(AgentSpriteSkin)
    case genericPlaceholder(AgentSpriteFallbackReason)

    public var skin: AgentSpriteSkin? {
        guard case .dedicated(let skin) = self else { return nil }
        return skin
    }

    public var isDedicated: Bool { skin != nil }

    public var visibleFallbackLabel: String? {
        isDedicated ? nil : "generic placeholder companion"
    }

    public func accessibilityDescription(profileName: String) -> String {
        switch self {
        case .dedicated:
            return "Dedicated \(profileName) companion character"
        case .genericPlaceholder(.unmappedIdentity):
            return "Generic placeholder companion; no approved dedicated sprite can be matched to this exact \(profileName) profile identity"
        case .genericPlaceholder(.incompleteSet):
            return "Generic placeholder companion; \(profileName)'s registered sprite set is incomplete or unavailable"
        }
    }
}

/// How companion art was resolved for presentation.
public enum AgentCompanionArtKind: Equatable, Sendable {
    /// Full six-pose exact set.
    case dedicatedPose
    /// Locked master sprite (interim identity; not six-pose complete).
    case lockedMaster(AgentCompanionMaster)
    /// Vector generic robot.
    case genericPlaceholder

    public var visibleLabel: String? {
        switch self {
        case .dedicatedPose: return nil
        case .lockedMaster:
            return "locked master companion (poses pending)"
        case .genericPlaceholder:
            return "generic placeholder companion"
        }
    }

    public func accessibilityDescription(profileName: String) -> String {
        switch self {
        case .dedicatedPose:
            return "Dedicated \(profileName) companion character"
        case .lockedMaster(let master):
            return "\(profileName) locked master companion (\(master.rawValue)); full pose set not yet shipped"
        case .genericPlaceholder:
            return "Generic placeholder companion for \(profileName)"
        }
    }
}

/// The app constructs this from resources that actually decode. Tests can use
/// the same pure value to prove empty, partial, and complete-set behavior.
public struct AgentSpriteResourceInventory: Equatable, Sendable {
    public let readableRelativePaths: Set<String>
    public let manifestHashes: [String: String]
    public let provenanceText: String

    public init(
        readableRelativePaths: Set<String>,
        manifestHashes: [String: String],
        provenanceText: String
    ) {
        self.readableRelativePaths = readableRelativePaths
        self.manifestHashes = manifestHashes
        self.provenanceText = provenanceText
    }

    public static let empty = AgentSpriteResourceInventory(
        readableRelativePaths: [],
        manifestHashes: [:],
        provenanceText: ""
    )
}

public struct AgentSpriteSetValidation: Equatable, Sendable {
    public let missingFiles: [String]
    public let missingHashEntries: [String]
    public let hasProvenanceEntry: Bool

    public var isComplete: Bool {
        missingFiles.isEmpty
            && missingHashEntries.isEmpty
            && hasProvenanceEntry
    }
}

/// Central insertion seam. Adding a future approved skin means adding its skin
/// id and exact signature here, then supplying the six resources, provenance
/// ledger entry, and hashes. Views and layout remain unchanged.
public enum AgentSpriteCatalog {
    public static let provenanceFileName = "README.md"
    public static let hashManifestFileName = "SHA256SUMS"

    public static let registrations: [AgentSpriteRegistration] = [
        AgentSpriteRegistration(
            skin: .claude,
            profileName: "Claude",
            executableName: "claude",
            provenanceMarker: "`claude/`:"
        ),
        AgentSpriteRegistration(
            skin: .claude,
            profileName: "Claude Code",
            executableName: "claude",
            provenanceMarker: "`claude/`:"
        ),
        AgentSpriteRegistration(
            skin: .codex,
            profileName: "Codex",
            executableName: "codex",
            provenanceMarker: "`codex/`:"
        )
    ]

    public static func requiredRelativePaths(for skin: AgentSpriteSkin) -> [String] {
        AgentSpritePose.allCases.map { "\(skin.rawValue)/\($0.fileName)" }
    }

    public static func registration(for profile: AgentProfile) -> AgentSpriteRegistration? {
        let name = exactKey(profile.name)
        let executable = exactKey(URL(fileURLWithPath: profile.command).lastPathComponent)
        let matches = registrations.filter {
            exactKey($0.profileName) == name
                && exactKey($0.executableName) == executable
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    public static func validation(
        for skin: AgentSpriteSkin,
        inventory: AgentSpriteResourceInventory
    ) -> AgentSpriteSetValidation {
        let required = requiredRelativePaths(for: skin)
        let missingFiles = required.filter {
            !inventory.readableRelativePaths.contains($0)
        }
        let missingHashEntries = required.filter {
            inventory.manifestHashes[$0] == nil
        }
        let markers = registrations
            .filter { $0.skin == skin }
            .map(\.provenanceMarker)
        let hasProvenanceEntry = !markers.isEmpty
            && markers.allSatisfy { inventory.provenanceText.contains($0) }
        return AgentSpriteSetValidation(
            missingFiles: missingFiles,
            missingHashEntries: missingHashEntries,
            hasProvenanceEntry: hasProvenanceEntry
        )
    }

    public static func artworkResolution(
        for profile: AgentProfile,
        inventory: AgentSpriteResourceInventory
    ) -> AgentSpriteArtworkResolution {
        guard let registration = registration(for: profile) else {
            return .genericPlaceholder(.unmappedIdentity)
        }
        guard validation(for: registration.skin, inventory: inventory).isComplete else {
            return .genericPlaceholder(.incompleteSet)
        }
        return .dedicated(registration.skin)
    }

    private static func exactKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Parses the existing two-column SHA-256 file without making the product
/// dependent on an asset-generation toolchain.
public enum AgentSpriteHashManifest {
    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var duplicatePaths = Set<String>()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }
            let hash = String(fields[0])
            let path = fields[1].trimmingCharacters(in: .whitespaces)
            let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
            guard hash.count == 64,
                  hash == hash.lowercased(),
                  hash.unicodeScalars.allSatisfy({ hexadecimal.contains($0) }),
                  !path.isEmpty
            else { continue }
            guard result[path] == nil, !duplicatePaths.contains(path) else {
                result.removeValue(forKey: path)
                duplicatePaths.insert(path)
                continue
            }
            result[path] = hash
        }
        return result
    }
}

/// P0 companion swaps are static. Keeping this as a tested policy prevents a
/// future decorative transition from bypassing Reduce Motion by accident.
public enum AgentSpriteMotionPolicy {
    public static func shouldAnimatePoseChange(reduceMotion: Bool) -> Bool {
        false
    }
}

/// Maps only identities backed by an explicit catalog signature. Both name and
/// executable must agree; punctuation, substrings, and conflicting fields fail
/// closed to Conduit's generic placeholder.
public enum AgentSpriteResolver {
    public static func resolve(_ profile: AgentProfile) -> AgentSpriteResolution {
        guard let registration = AgentSpriteCatalog.registration(for: profile) else {
            return AgentSpriteResolution(skin: nil, isExactMatch: false)
        }
        return AgentSpriteResolution(skin: registration.skin, isExactMatch: true)
    }
}
