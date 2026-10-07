import CoreGraphics
import Foundation

/// Geometry and revision binding only. AppKit owns the actual measurement.
/// Rectangles must share the real scroll clip view's coordinate space.
/// This neither persists a cursor nor decides whether a person read anything.
public enum ThreadSeenViewport {
    public static func visibleRevision(
        renderedTaskSessionID: TaskSessionID,
        currentTaskSessionID: TaskSessionID,
        renderedRevision: ThreadOutputRevisionIdentity,
        latestRevision: ThreadOutputRevisionIdentity?,
        tailRect: CGRect,
        viewportRect: CGRect
    ) -> ThreadOutputRevisionIdentity? {
        guard renderedTaskSessionID == currentTaskSessionID,
              renderedRevision == latestRevision,
              renderedRevision.visibleUTF8ByteCount > 0,
              isUsable(tailRect), isUsable(viewportRect),
              viewportRect.contains(tailRect)
        else { return nil }
        return renderedRevision
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        // Do not standardize malformed negative dimensions into valid evidence.
        !rect.isNull && !rect.isInfinite
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.size.width > 0 && rect.size.height > 0
            && rect.maxX.isFinite && rect.maxY.isFinite
    }
}
