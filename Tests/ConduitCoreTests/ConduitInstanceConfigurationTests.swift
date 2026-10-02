import Foundation
import XCTest
@testable import ConduitCore

final class ConduitInstanceConfigurationTests: XCTestCase {
    func testOrdinaryDefaultsDoNotChange() throws {
        let home = URL(fileURLWithPath: "/fixture-home")
        let config = try ConduitInstanceConfiguration.resolve(environment: [:], home: home)
        XCTAssertFalse(config.isQualification)
        XCTAssertEqual(config.sessionAPIPort, 8750)
        XCTAssertEqual(config.stateDirectory.path, "/fixture-home/.conduit")
    }

    func testPortAndRootAreOneExplicitBoundary() throws {
        for environment in [
            ["CONDUIT_SESSION_API_PORT": "18750"],
            ["CONDUIT_QUALIFICATION_ROOT": "/owned-fixture"],
            ["CONDUIT_QUALIFICATION_ROOT": "", "CONDUIT_SESSION_API_PORT": "18750"],
            ["CONDUIT_QUALIFICATION_ROOT": "relative", "CONDUIT_SESSION_API_PORT": "18750"],
            ["CONDUIT_QUALIFICATION_ROOT": "/owned-fixture", "CONDUIT_SESSION_API_PORT": "8750"],
            ["CONDUIT_QUALIFICATION_ROOT": "/owned-fixture", "CONDUIT_SESSION_API_PORT": "18850"],
            ["CONDUIT_QUALIFICATION_ROOT": "/owned-fixture", "CONDUIT_SESSION_API_PORT": "18749"],
            ["CONDUIT_QUALIFICATION_ROOT": "/owned-fixture", "CONDUIT_SESSION_API_PORT": "18750x"],
            ["CONDUIT_QUALIFICATION_ROOT": "/owned-fixture", "CONDUIT_SESSION_API_PORT": " 18750"],
            ["CONDUIT_QUALIFICATION_ROOT": "/owned-fixture", "CONDUIT_SESSION_API_PORT": "018750"],
            ["CONDUIT_QUALIFICATION_ROOT": "/", "CONDUIT_SESSION_API_PORT": "18750"],
            ["CONDUIT_QUALIFICATION_ROOT": "/fixture-home/.conduit", "CONDUIT_SESSION_API_PORT": "18750"]
        ] {
            XCTAssertThrowsError(try ConduitInstanceConfiguration.resolve(environment: environment, home: URL(fileURLWithPath: "/fixture-home")))
        }
        for port in [18750, 18849] {
            let config = try ConduitInstanceConfiguration.resolve(environment: ["CONDUIT_QUALIFICATION_ROOT": "/owned-fixture", "CONDUIT_SESSION_API_PORT": String(port)], home: URL(fileURLWithPath: "/fixture-home"))
            XCTAssertTrue(config.isQualification)
            XCTAssertEqual(config.sessionAPIPort, port)
        }
    }

    func testUnownedExistingRootAndSymlinkAreRefused() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let unowned = parent.appendingPathComponent("unowned")
        try FileManager.default.createDirectory(at: unowned, withIntermediateDirectories: true)
        try Data("must remain unchanged".utf8).write(to: unowned.appendingPathComponent("operator-sentinel"))
        let config = try ConduitInstanceConfiguration.resolve(environment: ["CONDUIT_QUALIFICATION_ROOT": unowned.path, "CONDUIT_SESSION_API_PORT": "18750"])
        XCTAssertThrowsError(try config.prepareQualificationStateRoot())
        XCTAssertEqual(try String(contentsOf: unowned.appendingPathComponent("operator-sentinel")), "must remain unchanged")
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unowned)
        XCTAssertThrowsError(try ConduitInstanceConfiguration.resolve(environment: ["CONDUIT_QUALIFICATION_ROOT": link.path, "CONDUIT_SESSION_API_PORT": "18750"]))
    }

    func testOwnedRootPreferencesPersistAndRejectLinkedArtifacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try ConduitInstanceConfiguration.resolve(environment: ["CONDUIT_QUALIFICATION_ROOT": root.path, "CONDUIT_SESSION_API_PORT": "18750"])
        try config.prepareQualificationStateRoot()
        let prefs = try QualificationPreferences(file: config.stateDirectory.appendingPathComponent("preferences.plist"))
        prefs.set(true, forKey: "boolean")
        prefs.set("qualified", forKey: "string")
        prefs.set(304.5, forKey: "double")
        prefs.set(Data([1,2,3]), forKey: "data")
        prefs.set(["a", "b"], forKey: "array")
        let fresh = try QualificationPreferences(file: config.stateDirectory.appendingPathComponent("preferences.plist"))
        XCTAssertTrue(fresh.bool(forKey: "boolean"))
        XCTAssertEqual(fresh.string(forKey: "string"), "qualified")
        XCTAssertEqual(fresh.double(forKey: "double"), 304.5)
        XCTAssertEqual(fresh.data(forKey: "data"), Data([1,2,3]))
        XCTAssertEqual(fresh.stringArray(forKey: "array"), ["a", "b"])
        try config.prepareQualificationStateRoot()
        let target = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("protected".utf8).write(to: target)
        defer { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("config.json"), withDestinationURL: target)
        XCTAssertThrowsError(try config.prepareQualificationStateRoot())
        XCTAssertEqual(try String(contentsOf: target), "protected")
    }

    func testWrongMarkerAndHardLinkedArtifactAreRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try ConduitInstanceConfiguration.resolve(environment: ["CONDUIT_QUALIFICATION_ROOT": root.path, "CONDUIT_SESSION_API_PORT": "18750"])
        try config.prepareQualificationStateRoot()
        let marker = config.stateURL(ConduitInstanceConfiguration.rootMarkerName)
        let original = try Data(contentsOf: marker)
        try Data("{\"schema_version\":1,\"kind\":\"operator\",\"root\":\"wrong\"}".utf8).write(to: marker)
        XCTAssertThrowsError(try config.prepareQualificationStateRoot())
        try original.write(to: marker)
        let external = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("protected".utf8).write(to: external)
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.linkItem(at: external, to: root.appendingPathComponent("adapter-threads.json"))
        XCTAssertThrowsError(try config.prepareQualificationStateRoot())
        XCTAssertEqual(try String(contentsOf: external), "protected")
    }

    func testSettingsWithoutConfiguredRootDoNotAutodetect() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore.loadSnapshot(directory: root, allowRootAutodetection: false)
        XCTAssertNil(settings.mainframeRoot)
        XCTAssertFalse(settings.enableSessionAPIWrites)
    }
}
