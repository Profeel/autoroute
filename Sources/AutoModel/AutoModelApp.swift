import AppKit
import AutoModelCore
import Combine
import SwiftUI

public enum SidebarTab: String, CaseIterable, Identifiable {
    case history = "路由概览"
    case modelsAndPolicy = "提供商"
    case agents = "Agent 接入"
    case settings = "设置"

    public var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .history: return "arrow.triangle.branch"
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
        pop.contentSize = NSSize(width: 320, height: 380)
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

        engine.$dailyUsageLedger
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusButtonAppearance()
            }
            .store(in: &cancellables)

        engine.$cooldownUntilByModelID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusButtonAppearance()
            }
            .store(in: &cancellables)
    }

    private func updateStatusButtonAppearance() {
        guard let button = statusItem?.button else { return }
        let alert = engine.currentAlertLevel()
        let today = engine.todayUsageSummary()
        switch alert {
        case .normal:
            let img = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "AutoRoute")
            img?.isTemplate = true
            button.image = img
            button.contentTintColor = nil
            button.toolTip = "AutoRoute — \(engine.proxyState.statusText) · 今日 \(today.callCount) 轮 · 策略: \(engine.config.policy.activeStrategy.displayName)"
        case .warning(let detail):
            let img = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "AutoRoute 预警")
            img?.isTemplate = true
            button.image = img
            button.contentTintColor = .systemOrange
            button.toolTip = "AutoRoute（提醒）— \(detail) · 今日 \(today.callCount) 轮"
        case .error(let detail):
            let img = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "AutoRoute 异常")
            img?.isTemplate = true
            button.image = img
            button.contentTintColor = .systemRed
            button.toolTip = "AutoRoute（异常）— \(detail)"
        }
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
                HStack {
                    Label(tab.rawValue, systemImage: tab.systemImage)
                    Spacer()
                    if tab == .modelsAndPolicy && !engine.config.providers.isEmpty {
                        let enabledCount = engine.config.providers.filter(\.isEnabled).count
                        Text("\(enabledCount)/\(engine.config.providers.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                    }
                }
                .tag(tab)
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                sidebarStatusFooter
            }
            .navigationSplitViewColumnWidth(min: 195, ideal: 215, max: 250)
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
                        },
                        onNavigate: { selectedTab = $0 }
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
            ToolbarItem(placement: .principal) {
                Picker("路由策略", selection: Binding(
                    get: { engine.config.policy.activeStrategy },
                    set: { engine.setStrategy($0) }
                )) {
                    Text("省钱").tag(RoutingStrategyPreset.costFirst)
                    Text("均衡").tag(RoutingStrategyPreset.balanced)
                    Text("质量").tag(RoutingStrategyPreset.qualityFirst)
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
                .help("全局切换路由策略：省钱 / 均衡 / 质量")
            }
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
                    },
                    onOpenReceipt: { id in
                        showOnboardingSheet = false
                        selectedTab = .history
                        navigationState.requestedRecordID = id
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
        return VStack(alignment: .leading, spacing: 8) {
            Divider()

            // Card 2: Proxy Status Card
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(engine.proxyState.isRunning ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text(engine.proxyState.statusText)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer()
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

                HStack(spacing: 4) {
                    Text(engine.config.proxySettings.baseURLString)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(engine.config.proxySettings.baseURLString, forType: .string)
                        copiedAddressToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copiedAddressToast = false
                        }
                    } label: {
                        Image(systemName: copiedAddressToast ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("复制本地代理地址")
                }
            }
            .padding(9)
            .background(Color(.controlBackgroundColor).opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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
