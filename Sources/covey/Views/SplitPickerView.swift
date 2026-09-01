import SwiftUI

/// Модалка выбора (spec «Модалка выбора» + «Дизайн модалки»): заголовок по
/// оси, общий контейнер «Split View», карточки с одинаковым отступом,
/// j/k и стрелки, Enter, Esc, стартовый фокус на «Терминал».
struct SplitPickerView: View {
    @Bindable var model: AppModel
    let axis: PaneAxis
    @State private var index = 0

    private var items: [SplitPickerItem] { model.splitPickerItems(for: axis) }
    private var title: String {
        axis == .vertical ? "Вертикальный сплит" : "Горизонтальный сплит"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 0) {
                Text("Split View")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                ForEach(items) { item in
                    let i = items.firstIndex(of: item) ?? 0
                    row(item, selected: i == index)
                        .onTapGesture { choose(i) }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.15))
            )
            .padding(.leading, 12)          // карточки сдвинуты от рамки —
                                            // расстояние между ними не меняется
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { index = 0 }             // фокус изначально на «Терминал»
        .background { keys }
    }

    private func row(_ item: SplitPickerItem, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "app.dashed")
                .frame(width: 16)
            Text(item.label).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        index = (index + delta + items.count) % items.count
    }

    private func choose(_ i: Int) {
        guard items.indices.contains(i) else { return }
        let item = items[i]
        Task { await model.splitPickerChosen(item) }
    }

    /// Шит принадлежит своему key window: клавиши — скрытые кнопки
    /// со шорткатами (проверенный SwiftUI-приём для sheet-навигации).
    private var keys: some View {
        Group {
            Button("Down") { move(1) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("Up") { move(-1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("j Down") { move(1) }.keyboardShortcut("j", modifiers: [])
            Button("k Up") { move(-1) }.keyboardShortcut("k", modifiers: [])
            Button("Choose") { choose(index) }.keyboardShortcut(.defaultAction)
            Button("Cancel") { model.modal = nil }.keyboardShortcut(.cancelAction)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
