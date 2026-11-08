import Foundation
#if os(macOS) && arch(arm64)
import Virtualization

/// Configuration construction only. No VM object, entitlement change, guest
/// launch, disk mounting, export, installation or recovery implementation.
public enum ConduitOfflineVMConfiguration {
    public static func make(request: ConduitOfflineRequest) throws -> VZVirtualMachineConfiguration {
        let blockers = ConduitOfflinePreflight.configurationBlockers(request: request)
        guard blockers.isEmpty else { throw ConduitOfflineFailure(blockers.joined(separator: ",")) }
        guard let hardware = request.assets.hardwareModel,
              let machine = request.assets.machineIdentifier,
              let auxiliary = request.assets.auxiliaryStorage,
              let boot = request.assets.bootDisk,
              let exchange = request.assets.exchangeDisk else { throw ConduitOfflineFailure("asset_missing") }
        let hardwareBytes = try ConduitOfflineFS.readAbsolute(hardware.path, maximumBytes: 1_048_576)
        let machineBytes = try ConduitOfflineFS.readAbsolute(machine.path, maximumBytes: 1_048_576)
        guard ConduitOfflineHash.bytes(hardwareBytes) == hardware.sha256,
              ConduitOfflineHash.bytes(machineBytes) == machine.sha256,
              let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareBytes), hardwareModel.isSupported,
              let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machineBytes) else {
            throw ConduitOfflineFailure("unsupported_or_changed_platform_identity")
        }
        let profile = ConduitOfflineProfile.v1
        guard (VZVirtualMachineConfiguration.minimumAllowedCPUCount...VZVirtualMachineConfiguration.maximumAllowedCPUCount).contains(profile.cpuCount),
              (VZVirtualMachineConfiguration.minimumAllowedMemorySize...VZVirtualMachineConfiguration.maximumAllowedMemorySize).contains(profile.memoryBytes) else {
            throw ConduitOfflineFailure("resource_budget_unavailable")
        }
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: URL(fileURLWithPath: auxiliary.path))
        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = profile.cpuCount
        configuration.memorySize = profile.memoryBytes
        // Apple's macOS configuration contract puts the boot disk first.
        configuration.storageDevices = try [boot, exchange].map { asset in
            VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(
                url: URL(fileURLWithPath: asset.path), readOnly: false))
        }
        configuration.networkDevices = []
        configuration.directorySharingDevices = []
        configuration.socketDevices = []
        configuration.serialPorts = []
        configuration.audioDevices = []
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1024, heightInPixels: 768, pixelsPerInch: 80)]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        // Attachment construction and validation are not boot or confinement
        // evidence. Callers must retain exclusive image ownership throughout.
        try configuration.validate()
        // Refuse if a path/manifest changed while the factory assembled it.
        let after = ConduitOfflinePreflight.configurationBlockers(request: request)
        guard after.isEmpty else { throw ConduitOfflineFailure("configuration_input_changed:" + after.joined(separator: ",")) }
        return configuration
    }
}
#else
public enum ConduitOfflineVMConfiguration {
    public static func make(request: ConduitOfflineRequest) throws -> Never {
        throw ConduitOfflineFailure("unsupported_host")
    }
}
#endif
