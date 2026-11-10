import Foundation

struct AlpacaOrder: Decodable, Sendable, Identifiable {
    let id: String
    let status: String
    let symbol: String
    let side: String
    let type: String
    let quantity: String?
    let filledQuantity: String?
    let filledAveragePrice: String?
    let submittedAt: String?
    let legs: [AlpacaOrder]?
    /// Le gambe di un bracket (stop/target) hanno il parent_order_id valorizzato:
    /// serve a distinguerle dagli ordini di ingresso nel conteggio dell'esposizione.
    let parentOrderId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case symbol
        case side
        case type
        case quantity = "qty"
        case filledQuantity = "filled_qty"
        case filledAveragePrice = "filled_avg_price"
        case submittedAt = "submitted_at"
        case legs
        case parentOrderId = "parent_order_id"
    }

    var filledQuantityValue: Double { Double(filledQuantity ?? "0") ?? 0 }
    var filledAveragePriceValue: Double? { Double(filledAveragePrice ?? "") }
    var quantityValue: Double { Double(quantity ?? "0") ?? 0 }

    var submittedDate: Date? {
        guard let submittedAt else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: submittedAt) { return date }
        return ISO8601DateFormatter().date(from: submittedAt)
    }

    /// True se l'ordine può ancora essere annullato manualmente.
    var isOpen: Bool {
        ["new", "partially_filled", "accepted", "pending_new", "pending_replace",
         "pending_cancel", "held", "done_for_day"].contains(status)
    }

    /// True se è un ordine di ingresso (non una gamba stop/target di un bracket).
    var isEntryOrder: Bool { parentOrderId == nil }
}

struct AlpacaPosition: Decodable, Sendable, Identifiable {
    let symbol: String
    let quantity: String
    let side: String?
    let averageEntryPrice: String?
    let currentPrice: String?
    let marketValue: String?
    let unrealizedPL: String?
    let unrealizedPLPercent: String?
    let changeToday: String?

    var id: String { symbol }

    enum CodingKeys: String, CodingKey {
        case symbol
        case quantity = "qty"
        case side
        case averageEntryPrice = "avg_entry_price"
        case currentPrice = "current_price"
        case marketValue = "market_value"
        case unrealizedPL = "unrealized_pl"
        case unrealizedPLPercent = "unrealized_plpc"
        case changeToday = "change_today"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try container.decode(String.self, forKey: .symbol)
        quantity = try container.decodeIfPresent(String.self, forKey: .quantity) ?? "0"
        side = try container.decodeIfPresent(String.self, forKey: .side)
        averageEntryPrice = try container.decodeIfPresent(String.self, forKey: .averageEntryPrice)
        currentPrice = try container.decodeIfPresent(String.self, forKey: .currentPrice)
        marketValue = try container.decodeIfPresent(String.self, forKey: .marketValue)
        unrealizedPL = try container.decodeIfPresent(String.self, forKey: .unrealizedPL)
        unrealizedPLPercent = try container.decodeIfPresent(String.self, forKey: .unrealizedPLPercent)
        changeToday = try container.decodeIfPresent(String.self, forKey: .changeToday)
    }

    var quantityValue: Double { Double(quantity) ?? 0 }
    var averageEntryPriceValue: Double? { averageEntryPrice.flatMap(Double.init) }
    var currentPriceValue: Double? { currentPrice.flatMap(Double.init) }
    var marketValueNumber: Double? { marketValue.flatMap(Double.init) }
    var unrealizedPLValue: Double { Double(unrealizedPL ?? "0") ?? 0 }
    var unrealizedPLPercentValue: Double? {
        unrealizedPLPercent.flatMap(Double.init).map { $0 * 100 }
    }
}

struct AlpacaClock: Decodable, Sendable {
    let isOpen: Bool
    let nextOpen: String?
    let nextClose: String?

    enum CodingKeys: String, CodingKey {
        case isOpen = "is_open"
        case nextOpen = "next_open"
        case nextClose = "next_close"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isOpen = try container.decodeIfPresent(Bool.self, forKey: .isOpen) ?? false
        nextOpen = try container.decodeIfPresent(String.self, forKey: .nextOpen)
        nextClose = try container.decodeIfPresent(String.self, forKey: .nextClose)
    }

