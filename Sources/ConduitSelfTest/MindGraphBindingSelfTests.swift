import ConduitCore
import Foundation

func mindGraphBindingSelfTests() -> [(String, Bool)] {
    let name = "conduit_expand_mindgraph_nomination"
    let handle = "exp2:eyJjaHVua19pbmRleCI6MCwiY29udGVudF9oYXNoIjoic2FtZS1oYXNoIiwiZG9jX2lkIjoic2FtZS1kb2MiLCJpbmRleF9pZCI6ImluZGV4LWEiLCJuYW1lc3BhY2UiOiJub3RlcyIsInBhdGgiOiJhLm1kIiwic2NvcGUiOiJrbm93bGVkZ2UiLCJ2IjoiZXhwMiJ9"
    return [
        ("MindGraph published expansion appears exactly once", ConduitSessionToolCatalog.tools().filter { $0["name"] as? String == name }.count == 1),
        ("MindGraph expansion is a read tool", ConduitSessionToolCatalog.readToolNames.contains(name) && !ConduitSessionToolCatalog.writeToolNames.contains(name)),
        ("MindGraph origin scope rejects cross-route expansion", (try? MindGraphExpansionBinding.validateRequest(handle, scope: "projects")) == nil),
        ("MindGraph explicit matching scope parses", (try? MindGraphExpansionBinding.validateRequest(handle, scope: "knowledge")) != nil),
    ]
}
