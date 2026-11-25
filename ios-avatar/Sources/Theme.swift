import SwiftUI

enum Theme {
    static let accent = Color(red: 0.30, green: 0.72, blue: 1.00)
    static let accent2 = Color(red: 0.55, green: 0.40, blue: 1.00)
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

func hexColor(_ hex: UInt32) -> Color {
    Color(uiColor: UIColor(hex: hex))
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

extension View {
    func card() -> some View {
        modifier(CardModifier())
    }
}
