import Foundation

/// Bounded, ordered window over the durable task inventory.
///
/// `conduit_list_sessions` used to return the first 40 tasks with no total, no
/// cursor, and no ordering guarantee, so a caller could not tell a complete
/// inventory from a truncated one, and the tasks it lost were whichever
/// identifiers happened to sort late. Ordering and paging live here, pure and
/// testable, and reuse the cursor convention `conduit_session_events` already
/// established rather than inventing a second one.
public enum ConduitSessionListPage {
    public static let defaultLimit = 40
    public static let maxLimit = 200
    public static let authorityNote =
        "observed task inventory ordered by last recorded activity, newest first; not verification"

    public static func clampLimit(_ limit: Int?) -> Int {
        guard let limit else { return defaultLimit }
        if limit < 1 { return defaultLimit }
        return min(limit, maxLimit)
    }

    public struct Window: Equatable, Sendable {
        public let startIndex: Int
        public let endIndex: Int
        public let total: Int
        public let nextCursor: String
        public let hasMore: Bool
        public let cursorState: ConduitSessionEventCursorState

        public var count: Int { max(0, endIndex - startIndex) }

        public init(
            startIndex: Int,
            endIndex: Int,
            total: Int,
            nextCursor: String,
            hasMore: Bool,
            cursorState: ConduitSessionEventCursorState
        ) {
            self.startIndex = startIndex
            self.endIndex = endIndex
            self.total = total
            self.nextCursor = nextCursor
            self.hasMore = hasMore
            self.cursorState = cursorState
        }
    }

    /// A cursor past the end is stale (`ahead`), not an error, matching the
    /// event page. An unparseable cursor restarts at the beginning and says so.
    public static func window(
        total: Int,
        cursor: String? = nil,
        limit: Int? = nil
    ) -> Window {
        let parsed = ConduitSessionEventExport.parseCursor(cursor)
        let bounded = max(0, total)
        let pageLimit = clampLimit(limit)
        var cursorState = parsed.state
        var start = parsed.index

        if parsed.state == .ok, start > bounded {
            cursorState = .ahead
            start = bounded
        } else if parsed.state == .ok {
            start = min(start, bounded)
        } else {
            start = 0
        }

        let end = min(bounded, start + pageLimit)
        return Window(
            startIndex: start,
            endIndex: end,
            total: bounded,
            nextCursor: ConduitSessionEventExport.encodeCursor(end),
            hasMore: end < bounded,
            cursorState: cursorState
        )
    }
}
