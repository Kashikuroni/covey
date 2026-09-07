import SwiftUI

/// The menu-bar window supplies its native background and appearance. Share
/// the existing row data and settings, without layering another glass card.
struct NativeLimitsContent: View {
    let rows: [LimitsRowModel]
    let connectionError: String?
    let settingsAvailable: Bool
    let settingsPending: Bool
    let menuBarEnabled: Bool
    let setEnabled: (UsageProvider, Bool) -> Void
    let setMenuBarEnabled: (Bool) -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("AI Usage Limits").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)

                if let connectionError {
                    Label(connectionError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                }

                ForEach(rows) { row in
                    Divider()
                    provider(row, now: context.date)
                }

                Divider()
                Toggle("Show in menu bar", isOn: Binding(get: { menuBarEnabled }, set: setMenuBarEnabled))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .padding(.top, 8)
            }
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .padding(12)
        }
    }

    private func provider(_ row: LimitsRowModel, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(row.chip.name).font(.system(size: 12, weight: .semibold))
                if let plan = row.chip.plan {
                    Text(plan).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("Enable \(row.chip.name) limits", isOn: Binding(
                    get: { row.enabled }, set: { setEnabled(row.provider, $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(settingsPending || !settingsAvailable)
            }

            ForEach(Array(row.chip.windows.enumerated()), id: \.offset) { entry in
                window(entry.element, enabled: row.enabled, now: now)
            }

            if row.stale {
                Label("Showing last received data", systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = row.emptyMessage {
                Text(message)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 9)
    }

    private func window(_ labeled: LabeledWindow, enabled: Bool, now: Date) -> some View {
        let percent = displayUsagePercent(labeled.window.utilization)
        let color = percent.map { percent in
            let semantic = nativeUsageColor(usageLevel(percent))
            let softened = semantic.blended(withFraction: 0.4, of: .white) ?? semantic
            return Color(nsColor: contrast == .increased ? semantic : softened)
        } ?? .secondary
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(labeled.label).fontWeight(.medium)
                if let reset = labeled.window.resetUnix {
                    Text("resets in \(remainingLabel(resetUnix: reset, now: now))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(percent.map { "\($0)%" } ?? "—")
                    .fontWeight(.semibold).monospacedDigit()
                    .foregroundStyle(.primary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule()
                        .fill(enabled ? color : Color.secondary.opacity(0.3))
                        .frame(width: geometry.size.width * Double(min(100, percent ?? 0)) / 100)
                }
            }
            .frame(height: 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(labeled.label) usage")
            .accessibilityValue(percent.map { "\($0) percent used" } ?? "Unavailable")
        }
    }
}
