import Foundation
import ConduitCore
#if os(macOS) && arch(arm64)
import Virtualization
import CryptoKit

/// Apple-framework metadata observation. No VZVirtualMachine is constructed.
enum OfflineAssetProbe {
    static func capabilities() -> [String: String] {
        ["status": "host_observation_only", "architecture": "arm64",
         "virtualization_supported": String(VZVirtualMachine.isSupported),
         "host_cpu_count": String(ProcessInfo.processInfo.processorCount),
         "host_memory_bytes": String(ProcessInfo.processInfo.physicalMemory),
         "framework_minimum_cpu_count": String(VZVirtualMachineConfiguration.minimumAllowedCPUCount),
         "framework_maximum_cpu_count": String(VZVirtualMachineConfiguration.maximumAllowedCPUCount),
         "framework_minimum_memory_bytes": String(VZVirtualMachineConfiguration.minimumAllowedMemorySize),
         "framework_maximum_memory_bytes": String(VZVirtualMachineConfiguration.maximumAllowedMemorySize),
         "execution_admitted": "false"]
    }

    static func observe(imagePath: String?, storageDirectory: URL, packet: URL) async throws -> [String: String] {
        // Invalid local destinations refuse before catalog/network/native parsing.
        _ = try ConduitOfflinePreparation.observe(storageDirectory: storageDirectory, restore: nil)
        try ConduitOfflinePreparation.validatePacketDestination(packet)
        let image: VZMacOSRestoreImage
        let localImageSHA256: String?
        if let imagePath {
            // Reject aliases before asking the native framework to parse the image.
            let file = URL(fileURLWithPath: imagePath)
            guard file.pathExtension.lowercased() == "ipsw", !file.hasDirectoryPath else {
                throw ConduitOfflineFailure("restore_image_path_invalid")
            }
            // Streaming identity check also bounds size/ordinary ownership and links.
            let before = try ConduitOfflinePreparation.restoreFileIdentity(at: file)
            image = try await VZMacOSRestoreImage.image(from: file)
            guard try ConduitOfflinePreparation.restoreFileIdentity(at: file) == before else {
                throw ConduitOfflineFailure("restore_image_changed_during_native_parse")
            }
            localImageSHA256 = before.sha256
        } else {
            image = try await VZMacOSRestoreImage.latestSupported
            localImageSHA256 = nil
        }
        guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw ConduitOfflineFailure("restore_has_no_supported_hardware_model")
        }
        let bytes: UInt64?
        if image.url.isFileURL {
            let info = try FileManager.default.attributesOfItem(atPath: image.url.path)
            bytes = (info[.size] as? NSNumber)?.uint64Value
        } else {
            guard ConduitOfflinePreparation.allowedAppleURL(image.url) else {
                throw ConduitOfflineFailure("restore_origin_not_apple_https")
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            let session = URLSession(configuration: configuration, delegate: AppleRestoreRedirectPolicy(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: image.url); request.httpMethod = "HEAD"
            let (data, response) = try await session.data(for: request)
            guard data.count <= 65_536, let http = response as? HTTPURLResponse,
                  http.statusCode == 200, let finalURL = http.url, ConduitOfflinePreparation.allowedAppleURL(finalURL) else {
                throw ConduitOfflineFailure("restore_size_observation_failed")
            }
            bytes = http.value(forHTTPHeaderField: "Content-Length").flatMap(UInt64.init)
        }
        let hardware = requirements.hardwareModel.dataRepresentation
        let version = image.operatingSystemVersion
        let observation = ConduitOfflineRestoreObservation(
            version: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            build: image.buildVersion, sourceURL: image.url.absoluteString, byteCount: bytes,
            minimumCPUCount: requirements.minimumSupportedCPUCount,
            minimumMemoryBytes: requirements.minimumSupportedMemorySize,
            hardwareModelSHA256: SHA256.hash(data: hardware).map { String(format: "%02x", $0) }.joined(),
            localImageSHA256: localImageSHA256)
        let report = try ConduitOfflinePreparation.observe(storageDirectory: storageDirectory, restore: observation)
        return try ConduitOfflinePreparation.writePacket(report: report, hardwareModel: hardware,
            machineIdentifier: VZMacMachineIdentifier().dataRepresentation, destination: packet)
    }
}

private final class AppleRestoreRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(ConduitOfflinePreparation.allowedAppleURL) == true ? request : nil)
    }
}
#else
enum OfflineAssetProbe {
    static func capabilities() -> [String: String] {
        ["status": "unsupported_host", "execution_admitted": "false"]
    }
    static func observe(imagePath: String?, storageDirectory: URL, packet: URL) async throws -> [String: String] {
        throw ConduitOfflineFailure("unsupported_host")
    }
}
#endif
