import AppKit
import SwiftUI
import CoveyKit

@main
struct CoveyApp: App {
    @State private var model: AppModel?
    @State private var startupError: String?

    init() {
        // SwiftPM executables launch as accessory processes; become a real app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("covey") {
            Group {
                if let model {
                    ContentView(model: model)
                } else if let startupError {
                    VStack(spacing: 10) {
                        Text("failed to start").font(.headline)
                        Text(startupError).foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 700, minHeight: 400)
                } else {
                    ProgressView("starting daemon…")
                        .frame(minWidth: 700, minHeight: 400)
                }
            }
            .onAppear {
                // Bring the window to the front on launch. `activate` in init runs
                // before any window exists (SwiftPM apps start as accessory), so
                // the window would otherwise open behind other apps.
                NSApplication.shared.activate(ignoringOtherApps: true)
                let window = NSApplication.shared.windows.first
                window?.makeKeyAndOrderFront(nil)
                // Start with vim-list focus: no control (filter field, buttons)
                // grabs the keyboard, so j/k work immediately.
                window?.makeFirstResponder(nil)
                // Content under the (invisible) title bar so the topbar row
                // sits at traffic-light level, not below it.
                window?.titleVisibility = .hidden
                window?.titlebarAppearsTransparent = true
                window?.styleMask.insert(.fullSizeContentView)
            }
            .task {
                guard model == nil else { return }
                do {
                    let store = StateStore(path: FileManager.default
                        .homeDirectoryForCurrentUser.appendingPathComponent(".covey/state.json").path)
                    let m = AppModel(client: try CoveyApp.makeClient(),
                                     makeClient: CoveyApp.makeClient,
                                     store: store,
                                     fetchAccount: UsageService.fetchAccount)
                    await m.start()
                    model = m
                } catch {
                    startupError = "\(error)"
                }
            }
        }
        // Content under the title bar: the topbar row sits at traffic-light
        // level (TopBar pads left for the buttons), and the toolbar is gone.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { model?.modal = .newSession }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("Filter Sessions") { model?.apply(.startFilter) }
                    .keyboardShortcut("f", modifiers: .command)
            }
            CommandMenu("Session") {
                Button("Kill Session…") {
                    if let selected = model?.selected { model?.modal = .kill(selected) }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model?.selected == nil)
                Button("Rename Session…") {
                    if let selected = model?.selected { model?.modal = .rename(selected) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model?.selected == nil)
            }
            CommandMenu("View") {
                Toggle("Show Sessions", isOn: Binding(
                    get: { model?.showSessions ?? true },
                    set: { model?.setShowSessions($0) }))
                Toggle("Show Top Bar", isOn: Binding(
                    get: { model?.showHeader ?? true },
                    set: { model?.setShowHeader($0) }))
                Toggle("Show Status Bar", isOn: Binding(
                    get: { model?.showFooter ?? true },
                    set: { model?.setShowFooter($0) }))
                Toggle("Show Inspector", isOn: Binding(
                    get: { model?.showInspector ?? false },
                    set: { model?.setShowInspector($0) }))
                Divider()
                Button("Focus Session") { model?.focusZone(.session) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Focus Agent") { model?.focusZone(.agent) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Focus Note") { model?.focusZone(.note) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Focus Issues") { model?.focusZone(.issues) }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Focus Terminal") { model?.focusZone(.terminalSplit) }
                    .keyboardShortcut("5", modifiers: .command)
                Divider()
                Toggle("Vim Mode", isOn: Binding(
                    get: { model?.vimMode ?? false },
                    set: { model?.setVimMode($0) }))
            }
        }
    }

    /// ensureDaemon + connect. The daemon binary lives next to our own binary —
    /// true both for `.build/debug` (swift run) and for a future .app bundle.
    static func makeClient() throws -> IPCClient {
        let binDir = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .deletingLastPathComponent()
        let daemonBinary = binDir.appendingPathComponent("coveyd").path
        let socket = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".covey/coveyd.sock").path
        try DaemonLauncher.ensureDaemon(socketPath: socket, binaryPath: daemonBinary)
        let client = IPCClient(path: socket)
        try client.connect()
        return client
    }
}
