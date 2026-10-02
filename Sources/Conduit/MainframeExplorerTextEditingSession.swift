#if os(macOS)
import Combine
import ConduitCore
import Foundation

/// One active, UI-local text buffer. The existing exact-file writer owns save.
@MainActor
final class MainframeExplorerTextEditingSession: ObservableObject {
    @Published private(set) var document: MainframeExplorerTextDocument?
    @Published private(set) var statusMessage: String?
    @Published private(set) var hasConflict = false
    @Published private(set) var readOnlyReason: String?
    @Published private(set) var diskComparison: String?
    private var loadedNode: MainframeExplorerNode?
    private let writer = MainframeTextFileWriter()

    var buffer: String {
        get { document?.buffer ?? "" }
        set {
            if document?.updateBuffer(newValue) == false {
                statusMessage = "Edit not applied: the buffer exceeds the 2,000,000-byte limit."
            }
        }
    }
    var baseline: String? { document?.baseline }
    var relativePath: String? { document?.relativePath }
    var absolutePath: String? { document?.absolutePath }
    var hasUnsavedChanges: Bool { document?.hasUnsavedChanges ?? false }
    var canUndo: Bool { document?.canUndo ?? false }
    var canRedo: Bool { document?.canRedo ?? false }
    var isEditable: Bool { document != nil }

    func load(node: MainframeExplorerNode, source: String) {
        loadedNode = node
        hasConflict = false
        diskComparison = nil
        statusMessage = nil
        do {
            let permissions = try FileManager.default.attributesOfItem(atPath: node.url.path)[.posixPermissions] as? NSNumber
            let writable = FileManager.default.isWritableFile(atPath: node.url.path) && ((permissions?.intValue ?? 0) & 0o222) != 0
            document = try MainframeExplorerTextDocument(node: node, source: source, isWritable: writable)
            readOnlyReason = nil
        } catch {
            document = nil
            readOnlyReason = error.localizedDescription
        }
    }

    func clear() {
        loadedNode = nil
        document = nil
        statusMessage = nil
        readOnlyReason = nil
        hasConflict = false
        diskComparison = nil
    }

    func discard() {
        document?.revert()
        statusMessage = hasConflict
            ? "Unsaved changes discarded. The disk file changed; reload it before continuing."
            : "Unsaved changes discarded."
    }

    func undo() { document?.undo() }
    func redo() { document?.redo() }

    func matchCount(_ query: String) -> String {
        guard !query.isEmpty, let document else { return "Literal search · up to 500 matches" }
        do { return "\(try document.literalMatchCount(query)) literal matches" }
        catch { return error.localizedDescription }
    }

    func replace(_ query: String, with replacement: String, all: Bool) {
        do {
            let count = try document?.replaceLiteral(query, with: replacement, all: all) ?? 0
            statusMessage = "Replaced \(count) literal match\(count == 1 ? "" : "es") in the buffer. Save explicitly to change the disk file."
        } catch { statusMessage = error.localizedDescription }
    }

    func noteNavigationBlocked() {
        statusMessage = "Choose Save, Discard or Cancel before leaving this buffer."
    }

    func noteExternalChange(_ message: String? = nil) {
        hasConflict = true
        statusMessage = message ?? "The disk file changed. Your buffer is preserved; compare or reload before saving."
    }

    func refreshCleanBufferFromDisk(_ source: String) {
        guard !hasUnsavedChanges, let loadedNode else { noteExternalChange(); return }
        load(node: loadedNode, source: source)
        statusMessage = "Reloaded after an observed external file change."
    }

    func compareWithDisk(root: URL) {
        guard let loadedNode else { return }
        do {
            diskComparison = try MainframeExplorerPreviewLoader().readUTF8Text(root: root, node: loadedNode)
            statusMessage = "Comparison is read-only. Your buffer and disk file are unchanged."
        } catch { diskComparison = nil; statusMessage = "Comparison unavailable: \(error.localizedDescription)" }
    }

    @discardableResult
    func save(root: URL, file: URL) -> Bool {
        guard let document, let loadedNode, file.standardizedFileURL.path == document.absolutePath else {
            statusMessage = "The selected file does not match an eligible edit buffer."
            return false
        }
        do {
            _ = try MainframeExplorerPreviewLoader().readUTF8Text(root: root, node: loadedNode)
            let source = try document.sourceForSave()
            try writer.saveUTF8Text(root: root, file: file, expectedSource: document.baseline, newSource: source)
            self.document?.noteSaved(source)
            statusMessage = "Saved explicitly · UTF-8 · \(document.lineEnding.rawValue)."
            hasConflict = false
            diskComparison = nil
            return true
        } catch MainframeTextEditError.conflict {
            statusMessage = "Save blocked: the disk bytes changed. Your buffer is preserved."
            hasConflict = true
            return false
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription). Your buffer is preserved."
            return false
        }
    }
}
#endif
