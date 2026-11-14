import Foundation

extension URL {
    /// Indirizzo scritto fisso nel codice (API del broker, di Kimi, link).
    /// Una costante valida non può fallire. Se un domani venisse scritta male
    /// l'app non si ferma: l'indirizzo di ripiego non risponde e la chiamata
    /// dà un errore di rete che si legge nel registro. `FixedURLTests`
    /// controlla che gli indirizzi usati siano quelli giusti.
    static func fixed(_ string: String) -> URL {
        URL(string: string) ?? URL(fileURLWithPath: "/indirizzo-non-valido")
    }
}
