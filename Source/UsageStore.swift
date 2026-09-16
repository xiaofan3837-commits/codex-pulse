import Foundation

struct UsageWindow: Codable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?
    var fraction: Double { min(100, max(0, usedPercent)) / 100 }
    var remainingFraction: Double { 1 - fraction }
    var label: String {
        switch windowDurationMins {
        case 300: return "5 小时额度"
        case 10080: return "每周额度"
        case .some(let minutes) where minutes >= 60: return "\(minutes / 60) 小时额度"
        case .some(let minutes): return "\(minutes) 分钟额度"
        default: return "用量额度"
        }
    }
}

struct UsageSnapshot: Codable {
    let primary: UsageWindow?
    let secondary: UsageWindow?
    static func decode(_ data: Data) throws -> UsageSnapshot {
        struct Bucket: Decodable { let primary: UsageWindow?; let secondary: UsageWindow? }
        struct Response: Decodable {
            let rateLimits: Bucket?
            let rateLimitsByLimitId: [String: Bucket]?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let bucket = response.rateLimitsByLimitId?["codex"] ?? response.rateLimits
        guard let bucket, bucket.primary != nil || bucket.secondary != nil else {
            throw StoreError.unavailable("当前账号暂无可用额度信息")
        }
        return UsageSnapshot(primary: bucket.primary, secondary: bucket.secondary)
    }
}

/// A persistent local Codex app-server connection. Only initialization and
/// account/rateLimits/read are sent; no turns, login changes, or reset calls.
final class UsageClient {
    var onResult: ((Result<UsageSnapshot, Error>) -> Void)?
    private let queue = DispatchQueue(label: "CodexPulse.usage", qos: .utility)
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var initialized = false
    private var pending = false
    private var requestID = 1
    private var timeout: DispatchWorkItem?
    private var generation = UUID()
    private var lastAttempt = Date.distantPast

    func refresh(force: Bool = false) {
        queue.async { [weak self] in
            guard let self, !self.pending, force || Date().timeIntervalSince(self.lastAttempt) >= 25 else { return }
            self.lastAttempt = Date(); self.pending = true
            self.scheduleTimeout()
            if self.initialized, self.process?.isRunning == true { self.requestUsage() }
            else { self.connect() }
        }
    }
    func stop() { queue.sync { shutdown() } }
    private func finish(_ result: Result<UsageSnapshot, Error>) {
        timeout?.cancel(); timeout = nil; pending = false
        DispatchQueue.main.async { [weak self] in self?.onResult?(result) }
    }
    private func fail(_ message: String) {
        shutdown()
        finish(.failure(StoreError.unavailable(message)))
    }
    private func shutdown() {
        generation = UUID(); initialized = false
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        if let process, process.isRunning { process.terminate() }
        process = nil; input = nil; output = nil; buffer.removeAll()
        timeout?.cancel(); timeout = nil; pending = false
    }
    private func scheduleTimeout() {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fail("用量更新超时，稍后自动重试") }
        timeout = work; queue.asyncAfter(deadline: .now() + 30, execute: work)
    }
    private func connect() {
        let paths = ["/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex", NSHomeDirectory() + "/Applications/Codex.app/Contents/Resources/codex"]
        guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            fail("未找到 Codex，用量暂不可用"); return
        }
        let process = Process(), input = Pipe(), output = Pipe()
        self.process = process; self.input = input; self.output = output
        let token = UUID(); generation = token
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { [weak self] in
                guard let self, self.generation == token else { return }
                if data.isEmpty { self.fail("用量连接已断开，稍后自动重试"); return }
                self.buffer.append(data)
                guard self.buffer.count < 2_000_000 else { self.fail("用量响应异常，稍后自动重试"); return }
                while let end = self.buffer.firstIndex(of: 10) {
                    let line = self.buffer.subdata(in: self.buffer.startIndex..<end)
                    self.buffer.removeSubrange(self.buffer.startIndex...end)
                    self.receive(line)
                }
            }
        }
        do { try process.run() }
        catch { fail("无法连接 Codex 用量服务"); return }
        requestID = 1
        send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codex_pulse", "title": "Codex Pulse", "version": "1.1.1"]]])
    }
    private func send(_ object: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        do { try input.fileHandleForWriting.write(contentsOf: data + Data([10])) }
        catch { fail("用量连接已断开，稍后自动重试") }
    }
    private func requestUsage() {
        requestID += 1
        send(["id": requestID, "method": "account/rateLimits/read", "params": [:]])
    }
    private func receive(_ data: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = message["id"] as? Int, id == requestID else { return }
        guard message["error"] == nil, let result = message["result"] as? [String: Any] else {
            fail("无法读取用量，请确认 Codex 已登录"); return
        }
        if id == 1 {
            initialized = true
            send(["method": "initialized", "params": [:]])
            requestUsage()
        } else {
            do { finish(.success(try UsageSnapshot.decode(JSONSerialization.data(withJSONObject: result)))) }
            catch { finish(.failure(error)) }
        }
    }
}
