import SwiftUI

let topBarFontSize: CGFloat = 13
let topBarFontDesign: Font.Design = .monospaced

func topBarAlignment(_ placement: UsagePlacement) -> Alignment {
    switch placement {
    case .left: return .leading
    case .center: return .center
    case .right: return .trailing
    }
}

struct TopBar: View {
    @Bindable var model: AppModel

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        UsageChip(usage: model.usage, usageError: model.usageError,
                  codexUsage: model.codexUsage, tk: tk)
            .font(.system(size: topBarFontSize, design: topBarFontDesign))
            .frame(maxWidth: .infinity, alignment: topBarAlignment(model.usagePlacement))
            // Room for the traffic lights overlaid by the hidden title bar.
            .padding(.leading, 78).padding(.trailing, 14)
            .frame(height: 38)
            .background(tk.surface)
    }
}
