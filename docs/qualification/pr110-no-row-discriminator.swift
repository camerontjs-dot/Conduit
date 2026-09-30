
import Foundation
import ConduitCore
import Darwin
@main struct ConsumerControls {
 static func main() throws {
  let env=ProcessInfo.processInfo.environment
  let binary=URL(fileURLWithPath:env["CONDUIT_MINDGRAPH_QUALIFICATION_BINARY"]!)
  let home=URL(fileURLWithPath:env["CONDUIT_MINDGRAPH_QUALIFICATION_HOME"]!)
  let root=URL(fileURLWithPath:env["QUALIFICATION_CONSUMER_CONTROLS"]!)
  let receipt=URL(fileURLWithPath:env["QUALIFICATION_CONSUMER_RECEIPT"]!)
  var cells:[[String:Any]]=[]
  func persist() throws {try JSONSerialization.data(withJSONObject:cells,options:[.prettyPrinted,.sortedKeys]).write(to:receipt)}
  func query(_ name:String,_ database:URL,_ question:String="MindGraph",lexical:Bool=false) throws -> [String:Any] {
   var invocations:[[String:Any]]=[]
   let payload=MindGraphQuerySupport.sessionQuery(question:question,scope:.operations,binary:binary,database:database,run:{ exe,args,_ in
    let actual=args+(lexical ? ["--lexical-only"] : [])
    let p=Process();let pipe=Pipe();p.executableURL=URL(fileURLWithPath:exe);p.arguments=actual;p.standardOutput=pipe;p.standardError=pipe
    do {try p.run();let d=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();let output=String(decoding:d,as:UTF8.self);invocations.append(["executable":exe,"args":actual,"status":p.terminationStatus,"output":output]);return (p.terminationStatus,output)}
    catch {invocations.append(["error":error.localizedDescription]);return (127,error.localizedDescription)}
   })
   cells.append(["case":name,"database":database.path,"lexical_profile":lexical,"payload":payload,"invocations":invocations]);try persist();return payload
  }
  for name in ["wrong-index","wrong-trust","wrong-path","producer-failed"] {
   let payload=try query(name,root.appendingPathComponent(name+".sqlite"))
   guard payload["error"] != nil,payload["results"] == nil else {print("BLOCK: incompatible identity admitted in \(name)");exit(1)}
  }
  let missing=try query("missing-database",root.appendingPathComponent("absent.sqlite"))
  guard missing["error"] != nil,missing["results"] == nil else {print("BLOCK: missing database accepted");exit(1)}
  // Paired no-row discriminator. Both fixed inputs are observed before its joint disposition.
  let noHit=try query("no-hit-wrong-projects-db",home.appendingPathComponent("mainframe-projects.sqlite"),"zzqualificationnomatch01a0f26e",lexical:true)
  let empty=try query("empty-default-semantic-db",root.appendingPathComponent("empty.sqlite"),"MindGraph")
  guard noHit["error"] == nil,empty["error"] == nil,
        (noHit["results"] as? [[String:Any]])?.isEmpty == true,
        (empty["results"] as? [[String:Any]])?.isEmpty == true else {
   print("INCONCLUSIVE: no-row apparatus did not yield the fixed empty pair");exit(2)
  }
  // No rows means the returned-row guard cannot establish the selected DB's stored identity.
  // The wrong projects DB and an unidentified empty DB were both labeled operations without rejection.
  print("BLOCK: no-hit projects DB and unidentified empty DB returned success, scope=operations, trust_profile=operations_status, zero rows. No database-wide index authority binding was established.")
  exit(1)
 }
}
