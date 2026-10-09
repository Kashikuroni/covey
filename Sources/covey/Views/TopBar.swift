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
            // Справа: селект источника Forecast (только на вкладке Forecast)
            // и шестерёнка настроек — на одном уровне с табами и часами.
            HStack(spacing: 10) {
                if model.windowMode == .forecast {
                    ForecastSourceMenu(model: model, tk: tk)
                }
                Button {
                    model.showDashboardSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundStyle(tk.t3)
                }
                .buttonStyle(.plain)
                .help("Dashboard settings — models, prices, providers, keys")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
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

/// Селект источника верхнего блока Forecast: Claude Code (GLM) / Codex (GPT).
/// Лицо — в токенах приложения (капсула в стиле сегментов WindowModeSwitch),
/// поповер — нативное меню с галочкой у текущего пункта. Тот же источник
/// циклит ⌘⇧F (Toggle Forecast Source).
struct ForecastSourceMenu: View {
    let model: AppModel
    let tk: Tokens

    var body: some View {
        Menu {
            Picker("Forecast source", selection: Binding(
                get: { model.forecastSource },
                set: { model.setForecastSource($0) })) {
                Text("Claude Code (GLM)").tag(ForecastSource.claudeCode)
                Text("Codex (GPT)").tag(ForecastSource.codex)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 5) {
                Text(model.forecastSource == .codex ? "Codex (GPT)" : "Claude Code (GLM)")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(tk.t2)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(tk.surf2)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.rSm))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Forecast source — Claude Code (GLM) / Codex (GPT)  ⌘⇧F")
    }
}
