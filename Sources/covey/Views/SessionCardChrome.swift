import SwiftUI

enum SessionCardChrome {
    static let focusFadeFraction: CGFloat = 0.25

    static func focusFadeWidth(cardWidth: CGFloat) -> CGFloat {
        max(0, cardWidth) * focusFadeFraction
    }
}

struct SessionFocusBorder: View {
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: Tokens.r)
                .strokeBorder(color, lineWidth: 1)
                .mask(alignment: .leading) {
                    LinearGradient(colors: [.white, .clear],
                                   startPoint: .leading,
                                   endPoint: .trailing)
                        .frame(width: SessionCardChrome.focusFadeWidth(
                            cardWidth: geometry.size.width))
                }
        }
        .allowsHitTesting(false)
    }
}
