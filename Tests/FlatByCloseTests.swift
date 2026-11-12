import XCTest
@testable import QuantSwarmAlphaZero

private struct FakeError: Error {}

/// Box Sendable per catturare i log in una closure @Sendable (test single-threaded).
private final class LogBox: @unchecked Sendable {
    private(set) var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
}

private actor FakeFlatBroker: FlatCloseBroker {
    var orders: [AlpacaOrder] = []
    var positionQty: Double = 0
    var failClose = false
    var failCancelIds: Set<String> = []
    var events: [String] = []
    var stops: [(symbol: String, qty: Double, price: Double, clientId: String?)] = []

    func setOrders(_ value: [AlpacaOrder]) { orders = value }
    func setPositionQty(_ value: Double) { positionQty = value }
    func setFailClose(_ value: Bool) { failClose = value }
    func setFailCancelIds(_ value: Set<String>) { failCancelIds = value }

    func openOrders() async throws -> [AlpacaOrder] { orders.filter { $0.isOpen } }
    func positions() async throws -> [AlpacaPosition] {
        guard positionQty > 0 else { return [] }
        let json = "{\"symbol\":\"SPY\",\"qty\":\"\(positionQty)\"}"
        return [try JSONDecoder().decode(AlpacaPosition.self, from: Data(json.utf8))]
    }
    func cancelOrder(id: String) async throws {
        events.append("cancel \(id)")
        if failCancelIds.contains(id) { throw FakeError() }
        orders.removeAll { $0.id == id }
    }
    func closePosition(symbol: String) async throws {
        events.append("close \(symbol)")
        if failClose { throw FakeError() }
        positionQty = 0
    }
    func submitStop(symbol: String, quantity: Double, stopPrice: Double,
                    clientOrderId: String?) async throws -> AlpacaOrder {
        events.append("stop \(symbol) x\(quantity) @\(stopPrice) id=\(clientOrderId ?? "nil")")
        stops.append((symbol, quantity, stopPrice, clientOrderId))
        let order = AlpacaOrder(id: "emg-\(symbol)", status: "new", symbol: symbol, side: "sell",
                                type: "stop", quantity: String(quantity), filledQuantity: "0",
                                filledAveragePrice: nil, submittedAt: nil, legs: nil,
                                parentOrderId: nil, stopPrice: String(stopPrice), limitPrice: nil,
                                clientOrderId: clientOrderId)
        orders.append(order)
        return order
    }
}

/// Test del flat-by-close della VELOCE: a T-10 si annullano TUTTI gli ordini del
/// simbolo (gambe del bracket e stop d'emergenza), si verifica l'annullo, si chiude
/// a mercato; se la chiusura fallisce si rimette subito lo stop d'emergenza con
/// client_order_id qsv-emg-SIMBOLO-GIORNO, mai due volte lo stesso.
final class FlatByCloseTests: XCTestCase {

    private func order(id: String, side: String, type: String, status: String = "new",
                       parent: String? = nil, clientId: String? = nil, stop: Double? = nil) -> AlpacaOrder {
        AlpacaOrder(id: id, status: status, symbol: "SPY", side: side, type: type,
                    quantity: "5", filledQuantity: "0", filledAveragePrice: nil, submittedAt: nil,
                    legs: nil, parentOrderId: parent, stopPrice: stop.map { String($0) },
                    limitPrice: nil, clientOrderId: clientId)
    }

    /// Bracket aperto a T-10: gamba stop + gamba take-profit vengono annullate,
    /// poi la posizione si chiude a mercato. Nessuno stop residuo.
    func testBracketLegsCanceledThenPositionClosed() async {
        let broker = FakeFlatBroker()
        await broker.setOrders([
            order(id: "leg-stop", side: "sell", type: "stop", parent: "e1", stop: 90),
            order(id: "leg-tp", side: "sell", type: "limit", parent: "e1")
        ])
        await broker.setPositionQty(5)
        let closed = await FlatByClose.closeSymbol(broker: broker, symbol: "SPY",
                                                   emergencyStopPrice: 90, day: "2026-11-12") { _ in }
        XCTAssertTrue(closed)
        let events = await broker.events
        XCTAssertTrue(events.contains("cancel leg-stop"), "la gamba stop del bracket va annullata")
        XCTAssertTrue(events.contains("cancel leg-tp"), "la gamba take-profit va annullata")
        XCTAssertTrue(events.contains("close SPY"))
        XCTAssertTrue((await broker.stops).isEmpty, "posizione chiusa: nessuno stop d'emergenza")
        XCTAssertTrue((await broker.openOrders()).isEmpty, "nessun ordine residuo")
    }

