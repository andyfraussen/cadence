import Foundation

enum WidgetStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Cadence", isDirectory: true)
    }

    static var snapshotURL: URL { directory.appendingPathComponent("widget-snapshot.json") }
    static var codeyURL: URL { directory.appendingPathComponent("codey-idle.png") }

    static func write(_ snapshot: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try WidgetCoding.encoder().encode(snapshot)
        try data.write(to: snapshotURL, options: .atomic)
    }

    static func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? WidgetCoding.decoder().decode(WidgetSnapshot.self, from: data)
    }
}
