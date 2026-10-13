import Foundation

public struct KnownStack: Codable, Equatable, Hashable, Sendable {
    public var name: String
    /// Absolute path of the pier.yml.
    public var file: String
    public var lastUp: Date
    public init(name: String, file: String, lastUp: Date = Date()) { self.name = name; self.file = file; self.lastUp = lastUp }
}

/// Stacks started with `pier up`, remembered in `<ManagedPaths.root>/stacks.json` (the menu bar app lists them).
public enum StackRegistry {
    public static func fileURL(root: URL = ManagedPaths.root) -> URL { root.appendingPathComponent("stacks.json") }

    /// Most recently started first; entries whose file vanished are omitted.
    public static func known() -> [KnownStack] { known(root: ManagedPaths.root) }

    public static func known(root: URL, includeMissing: Bool = false) -> [KnownStack] {
        guard let data = try? Data(contentsOf: fileURL(root: root)) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let all = try? dec.decode([KnownStack].self, from: data) else { return [] }
        return all.filter { includeMissing || FileManager.default.fileExists(atPath: $0.file) }
                  .sorted { $0.lastUp > $1.lastUp }
    }

    /// Upserts by file path (a renamed stack replaces its old entry).
    public static func record(name: String, file: String, at date: Date = Date(), root: URL = ManagedPaths.root) {
        var all = known(root: root, includeMissing: true).filter { $0.file != file }
        all.append(KnownStack(name: name, file: file, lastUp: date))
        all.sort { $0.lastUp > $1.lastUp }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try enc.encode(all).write(to: fileURL(root: root), options: .atomic)
        } catch { /* best effort: the registry is a convenience for the app */ }
    }

    /// Loads the file of a known stack by name, if still valid.
    public static func file(named name: String, root: URL = ManagedPaths.root) -> StackFile? {
        for k in known(root: root) where k.name == name {
            if let f = try? StackLoader.load(url: URL(fileURLWithPath: k.file)) { return f }
        }
        return nil
    }
}
