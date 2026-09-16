import Foundation

@main struct CompletionTests {
    static func main() {
        let base = Date(timeIntervalSince1970: 1000)
        func task(_ status: TaskStatus, _ turn: String = "turn-1") -> TaskRecord {
            TaskRecord(id: "task", title: "Example", project: "", status: status, turnID: turn, updated: 0, started: 0)
        }
        func update(_ tracker: CompletionTracker, _ status: TaskStatus, _ unread: Set<String>?, _ seconds: Double, _ turn: String = "turn-1") -> Set<String> {
            tracker.update(records: [task(status, turn)], unread: unread, now: base.addingTimeInterval(seconds))
        }
        let unread: Set<String> = ["task"]
        let tracker = CompletionTracker()
        assert(update(tracker, .completed, [], 0).isEmpty, "Old read tasks must stay hidden")
        assert(update(tracker, .running, [], 1).isEmpty)
        assert(update(tracker, .completed, [], 2) == unread, "Completion must survive delayed unread writes")
        assert(update(tracker, .completed, unread, 10) == unread)
        assert(update(tracker, .completed, unread, 1000) == unread, "Unread completion must not expire")
        let restored = CompletionTracker(saved: tracker.saved)
        assert(update(restored, .completed, unread, 1001) == unread, "Restart must preserve completion")
        assert(update(restored, .completed, nil, 1002) == unread, "Read errors must not clear completion")
        assert(update(restored, .completed, [], 1003).isEmpty, "Viewing in Codex must clear completion")
        assert(update(restored, .completed, [], 1004).isEmpty, "Cleared task must not reappear")
        assert(update(tracker, .running, unread, 1005, "turn-2").isEmpty, "New turn must remove old completion")
        assert(update(tracker, .interrupted, unread, 1006, "turn-2").isEmpty)
        assert(update(tracker, .failed, unread, 1007, "turn-2").isEmpty)
        let focused = CompletionTracker()
        _ = update(focused, .running, [], 0)
        assert(update(focused, .completed, [], 1) == unread)
        assert(update(focused, .completed, [], 8).isEmpty, "Already viewed results clear after synchronization grace")
        let startup = CompletionTracker()
        assert(update(startup, .completed, unread, 0) == unread, "Unread completion must appear on launch")
        assert(startup.update(records: [], unread: unread, now: base).isEmpty)
        assert(startup.pending.isEmpty, "Archived tasks must be removed")
        assert(CompletionTracker(saved: Data("invalid".utf8)).pending.isEmpty)

        func decode(_ identities: [String: [String: [String]]], version: Int = 1) -> Set<String>? {
            let root: [String: Any] = ["electron-thread-read-state-v1": ["version": version, "unreadByIdentity": identities]]
            return CodexReadState.decode(try! JSONSerialization.data(withJSONObject: root))
        }
        assert(decode(["account": ["local:host": ["task"], "remote:host": ["remote-task"]]]) == unread)
        assert(decode(["account": ["local:host": []]]) == [])
        assert(decode(["account": ["local": ["task"]]]) == unread)
        assert(decode([:]) == nil)
        assert(decode(["a": ["local:h": []], "b": ["local:h": ["task"]]]) == nil)
        assert(decode(["a": ["local:h1": [], "local:h2": ["task"]]]) == nil)
        assert(decode(["a": ["remote:h": ["task"]]]) == nil)
        assert(decode(["a": ["local:h": []]], version: 2) == nil)
        assert(CodexReadState.decode(Data("{}".utf8)) == nil)
        assert(CodexReadState.decode(Data("invalid".utf8)) == nil)
        print("Completion lifecycle and read-state checks passed")
    }
}
