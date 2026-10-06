import SwiftUI

/// Текстовое действие в языке оверлея: monospace, link-blue, без рамки —
/// замена системным кнопкам внутри стеклянной карточки. Hover подчёркивает
/// и ставит курсор-руку, нажатие гасит цвет. Пережил удаление detailed
/// limits overlay: Forecast-окно использует его для ссылок-действий.
struct OverlayActionLink: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color(nsColor: .linkColor))
                .underline(hovering)
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(OverlayActionLinkStyle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

/// Нажатие гасит линк — bezel нет и во взятом состоянии.
private struct OverlayActionLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}
