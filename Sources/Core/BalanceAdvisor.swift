import Foundation

/// BALANCE ADVISOR — auto-consiglio sulla modalità in base al saldo del conto
/// (richiesta del proprietario, 13/11/2026). Funzione pura: niente stato,
/// niente ordini, solo un banner suggerito nel CRUSCOTTO e in SISTEMA.
///
/// Soglie decise dal proprietario:
/// - < 1.500 USD → CRYPTO · 24/7: gli ordini frazionati (qty decimale, fino a
///   8 decimali) permettono di operare su OGNI segnale senza blocchi di
///   liquidità; con le azioni intere un conto piccolo resta spesso fermo.
/// - 1.500 – 5.000 USD → PORTAFOGLIO · 30/70 con i gemelli micro
///   (SPYM, QQQM, VTWO, GLDM), oppure CRYPTO · 24/7.
/// - > 5.000 USD → PORTAFOGLIO · 30/70 completo (ETF originali).
///
/// È un CONSIGLIO, non un obbligo: la scelta della modalità resta dell'utente
/// (il selettore non cambia da solo).
enum BalanceAdvisor {
    static let microThreshold = 1_500.0
    static let fullThreshold = 5_000.0

    struct Advice: Sendable, Equatable {
        /// Modalità consigliata (per il testo del banner).
        let recommended: TradingMode
        /// Titolo corto del banner.
        let headline: String
        /// Spiegazione del perché (una frase, mostrata nel banner).
        let detail: String
        /// Seconda possibilità, se la fascia ne ha una.
        let alternative: String?
    }

    /// nil finché il saldo non è noto (o non positivo). `maskAmounts` sostituisce
    /// il numero del saldo con un testo neutro quando NASCONDI SALDO è attivo.
    static func advise(equity: Double?, maskAmounts: Bool = false) -> Advice? {
        guard let equity, equity.isFinite, equity > 0 else { return nil }
        let balance = maskAmounts ? "In questa fascia di saldo" : "Con \(Int(equity)) USD"
        if equity < microThreshold {
            return Advice(
                recommended: .crypto,
                headline: "Saldo piccolo: consiglio CRYPTO · 24/7",
                detail: "\(balance) gli ordini frazionati della crypto (anche 0,0001 BTC) fanno operare il bot su ogni segnale; con le azioni intere un conto così resta spesso fermo. Blocco drawdown al 10% e stop GTC sul broker come nelle altre modalità.",
                alternative: "Alternativa: PORTAFOGLIO · 30/70 con i gemelli micro SPYM/QQQM/VTWO/GLDM."
            )
        }
        if equity <= fullThreshold {
            return Advice(
                recommended: .portfolio,
                headline: "Saldo medio: consiglio PORTAFOGLIO · 30/70 (micro) o CRYPTO · 24/7",
                detail: "\(balance) il portafoglio 30/70 funziona già coi gemelli micro (SPYM, QQQM, VTWO, GLDM) senza azioni intere che bloccano gli ingressi; la crypto resta valida in parallelo o da sola, sempre frazionata.",
                alternative: "CRYPTO · 24/7 come alternativa unica: regole validate dallo studio, paniere equal-weight."
            )
        }
        return Advice(
            recommended: .portfolio,
            headline: "Saldo pieno: consiglio PORTAFOGLIO · 30/70 completo",
            detail: "\(balance) il budget per strategia basta per gli ETF originali della divisione 30/70; niente gemelli micro necessari.",
            alternative: nil
        )
    }
}
