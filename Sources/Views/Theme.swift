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

private struct ProModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// MODALITÀ PRO: niente spiegazioni né testi d'aiuto.
    var proMode: Bool {
        get { self[ProModeKey.self] }
        set { self[ProModeKey.self] = newValue }
    }
}

/// Testo d'aiuto: sparisce in MODALITÀ PRO.
private struct ExplanationModifier: ViewModifier {
    @Environment(\.proMode) private var proMode
    func body(content: Content) -> some View {
        if proMode { EmptyView() } else { content }
    }
}

extension View {
    func explanation() -> some View { modifier(ExplanationModifier()) }

    }

// MARK: - Sistema nuovo (docs/DESIGN.md): griglia 8 pt, un solo accento, componenti unici

/// Griglia di spaziatura: multipli di 8 pt.
enum Layout {
    static let grid: CGFloat = 8
    static let paddingS: CGFloat = 8
    static let paddingM: CGFloat = 16
    static let paddingL: CGFloat = 24
}

extension Theme {
    /// Unico colore d'accento dell'app. Verde/rosso restano solo per
    /// guadagno/perdita e stati; arancione solo per avvisi.
    static let accent = green
    /// Bordo hairline neutro (niente bordi colorati sulle card).
    static let hairline = Color.white.opacity(0.06)
}

extension View {
    /// Numero con cifre tabellari (mai font monospaziato pieno, réservé al registro eventi).
    func tabularNumber(_ font: Font = .title3, _ weight: Font.Weight = .heavy) -> some View {
        self.font(font.weight(weight)).monospacedDigit()
    }
}

/// Card a superficie piena, senza bordo colorato (docs/DESIGN.md).
struct AppCard<Content: View>: View {
    private let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(Layout.paddingM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: Theme.shape())
    }
}

/// Riga valore: etichetta sinistra in caption secondaria, valore destra tabellare.
struct ValueRow: View {
    let label: String
    let value: String
    var valueColor: Color? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.paddingS) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(valueColor ?? Theme.textPrimary)
        }
        .padding(.vertical, 4)
    }
}

/// Pillola di stato con un solo colore semantico (verde/rosso stati, arancione avvisi).
/// Maiuscole solo alla prima lettera e sempre una riga: nelle tile della griglia
/// l'etichetta non deve andare a capo (altezze diverse delle caselle).
struct StatusChip: View {
    let text: String
    let color: Color
    var filled = false
    var body: some View {
        Text(text.capitalizedFirstLetter)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(filled ? Theme.background : color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(filled ? color : color.opacity(0.14), in: Capsule())
    }
}

extension String {
    /// Prima lettera maiuscola, resto invariato (niente "In Posizione"/"Trend Su").
    var capitalizedFirstLetter: String {
        guard let first = first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}

/// Intestazione di sezione: titolo headline + azione opzionale a destra.
struct SectionHeader: View {
    let title: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
    }
}

/// Pulsante "i": mostra la spiegazione su tocco. In MODALITÀ PRO sparisce.
struct InfoButton: View {
    @Environment(\.proMode) private var proMode
    let text: String
    @State private var show = false
    var body: some View {
        if !proMode {
            Button {
                show.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Informazioni")
            .popover(isPresented: $show) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(Layout.paddingM)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
}

/// Pulsante primario: pieno con l'unico accento, testo scuro, area ≥ 44 pt.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, Layout.paddingM)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: Theme.shape())
    }
}

/// Pulsante secondario: ghost, testo accento, bordo hairline, area ≥ 44 pt.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, Layout.paddingM)
            .background(Theme.surfaceHigh, in: Theme.shape())
            .overlay(Theme.shape().strokeBorder(Theme.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Pulsante di avvertenza (arancione, il colore degli avvisi): STOP si distingue
/// dall'azione primaria. Area ≥ 44 pt.
struct WarningButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, Layout.paddingM)
            .background(Theme.amber.opacity(configuration.isPressed ? 0.8 : 1), in: Theme.shape())
    }
}

extension View {
    func primaryButton() -> some View { buttonStyle(PrimaryButtonStyle()) }
    func secondaryButton() -> some View { buttonStyle(SecondaryButtonStyle()) }
    func warningButton() -> some View { buttonStyle(WarningButtonStyle()) }
}
