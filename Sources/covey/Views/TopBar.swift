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
        UsageChip(usage: model.claudeUsageEnabled ? model.usage : nil,
                  usageError: model.claudeUsageEnabled ? model.usageError : nil,
                  codexUsage: model.codexUsageEnabled ? model.codexUsage : nil, tk: tk)
            .font(.system(size: topBarFontSize, design: topBarFontDesign))
            .frame(maxWidth: .infinity, alignment: topBarAlignment(model.usagePlacement))
            // Room for the traffic lights overlaid by the hidden title bar:
            // the cluster ends 69pt in, so 78 leaves it 9pt of air.
            .padding(.leading, 78).padding(.trailing, 14)
            // Twice the traffic lights' centre, so the row is symmetric about
            // them. AppKit puts those 14pt buttons 9pt below the window's top
            // edge, i.e. centred at 16pt; at any greater height the row grows
            // downwards only and reads bottom-heavy. The 16pt-tall chip still
            // clears 8pt above and below.
            .frame(height: 32)
    }
}
