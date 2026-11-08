import Foundation
import ConduitCore
#if canImport(Virtualization)
import Virtualization
#endif

func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value)); FileHandle.standardOutput.write(Data("\n".utf8))
}
func input(_ path: String) throws -> Data {
    try ConduitOfflinePreparation.readSampleInput(atPath: path)
}

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "stage" where args.count == 3:
        try emit(ConduitOfflineWorkspace.stage(sourceRoot: URL(fileURLWithPath: args[1]), stagedRoot: URL(fileURLWithPath: args[2])))
    case "manifest" where args.count == 2:
        try emit(ConduitOfflineWorkspace.manifest(stagedRoot: URL(fileURLWithPath: args[1])))
    case "export-input" where args.count == 3:
        try emit(ConduitOfflineWorkspace.exportInput(stagedRoot: URL(fileURLWithPath: args[1]), destination: URL(fileURLWithPath: args[2])))
    case "inspect" where args.count == 3:
        let text = try ConduitOfflineWorkspace.inspect(stagedRoot: URL(fileURLWithPath: args[1]), relativePath: args[2])
        try emit(["status": "observed", "text": text])
    case "search" where args.count == 3:
        try emit(ConduitOfflineWorkspace.search(stagedRoot: URL(fileURLWithPath: args[1]), literal: args[2]))
    case "replace" where args.count == 5:
        guard let text = String(data: try input(args[4]), encoding: .utf8) else { throw ConduitOfflineFailure("replacement_not_utf8") }
        try emit(ConduitOfflineWorkspace.replace(stagedRoot: URL(fileURLWithPath: args[1]), relativePath: args[2],
                                                expectedSHA256: args[3], replacement: text))
    case "request" where args.count == 3:
        let root = URL(fileURLWithPath: args[1]); let manifest = try ConduitOfflineWorkspace.manifest(stagedRoot: root)
        try emit(ConduitOfflineRequest(operationID: args[2], stagedRoot: root.path, expectedManifestSHA256: manifest.sha256))
    case "preflight" where args.count == 2:
        let request = try JSONDecoder().decode(ConduitOfflineRequest.self, from: input(args[1]))
        try emit(ConduitOfflinePreflight.observe(request: request))
        exit(2) // This source preparation sample never admits execution.
    case "host-preparation" where args.count == 2:
        try emit(ConduitOfflinePreparation.observe(storageDirectory: URL(fileURLWithPath: args[1]), restore: nil))
        exit(2)
    case "host-capabilities" where args.count == 1:
        try emit(OfflineAssetProbe.capabilities())
        exit(2)
    case "prepare-latest" where args.count == 3:
        try emit(try await OfflineAssetProbe.observe(imagePath: nil,
            storageDirectory: URL(fileURLWithPath: args[1]), packet: URL(fileURLWithPath: args[2])))
        exit(2) // A metadata packet is never image/VM execution admission.
    case "prepare-image" where args.count == 4:
        try emit(try await OfflineAssetProbe.observe(imagePath: args[1],
            storageDirectory: URL(fileURLWithPath: args[2]), packet: URL(fileURLWithPath: args[3])))
        exit(2)
    case "run":
        throw ConduitOfflineFailure("guest_runtime_not_in_preparation_slice")
    case "describe-vm" where args.count == 2:
        let request = try JSONDecoder().decode(ConduitOfflineRequest.self, from: input(args[1]))
        #if os(macOS) && arch(arm64)
        let config = try ConduitOfflineVMConfiguration.make(request: request)
        let summary: [String: Any] = ["status": "configuration_only_no_machine_created", "cpu_count": config.cpuCount,
                  "storage_devices": config.storageDevices.count, "network_devices": config.networkDevices.count,
                  "directory_shares": config.directorySharingDevices.count, "socket_devices": config.socketDevices.count,
                  "serial_ports": config.serialPorts.count]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
        #else
        throw ConduitOfflineFailure("unsupported_host")
        #endif
    default:
        let usage: [String: Any] = ["status": "usage", "commands": ["stage SOURCE NEW_STAGE", "manifest STAGE", "export-input STAGE NEW_INPUT_PROJECT", "inspect STAGE PATH",
            "search STAGE LITERAL", "replace STAGE PATH EXPECTED_SHA256 REPLACEMENT_FILE", "request STAGE OPERATION_ID",
            "preflight REQUEST_JSON", "describe-vm REQUEST_JSON", "host-preparation STORAGE_DIRECTORY", "host-capabilities",
            "prepare-latest STORAGE_DIRECTORY NEW_PACKET", "prepare-image IPSW STORAGE_DIRECTORY NEW_PACKET"],
            "execution": "preparation only; run refuses; no image download/allocation, grant, ledger or VM actuator"]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: usage, options: [.prettyPrinted, .sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(2)
    }
} catch {
    let code = (error as? ConduitOfflineFailure)?.code ?? (error as? ConduitDirectCommandError)?.code ?? "sample_failed"
    let native = error as NSError
    var failure: [String: Any] = ["status": code, "detail": error.localizedDescription,
                                  "error_domain": native.domain, "error_code": native.code]
    if let underlying = native.userInfo[NSUnderlyingErrorKey] as? NSError {
        failure["underlying_domain"] = underlying.domain
        failure["underlying_code"] = underlying.code
    }
    let bytes = try! JSONSerialization.data(withJSONObject: failure, options: [.sortedKeys])
    FileHandle.standardError.write(bytes); FileHandle.standardError.write(Data("\n".utf8)); exit(2)
}
