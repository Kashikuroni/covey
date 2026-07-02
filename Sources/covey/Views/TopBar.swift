import SwiftUI

struct TopBar: View {
    @Bindable var model: AppModel
    @State private var view: ViewKind = .standard
    enum ViewKind: String, CaseIterable { case standard = "Standard", git = "Git" }

    var body: some View {
        HStack(spacing: 12) {
            Text("covey").fontWeight(.semibold)
            let c = model.counts
            Text("\(c.total) · ▶\(c.running) · ⏸\(c.waiting)")
                .foregroundStyle(.secondary).font(.callout)
            Spacer()
            Picker("", selection: $view) {
                Text("Standard").tag(ViewKind.standard)
                Text("Git").tag(ViewKind.git).disabled(true)   // stub target
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Button {
                model.setTheme(model.themeRaw == "dark" ? "light" : "dark")
            } label: {
                Image(systemName: model.themeRaw == "dark" ? "sun.max" : "moon")
            }
            .buttonStyle(.borderless).help("Toggle theme")
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                Text(clock(ctx.date)).foregroundStyle(.secondary).font(.callout).monospacedDigit()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func clock(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
