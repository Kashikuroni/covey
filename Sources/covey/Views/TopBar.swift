import SwiftUI

struct TopBar: View {
    @Bindable var model: AppModel

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        HStack(spacing: 12) {
            Spacer()
            TimelineView(.everyMinute) { ctx in
                Text(clock(ctx.date))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(tk.t3)
            }
        }
        // Room for the traffic lights overlaid by the hidden title bar.
        .padding(.leading, 78).padding(.trailing, 14)
        .frame(height: 38)
        .background(tk.surface)
    }

    private func clock(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
