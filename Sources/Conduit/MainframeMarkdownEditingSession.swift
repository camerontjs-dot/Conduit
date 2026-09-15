#if os(macOS)
import ConduitCore
import Foundation

/// UI-local edit state. The file on disk remains authoritative until an
/// explicit save succeeds through `MainframeTextFileWriter`.
@MainActor
final class MainframeMarkdownEditingSession: ObservableObject {
    @Published var buffer = ""
    @Published private(set) var baseline: String?
    @Published private(set) var relativePath: String?
    @Published private(set) var absolutePath: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var hasConflict = false

    private let writer = MainframeTextFileWriter()

    var hasUnsavedChanges: Bool {
        guard let baseline else { return false }
        return buffer != baseline
    }

    func load(relativePath: String, absolutePath: String, source: String) {
        self.relativePath = relativePath
        self.absolutePath = absolutePath
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
        statusMessage = nil
        hasConflict = false
    }

    func discard() {
        guard let baseline else { return }
        buffer = baseline
        statusMessage = "Unsaved changes discarded."
        hasConflict = false
    }

    func noteNavigationBlocked() {
        statusMessage = "Save or discard the current edit before navigating away."
    }

    @discardableResult
    func save(root: URL, file: URL) -> Bool {
        guard let baseline, let absolutePath else {
            statusMessage = "No editable Markdown source is loaded."
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
}
#endif
