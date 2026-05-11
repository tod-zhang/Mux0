import SwiftUI
import AppKit
import Observation

/// 引用类型 ticker：MetadataRefresher 的 onRefresh 是逃逸闭包，
/// 直接 `metadataTick &+= 1` (值类型 @State Int) 只会修改捕获的副本，不会触发
/// SwiftUI 重渲。换成 @Observable class，闭包按引用捕获，mutate 才能让 SwiftUI 重跑 body。
@Observable
fileprivate final class MetadataChangeTicker {
    var tick: Int = 0
}

struct SidebarView: View {
    @Bindable var store: WorkspaceStore
    @Bindable var statusStore: TerminalStatusStore
    @Bindable var pwdStore: TerminalPwdStore
    @Bindable var quickActionsStore: QuickActionsStore
    var theme: AppTheme
    /// ghostty `background-opacity`。乘到 sidebar 底色上 —— 当 < 1 且 NSWindow
    /// 已经是透明时，桌面/下层应用才透得过来。
    var backgroundOpacity: CGFloat = 1.0
    /// Beta gate: when false, workspace rows hide their TerminalStatusIconView
    /// and collapse its layout slot. Forwarded to SidebarListBridge.
    var showStatusIndicators: Bool = false
    /// Drives the footer version number + red pulsing dot when an update
    /// is available. Clicking the version jumps to Settings → Update.
    @Bindable var updateStore: UpdateStore
    @Environment(LanguageStore.self) private var languageStore
    @Environment(\.locale) private var locale
    @State private var metadataMap: [UUID: WorkspaceMetadata] = [:]
    @State private var refreshers: [UUID: MetadataRefresher] = [:]
    @State private var metadataTicker = MetadataChangeTicker()

    // Delete confirmation (alert lives in SwiftUI shell; AppKit row bubbles request up)
    @State private var workspaceToDelete: UUID?

