import XCTest
@testable import QuantSwarmAlphaZero

/// Test HTTP di AlpacaService con URLProtocol mock: caso normale e caso di
/// errore (rete assente, ordine rifiutato, risposta parziale) per ogni
/// funzione che invia, annulla o chiude ordini.
final class AlpacaServiceTests: XCTestCase {

    private final class MockURLProtocol: URLProtocol {
        // I test impostano l'handler prima di ogni chiamata e non girano in
        // parallelo: unsafe è intenzionale e isolato dentro questa classe.
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (URLResponse, Data))?
        /// Body della richiesta catturato qui: URLSession può spostarlo su
        /// httpBodyStream, quindi request.httpBody può essere nil nel mock.
        nonisolated(unsafe) static var lastBody: Data?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastBody = request.httpBody ?? request.httpBodyStream.flatMap { stream in
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 8192)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                return data.isEmpty ? nil : data
            }
            do {
                let (response, data) = try Self.handler?(request)
                    ?? (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private var service: AlpacaService!
    private var lastRequest: URLRequest?

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let credentials = AlpacaCredentials(keyID: "PK-TEST", secretKey: "SK-TEST", paperTrading: true)
        service = AlpacaService(credentials: credentials, session: session)
        MockURLProtocol.handler = { [weak self] request in
            self?.lastRequest = request
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.lastBody = nil
        service = nil
        lastRequest = nil
        super.tearDown()
    }

    private func respond(status: Int, body: String) {
        MockURLProtocol.handler = { [weak self] request in
            self?.lastRequest = request
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
    }

    private static let orderJSON = """
        {"id": "ord-1", "status": "pending_new", "symbol": "SPY", "side": "buy", "type": "limit",
         "qty": "2", "filled_qty": "0", "filled_avg_price": null, "submitted_at": "2026-11-12T14:30:00Z",
         "parent_order_id": null, "stop_price": null, "limit_price": "600.00", "legs": []}
        """

    // MARK: - Invio ordini: caso normale

    func testSubmitEntryWithStopSuccessSendsGTCWithStop() async throws {
        respond(status: 200, body: Self.orderJSON)
        let order = try await service.submitEntryWithStop(
            symbol: "SPY", quantity: 2, limitPrice: 600, stopPrice: 585,
            clientOrderId: "qsn-test-1"
        )
        XCTAssertEqual(order.id, "ord-1")
        XCTAssertEqual(order.status, "pending_new")
        XCTAssertEqual(lastRequest?.httpMethod, "POST")
        XCTAssertTrue(lastRequest?.url?.absoluteString.hasSuffix("/v2/orders") ?? false)
        XCTAssertEqual(lastRequest?.value(forHTTPHeaderField: "APCA-API-KEY-ID"), "PK-TEST")
        let body = try XCTUnwrap(MockURLProtocol.lastBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["time_in_force"] as? String, "gtc")
        XCTAssertEqual(json["order_class"] as? String, "oto")
        XCTAssertEqual(json["client_order_id"] as? String, "qsn-test-1")
        XCTAssertNotNil((json["stop_loss"] as? [String: Any])?["stop_price"])
    }

    func testSubmitBracketSuccessDecodesLegs() async throws {
        respond(status: 200, body: """
            {"id": "ord-2", "status": "pending_new", "symbol": "QQQ", "side": "buy", "type": "limit",
             "qty": "1", "submitted_at": "2026-11-12T14:30:00Z", "parent_order_id": null,
             "legs": [
                {"id": "ord-2s", "status": "pending_new", "symbol": "QQQ", "side": "sell", "type": "stop",
                 "qty": "1", "parent_order_id": "ord-2", "stop_price": "500.00"},
                {"id": "ord-2t", "status": "pending_new", "symbol": "QQQ", "side": "sell", "type": "limit",
                 "qty": "1", "parent_order_id": "ord-2", "limit_price": "620.00"}
             ]}
            """)
        let decision = KimiDecision(symbol: "QQQ", action: .buy, confidence: 0.8,
                                     entryPrice: 550, stopLoss: 500, takeProfit: 620,
                                     winProbability: 0.6, payoffRatio: 1.2, rationale: "test")
        let order = try await service.submitBracket(decision: decision, quantity: 1,
                                                    quantityFractionDigits: 0, limitPrice: 550,
                                                    stopPrice: 500, takeProfitPrice: 620,
                                                    clientOrderId: "qsn-bracket-1")
        XCTAssertEqual(order.withLegs.count, 3)
        XCTAssertTrue(order.withLegs.contains { $0.parentOrderId == "ord-2" })
    }

    func testSubmitAuctionSuccessPassesAuctionTIF() async throws {
        respond(status: 200, body: Self.orderJSON)
        _ = try await service.submitAuction(symbol: "SPY", quantity: 3, side: "buy",
                                            timeInForce: "cls", clientOrderId: "qsn-moc-1")
        let body = try XCTUnwrap(MockURLProtocol.lastBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["time_in_force"] as? String, "cls")
        XCTAssertEqual(json["type"] as? String, "market")
        XCTAssertEqual(json["qty"] as? String, "3")
    }

    func testSubmitMarketSuccessForPartialNightSell() async throws {
        respond(status: 200, body: Self.orderJSON)
        _ = try await service.submitMarket(symbol: "SPY", quantity: 1, side: "sell",
                                           clientOrderId: "qsn-s-1")
        let body = try XCTUnwrap(MockURLProtocol.lastBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["side"] as? String, "sell")
        XCTAssertEqual(json["time_in_force"] as? String, "day")
    }

    func testSubmitStopSuccessIsGTC() async throws {
        respond(status: 200, body: Self.orderJSON)
        _ = try await service.submitStop(symbol: "SPY", quantity: 2, stopPrice: 585)
        let body = try XCTUnwrap(MockURLProtocol.lastBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["time_in_force"] as? String, "gtc")
        XCTAssertEqual(json["type"] as? String, "stop")
    }

    // MARK: - Annullamento e chiusura: caso normale

    func testCancelOrderSuccess() async throws {
        respond(status: 204, body: "")
        try await service.cancelOrder(id: "ord-1")
        XCTAssertEqual(lastRequest?.httpMethod, "DELETE")
        XCTAssertTrue(lastRequest?.url?.absoluteString.hasSuffix("/v2/orders/ord-1") ?? false)
    }

    func testClosePositionSuccessReturnsOrder() async throws {
        respond(status: 200, body: Self.orderJSON)
        let order = try await service.closePositionReturningOrder(symbol: "SPY")
        XCTAssertEqual(order?.id, "ord-1")
        XCTAssertEqual(lastRequest?.httpMethod, "DELETE")
        XCTAssertTrue(lastRequest?.url?.absoluteString.hasSuffix("/v2/positions/SPY") ?? false)
    }

    // MARK: - Casi di errore

    func testSubmitOrderRejected422ThrowsHTTPStatus() async {
        respond(status: 422, body: "{\"code\": 40310000, \"message\": \"insufficient buying power\"}")
        await XCTAssertThrowsErrorAsync(
            try await service.submitEntryWithStop(symbol: "SPY", quantity: 100, limitPrice: 600,
                                                  stopPrice: 585, clientOrderId: "qsn-rej")
        ) { error in
            guard case QuantSwarmError.httpStatus(let status, let body) = error else {
                return XCTFail("Atteso httpStatus, ottenuto \(error)")
            }
            XCTAssertEqual(status, 422)
            XCTAssertTrue(body.contains("insufficient buying power"))
        }
    }

    func testCancelOrder404Throws() async {
        respond(status: 404, body: "{\"message\": \"order not found\"}")
        await XCTAssertThrowsErrorAsync(try await service.cancelOrder(id: "missing")) { error in
            guard case QuantSwarmError.httpStatus(let status, _) = error else {
                return XCTFail("Atteso httpStatus, ottenuto \(error)")
            }
            XCTAssertEqual(status, 404)
        }
    }

    func testClosePositionPartialResponseDoesNotThrow() async throws {
        // DELETE posizione può rispondere 200 con un corpo non decodabile come
        // ordine: la chiusura è riuscita lo stesso e non deve sembrare fallita.
        respond(status: 200, body: "{}")
        let order = try await service.closePositionReturningOrder(symbol: "SPY")
        XCTAssertNil(order)
    }

    func testNetworkAbsentNonHTTPResponseThrowsImmediately() async {
        MockURLProtocol.handler = { [weak self] request in
            self?.lastRequest = request
            return (URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), Data())
        }
        await XCTAssertThrowsErrorAsync(try await service.account()) { error in
            guard case QuantSwarmError.invalidServerResponse = error else {
                return XCTFail("Atteso invalidServerResponse, ottenuto \(error)")
            }
        }
    }

    func testURLErrorIsRetriedThenThrows() async {
        MockURLProtocol.handler = { request in
            throw URLError(.notConnectedToInternet)
        }
        await XCTAssertThrowsErrorAsync(try await service.openOrders()) { error in
            XCTAssertTrue(error is URLError)
        }
    }

    func testAccountDecodeFailureThrowsInvalidServerResponse() async {
        respond(status: 200, body: "not-json")
        await XCTAssertThrowsErrorAsync(try await service.account()) { error in
            guard case QuantSwarmError.invalidServerResponse(let message) = error else {
                return XCTFail("Atteso invalidServerResponse, ottenuto \(error)")
            }
            XCTAssertTrue(message.contains("decode"))
        }
    }

    // MARK: - Configurazioni conto (voce "trades suspended", errore 40310000)

    func testAccountConfigurationsDecodesSuspendTrade() async throws {
        respond(status: 200, body: """
            {"dtbp_check": "both", "fractional_trading": true, "no_shorting": false,
             "suspend_trade": true, "trade_confirm_email": "all"}
            """)
        let config = try await service.accountConfigurations()
        XCTAssertEqual(lastRequest?.httpMethod, "GET")
        XCTAssertTrue(lastRequest?.url?.absoluteString.hasSuffix("/v2/account/configurations") ?? false,
                      "il flag si legge da GET /v2/account/configurations")
        XCTAssertEqual(config.isSuspended, true, "suspend_trade true = il conto rifiuta i nuovi ordini")
    }

    func testAccountConfigurationsAcceptsLegacyFieldName() async throws {
        respond(status: 200, body: """
            {"trade_suspended_by_user": true, "no_shorting": false}
            """)
        let config = try await service.accountConfigurations()
        XCTAssertEqual(config.isSuspended, true,
                       "il nome storico del flag (API v2 precedenti) va accettato lo stesso")
    }

    func testAccountConfigurationsWithoutFlagIsUnknown() async throws {
        respond(status: 200, body: """
            {"no_shorting": false}
            """)
        let config = try await service.accountConfigurations()
        XCTAssertNil(config.isSuspended, "campo assente = non verificato, non falso")
    }

    func testSetSuspendTradePatchesTheFlag() async throws {
        respond(status: 200, body: """
            {"fractional_trading": true, "no_shorting": false, "suspend_trade": false}
            """)
        let config = try await service.setSuspendTrade(false)
        XCTAssertEqual(lastRequest?.httpMethod, "PATCH")
        XCTAssertEqual(config.isSuspended, false)
        let body = try XCTUnwrap(MockURLProtocol.lastBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["suspend_trade"] as? Bool, false,
                      "la PATCH deve impostare suspend_trade=false: è la voce \"trades suspended\" del pannello Alpaca")
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ message: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ errorHandler: (Error) -> Void
    ) async {
        do {
            _ = try await expression()
            XCTFail(message ?? "Atteso un errore, ma la chiamata è riuscita", file: file, line: line)
        } catch {
            errorHandler(error)
        }
    }
}
