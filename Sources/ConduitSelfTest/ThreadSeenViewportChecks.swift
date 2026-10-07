import CoreGraphics
import ConduitCore
import Foundation

func runThreadSeenViewportChecks(_ check: (String, Bool) -> Void) {
    let task = TaskSessionID()
    let eventID = UUID()
    func revision(_ text: String) -> ThreadOutputRevisionIdentity {
        let event = SessionPresentation.agentOutputEvent(
            promptEventID: nil, text: text, extraction: .renderedBuffer,
            truncated: false, id: eventID,
            occurredAt: Date(timeIntervalSince1970: 1_800_100_000)
        )
        guard case .agentOutput(let output) = event.kind else { fatalError("fixture") }
        return ThreadUnseenOutput.revisionIdentity(event: event, output: output)
    }
    let original = revision("alpha")
    let viewport = CGRect(x: 0, y: 100, width: 400, height: 300)
    let tail = CGRect(x: 20, y: 399, width: 360, height: 1)
    func sample(_ rect: CGRect, taskID: TaskSessionID, latest: ThreadOutputRevisionIdentity?)
        -> ThreadOutputRevisionIdentity? {
        ThreadSeenViewport.visibleRevision(
            renderedTaskSessionID: task, currentTaskSessionID: taskID,
            renderedRevision: original, latestRevision: latest,
            tailRect: rect, viewportRect: viewport
        )
    }
    check("viewport binds the exact visible output tail",
          sample(tail, taskID: task, latest: original) == original)
    check("viewport refuses a tail scrolled away",
          sample(tail.offsetBy(dx: 0, dy: 2), taskID: task, latest: original) == nil)
    check("viewport requires full tail containment",
          sample(tail.offsetBy(dx: 0, dy: 0.5), taskID: task, latest: original) == nil)
    check("viewport refuses wrong task with identical output",
          sample(tail, taskID: TaskSessionID(), latest: original) == nil)
    check("viewport refuses same-length changed text under same event ID",
          sample(tail, taskID: task, latest: revision("omega")) == nil)
    check("viewport refuses unavailable current revision",
          sample(tail, taskID: task, latest: nil) == nil)
    check("viewport refuses nonfinite geometry",
          sample(.infinite, taskID: task, latest: original) == nil)
    check("viewport refuses the CoreGraphics infinite sentinel",
          ThreadSeenViewport.visibleRevision(
              renderedTaskSessionID: task, currentTaskSessionID: task,
              renderedRevision: original, latestRevision: original,
              tailRect: tail, viewportRect: .infinite
          ) == nil)
    check("viewport refuses empty geometry",
          sample(.zero, taskID: task, latest: original) == nil)
}
