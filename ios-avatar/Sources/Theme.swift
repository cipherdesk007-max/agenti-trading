import SwiftUI
import UIKit

enum Theme {
    static let accent = hexColor(0x00E5FF)
    static let gold = hexColor(0xFFD60A)
    static let danger = hexColor(0xFF453A)
    static let background = Color.black
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

func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
    UIImpactFeedbackGenerator(style: style).impactOccurred()
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Color.black)
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Theme.accent.opacity(0.22), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Theme.accent.opacity(0.10), radius: 10, x: 0, y: 0)
    }
}

extension View {
    func card() -> some View {
        modifier(CardModifier())
    }
}