    private static func parse(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    var nextOpenDate: Date? { Self.parse(nextOpen) }
    var nextCloseDate: Date? { Self.parse(nextClose) }
}

/// Barra storica dal market data REST di Alpaca (backfill candele per Kimi).
struct AlpacaBar: Decodable, Sendable {
    let timestamp: String
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double

    enum CodingKeys: String, CodingKey {
        case timestamp = "t"
        case open = "o"
        case high = "h"
        case low = "l"
        case close = "c"
        case volume = "v"
    }

    var date: Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: timestamp) { return date }
        return ISO8601DateFormatter().date(from: timestamp)
    }

    var candle: Candle? {
        guard let date else { return nil }
        return Candle(timestamp: date, open: open, high: high, low: low, close: close, volume: volume)
    }
}

private struct BarsResponse: Decodable {
    let bars: [AlpacaBar]?
}

/// Ultimo trade dal market data REST (rilettura prezzo dopo la risposta di Kimi).
private struct LatestTradeResponse: Decodable {
    struct Trade: Decodable {
        let price: Double?

        enum CodingKeys: String, CodingKey {
            case price = "p"
        }
    }
    let trade: Trade?
}

actor AlpacaService {
    private let credentials: AlpacaCredentials
    private let session: URLSession

    init(credentials: AlpacaCredentials) {
        self.credentials = credentials
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func validateCredentials() async throws {
        _ = try await account()
    }

    func account() async throws -> AccountSnapshot {
        let data = try await send(path: "/v2/account", method: "GET")
        do {
            return try JSONDecoder().decode(AccountSnapshot.self, from: data)
        } catch {
            let preview = String(decoding: data.prefix(300), as: UTF8.self)
            throw QuantSwarmError.invalidServerResponse(
                "Account decode fallita (\(data.count) byte): \(preview)"
            )
        }
    }

    func openOrders() async throws -> [AlpacaOrder] {
        let data = try await send(
            path: "/v2/orders",
            method: "GET",
            query: [URLQueryItem(name: "status", value: "open")]
        )
        return try JSONDecoder().decode([AlpacaOrder].self, from: data)
    }

    func recentOrders(limit: Int = 20) async throws -> [AlpacaOrder] {
        let data = try await send(
            path: "/v2/orders",
            method: "GET",
            query: [
                URLQueryItem(name: "status", value: "all"),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "direction", value: "desc")
            ]
        )
        return try JSONDecoder().decode([AlpacaOrder].self, from: data)
    }

    func positions() async throws -> [AlpacaPosition] {
        let data = try await send(path: "/v2/positions", method: "GET")
        return try JSONDecoder().decode([AlpacaPosition].self, from: data)
    }

    func clock() async throws -> AlpacaClock {
        let data = try await send(path: "/v2/clock", method: "GET")
        return try JSONDecoder().decode(AlpacaClock.self, from: data)
    }

    func order(id: String) async throws -> AlpacaOrder {
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw QuantSwarmError.invalidServerResponse("Order ID non codificabile")
        }
        // nested=true: senza, Alpaca non restituisce le gambe stop/target e
        // l'esito dei trade chiusi da stop o target non verrebbe mai registrato.
        let data = try await send(
            path: "/v2/orders/\(escaped)",
            method: "GET",
            query: [URLQueryItem(name: "nested", value: "true")]
        )
        return try JSONDecoder().decode(AlpacaOrder.self, from: data)
    }

    /// Lookup per client_order_id: dopo un invio fallito (timeout, rete caduta)
    /// verifica se il broker ha comunque registrato l'ordine, così un retry
    /// non può creare un duplicato. 404 = l'ordine non esiste.
    func order(byClientOrderId clientOrderId: String) async throws -> AlpacaOrder? {
        do {
            let data = try await send(
                path: "/v2/orders:by_client_order_id",
                method: "GET",
                query: [URLQueryItem(name: "client_order_id", value: clientOrderId)]
            )
            return try JSONDecoder().decode(AlpacaOrder.self, from: data)
        } catch QuantSwarmError.httpStatus(let code, _) where code == 404 {
            return nil
        }
    }

    /// Candele storiche per il contesto di Kimi (backfill all'avvio del motore).
    /// Host market data dedicato, piano IEX gratuito.
    func bars(symbol: String, timeframe: String, limit: Int = 100) async throws -> [Candle] {
        guard let escaped = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw QuantSwarmError.invalidServerResponse("Simbolo non codificabile")
        }
        // Senza "start" Alpaca restituisce solo le barre di OGGI (a inizio
        // sessione 1m ≈ 20, 15m ≈ 4). Si parte da 7 giorni fa (copre weekend
        // e festivi) e si chiedono le PIÙ RECENTI con sort=desc, poi si
        // riordina dalla più vecchia: con sort=asc + limit arrivavano le più
        // vecchie della finestra.
        let start = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7 * 86_400))
        let data = try await send(
            baseURL: credentials.marketDataBaseURL,
            path: "/v2/stocks/\(escaped)/bars",
            method: "GET",
            query: [
                URLQueryItem(name: "timeframe", value: timeframe),
                URLQueryItem(name: "start", value: start),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "feed", value: "iex"),
                URLQueryItem(name: "sort", value: "desc")
            ]
        )
        let response = try JSONDecoder().decode(BarsResponse.self, from: data)
        return (response.bars ?? [])
            .compactMap(\.candle)
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Barre GIORNALIERE per la modalità swing: ~420 giorni di calendario
    /// (oltre 260 sedute) per avere SMA200 + RSI + ATR. Rettificate per
    /// dividendi e split, come nel backtest.
    func dailyBars(symbol: String, limit: Int = 300) async throws -> [Candle] {
        guard let escaped = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw QuantSwarmError.invalidServerResponse("Simbolo non codificabile")
        }
        let start = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-420 * 86_400))
        let data = try await send(
            baseURL: credentials.marketDataBaseURL,
            path: "/v2/stocks/\(escaped)/bars",
            method: "GET",
            query: [
                URLQueryItem(name: "timeframe", value: "1Day"),
                URLQueryItem(name: "start", value: start),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "feed", value: "iex"),
                URLQueryItem(name: "adjustment", value: "all"),
                URLQueryItem(name: "sort", value: "desc")
            ]
        )
        let response = try JSONDecoder().decode(BarsResponse.self, from: data)
        return (response.bars ?? [])
            .compactMap(\.candle)
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Ultimo prezzo scambiato (feed IEX): rilettura DOPO la risposta di Kimi,
    /// prima dell'invio dell'ordine. Se il prezzo si è mosso oltre 0,5×ATR
    /// il risk manager annulla: i livelli proposti non valgono più.
    func latestTradePrice(symbol: String) async throws -> Double {
        guard let escaped = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw QuantSwarmError.invalidServerResponse("Simbolo non codificabile")
        }
        let data = try await send(
            baseURL: credentials.marketDataBaseURL,
            path: "/v2/stocks/\(escaped)/trades/latest",
            method: "GET",
            query: [URLQueryItem(name: "feed", value: "iex")]
        )
        let response = try JSONDecoder().decode(LatestTradeResponse.self, from: data)
        guard let price = response.trade?.price, price > 0 else {
            throw QuantSwarmError.invalidServerResponse("Ultimo prezzo assente per \(symbol)")
        }
        return price
    }

    func submitBracket(
        decision: KimiDecision,
        quantity: Double,
        quantityFractionDigits: Int,
        limitPrice: Double,
        stopPrice: Double,
        takeProfitPrice: Double,
        clientOrderId: String
    ) async throws -> AlpacaOrder {
        let body: [String: Any] = [
            "symbol": decision.symbol.uppercased(),
            "qty": decimalString(quantity, fractionDigits: quantityFractionDigits),
            "side": decision.action.rawValue,
            "type": "limit",
            "time_in_force": "day",
            "limit_price": decimalString(limitPrice, fractionDigits: priceFractionDigits(limitPrice)),
            "order_class": "bracket",
            "client_order_id": clientOrderId,
            "extended_hours": false,
            "take_profit": [
                "limit_price": decimalString(
                    takeProfitPrice,
                    fractionDigits: priceFractionDigits(takeProfitPrice)
                )
            ],
            "stop_loss": [
                "stop_price": decimalString(
                    stopPrice,
                    fractionDigits: priceFractionDigits(stopPrice)
                )
            ]
        ]
        let data = try await send(path: "/v2/orders", method: "POST", body: body)
        return try JSONDecoder().decode(AlpacaOrder.self, from: data)
    }

    /// Ingresso della modalità giornaliera: ordine limite d'acquisto con stop
    /// protettivo agganciato (OTO), validi finché non annullati (GTC). Lo stop
    /// vive sul server Alpaca: resta attivo anche con l'app chiusa.
    func submitEntryWithStop(
        symbol: String,
        quantity: Double,
        limitPrice: Double,
        stopPrice: Double,
        clientOrderId: String
    ) async throws -> AlpacaOrder {
        let body: [String: Any] = [
            "symbol": symbol.uppercased(),
            "qty": decimalString(quantity, fractionDigits: 0),
            "side": "buy",
            "type": "limit",
            "time_in_force": "gtc",
            "limit_price": decimalString(limitPrice, fractionDigits: priceFractionDigits(limitPrice)),
            "order_class": "oto",
            "client_order_id": clientOrderId,
            "stop_loss": [
                "stop_price": decimalString(stopPrice, fractionDigits: priceFractionDigits(stopPrice))
            ]
        ]
        let data = try await send(path: "/v2/orders", method: "POST", body: body)
        return try JSONDecoder().decode(AlpacaOrder.self, from: data)
    }

    /// Uscita a regole: prima annulla gli ordini aperti del simbolo (lo stop
    /// GTC tiene impegnate le azioni e bloccherebbe la vendita), poi chiude
    /// la posizione a mercato.
    func exitPosition(symbol: String) async throws {
        let upper = symbol.uppercased()
        for order in try await openOrders() where order.symbol.uppercased() == upper {
            try? await cancelOrder(id: order.id)
        }
        // Alpaca libera le azioni appena la cancellazione è confermata.
        for _ in 0..<5 {
            let still = try await openOrders().contains { $0.symbol.uppercased() == upper }
            if !still { break }
            try await Task.sleep(nanoseconds: 600_000_000)
        }
        try await closePosition(symbol: upper)
    }

    /// Chiude a mercato una singola posizione (controllo manuale dal broker panel).
    func closePosition(symbol: String) async throws {
        guard let escaped = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw QuantSwarmError.invalidServerResponse("Simbolo non codificabile")
        }
        _ = try await send(path: "/v2/positions/\(escaped)", method: "DELETE")
    }

    /// Annulla un singolo ordine aperto (controllo manuale dal broker panel).
    func cancelOrder(id: String) async throws {
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw QuantSwarmError.invalidServerResponse("Order ID non codificabile")
        }
        _ = try await send(path: "/v2/orders/\(escaped)", method: "DELETE")
    }

    func cancelAllAndFlatten() async throws {
        _ = try await send(path: "/v2/orders", method: "DELETE")
        _ = try await send(path: "/v2/positions", method: "DELETE")
    }

    private func send(
        baseURL: URL? = nil,
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) async throws -> Data {
        let absoluteURL = (baseURL ?? credentials.tradingBaseURL).absoluteString + path
        guard var components = URLComponents(string: absoluteURL) else {
            throw QuantSwarmError.invalidServerResponse("URL Alpaca non valido")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw QuantSwarmError.invalidServerResponse("URL Alpaca non valido")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(credentials.keyID, forHTTPHeaderField: "APCA-API-KEY-ID")
        request.setValue(credentials.secretKey, forHTTPHeaderField: "APCA-API-SECRET-KEY")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await sendWithRetry(request)
    }

    private func sendWithRetry(_ request: URLRequest) async throws -> Data {
        let retryableStatuses: Set<Int> = [429, 500, 502, 503, 504]
        for attempt in 0..<4 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw QuantSwarmError.invalidServerResponse("Risposta Alpaca non HTTP")
                }
                if (200..<300).contains(http.statusCode) {
                    return data
                }
                let message = String(decoding: data.prefix(1_000), as: UTF8.self)
                if retryableStatuses.contains(http.statusCode), attempt < 3 {
                    try await backoff(attempt: attempt)
                    continue
                }
                throw QuantSwarmError.httpStatus(http.statusCode, message)
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                if attempt == 3 { throw error }
                try await backoff(attempt: attempt)
            }
        }
        throw QuantSwarmError.invalidServerResponse("Retry Alpaca esauriti")
    }

    private func backoff(attempt: Int) async throws {
        let seconds = pow(2.0, Double(attempt)) + Double.random(in: 0...0.25)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func decimalString(_ value: Double, fractionDigits: Int) -> String {
        String(
            format: "%.\(fractionDigits)f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
    }

    /// Regola Alpaca per i prezzi azionari: 2 decimali sopra 1 USD, 4 sotto.
    private func priceFractionDigits(_ price: Double) -> Int {
        price >= 1 ? 2 : 4
    }
}
