import Foundation

public enum TaskAttentionLevel: String, Codable, CaseIterable, Sendable {
    case pinned
    case normal
    case later

    public var sortOrder: Int {
        switch self {
        case .pinned: 0
        case .normal: 1
        case .later: 2
        }
    }
}

public struct LocalTaskAttentionStore: Sendable {
    public let file: URL

    public init(root: URL) {
        file = root.appendingPathComponent("task-attention.json")
    }

    public func load() -> [String: TaskAttentionLevel] {
        guard let data = try? Data(contentsOf: file),
              let values = try? JSONDecoder().decode([String: TaskAttentionLevel].self, from: data)
        else { return [:] }
        return values
    }

    public func set(_ level: TaskAttentionLevel, for sessionKey: String) throws {
        var values = load()
        if level == .normal {
            values.removeValue(forKey: sessionKey)
        } else {
            values[sessionKey] = level
        }
        try save(values)
    }

    public func prune(keeping sessionKeys: Set<String>) throws {
        let values = load()
        let retained = values.filter { sessionKeys.contains($0.key) }
        guard retained != values else { return }
        try save(retained)
    }

    private func save(_ values: [String: TaskAttentionLevel]) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(values)
        let temporary = file.deletingLastPathComponent()
            .appendingPathComponent(".task-attention-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: file)
        }
    }
}
