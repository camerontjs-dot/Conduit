#if os(macOS)
import ConduitCore
import Foundation

/// One active source-edit buffer for the Context IDE.
///
/// This deliberately mirrors the already-qualified Markdown conflict boundary:
/// disk remains authoritative until an explicit save succeeds, only the exact
/// selected file may be replaced, and external changes force an explicit reload.
@MainActor
final class MainframeSourceEditingSession: ObservableObject {
    @Published var buffer = ""
    @Published private(set) var baseline: String?
    @Published private(set) var relativePath: String?
    @Published private(set) var absolutePath: String?
    @Published private(set) var kind: MainframeSourceKind = .unsupported
    @Published private(set) var permission: MainframeSourceEditPermission = .readOnly(
        kind: .unsupported,
        reason: "No source loaded"
    )
    @Published private(set) var statusMessage: String?
    @Published private(set) var hasConflict = false

    private let writer = MainframeTextFileWriter()

    var hasUnsavedChanges: Bool {
        guard let baseline else { return false }
        return buffer != baseline
    }

    var canEdit: Bool {
        if case .editable = permission { return true }
        return false
    }

    var readOnlyReason: String? {
        if case .readOnly(_, let reason) = permission { return reason }
        return nil
    }

    func load(relativePath: String, absolutePath: String, source: String) {
        self.relativePath = relativePath
        self.absolutePath = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        kind = MainframeSourcePolicy.classify(
            fileName: URL(fileURLWithPath: relativePath).lastPathComponent
        )
        permission = MainframeSourcePolicy.editPermission(
            relativePath: relativePath,
            fileName: URL(fileURLWithPath: relativePath).lastPathComponent
        )
        buffer = source
        baseline = source
        statusMessage = nil
        hasConflict = false
    }

    func clear() {
        relativePath = nil
        absolutePath = nil
        buffer = ""
        baseline = nil
        kind = .unsupported
        permission = .readOnly(kind: .unsupported, reason: "No source loaded")
        statusMessage = nil
        hasConflict = false
    }

    func discard() {
        guard let baseline else { return }
        buffer = baseline
        statusMessage = hasConflict
            ? "Local edits discarded. The file still changed on disk; reload before continuing."
            : "Unsaved changes discarded."
        // Preserve conflict state until authoritative disk content is reloaded.
    }

    @discardableResult
    func replaceAll(find needle: String, replacement: String) -> Int {
        guard canEdit else {
            statusMessage = readOnlyReason ?? "This source is read-only."
            return 0
        }
        guard !needle.isEmpty else { return 0 }
        let count = buffer.components(separatedBy: needle).count - 1
        guard count > 0 else {
            statusMessage = "No matches for \(needle)."
            return 0
        }
        buffer = buffer.replacingOccurrences(of: needle, with: replacement)
        statusMessage = "Replaced \(count) match\(count == 1 ? "" : "es") in the buffer. Save is still required."
        return count
    }

    func noteNavigationBlocked() {
        statusMessage = "Choose Save, Discard or Cancel before closing this source buffer."
    }

    @discardableResult
    func save(root: URL, file: URL) -> Bool {
        guard canEdit else {
            statusMessage = readOnlyReason ?? "This source is read-only."
            return false
        }
        guard let baseline, let absolutePath else {
            statusMessage = "No editable source is loaded."
            return false
        }
        guard file.standardizedFileURL.path == absolutePath else {
            statusMessage = "The selected file no longer matches the edit buffer."
            return false
        }

        do {
            try writer.saveUTF8Text(
                root: root,
                file: file,
                expectedSource: baseline,
                newSource: buffer
            )
            self.baseline = buffer
            statusMessage = "Saved."
            hasConflict = false
            return true
        } catch MainframeTextEditError.conflict {
            statusMessage = "Save blocked: the file changed on disk after this edit began. Your buffer is preserved."
            hasConflict = true
            return false
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
            hasConflict = false
            return false
        }
    }

    @discardableResult
    func reload(root: URL, file: URL, maxBytes: Int = 2_000_000) -> Bool {
        do {
            let source = try MainframeExplorerScanner().readUTF8Text(
                root: root,
                file: file,
                maxBytes: maxBytes
            )
            guard let relativePath else {
                statusMessage = "No source path is loaded."
                return false
            }
            load(
                relativePath: relativePath,
                absolutePath: file.standardizedFileURL.path,
                source: source
            )
            statusMessage = "Reloaded authoritative disk content."
            return true
        } catch {
            statusMessage = "Reload failed: \(error.localizedDescription)"
            return false
        }
    }
}
#endif
