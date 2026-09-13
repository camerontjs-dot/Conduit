#if os(macOS)
import Foundation
import SwiftUI

/// Backward-compatible entry point retained for RootView.
///
/// Explore v0 grew into one coherent read-only knowledge workspace. Keeping
/// this wrapper avoids widening the global navigation seam while Reader,
/// Graph, and Workstation share one root, selection, and navigation history.
struct MainframeExplorerWorkspaceView: View {
    let root: URL

    var body: some View {
        MainframeKnowledgeWorkspaceView(root: root)
    }
}
#endif
