#if os(macOS)
import Combine
import ConduitCore
import Foundation

/// The sidebar's low-frequency presentation boundary.
///
/// AppModel remains the authority for task/runtime actions, but the sidebar
/// observes this projection instead of the whole application object. A live
/// conversation revision therefore has no path to invalidate this model.
@MainActor
final class TaskSidebarModel: ObservableObject {
    struct State: Equatable {
        let taskSessions: [TaskSessionSnapshot]
        let taskCatalogRows: [TaskSessionCatalogRow]
        let resumableSessions: [ResumableSession]
        let projects: [MainframeProject]
        let taskSessionDiagnostics: [TaskSessionEventLogDiagnostic]
        let selectedTaskSessionID: TaskSessionID?
        let taskSearchText: String
        let showArchivedTasks: Bool
        let taskScopeProjectID: String?
        let taskSearchFocusRequest: Int
        let density: Density
        let juicyFeedbackEnabled: Bool
        let companionScale: CompanionScale
        let companionShelfEnabled: Bool
        let railSpritesForAllRows: Bool
        let outputActivePulseEnabled: Bool
        let rootAccessNeedsAuthorization: Bool
        let isScanningProjects: Bool

        init(
            taskSessions: [TaskSessionSnapshot] = [],
            taskCatalogRows: [TaskSessionCatalogRow] = [],
            resumableSessions: [ResumableSession] = [],
            projects: [MainframeProject] = [],
            taskSessionDiagnostics: [TaskSessionEventLogDiagnostic] = [],
            selectedTaskSessionID: TaskSessionID? = nil,
            taskSearchText: String = "",
            showArchivedTasks: Bool = false,
            taskScopeProjectID: String? = nil,
            taskSearchFocusRequest: Int = 0,
            density: Density = .focused,
            juicyFeedbackEnabled: Bool = true,
            companionScale: CompanionScale = .standard,
            companionShelfEnabled: Bool = true,
            railSpritesForAllRows: Bool = false,
            outputActivePulseEnabled: Bool = true,
            rootAccessNeedsAuthorization: Bool = false,
            isScanningProjects: Bool = false
        ) {
            self.taskSessions = taskSessions
            self.taskCatalogRows = taskCatalogRows
            self.resumableSessions = resumableSessions
            self.projects = projects
            self.taskSessionDiagnostics = taskSessionDiagnostics
            self.selectedTaskSessionID = selectedTaskSessionID
            self.taskSearchText = taskSearchText
            self.showArchivedTasks = showArchivedTasks
            self.taskScopeProjectID = taskScopeProjectID
            self.taskSearchFocusRequest = taskSearchFocusRequest
            self.density = density
            self.juicyFeedbackEnabled = juicyFeedbackEnabled
            self.companionScale = companionScale
            self.companionShelfEnabled = companionShelfEnabled
            self.railSpritesForAllRows = railSpritesForAllRows
            self.outputActivePulseEnabled = outputActivePulseEnabled
            self.rootAccessNeedsAuthorization = rootAccessNeedsAuthorization
            self.isScanningProjects = isScanningProjects
        }
    }

    @Published private(set) var state = State()

    /// Runtime references are needed only for presentation-only companion
    /// state. They are refreshed on session topology changes, never on a
    /// runtime's high-frequency presentation revision.
    private(set) var sessions: [TerminalRuntime] = []
    private var sessionIDs: [UUID] = []

    var taskSessions: [TaskSessionSnapshot] { state.taskSessions }
    var taskCatalogRows: [TaskSessionCatalogRow] { state.taskCatalogRows }
    var resumableSessions: [ResumableSession] { state.resumableSessions }
    var projects: [MainframeProject] { state.projects }
    var taskSessionDiagnostics: [TaskSessionEventLogDiagnostic] {
        state.taskSessionDiagnostics
    }
    var selectedTaskSessionID: TaskSessionID? {
        state.selectedTaskSessionID
    }
    var taskSearchText: String { state.taskSearchText }
    var showArchivedTasks: Bool { state.showArchivedTasks }
    var taskScopeProjectID: String? { state.taskScopeProjectID }
    var taskSearchFocusRequest: Int { state.taskSearchFocusRequest }
    var density: Density { state.density }
    var juicyFeedbackEnabled: Bool { state.juicyFeedbackEnabled }
    var companionScale: CompanionScale { state.companionScale }
    var companionShelfEnabled: Bool { state.companionShelfEnabled }
    var railSpritesForAllRows: Bool { state.railSpritesForAllRows }
    var outputActivePulseEnabled: Bool { state.outputActivePulseEnabled }
    var rootAccessNeedsAuthorization: Bool {
        state.rootAccessNeedsAuthorization
    }
    var isScanningProjects: Bool { state.isScanningProjects }

    /// Refresh only after a state mutation that can affect sidebar output.
    /// Conversation presentation revisions are intentionally not an input.
    func refresh(from appModel: AppModel) {
        let nextState = State(
            taskSessions: appModel.taskSessions,
            taskCatalogRows: appModel.taskCatalogRows,
            resumableSessions: appModel.resumableSessions,
            projects: appModel.projects,
            taskSessionDiagnostics: appModel.taskSessionDiagnostics,
            selectedTaskSessionID: appModel.selectedTaskSessionID,
            taskSearchText: appModel.taskSearchText,
            showArchivedTasks: appModel.showArchivedTasks,
            taskScopeProjectID: appModel.taskScopeProjectID,
            taskSearchFocusRequest: appModel.taskSearchFocusRequest,
            density: appModel.density,
            juicyFeedbackEnabled: appModel.juicyFeedbackEnabled,
            companionScale: appModel.companionScale,
            companionShelfEnabled: appModel.companionShelfEnabled,
            railSpritesForAllRows: appModel.railSpritesForAllRows,
            outputActivePulseEnabled: appModel.outputActivePulseEnabled,
            rootAccessNeedsAuthorization: appModel.rootAccessNeedsAuthorization,
            isScanningProjects: appModel.isScanningProjects
        )
        let nextSessionIDs = appModel.sessions.map(\.id)
        let stateChanged = state != nextState
        let sessionsChanged = sessionIDs != nextSessionIDs
        guard stateChanged || sessionsChanged else { return }

        if sessionsChanged {
            sessions = appModel.sessions
            sessionIDs = nextSessionIDs
        }
        if stateChanged {
            state = nextState
        } else {
            // No @Published field represents the runtime references above.
            // Publish exactly once when session topology changes.
            objectWillChange.send()
        }
    }
}
#endif
