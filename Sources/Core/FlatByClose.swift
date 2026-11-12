import Foundation

/// Broker minimo per il flat-by-close della modalità veloce (testabile con un fake).
protocol FlatCloseBroker: Sendable {
    func openOrders() async throws -> [AlpacaOrder]
    func positions() async throws -> [AlpacaPosition]
    func cancelOrder(id: String) async throws
    func closePosition(symbol: String) async throws
    func submitStop(symbol: String, quantity: Double, stopPrice: Double,
                    clientOrderId: String?) async throws -> AlpacaOrder
}

extension AlpacaService: FlatCloseBroker {}

/// Flat-by-close della modalità VELOCE a T-10 minuti.
///
/// Documentazione Alpaca (verificata 12/11/2026):
/// - `DELETE /v2/positions/{symbol}` (https://docs.alpaca.markets/us/reference/deleteopenposition-1)
///   crea SOLO l'ordine di chiusura a mercato per l'intera posizione: NON annulla gli
///   ordini aperti del simbolo (a differenza del close-all, che ha il parametro
///   `cancel_orders=true`).
/// - Le azioni riservate da ordini di vendita aperti (gamba stop del bracket) restano
///   "held": una nuova vendita sulle stesse azioni viene rifiutata con
///   "insufficient qty", e anche la sequenza cancel→close può fallire per corsa se le
///   azioni risultano ancora riservate (https://alpaca.markets/learn/how-to-fix-common-trading-api-errors-at-alpaca).
/// Quindi: annulla TUTTI gli ordini del simbolo, VERIFICA l'annullo rileggendo gli
/// ordini aperti, poi chiudi a mercato; se la chiusura fallisce rimetti SUBITO lo
/// stop d'emergenza (riconosciuto dal client_order_id qsv-emg-…, mai due insieme).
enum FlatByClose {

    /// client_order_id dello stop d'emergenza: prefisso proprio, riconoscibile a colpo
    /// d'occhio e non dal tipo d'ordine (anche la gamba stop del bracket è una vendita stop).
    static func emergencyStopId(symbol: String, day: String) -> String {
        "\(SystemLimits.emergencyStopPrefix)\(symbol.uppercased())-\(day)"
    }

    /// Chiude un simbolo a mercato dopo aver annullato tutti i suoi ordini aperti.
    /// Ritorna true se la posizione risulta chiusa; altrimenti ha (di nuovo) uno stop
    /// d'emergenza sul broker. A fine tentativo: o chiusa, o con uno stop.
    @discardableResult
    static func closeSymbol(broker: any FlatCloseBroker, symbol: String,
                            emergencyStopPrice: Double?, day: String,
                            log: @Sendable (String) async -> Void) async -> Bool {
        let sym = symbol.uppercased()
        // 1) Annulla TUTTI gli ordini aperti del simbolo: gambe del bracket (stop e
        //    take-profit) ed eventuale stop d'emergenza. Nessuna eccezione per tipo.
        let before = (try? await broker.openOrders()) ?? []
        for order in before where order.symbol.uppercased() == sym && order.isOpen {
            do {
                try await broker.cancelOrder(id: order.id)
            } catch {
                await log("\(sym): annullo di \(order.id) (\(order.type)) fallito: \(error.localizedDescription).")
            }
        }
        // 2) Verifica l'annullo rileggendo gli ordini aperti: dopo un cancel le azioni
        //    possono risultare ancora riservate per un istante (corsa cancel→close).
        let after = (try? await broker.openOrders()) ?? []
        let residual = after.filter { $0.symbol.uppercased() == sym && $0.isOpen }
        if !residual.isEmpty {
            await log("\(sym): dopo l'annullo restano \(residual.count) ordini aperti; chiudo lo stesso e ricontrollo.")
        }
        // 3) Chiudi a mercato l'intera posizione.
        do {
            try await broker.closePosition(symbol: sym)
            await log("\(sym): posizione chiusa a mercato (flat-by-close).")
            return true
        } catch {
            await log("\(sym): chiusura a mercato fallita (\(error.localizedDescription)).")
        }
        // 4) Chiusura fallita: rimetti SUBITO lo stop d'emergenza, senza duplicati.
        guard let stop = emergencyStopPrice, stop > 0 else { return false }
        let qty = (try? await broker.positions())?.first { $0.symbol.uppercased() == sym }?.quantityValue ?? 0
        guard qty > 0 else { return false }
        let emgId = emergencyStopId(symbol: sym, day: day)
        let current = (try? await broker.openOrders()) ?? []
        if current.contains(where: { $0.clientOrderId == emgId }) {
            await log("\(sym): stop d'emergenza \(emgId) già presente sul broker: non ne metto un altro.")
            return false
        }
        do {
            _ = try await broker.submitStop(symbol: sym, quantity: qty, stopPrice: stop, clientOrderId: emgId)
            await log("\(sym): stop d'emergenza GTC a \(String(format: "%.2f", stop)) USD (\(emgId)).")
        } catch {
            await log("\(sym): anche lo stop d'emergenza è fallito (\(error.localizedDescription)): POSIZIONE SENZA STOP.")
        }
        return false
    }
}
