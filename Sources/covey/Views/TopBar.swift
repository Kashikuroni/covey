import SwiftUI
import AppKit

struct TopBar: View {
    @Bindable var model: AppModel
    /// Windowed mode shows the macOS menu-bar clock; ours only earns its
    /// place when fullscreen hides that one.
    @State private var isFullscreen = false

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        HStack(spacing: 12) {
            Spacer()
            UsageChip(usage: model.usage, plan: model.plan,
                      error: model.usageError, tk: tk)
            if isFullscreen {
                TimelineView(.everyMinute) { ctx in
                    Text(clock(ctx.date))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(tk.t3)
                }
            }
        }
        // Room for the traffic lights overlaid by the hidden title bar.
        .padding(.leading, 78).padding(.trailing, 14)
        .frame(height: 38)
        .background(tk.surface)
        .onAppear {
            isFullscreen = NSApp.windows.contains { $0.styleMask.contains(.fullScreen) }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didEnterFullScreenNotification)) { _ in isFullscreen = true }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didExitFullScreenNotification)) { _ in isFullscreen = false }
    }

    private func clock(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
