import Foundation
import SQLite3

enum TaskStatus: String, Codable {
    case running, completed, interrupted, failed, unknown
    init(stored: String) {
        switch stored {
        case "inProgress", "in_progress": self = .running
        case "completed": self = .completed
        case "interrupted": self = .interrupted
        case "failed": self = .failed
        default: self = .unknown
        }
    }
    var title: String {
        switch self {
        case .running: return "进行中"
        case .completed: return "已完成"
        case .interrupted: return "已中断"
        case .failed: return "失败"
        case .unknown: return "待确认"
        }
    }
    var rank: Int {
        switch self { case .running: return 0; case .failed: return 1; case .interrupted: return 2; case .unknown: return 3; case .completed: return 4 }
    }
}

struct TaskRecord: Identifiable, Codable {
    let id: String
    let title: String
    let project: String
    let status: TaskStatus
    let turnID: String
    let updated: Double
    let started: Double
}

enum StoreError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

/// Opens each database read-only. Never reads prompts, tool outputs, or credentials.
final class TaskStore {
    let home: URL
    init(home: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex")) { self.home = home }

    /// History rows are keyed by the current rollout ID, which can differ from
    /// the permanent task ID after a session is replaced. Resolve only from the
    /// authoritative state DB path; never read conversation contents or merge
    /// old and new rollouts by ordinal.
    private func historyKey(threadID: String, rolloutPath: String) -> String? {
        guard !rolloutPath.isEmpty else { return threadID }
        guard UUID(uuidString: threadID) != nil else { return nil }
        let name = URL(fileURLWithPath: rolloutPath).lastPathComponent.lowercased()
        let logical = threadID.lowercased()
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { return nil }
        let stem = String(name.dropLast(6))
        if stem.hasSuffix("-" + logical) { return threadID }
        guard let separator = stem.lastIndex(of: "_") else { return nil }
        let prefix = String(stem[..<separator])
        let storage = String(stem[stem.index(after: separator)...])
        guard prefix.hasSuffix("-" + logical), UUID(uuidString: storage) != nil else { return nil }
        return storage
    }

    private func open(_ file: String) throws -> OpaquePointer {
        var db: OpaquePointer?
        let result = sqlite3_open_v2(home.appendingPathComponent(file).path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle = db else {
            if let db { sqlite3_close(db) }
            throw StoreError.unavailable("无法读取 Codex 任务记录，请先打开 Codex。")
        }
        sqlite3_busy_timeout(handle, 350)
        return handle
    }

    private func query(_ db: OpaquePointer, _ sql: String) throws -> [[String]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.unavailable("任务记录格式暂不兼容，请更新悬浮窗。")
        }
        defer { sqlite3_finalize(stmt) }
        var rows = [[String]]()
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw StoreError.unavailable("任务记录暂时繁忙，正在重试。") }
            rows.append((0..<sqlite3_column_count(stmt)).map { column in
                sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
            })
        }
    }

    func read() throws -> [TaskRecord] {
        let db = try open("state_5.sqlite")
        defer { sqlite3_close(db) }
        let threads = try query(db, """
            SELECT id, COALESCE(NULLIF(name,''), NULLIF(title,''), '未命名任务'), cwd, updated_at, rollout_path
            FROM threads
            WHERE archived = 0 AND (thread_source = 'user' OR (thread_source IS NULL AND source IN ('vscode','cli','exec')))
            ORDER BY updated_at DESC
            """)
        let history = try open("thread_history_1.sqlite")
        defer { sqlite3_close(history) }
        // Read the last turn for each visible task; no full conversation scan.
        var stmt: OpaquePointer?
        let sql = "SELECT status, turn_id, started_at, completed_at FROM thread_turns WHERE thread_id = ? ORDER BY rollout_ordinal DESC LIMIT 1"
        guard sqlite3_prepare_v2(history, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.unavailable("任务状态格式暂不兼容，请更新悬浮窗。")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var records = [TaskRecord]()
        for row in threads {
            let storageKey = historyKey(threadID: row[0], rolloutPath: row[4])
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            // A missing/unknown current key must not revive stale logical-ID
            // history. It remains unknown until the current rollout is indexed.
            if let storageKey { sqlite3_bind_text(stmt, 1, storageKey, -1, transient) }
            let result = storageKey == nil ? SQLITE_DONE : sqlite3_step(stmt)
            guard result == SQLITE_ROW || result == SQLITE_DONE else { throw StoreError.unavailable("状态读取暂时失败，正在重试。") }
            func value(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
            let status = result == SQLITE_ROW ? TaskStatus(stored: value(0)) : .unknown
            let project = URL(fileURLWithPath: row[2]).lastPathComponent
            let title = row[1].split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? "未命名任务"
            records.append(TaskRecord(id: row[0], title: String(title.prefix(160)), project: project, status: status,
                                      turnID: result == SQLITE_ROW ? value(1) : "", updated: Double(row[3]) ?? 0,
                                      started: result == SQLITE_ROW ? Double(value(2)) ?? 0 : 0))
        }
        return records.sorted { a,b in
            if a.status.rank != b.status.rank { return a.status.rank < b.status.rank }
            // Keep live rows stable while two tasks write updates concurrently.
            let aTime = a.status == .running ? a.started : a.updated
            let bTime = b.status == .running ? b.started : b.updated
            return aTime == bTime ? a.id < b.id : aTime > bTime
        }
    }
}
