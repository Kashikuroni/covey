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
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("covey") {
            Group {
                if let model {
                    ContentView(model: model)
                        .toolbar {
                            Button {
                                model.setTheme(model.themeRaw == "dark" ? "light" : "dark")
                            } label: {
                                Image(systemName: model.themeRaw == "dark" ? "sun.max" : "moon")
                            }
                            .help("Toggle theme")
                        }
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
            .task {
                guard model == nil else { return }
                do {
                    let store = StateStore(path: FileManager.default
                        .homeDirectoryForCurrentUser.appendingPathComponent(".covey/state.json").path)
                    let m = AppModel(client: try CoveyApp.makeClient(),
                                     makeClient: CoveyApp.makeClient,
                                     store: store)
                    await m.start()
                    model = m
                } catch {
                    startupError = "\(error)"
                }
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
