import SwiftUI

let topBarFontSize: CGFloat = 13
let topBarFontDesign: Font.Design = .monospaced
let topBarLeadingInset: CGFloat = 78
let topBarTrailingInset: CGFloat = 14

func topBarAlignment(_ placement: UsagePlacement) -> Alignment {
    switch placement {
    case .left: return .leading
    case .center: return .center
    case .right: return .trailing
    }
}

/// Moves the limits card into the same asymmetric horizontal region used by
/// the compact limits block in `TopBar`.
func limitsOverlayHorizontalOffset(_ placement: UsagePlacement) -> CGFloat {
    switch placement {
    case .left: return topBarLeadingInset
    case .center: return (topBarLeadingInset - topBarTrailingInset) / 2
    case .right: return -topBarTrailingInset
    }
}

struct TopBar: View {
    @Bindable var model: AppModel

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        UsageChip(usage: (model.claudeUsageEnabled && model.providerIsAnthropic) ? model.usage : nil,
                  usageError: (model.claudeUsageEnabled && model.providerIsAnthropic) ? model.usageError : nil,
                  codexUsage: model.codexUsageEnabled ? model.codexUsage : nil, tk: tk)
            .font(.system(size: topBarFontSize, design: topBarFontDesign))
            .frame(maxWidth: .infinity, alignment: topBarAlignment(model.usagePlacement))
            // Room for the traffic lights overlaid by the hidden title bar:
            // the cluster ends 69pt in, so 78 leaves it 9pt of air.
            .padding(.leading, topBarLeadingInset)
            .padding(.trailing, topBarTrailingInset)
            // Twice the traffic lights' centre, so the row is symmetric about
            // them. AppKit puts those 14pt buttons 9pt below the window's top
            // edge, i.e. centred at 16pt; at any greater height the row grows
            // downwards only and reads bottom-heavy. The 16pt-tall chip still
            // clears 8pt above and below.
            .frame(height: 32)
    }
}
