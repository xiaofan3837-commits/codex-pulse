import AppKit
import SwiftUI

extension TaskStatus {
    var color: Color {
        switch self { case .running: return .cyan; case .completed: return .green; case .interrupted: return .orange; case .failed: return .red; case .unknown: return .secondary }
    }
    var icon: String {
        switch self { case .running: return "arrow.triangle.2.circlepath"; case .completed: return "checkmark.circle.fill"; case .interrupted: return "pause.circle.fill"; case .failed: return "exclamationmark.circle.fill"; case .unknown: return "questionmark.circle" }
    }
}

final class PulseModel: ObservableObject {
    @Published var tasks: [TaskRecord] = []
    @Published var pendingCompletions: Set<String> = []
    private let completionTracker = CompletionTracker(saved: UserDefaults.standard.data(forKey: "pending-completions-v1"))
    @Published var error: String?
    @Published var lastRead: Date?
    @Published var pinned = UserDefaults.standard.object(forKey: "pinned") as? Bool ?? true
    @Published var compact = false
    @Published var sound = UserDefaults.standard.bool(forKey: "sound") {
        didSet { UserDefaults.standard.set(sound, forKey: "sound") }
    }
    @Published var codexRunning = true
    @Published var usage: UsageSnapshot?
    @Published var usageError: String?
    @Published var usageUpdated: Date?
    private let usageClient = UsageClient()
    private var usageTimer: Timer?
    var onUpdate: (() -> Void)?
    private let store = TaskStore()
    private var busy = false
    private var timer: Timer?
    private let queue = DispatchQueue(label: "CodexPulse.read", qos: .utility)
    var running: Int { tasks.filter { $0.status == .running }.count }
    var unknown: Int { tasks.filter { $0.status == .unknown }.count }
    var taskSummary: String {
        if error != nil { return "任务状态待更新" }
        if running > 0 {
            return pendingCompletions.isEmpty ? "\(running) 项任务进行中" : "\(running) 项进行中 · \(pendingCompletions.count) 项已完成"
        }
        if !pendingCompletions.isEmpty { return "\(pendingCompletions.count) 项已完成 · 待查看" }
        if lastRead == nil { return "正在读取任务状态…" }
        if unknown > 0 { return "\(unknown) 项任务状态待确认" }
        return "目前没有进行中的任务"
    }
    var visible: [TaskRecord] { tasks.filter { $0.status == .running || ($0.status == .completed && pendingCompletions.contains($0.id)) } }
    func start() {
        usageClient.onResult = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let snapshot): self.usage = snapshot; self.usageError = nil; self.usageUpdated = Date()
            case .failure(let error): self.usageError = error.localizedDescription
            }
        }
        refresh(); usageClient.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        usageTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.usageClient.refresh() }
    }
    func refreshAll() { refresh(); usageClient.refresh(force: true) }
    func stop() { timer?.invalidate(); usageTimer?.invalidate(); usageClient.stop() }
    func refresh() {
        guard !busy else { return }
        busy = true
        codexRunning = NSWorkspace.shared.runningApplications.contains { app in
            let name = app.bundleURL?.lastPathComponent ?? ""
            return name == "ChatGPT.app" || name == "Codex.app"
        }
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.store.read() }
            let unread = CodexReadState.unreadThreads(home: self.store.home)
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let records):
                    let prior = Dictionary(uniqueKeysWithValues: self.tasks.map { ($0.id, $0) })
                    let finished = records.contains { item in
                        guard let old = prior[item.id] else { return false }
                        return old.status == .running && item.status == .completed && old.turnID == item.turnID
                    }
                    if finished && self.sound { NSSound(named: "Glass")?.play() }
                    self.pendingCompletions = self.completionTracker.update(records: records, unread: unread)
                    let saved = self.completionTracker.saved
                    if saved != UserDefaults.standard.data(forKey: "pending-completions-v1") {
                        UserDefaults.standard.set(saved, forKey: "pending-completions-v1")
                    }
                    self.tasks = records; self.error = nil; self.lastRead = Date()
                case .failure(let error): self.error = error.localizedDescription
                }
                self.onUpdate?()
            }
        }
    }
    func open(_ task: TaskRecord) {
        guard let url = URL(string: "codex://threads/\(task.id)") else { return }
        if !NSWorkspace.shared.open(url) { error = "无法打开 Codex，请检查应用是否已安装。" }
    }
}

enum CodexAppearance {
    static let icon: NSImage = {
        if let url = Bundle.main.url(forResource: "CodexPulseIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) { return image }
        return NSImage(systemSymbolName: "terminal", accessibilityDescription: "Codex Pulse")!
    }()
}

private struct ContentHeights: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
private extension View {
    func measureHeight(_ key: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: ContentHeights.self, value: [key: geometry.size.height])
        })
    }
}

