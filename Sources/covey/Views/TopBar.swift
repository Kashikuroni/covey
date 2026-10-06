import SwiftUI

let topBarFontSize: CGFloat = 13
let topBarFontDesign: Font.Design = .monospaced
let topBarLeadingInset: CGFloat = 78
let topBarTrailingInset: CGFloat = 14

/// Лимиты и часы всегда по центру топбара: слева — режимы, справа пусто;
/// положение зафиксировано и командой не циклится.
func topBarAlignment(_ placement: UsagePlacement) -> Alignment {
    .center
}

struct TopBar: View {
    @Bindable var model: AppModel

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        ZStack {
            UsageChip(usage: model.usage,
                      usageError: model.usageError,
                      codexUsage: model.codexUsage,
                      glmQuota: model.glmUsageEnabled ? model.glmQuota : nil,
                      glmEnabled: model.glmUsageEnabled,
                      claudeEnabled: model.claudeUsageEnabled,
                      codexEnabled: model.codexUsageEnabled,
                      tk: tk,
                      onClockTap: { model.showProvidersPanel = true })
                .font(.system(size: topBarFontSize, design: topBarFontDesign))
                .frame(maxWidth: .infinity, alignment: topBarAlignment(model.usagePlacement))
            WindowModeSwitch(model: model, tk: tk)
                .frame(maxWidth: .infinity, alignment: windowModeSwitchAlignment(model.usagePlacement))
            // Шестерёнка настроек — справа, на одном уровне с табами и часами.
            Button {
                model.showDashboardSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(tk.t3)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help("Dashboard settings — models, prices, providers, keys")
        }
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
