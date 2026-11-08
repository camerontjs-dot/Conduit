import Foundation
import XCTest

enum ConduitOfflineFixtureEvidence {
    static func preserveAndClean(_ base: URL, test: String) {
        guard let path = ProcessInfo.processInfo.environment["CONDUIT_D2_TEST_EVIDENCE"] else {
            try? FileManager.default.removeItem(at: base); return
        }
        do {
            let destination = URL(fileURLWithPath: path).appendingPathComponent(test).appendingPathComponent(base.lastPathComponent)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: base, to: destination)
            print("D3_FIXTURE_EVIDENCE \(destination.path)")
            try FileManager.default.removeItem(at: base)
        } catch {
            // Keep the original in place when evidence capture fails.
            XCTFail("Fixture evidence retention failed; original retained at \(base.path): \(error)")
        }
    }
}