struct PulseView: View {
    @ObservedObject var model: PulseModel
    let collapse: () -> Void
    let hide: () -> Void
    let contentHeightChanged: (CGFloat) -> Void
    private let ink = Color(red: 0.10, green: 0.12, blue: 0.15)
    private let blue = Color(red: 0.0, green: 0.43, blue: 0.96)
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: CodexAppearance.icon).resizable().interpolation(.high)
                    .scaledToFit().frame(width: 32, height: 34).accessibilityLabel("Codex Pulse 图标")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex Pulse").font(.system(size: 14, weight: .semibold)).foregroundStyle(ink)
                    Text(model.taskSummary)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button(action: collapse) { Image(systemName: model.compact ? "chevron.down" : "chevron.up") }.help("折叠 / 展开")
                Button(action: hide) { Image(systemName: "xmark") }.help("隐藏悬浮窗")
            }.font(.system(size: 11, weight: .medium)).buttonStyle(.plain).padding(16)
                .fixedSize(horizontal: false, vertical: true).measureHeight("header")
            if !model.compact {
                Divider().opacity(0.45).padding(.horizontal, 16).measureHeight("divider")
                if let error = model.error {
                    Label(error + " 显示上次记录。", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.orange).padding(12)
                        .fixedSize(horizontal: false, vertical: true).measureHeight("notice")
                } else if !model.codexRunning {
                    Label("Codex 未运行，以下为最后记录。", systemImage: "clock")
                        .font(.system(size: 11)).foregroundStyle(.orange).padding(12)
                        .fixedSize(horizontal: false, vertical: true).measureHeight("notice")
                }
                if !model.visible.isEmpty {
                    ScrollView {
                        VStack(spacing: 0) {
                        ForEach(model.visible) { task in
                            Button { model.open(task) } label: {
                                HStack(alignment: .top, spacing: 11) {
                                    if task.status == .completed {
                                        Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green).padding(.top, 2)
                                    } else {
                                        Circle().fill(blue).frame(width: 7, height: 7).padding(.top, 5)
                                    }
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(task.title).font(.system(size: 12, weight: .medium)).foregroundStyle(ink)
                                            .lineLimit(2).multilineTextAlignment(.leading)
                                        Text(task.status == .completed ? "已完成 · 待查看" : "进行中")
                                            .font(.system(size: 10)).foregroundStyle(task.status == .completed ? Color.green : blue)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary).padding(.top, 4)
                                }.padding(.vertical, 14).padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).help(task.status == .completed ? "\(task.title) · 在 Codex 中查看后自动移除" : "\(task.title) · 点击在 Codex 中打开")
                        }
                        }.padding(.horizontal, 16)
                            .fixedSize(horizontal: false, vertical: true).measureHeight("tasks")
                    }.frame(minHeight: 0, maxHeight: .infinity)
                }
                usageSection.padding(.top, model.visible.isEmpty ? 12 : 0)
                    .fixedSize(horizontal: false, vertical: true).measureHeight("usage")
                HStack(spacing: 5) {
                    Circle().fill(model.error == nil ? Color.green : Color.orange).frame(width: 4, height: 4)
                    Text("本机任务").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.refreshAll() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }.buttonStyle(.plain).help("刷新任务与用量")
                    Menu {
                        Toggle("完成时播放提示音", isOn: $model.sound)
                        Button("退出悬浮窗") { NSApp.terminate(nil) }
                    } label: { Image(systemName: "ellipsis.circle").font(.system(size: 13)) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
                }.foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 12)
                    .fixedSize(horizontal: false, vertical: true).measureHeight("footer")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.white).preferredColorScheme(.light).ignoresSafeArea()
            .onPreferenceChange(ContentHeights.self) { heights in
                contentHeightChanged(ceil(heights.values.reduce(0, +)))
            }
    }
    var usageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("账号剩余额度").font(.system(size: 11, weight: .semibold)).foregroundStyle(ink)
                Spacer()
                if let updated = model.usageUpdated {
                    (Text("更新于 ") + Text(updated, style: .time)).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            if let usage = model.usage {
                if let primary = usage.primary { usageRow(primary) }
                if let secondary = usage.secondary { usageRow(secondary) }
            } else if model.usageError == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("正在读取用量…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let error = model.usageError {
                Text(error + (model.usage == nil ? "" : " · 显示上次用量"))
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
        }.padding(14).background(Color(red: 0.96, green: 0.965, blue: 0.975), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
    }
    func usageRow(_ window: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window.label).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("剩余 \(Int((window.remainingFraction * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(ink)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.055))
                    Capsule().fill(window.remainingFraction <= 0.1 ? Color.orange : blue)
                        .frame(width: geometry.size.width * window.remainingFraction)
                }
            }.frame(height: 5)
                .accessibilityLabel("\(window.label)剩余 \(Int((window.remainingFraction * 100).rounded()))%")
                .help("已用 \(Int((window.fraction * 100).rounded()))%，进度条表示剩余额度")
            if let timestamp = window.resetsAt {
                Text(resetLabel(timestamp)).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }
    func resetLabel(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        if date <= Date() { return "重置时间已到，等待刷新" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "今天 HH:mm" : "M月d日 HH:mm"
        return formatter.string(from: date) + " 重置"
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = PulseModel()
    var panel: FloatingPanel!
    var statusItem: NSStatusItem!
    var desiredHeight: CGFloat = 220
    private var resizeWork: DispatchWorkItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 480), styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Codex Pulse"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 320, height: 66)
        panel.maxSize = NSSize(width: 520, height: 10000)
        panel.delegate = self
        panel.appearance = NSAppearance(named: .aqua)
        panel.setFrameAutosaveName("CodexPulsePanel")
        if !panel.setFrameUsingName("CodexPulsePanel"), let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 374, y: screen.visibleFrame.maxY - 510))
        }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }), let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 374, y: screen.visibleFrame.maxY - 510))
        }
        let hostingView = NSHostingView(rootView: PulseView(model: model, collapse: { [weak self] in self?.toggleCompact() }, hide: { [weak self] in self?.panel.orderOut(nil) }, contentHeightChanged: { [weak self] height in
            self?.contentHeightChanged(height)
        }))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        setLevel()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menuIcon = CodexAppearance.icon.copy() as! NSImage
        menuIcon.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = menuIcon
        NSApp.applicationIconImage = CodexAppearance.icon
        let menu = NSMenu()
        menu.addItem(withTitle: "显示 / 隐藏悬浮窗", action: #selector(toggleVisible), keyEquivalent: "")
        menu.addItem(withTitle: "置顶 / 取消置顶", action: #selector(togglePin), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Codex Pulse", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        model.onUpdate = { [weak self] in
            guard let self else { return }
            self.statusItem.button?.title = self.model.error == nil ? " \(self.model.running)" : " !"
            self.statusItem.button?.toolTip = self.model.taskSummary
        }
        panel.orderFrontRegardless()
        model.start()
    }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
    func setLevel() { panel.level = model.pinned ? .floating : .normal }
    @objc func togglePin() { model.pinned.toggle(); UserDefaults.standard.set(model.pinned, forKey: "pinned"); setLevel() }
    @objc func toggleVisible() { if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() } }
    @objc func quit() { NSApp.terminate(nil) }
    func contentHeightChanged(_ height: CGFloat) {
        guard height > 0 else { return }
        desiredHeight = height
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fitContent() }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }
    func fitContent(animated: Bool = true) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        var frame = panel.frame
        let height = min(model.compact ? 66 : max(66, desiredHeight), visible.height)
        let top = min(frame.maxY, visible.maxY)
        frame.origin.y = max(visible.minY, top - height)
        frame.size.height = height
        guard abs(frame.height - panel.frame.height) > 1 || abs(frame.minY - panel.frame.minY) > 1 else { return }
        panel.setFrame(frame, display: true, animate: animated && panel.isVisible)
    }
    func windowDidChangeScreen(_ notification: Notification) { fitContent() }
    func windowDidEndLiveResize(_ notification: Notification) { fitContent() }
    func toggleCompact() {
        model.compact.toggle()
        if model.compact { fitContent() }
        // Expanded content is measured by SwiftUI after it reappears.
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { panel.orderFrontRegardless(); return true }
}

if CommandLine.arguments.contains("--parse-usage") {
    do {
        let result = try UsageSnapshot.decode(FileHandle.standardInput.readDataToEndOfFile())
        print(String(data: try JSONEncoder().encode(result), encoding: .utf8)!)
    } catch { fputs("用量不可用\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--diagnose-usage") {
    let client = UsageClient()
    var done = false
    client.onResult = { result in
        switch result {
        case .success(let snapshot): print(String(data: try! JSONEncoder().encode(snapshot), encoding: .utf8)!)
        case .failure(let error): fputs("\(error.localizedDescription)\n", stderr)
        }
        done = true
    }
    client.refresh()
    while !done { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) }
    client.stop()
} else if CommandLine.arguments.contains("--diagnose") {
    do {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: try encoder.encode(TaskStore().read()), encoding: .utf8)!)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
