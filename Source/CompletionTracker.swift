import Foundation

enum CodexReadState {
    /// Nil means unavailable/ambiguous, never "all read". Select only one local
    /// account/host scope rather than merging read flags from other accounts.
    static func unreadThreads(home: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".codex-global-state.json")) else { return nil }
        return decode(data)
    }
    static func decode(_ data: Data) -> Set<String>? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let state = root["electron-thread-read-state-v1"] as? [String: Any],
              state["version"] as? Int == 1,
              let identities = state["unreadByIdentity"] as? [String: [String: [String]]],
              identities.count == 1, let hosts = identities.values.first else { return nil }
        let local = hosts.filter { $0.key == "local" || $0.key.hasPrefix("local:") }
        guard local.count == 1, let ids = local.values.first else { return nil }
        return Set(ids)
    }
}

final class CompletionTracker {
    struct Pending: Codable {
        let turnID: String
        let firstObserved: Date
    }
    private(set) var pending: [String: Pending]
    private var previousRunning: [String: String] = [:]
    // The desktop's unread flag and the turn status are saved separately. Keep
    // a short grace period so a newly completed row cannot vanish in that gap.
    private let grace: TimeInterval = 6
    init(saved: Data? = nil) {
        pending = saved.flatMap { try? JSONDecoder().decode([String: Pending].self, from: $0) } ?? [:]
    }
    var saved: Data? { try? JSONEncoder().encode(pending) }
    func update(records: [TaskRecord], unread: Set<String>?, now: Date = Date()) -> Set<String> {
        let ids = Set(records.map(\.id))
        pending = pending.filter { ids.contains($0.key) }
        for task in records {
            if task.status == .running || task.status == .interrupted || task.status == .failed {
                pending.removeValue(forKey: task.id)
                continue
            }
            guard task.status == .completed else { continue }
            if let old = pending[task.id], old.turnID != task.turnID {
                pending.removeValue(forKey: task.id)
            }
            let justFinished = previousRunning[task.id] == task.turnID
            if pending[task.id] == nil, justFinished || unread?.contains(task.id) == true {
                pending[task.id] = Pending(turnID: task.turnID, firstObserved: now)
            }
            if let entry = pending[task.id], let unread, !unread.contains(task.id),
               now.timeIntervalSince(entry.firstObserved) >= grace {
                pending.removeValue(forKey: task.id)
            }
        }
        previousRunning = Dictionary(uniqueKeysWithValues: records.filter { $0.status == .running }.map { ($0.id, $0.turnID) })
        return Set(records.filter { $0.status == .completed && pending[$0.id]?.turnID == $0.turnID }.map(\.id))
    }
}