    // Edit-default-command alert (same pattern as deleteAlert: AppKit row only
    // bubbles a request up; SwiftUI shell owns the input field state and writes
    // back through WorkspaceStore on Save).
    @State private var workspaceForCommandEdit: UUID?
    @State private var commandDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarListBridge(
                store: store,
                statusStore: statusStore,
                theme: theme,
                metadata: metadataMap,
                metadataTick: metadataTicker.tick,    // 读取触发 @Observable 跟踪
                languageTick: languageStore.tick,
                backgroundOpacity: backgroundOpacity,
                showStatusIndicators: showStatusIndicators,
                onRequestDelete: { workspaceToDelete = $0 },
                onRequestEditCommand: { id, current in
                    commandDraft = current
                    workspaceForCommandEdit = id
                },
                onRequestNewWorkspace: { createWorkspaceWithDefaultName() }
            )
            // 顶部留出与 traffic light 区的呼吸：原 header 撤掉后，第一行
            // workspace 直接贴到 28pt traffic light inset 下沿会显得局促；
            // lg(16) 让 workspace 列表距 trafficLightInset 下沿有足够喘息。
            .padding(.top, DT.Space.lg)
        }
        .frame(width: DT.Layout.sidebarWidth)
        // Sidebar 区有意不再自画背景 —— 依赖 ContentView 的根 `.background(sidebar)`
        // 单层提供底色。这样 sidebar 区、卡片圆角外、traffic light 带共用同一
        // 根层 alpha，颜色浓度完全一致，中间不出现「双层叠加形成的分格」。
        .onAppear { startRefreshers() }
        .onChange(of: store.workspaces) { _, _ in startRefreshers() }
        .alert(String(localized: (L10n.Sidebar.deleteAlertTitle).withLocale(locale)),
               isPresented: Binding(
                   get: { workspaceToDelete != nil },
                   set: { if !$0 { workspaceToDelete = nil } })) {
            Button(String(localized: (L10n.Sidebar.deleteAlertCancel).withLocale(locale)), role: .cancel) {
                workspaceToDelete = nil
            }
            Button(String(localized: (L10n.Sidebar.deleteAlertConfirm).withLocale(locale)), role: .destructive) {
                if let id = workspaceToDelete { store.deleteWorkspace(id: id) }
                workspaceToDelete = nil
            }
        } message: {
            if let id = workspaceToDelete,
               let ws = store.workspaces.first(where: { $0.id == id }) {
                Text(L10n.Sidebar.deleteAlertMessage(ws.name))
            }
        }
        .alert(String(localized: L10n.Sidebar.commandAlertTitle.withLocale(locale)),
               isPresented: Binding(
                   get: { workspaceForCommandEdit != nil },
                   set: { if !$0 { workspaceForCommandEdit = nil } })) {
            TextField(
                String(localized: L10n.Sidebar.commandAlertPlaceholder.withLocale(locale)),
                text: $commandDraft
            )
            Button(String(localized: L10n.Sidebar.commandAlertCancel.withLocale(locale)), role: .cancel) {
                workspaceForCommandEdit = nil
            }
            Button(String(localized: L10n.Sidebar.commandAlertSave.withLocale(locale))) {
                if let id = workspaceForCommandEdit {
                    store.updateDefaultCommand(workspaceId: id, command: commandDraft)
                }
                workspaceForCommandEdit = nil
            }
        }
    }

    // MARK: - Create

    func createWorkspaceWithDefaultName() {
        // Open a folder picker first; the new workspace will auto-cd into the
        // chosen folder and adopt the folder name. Cancel = no workspace
        // created. The picker is attached as a sheet to the host window so it
        // tracks app focus and tells macOS to grant TCC access in-context.
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: L10n.Sidebar.folderPickerPrompt.withLocale(locale))
        panel.message = String(localized: L10n.Sidebar.folderPickerMessage.withLocale(locale))
        // Pre-seed at the currently focused terminal's cwd so the picker opens
        // somewhere meaningful instead of "Recents". Fallback: home dir.
        if let focused = store.selectedWorkspace?.selectedTab?.focusedTerminalId,
           let cwd = pwdStore.pwd(for: focused),
           !cwd.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }
        let host = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible }
        let handler: (NSApplication.ModalResponse) -> Void = { [self] response in
            guard response == .OK, let url = panel.url else { return }
            createWorkspace(forFolder: url)
        }
        if let host {
            panel.beginSheetModal(for: host, completionHandler: handler)
        } else {
            // No window yet (rare — sidebar visible means there's a window,
            // but kept defensively): fall back to a free-floating panel.
            panel.begin(completionHandler: handler)
        }
    }

    private func createWorkspace(forFolder url: URL) {
        let folderName = url.lastPathComponent
        // basename can be empty for "/" — fall back to numeric default so the
        // workspace row never renders blank.
        let name = folderName.isEmpty
            ? "workspace \(store.workspaces.count + 1)"
            : folderName
        // The first tab adopts whichever Quick Action sits at the top of the
        // user's enabled list (Claude Code by default). nil → plain terminal
        // tab. We do NOT inject `cd '/path'` as defaultCommand — ghostty's
        // `working_directory` (seeded from pwdStore below) starts the shell
        // in the right folder, so the cd would only be a redundant echo.
        let quickActionId = quickActionsStore.displayList.first
        let newTerminalId = store.createWorkspace(name: name, quickActionId: quickActionId)
        // Seed pwd immediately so (a) ghostty starts the shell in the chosen
        // folder via working_directory, and (b) the sidebar's metadata
        // refresher's first git poll (5 s tick) hits the right path.
        pwdStore.setPwd(url.path, for: newTerminalId)
    }

    // MARK: - Refreshers

    private func startRefreshers() {
        let activeIds = Set(store.workspaces.map { $0.id })
        for id in refreshers.keys where !activeIds.contains(id) {
            refreshers[id]?.stop()
            refreshers.removeValue(forKey: id)
            metadataMap.removeValue(forKey: id)
        }
        for ws in store.workspaces where refreshers[ws.id] == nil {
            let meta = WorkspaceMetadata()
            metadataMap[ws.id] = meta
            let workspaceId = ws.id
            let storeRef = store
            let pwdRef = pwdStore
            // workingDirectoryProvider: resolve the workspace's current cwd lazily
            // each tick. Selected tab + its focused terminal can change over time,
            // and the terminal's pwd moves with `cd`, so we can't bake a static
            // path here — we re-read WorkspaceStore + TerminalPwdStore every time.
            let refresher = MetadataRefresher(metadata: meta) { [weak storeRef, weak pwdRef] in
                guard let storeRef, let pwdRef,
                      let ws = storeRef.workspaces.first(where: { $0.id == workspaceId }),
                      let tab = ws.selectedTab
                else { return nil }
                return pwdRef.pwd(for: tab.focusedTerminalId)
            }
            let ticker = metadataTicker  // capture by reference
            refresher.onRefresh = {
                // mutate 引用类型属性 → @Observable 通知 SwiftUI body 重跑 → updateNSView 推 metadata
                // overflow-safe：tick 数值无意义，只要变化就行
                ticker.tick &+= 1
            }
            refreshers[ws.id] = refresher
            refresher.start()
        }
    }
}
