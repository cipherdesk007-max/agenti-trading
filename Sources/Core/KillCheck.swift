import Foundation

/// Controllo dopo HARD KILL: il conto è davvero piatto?
///
/// Alpaca risponde "ok" alla richiesta di chiudere tutto anche quando una
/// singola chiusura non parte (la risposta è un elenco con un esito per
/// posizione), e a mercato chiuso le azioni non si vendono subito: l'ordine
/// di chiusura resta in coda fino all'apertura. Per questo dopo la richiesta
/// si rileggono posizioni e ordini e si dice all'utente che cosa c'è davvero.
struct KillCheck: Equatable, Sendable {
    /// Posizioni ancora aperte SENZA un ordine di chiusura: da guardare subito.
    var stillOpen: [String] = []
    /// Posizioni con l'ordine di chiusura in coda (mercato chiuso): si
    /// chiudono alla prossima apertura.
    var queued: [String] = []

    /// Né posizioni né chiusure in attesa.
    var isFlat: Bool { stillOpen.isEmpty && queued.isEmpty }

    /// `positions` = posizioni rilette dal broker dopo la richiesta;
    /// `orderSymbols` = simboli degli ordini ancora aperti (dopo un HARD KILL
    /// gli unici ordini vivi sono le chiusure appena create). Le crypto hanno
    /// due scritture ("BTC/USD" negli ordini, "BTCUSD" nelle posizioni): il
    /// confronto passa da CryptoSymbol.
    static func evaluate(positions: [(symbol: String, quantity: Double)],
                         orderSymbols: [String]) -> KillCheck {
        let closing = Set(orderSymbols.map(CryptoSymbol.key))
        var check = KillCheck()
        for position in positions where abs(position.quantity) > 0.000000001 {
            if closing.contains(CryptoSymbol.key(position.symbol)) {
                check.queued.append(position.symbol)
            } else {
                check.stillOpen.append(position.symbol)
            }
        }
        check.stillOpen.sort()
        check.queued.sort()
        return check
    }
}
