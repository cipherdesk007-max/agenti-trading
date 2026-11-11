import SwiftUI

/// Sistema visivo unico dell'app: colori dell'icona (verde terminale su nero),
/// superfici a strati, angoli continui, numeri a cifre fisse.
enum Theme {
    // Colori
    static let background = Color(red: 0.027, green: 0.035, blue: 0.043)
    static let surface = Color(red: 0.058, green: 0.072, blue: 0.086)
    static let surfaceHigh = Color(red: 0.090, green: 0.110, blue: 0.128)
    static let stroke = Color.white.opacity(0.08)
    static let green = Color(red: 0.12, green: 0.95, blue: 0.63)
    static let cyan = Color(red: 0.36, green: 0.80, blue: 1.0)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let red = Color(red: 1.0, green: 0.33, blue: 0.36)
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.62)
    static let textTertiary = Color(white: 0.42)

    // Forme
    static let radius: CGFloat = 14
    static let smallRadius: CGFloat = 10

    static func shape(_ radius: CGFloat = Theme.radius) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    /// Colore per un valore con segno (guadagno/perdita).
    static func signed(_ value: Double) -> Color { value >= 0 ? green : red }
}

/// Versione installata (MARKETING_VERSION + numero build della CI).
enum AppVersion {
    static var text: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "FMLAB QuantSwarm Alpha Zero \(version) (build \(build))"
    }
}

extension View {
    /// Superficie a scheda: fondo a strati, bordo sottile, accento colorato.
    func themedCard(_ accent: Color = Theme.green, padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [Theme.surfaceHigh, Theme.surface], startPoint: .top, endPoint: .bottom),
                in: Theme.shape()
            )
            .overlay(Theme.shape().strokeBorder(accent.opacity(0.22), lineWidth: 1))
    }

    /// Etichetta a pillola (stato, modalità).
    func themedChip(_ color: Color, filled: Bool = false) -> some View {
        self
            .font(.system(.caption2, design: .monospaced, weight: .heavy))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(filled ? Theme.background : color)
            .background(filled ? color : color.opacity(0.14), in: Capsule())
    }
}
