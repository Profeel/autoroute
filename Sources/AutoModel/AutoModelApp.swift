import AppKit
import AutoModelCore
import Combine
import SwiftUI

public enum SidebarTab: String, CaseIterable, Identifiable {
    case history = "首页"
    case modelsAndPolicy = "供应商"
    case agents = "Agent 接入"
    case settings = "设置"

    public var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .history: return "house"
        case .modelsAndPolicy: return "server.rack"
        case .agents: return "link.badge.plus"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = AutoModelEngine()
    let navigationState = AppNavigationState()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables: Set<AnyCancellable> = []
    private weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMenuBarItem()
        observeEngineChanges()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.captureMainWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep proxy & menu bar status running when the user closes the main window
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return true
    }

    private var terminationPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task {
            do {
                try await engine.shutdown()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                terminationPending = false
                let alert = NSAlert()
                alert.messageText = "尚未安全保存，已取消退出"
                alert.informativeText = engine.lastPersistenceError ?? "持久化失败，请修复后重试。"
                alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stopBackgroundTasks()
        engine.stopProxy()
        engine.stopLocalTestUpstream()
    }

    private func setupMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = item

        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentSize = NSSize(width: 360, height: 470)
        pop.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(
                engine: engine,
                onOpenMainWindow: { [weak self] targetTab, recordID in
                    guard let self else { return }
                    self.popover?.performClose(nil)
                    if let targetTab {
                        self.navigationState.requestedTab = targetTab
                    }
                    if let recordID {
                        self.navigationState.requestedRecordID = recordID
                    }
                    self.openMainWindow()
                },
                onQuit: { [weak self] in
                    self?.popover?.performClose(nil)
                    self?.quitApp()
                }
            )
        )
        self.popover = pop
        updateStatusButtonAppearance()
    }

    private func observeEngineChanges() {
        engine.$proxyState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusButtonAppearance()
            }
            .store(in: &cancellables)

        engine.$config
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusButtonAppearance()
            }
            .store(in: &cancellables)
    }

    private func updateStatusButtonAppearance() {
        guard let button = statusItem?.button else { return }
        let symbolName = engine.proxyState.isRunning ? "arrow.triangle.branch" : "exclamationmark.triangle"
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "AutoRoute")
        button.toolTip = "AutoRoute — \(engine.proxyState.statusText) · 策略: \(engine.config.policy.activeStrategy.displayName)"
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let pop = popover, let button = statusItem?.button else { return }
        if pop.isShown {
            pop.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: false)
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func captureMainWindow() {
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            self.mainWindow = window
        }
    }

    @objc func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let win = mainWindow ?? NSApp.windows.first(where: { $0.canBecomeMain }) {
            win.makeKeyAndOrderFront(nil)
            self.mainWindow = win
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

@main
struct AutoModelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("AutoRoute — 本地多模型路由器", id: "main") {
            MainContentView(engine: appDelegate.engine, navigationState: appDelegate.navigationState)
                .frame(minWidth: 980, minHeight: 660)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct MainContentView: View {
    @ObservedObject var engine: AutoModelEngine
    @ObservedObject var navigationState: AppNavigationState
    @State private var selectedTab: SidebarTab = .history
    @State private var copiedAddressToast = false
    @State private var showTestBenchSheet = false
    @State private var showOnboardingSheet = false

    var body: some View {
        NavigationSplitView {
            List(SidebarTab.allCases, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.systemImage)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                sidebarStatusFooter
            }
            .navigationSplitViewColumnWidth(min: 175, ideal: 195, max: 230)
        } detail: {
            VStack(spacing: 0) {
                if case .portConflict(let occupiedPort, let suggested) = engine.proxyState {
                    portConflictBanner(occupiedPort: occupiedPort, suggested: suggested)
                }

                switch selectedTab {
                case .history:
                    CallHistoryView(
                        engine: engine,
                        requestedRecordID: navigationState.requestedRecordID,
                        onConsumeRequestedRecord: {
                            navigationState.requestedRecordID = nil
                        },
                        onNavigateToProviders: {
                            selectedTab = .modelsAndPolicy
                        }
                    )
                case .modelsAndPolicy:
                    ProvidersModelsView(engine: engine)
                case .agents:
                    AgentIntegrationView(engine: engine)
                case .settings:
                    SettingsView(engine: engine, onShowOnboarding: {
                        showOnboardingSheet = true
                    })
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showTestBenchSheet = true
                } label: {
                    Label("快速测试", systemImage: "play.circle")
                }
                .keyboardShortcut("t", modifiers: [.command])
                .help("打开快速测试抽屉 (⌘T)")
            }
        }
        .sheet(isPresented: $showTestBenchSheet) {
            VStack(spacing: 0) {
                HStack {
                    Label("快速测试台", systemImage: "play.circle")
                        .font(.headline)
                    Spacer()
                    Button("关闭") {
                        showTestBenchSheet = false
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
                TestBenchView(engine: engine)
            }
            .frame(minWidth: 920, minHeight: 620)
        }
        .sheet(isPresented: $showOnboardingSheet) {
            VStack(spacing: 0) {
                HStack {
                    Label("首次使用引导", systemImage: "sparkles")
                        .font(.headline)
                    Spacer()
                    Button("完成") {
                        showOnboardingSheet = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
                OnboardingView(
                    engine: engine,
                    onNavigate: { target in
                        selectedTab = target
                        showOnboardingSheet = false
                    },
                    onOpenTestBench: {
                        showOnboardingSheet = false
                        showTestBenchSheet = true
                    }
                )
            }
            .frame(minWidth: 820, minHeight: 620)
        }
        .onAppear {
            if let reqTab = navigationState.requestedTab {
                selectedTab = reqTab
                navigationState.requestedTab = nil
            } else {
                selectedTab = .history
                if engine.config.providers.isEmpty && !engine.config.privacySettings.hasCompletedOnboarding {
                    showOnboardingSheet = true
                }
            }
        }
        .onChange(of: navigationState.requestedTab) { _, newTab in
            if let newTab {
                selectedTab = newTab
                navigationState.requestedTab = nil
            }
        }
    }

    private var sidebarStatusFooter: some View {
        let cal = Calendar.current
        let todayRecords = engine.callHistory.filter { cal.isDateInToday($0.timestamp) }
        let todayTokens = todayRecords.compactMap { $0.finalUsage?.totalTokens }.reduce(0, +)
        let todayTokensLabel = todayTokens >= 1_000_000
            ? String(format: "%.2fM", Double(todayTokens) / 1_000_000.0)
            : (todayTokens >= 1000 ? String(format: "%.1fk", Double(todayTokens) / 1000.0) : "\(todayTokens)")

        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(engine.proxyState.isRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(engine.proxyState.statusText)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }

            Text("今日 \(todayRecords.count) 轮 · \(todayTokensLabel) tok")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(engine.config.proxySettings.baseURLString)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 6) {
                Button(copiedAddressToast ? "已复制" : "复制地址") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(engine.config.proxySettings.baseURLString, forType: .string)
                    copiedAddressToast = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copiedAddressToast = false
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button(engine.proxyState.isRunning ? "停止" : "启动") {
                    if engine.proxyState.isRunning {
                        engine.stopProxy()
                    } else {
                        engine.startProxy()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor).opacity(0.6))
    }

    private func portConflictBanner(occupiedPort: Int, suggested: Int?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("本地代理端口 127.0.0.1:\(occupiedPort) 已被其他程序占用，外部应用暂时无法连接到 AutoRoute。")
                .font(.callout)
            Spacer()
            if let suggested {
                Button("切换到端口 \(suggested)") {
                    engine.updateProxyPort(suggested)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            Button("前往设置") {
                selectedTab = .settings
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.14))
    }
}
