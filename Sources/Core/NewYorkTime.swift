import Foundation

extension TimeZone {
    /// Fuso di New York: gli orari di borsa si calcolano sempre qui.
    /// L'identificativo esiste su ogni iOS; se mancasse si ripiega sull'ora
    /// solare della costa est (UTC-5) invece di fermare l'app.
    static let newYork: TimeZone = TimeZone(identifier: "America/New_York")
        ?? TimeZone(secondsFromGMT: -5 * 3600)
        ?? TimeZone.current
}
