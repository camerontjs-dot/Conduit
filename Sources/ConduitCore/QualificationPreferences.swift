import Foundation

/// File-backed defaults used only by an explicitly owned qualification instance.
/// Every read/write goes to this dictionary; the unique superclass suite is never
/// persisted or used as fallback, so SwiftUI AppStorage can share the same store.
public final class QualificationPreferences: UserDefaults, @unchecked Sendable {
    private let file: URL
    private let lock = NSRecursiveLock()
    private var values: [String: Any]

    public init(file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            values = object
        } else {
            values = [:]
        }
        super.init(suiteName: "dev.camerontjs.conduit.qualification.\(UUID().uuidString)")!
    }

    public override func object(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }
    public override func set(_ value: Any?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        #if canImport(ObjectiveC)
        willChangeValue(forKey: key)
        #endif
        values[key] = value
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            try data.write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            fputs("Conduit qualification preferences refused: \(error.localizedDescription)\n", stderr)
            exit(78) // never silently write operator preferences or claim persistence
        }
        #if canImport(ObjectiveC)
        didChangeValue(forKey: key)
        #endif
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }
    public override func removeObject(forKey key: String) { set(nil as Any?, forKey: key) }
    public override func set(_ value: Bool, forKey key: String) { set(value as Any, forKey: key) }
    public override func set(_ value: Int, forKey key: String) { set(value as Any, forKey: key) }
    public override func set(_ value: Float, forKey key: String) { set(value as Any, forKey: key) }
    public override func set(_ value: Double, forKey key: String) { set(value as Any, forKey: key) }
    public override func set(_ value: URL?, forKey key: String) { set(value?.absoluteString as Any?, forKey: key) }
    public override func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? false }
    public override func integer(forKey key: String) -> Int { (object(forKey: key) as? NSNumber)?.intValue ?? 0 }
    public override func double(forKey key: String) -> Double { (object(forKey: key) as? NSNumber)?.doubleValue ?? 0 }
    public override func float(forKey key: String) -> Float { (object(forKey: key) as? NSNumber)?.floatValue ?? 0 }
    public override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    public override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    public override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    public override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    public override func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    public override func url(forKey key: String) -> URL? { string(forKey: key).flatMap(URL.init(string:)) }
    public override func dictionaryRepresentation() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }; return values
    }
    public override func register(defaults registrationDictionary: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        for (key, value) in registrationDictionary where values[key] == nil { values[key] = value }
    }
}

public enum ConduitPreferences {
    public static let current: UserDefaults = {
        let config = ConduitInstanceConfiguration.current
        guard config.isQualification else { return .standard }
        do { return try QualificationPreferences(file: config.stateURL("preferences.plist")) }
        catch {
            fputs("Conduit qualification preferences refused: \(error.localizedDescription)\n", stderr)
            exit(78)
        }
    }()
}