    /// Chiusura fallita: lo stop d'emergenza viene rimesso subito, con il
    /// client_order_id qsv-emg-SIMBOLO-GIORNO e la quantità detenuta.
    func testCloseFailsEmergencyStopPlaced() async {
        let broker = FakeFlatBroker()
        await broker.setPositionQty(5)
        await broker.setFailClose(true)
        let closed = await FlatByClose.closeSymbol(broker: broker, symbol: "SPY",
                                                   emergencyStopPrice: 90, day: "2026-11-12") { _ in }
        XCTAssertFalse(closed)
        let stops = await broker.stops
        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops.first?.clientId, "qsv-emg-SPY-2026-11-12")
        XCTAssertEqual(stops.first?.qty, 5)
        XCTAssertEqual(stops.first?.price, 90)
        let open = await broker.openOrders()
        XCTAssertEqual(open.count, 1)
        XCTAssertTrue(open.first?.isEmergencyStop ?? false, "lo stop si riconosce dal client_order_id, non dal tipo")
    }

    /// Secondo tentativo riuscito: il retry annulla anche lo stop d'emergenza
    /// (annulla TUTTI gli ordini del simbolo), chiude, e non ne mette un altro.
    func testSecondAttemptSucceedsWithNoResidualOrders() async {
        let broker = FakeFlatBroker()
        await broker.setPositionQty(5)
        await broker.setFailClose(true)
        let first = await FlatByClose.closeSymbol(broker: broker, symbol: "SPY",
                                                  emergencyStopPrice: 90, day: "2026-11-12") { _ in }
        XCTAssertFalse(first)
        XCTAssertEqual((await broker.stops).count, 1)
        // Secondo tentativo: la chiusura ora riesce.
        await broker.setFailClose(false)
        let second = await FlatByClose.closeSymbol(broker: broker, symbol: "SPY",
                                                   emergencyStopPrice: 90, day: "2026-11-12") { _ in }
        XCTAssertTrue(second)
        let events = await broker.events
        XCTAssertTrue(events.contains("cancel emg-SPY"), "il retry annulla anche lo stop d'emergenza")
        XCTAssertEqual((await broker.stops).count, 1, "niente secondo stop d'emergenza dopo la chiusura riuscita")
        XCTAssertTrue((await broker.openOrders()).isEmpty, "nessun ordine residuo a fine tentativo")
    }

    /// Mai due stop d'emergenza insieme: se qsv-emg-… è già aperto (e il suo annullo
    /// è fallito, quindi resta vivo sul broker), non si rimette.
    func testNeverTwoEmergencyStopsTogether() async {
        let broker = FakeFlatBroker()
        await broker.setPositionQty(5)
        await broker.setFailClose(true)
        let emgId = FlatByClose.emergencyStopId(symbol: "SPY", day: "2026-11-12")
        await broker.setOrders([order(id: "old-emg", side: "sell", type: "stop", clientId: emgId, stop: 88)])
        await broker.setFailCancelIds(["old-emg"])
        let closed = await FlatByClose.closeSymbol(broker: broker, symbol: "SPY",
                                                   emergencyStopPrice: 90, day: "2026-11-12") { _ in }
        XCTAssertFalse(closed)
        XCTAssertTrue((await broker.stops).isEmpty, "stop d'emergenza già presente: non ne viene messo un altro")
        let open = await broker.openOrders()
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open.first?.clientOrderId, emgId)
    }

    /// Annulllo di una gamba fallito: si chiude lo stesso a mercato, ma il log avvisa
    /// che restano ordini aperti (le azioni possono risultare ancora riservate).
    func testFailedCancelIsLoggedAndCloseStillAttempted() async {
        let broker = FakeFlatBroker()
        await broker.setOrders([order(id: "leg-stop", side: "sell", type: "stop", parent: "e1", stop: 90)])
        await broker.setFailCancelIds(["leg-stop"])
        await broker.setPositionQty(5)
        let box = LogBox()
        let closed = await FlatByClose.closeSymbol(broker: broker, symbol: "SPY",
                                                   emergencyStopPrice: 90, day: "2026-11-12") { box.append($0) }
        XCTAssertTrue(closed, "la chiusura viene tentata comunque")
        XCTAssertTrue(box.lines.contains { $0.contains("restano") }, "il log avvisa degli ordini rimasti aperti dopo l'annullo")
    }
}
