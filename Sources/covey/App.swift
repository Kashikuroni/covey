import AppKit
import SwiftUI
import CoveyKit

@main
struct CoveyApp: App {
    @State private var model: AppModel?
    @State private var startupError: String?

    init() {
        // Hold-to-repeat for movement keys (holding j/k to scroll in nvim/less):
        // macOS press-and-hold otherwise swallows repeat key-downs for keys with
        // no accent variant (j/k/h/l), so a held key fires exactly once. Every
        // terminal disables it. Must be set() not register(): the input system
        // reads this via CFPreferencesCopyAppValue, which never consults the
        // registration domain — so a registered default has no effect here.
        UserDefaults.standard.set(false, forKey: "ApplePressAndHoldEnabled")
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
                // The backdrop blurs what is behind the window; an opaque
                // window would have nothing to blur.
                window?.isOpaque = false
                window?.backgroundColor = .clear
            }
            .task {
                guard model == nil else { return }
                do {
                    let store = StateStore(path: FileManager.default
                        .homeDirectoryForCurrentUser.appendingPathComponent(".covey/state.json").path)
                    let m = AppModel(client: try CoveyApp.makeClient(),
                                     makeClient: CoveyApp.makeClient,
                                     store: store,
                                     fetchAccount: UsageService.fetchAccount,
                                     fetchGlmAccount: GlmUsageService.fetchAccount)
                    await m.start()
                    Notifier.requestPermission()
                    model = m
                } catch {
                    startupError = "\(error)"
                }
            }
            .onDisappear { model?.stopCodexServer() }
        }
        // Content under the title bar: the topbar row sits at traffic-light
        // level (TopBar pads left for the buttons), and the toolbar is gone.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                CatalogCommandButton(.settings, model: model)
            }
            CommandGroup(replacing: .newItem) {
                CatalogCommandButton(.newSession, model: model)
            }
            CommandGroup(after: .textEditing) {
                Button("Command Palette…") { model?.toggleCommandPalette() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(model == nil || model?.modal != nil)
                Divider()
                CatalogCommandButton(.filterSessions, model: model)
            }
            CommandMenu("Session") {
                CatalogCommandButton(.killSession, model: model)
                CatalogCommandButton(.renameSession, model: model)
            }
            CommandMenu("View") {
                CatalogCommandToggle(.toggleSessionsPanel, model: model,
                                     isOn: model?.showSessions ?? true)
                CatalogCommandToggle(.toggleTopBar, model: model,
                                     isOn: model?.showHeader ?? true)
                CatalogCommandToggle(.toggleStatusBar, model: model,
                                     isOn: model?.showFooter ?? true)
                CatalogCommandToggle(.toggleInspector, model: model,
                                     isOn: model?.showInspector ?? false)
                Divider()
                CatalogCommandButton(.focusSessionList, model: model)
                CatalogCommandButton(.focusAgent, model: model)
                CatalogCommandButton(.focusIssues, model: model)
                CatalogCommandButton(.focusTerminalSplit, model: model)
                CatalogCommandButton(.focusTrace, model: model)
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

private struct CatalogCommandButton: View {
    let command: AppCommand
    let model: AppModel?

    init(_ command: AppCommand, model: AppModel?) {
        self.command = command
        self.model = model
    }

    var body: some View {
        let descriptor = CommandCatalog.descriptor(for: command)
        Button(descriptor.title) { model?.perform(command) }
            .modifier(CatalogShortcutModifier(shortcut: descriptor.shortcut))
            .disabled(catalogCommandDisabled(command, model: model))
    }
}

private struct CatalogCommandToggle: View {
    let command: AppCommand
    let model: AppModel?
    let isOn: Bool

    init(_ command: AppCommand, model: AppModel?, isOn: Bool) {
        self.command = command
        self.model = model
        self.isOn = isOn
    }

    var body: some View {
        let descriptor = CommandCatalog.descriptor(for: command)
        Toggle(descriptor.title, isOn: Binding(
            get: { isOn },
            set: { _ in model?.perform(command) }
        ))
        .modifier(CatalogShortcutModifier(shortcut: descriptor.shortcut))
        .disabled(catalogCommandDisabled(command, model: model))
    }
}

private struct CatalogShortcutModifier: ViewModifier {
    let shortcut: CommandShortcut?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(
                KeyEquivalent(shortcut.key),
                modifiers: shortcut.modifiers
            )
        } else {
            content
        }
    }
}

@MainActor
private func catalogCommandDisabled(_ command: AppCommand, model: AppModel?) -> Bool {
    guard let model, model.modal == nil, !model.commandPalettePresented else { return true }
    return !model.commandAvailability(command).isEnabled
}
