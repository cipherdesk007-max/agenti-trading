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
    let stopPrice: String?
    /// Prezzo limite (ingresso limite o gamba take-profit).
    let limitPrice: String?
    /// client_order_id: serve a riconoscere lo stop d'emergenza (prefisso qsv-emg-).
    let clientOrderId: String?

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
        case stopPrice = "stop_price"
        case limitPrice = "limit_price"
        case clientOrderId = "client_order_id"
    }

    var stopPriceValue: Double? { stopPrice.flatMap(Double.init) }
    var limitPriceValue: Double? { limitPrice.flatMap(Double.init) }

    /// L'ordine e le sue gambe (bracket), appiattiti.
    var withLegs: [AlpacaOrder] { [self] + (legs ?? []).flatMap(\.withLegs) }

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

    /// Stop d'emergenza del flat-by-close: riconosciuto dal client_order_id
    /// (prefisso qsv-emg-), non dal tipo d'ordine.
    var isEmergencyStop: Bool {
        clientOrderId?.hasPrefix(SystemLimits.emergencyStopPrefix) ?? false
    }

    /// True se l'ordine esiste sul broker e può ancora eseguirsi (o si è già
    /// eseguito). Usato nel recupero per client_order_id: un ordine rifiutato
    /// o annullato non è un invio riuscito. Stati da
    /// docs.alpaca.markets/reference/postorder.
    var countsAsPlaced: Bool {
        ["new", "partially_filled", "accepted", "pending_new", "pending_replace",
         "pending_cancel", "held", "done_for_day", "filled"].contains(status)
    }
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

/// Risposta di GET /v2/stocks/{symbol}/auctions: per giorno, aste di apertura
/// ("o") e di chiusura ("c") con prezzo, timestamp, size, exchange.
private struct AlpacaAuctionsResponse: Decodable {
    let auctions: [String: [AlpacaDayAuctions]]
}

private struct AlpacaDayAuctions: Decodable {
    let d: String
    let o: [AlpacaAuctionPrint]
    let c: [AlpacaAuctionPrint]
}

private struct AlpacaAuctionPrint: Decodable {
    let p: Double?
    let s: Int?
    let t: String?
    let x: String?
    let c: String?
}

/// Giorno di borsa dal calendario USA (GET /v2/calendar): open/close in ora di
/// New York, con le chiusure anticipate (mezze giornate) già applicate.
struct AlpacaCalendarDay: Decodable, Sendable, Equatable {
    let date: String
    let open: String?
    let close: String?

    /// Chiusura esatta del giorno come Date (fuso America/New_York).
    var closeDate: Date? {
        guard let close else { return nil }
        let d = date.split(separator: "-").compactMap { Int($0) }
        let t = close.split(separator: ":").compactMap { Int($0) }
        guard d.count == 3, t.count >= 2 else { return nil }
        var c = DateComponents()
        c.calendar = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")
        c.year = d[0]; c.month = d[1]; c.day = d[2]
        c.hour = t[0]; c.minute = t[1]
        return c.date
    }
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

/// Risposta /v1beta3/crypto/us/bars: barre per simbolo + token di paginazione.
private struct CryptoBarsResponse: Decodable {
    let bars: [String: [AlpacaBar]]?
    let nextPageToken: String?

    enum CodingKeys: String, CodingKey {
        case bars
        case nextPageToken = "next_page_token"
    }
}

/// Risposta /v1beta3/crypto/us/latest/quotes: bid/ask per simbolo.
private struct CryptoLatestQuotesResponse: Decodable {
    struct Quote: Decodable {
        let bp: Double?
        let ap: Double?
    }

    let quotes: [String: Quote]?
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

    /// Init per i test: sessione iniettabile (con URLProtocol mock).
    init(credentials: AlpacaCredentials, session: URLSession) {
        self.credentials = credentials
        self.session = session
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

    /// Prezzo reale dell'asta di un giorno (GET /v2/stocks/{symbol}/auctions,
    /// feed sip): kind "open" = asta di apertura (OPG), "close" = asta di chiusura
    /// (MOC). Restituisce l'ultima stampa dell'asta. Solo misura: in caso di
    /// errore l'app si comporta come prima (nil).
    func auctionPrice(symbol: String, day: String, kind: String) async throws -> Double? {
        guard let escaped = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        let data = try await send(
            baseURL: credentials.marketDataBaseURL,
            path: "/v2/stocks/\(escaped)/auctions",
            method: "GET",
            query: [URLQueryItem(name: "start", value: day),
                    URLQueryItem(name: "end", value: day),
                    URLQueryItem(name: "feed", value: "sip"),
                    URLQueryItem(name: "limit", value: "10000")]
        )
        let resp = try JSONDecoder().decode(AlpacaAuctionsResponse.self, from: data)
        guard let entry = resp.auctions[symbol.uppercased()]?.first(where: { $0.d == day }) else { return nil }
        let prints = kind == "open" ? entry.o : entry.c
        return prints.compactMap { $0.p }.last
    }

    /// Calendario di borsa USA (GET /v2/calendar): stesso piano e stesso limite
    /// della Trading API (200 req/min per conto). Mai obbligatoria: in caso di
    /// errore l'app resta su clock() come prima.
    func calendar(start: Date, end: Date) async throws -> [AlpacaCalendarDay] {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "America/New_York")
        fmt.dateFormat = "yyyy-MM-dd"
        let data = try await send(
            path: "/v2/calendar",
            method: "GET",
            query: [URLQueryItem(name: "start", value: fmt.string(from: start)),
                    URLQueryItem(name: "end", value: fmt.string(from: end))]
        )
        return try JSONDecoder().decode([AlpacaCalendarDay].self, from: data)
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

    /// Notizie Benzinga (News API di Alpaca, stesse chiavi): ultime `hours` ore,
    /// le più recenti prima, solo titoli.
    func news(symbols: [String], hours: Int, limit: Int = 50) async throws -> [NewsHeadline] {
        let iso = ISO8601DateFormatter()
        let query = [
            URLQueryItem(name: "symbols", value: symbols.joined(separator: ",")),
            URLQueryItem(name: "start", value: iso.string(from: Date().addingTimeInterval(-Double(hours) * 3_600))),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50))),
            URLQueryItem(name: "sort", value: "desc"),
            URLQueryItem(name: "include_content", value: "false")
        ]
        let data = try await send(baseURL: credentials.marketDataBaseURL, path: "/v1beta1/news", method: "GET", query: query)
        let parser = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (try JSONDecoder().decode(NewsResponse.self, from: data).news ?? []).compactMap { item in
            guard let date = parser.date(from: item.created_at) ?? fractional.date(from: item.created_at) else { return nil }
            let title = item.headline.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return NewsHeadline(id: item.id, headline: String(title.prefix(220)), createdAt: date,
                                symbols: item.symbols ?? [], source: item.source ?? "benzinga", url: item.url)
        }
    }

    /// Candele per i grafici (1Hour, 15Min, 5Min…), anche a mercato chiuso:
    /// ultimi `days` giorni, le più recenti. Prima SIP (tutte le borse, gratis
    /// se la richiesta finisce ad almeno 15 minuti fa), poi IEX.
    func chartBars(symbol: String, timeframe: String, days: Int, limit: Int = 300) async throws -> [Candle] {
        guard let escaped = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw QuantSwarmError.invalidServerResponse("Simbolo non codificabile")
        }
        // Stringhe calcolate prima: il formatter non è Sendable e non va catturato.
        let iso = ISO8601DateFormatter()
        let start = iso.string(from: Date().addingTimeInterval(-Double(days) * 86_400))
        let sipEnd = iso.string(from: Date().addingTimeInterval(-16 * 60))
        func fetch(_ feed: String) async throws -> [Candle] {
            var query = [
                URLQueryItem(name: "timeframe", value: timeframe),
                URLQueryItem(name: "start", value: start),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "feed", value: feed),
                URLQueryItem(name: "adjustment", value: "all"),
                URLQueryItem(name: "sort", value: "desc")
            ]
            if feed == "sip" {
                query.append(URLQueryItem(name: "end", value: sipEnd))
            }
            let data = try await send(baseURL: credentials.marketDataBaseURL, path: "/v2/stocks/\(escaped)/bars",
                                      method: "GET", query: query)
            let response = try JSONDecoder().decode(BarsResponse.self, from: data)
            return (response.bars ?? []).compactMap(\.candle).sorted { $0.timestamp < $1.timestamp }
        }
        if let sip = try? await fetch("sip"), !sip.isEmpty { return sip }
        return try await fetch("iex")
    }

    /// Barre GIORNALIERE per la modalità swing: ~420 giorni di calendario
    /// (oltre 260 sedute) per avere SMA200 + RSI + ATR. Rettificate per
    /// dividendi e split, come nel backtest.
    func dailyBars(symbol: String, limit: Int = 300) async throws -> [Candle] {
        // Prima il feed consolidato SIP (tutte le borse, come nel backtest):
        // gratuito se la richiesta finisce ad almeno 15 minuti fa. Se il piano
        // non lo consente, si ripiega su IEX.
        if let sip = try? await dailyBars(symbol: symbol, limit: limit, feed: "sip"), !sip.isEmpty {
            return sip
        }
        return try await dailyBars(symbol: symbol, limit: limit, feed: "iex")
    }

    private func dailyBars(symbol: String, limit: Int, feed: String) async throws -> [Candle] {
        guard let escaped = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw QuantSwarmError.invalidServerResponse("Simbolo non codificabile")
        }
        let formatter = ISO8601DateFormatter()
        let start = formatter.string(from: Date().addingTimeInterval(-420 * 86_400))
        var query = [
            URLQueryItem(name: "timeframe", value: "1Day"),
            URLQueryItem(name: "start", value: start),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "feed", value: feed),
            URLQueryItem(name: "adjustment", value: "all"),
            URLQueryItem(name: "sort", value: "desc")
        ]
        if feed == "sip" {
            query.append(URLQueryItem(name: "end", value: formatter.string(from: Date().addingTimeInterval(-16 * 60))))
        }
        let data = try await send(
            baseURL: credentials.marketDataBaseURL,
            path: "/v2/stocks/\(escaped)/bars",
            method: "GET",
            query: query
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
        takeProfitPrice: Double? = nil,
        clientOrderId: String
    ) async throws -> AlpacaOrder {
        var body: [String: Any] = [
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
        // Con il take-profit diventa un bracket: stop e target collegati (OCO),
        // eseguito uno l'altro si annulla, nessun rischio di doppia vendita.
        if let takeProfitPrice, takeProfitPrice > limitPrice {
            body["order_class"] = "bracket"
            body["take_profit"] = [
                "limit_price": decimalString(takeProfitPrice, fractionDigits: priceFractionDigits(takeProfitPrice))
            ]
        }
        let data = try await send(path: "/v2/orders", method: "POST", body: body)
        return try JSONDecoder().decode(AlpacaOrder.self, from: data)
    }

    /// Chiude a mercato una singola posizione (controllo manuale dal broker panel).
    func closePosition(symbol: String) async throws {
        guard let escaped = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw QuantSwarmError.invalidServerResponse("Simbolo non codificabile")
        }
        _ = try await closePositionReturningOrder(symbol: symbol)
    }

    /// Chiusura a mercato che restituisce l'ordine creato (per leggere il
    /// prezzo di esecuzione reale).
    func closePositionReturningOrder(symbol: String) async throws -> AlpacaOrder? {
        guard let escaped = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw QuantSwarmError.invalidServerResponse("Simbolo non codificabile")
        }
        let data = try await send(path: "/v2/positions/\(escaped)", method: "DELETE")
        // La chiusura è riuscita (HTTP 2xx): una risposta non leggibile non
        // deve mai farla sembrare fallita.
        return try? JSONDecoder().decode(AlpacaOrder.self, from: data)
    }

    /// Stop protettivo semplice (vendita stop GTC), usato per ripristinare la
    /// protezione quando manca.
    func submitStop(symbol: String, quantity: Double, stopPrice: Double,
                    clientOrderId: String? = nil) async throws -> AlpacaOrder {
        var body: [String: Any] = [
            "symbol": symbol.uppercased(),
            "qty": decimalString(quantity, fractionDigits: 0),
            "side": "sell",
            "type": "stop",
            "time_in_force": "gtc",
            "stop_price": decimalString(stopPrice, fractionDigits: priceFractionDigits(stopPrice))
        ]
        if let clientOrderId { body["client_order_id"] = clientOrderId }
        let data = try await send(path: "/v2/orders", method: "POST", body: body)
        return try JSONDecoder().decode(AlpacaOrder.self, from: data)
    }

    /// Ordine a mercato in asta (modalità notte): "cls" = asta di chiusura,
    /// "opg" = asta di apertura. Solo azioni intere.
    func submitAuction(symbol: String, quantity: Int, side: String, timeInForce: String,
                       clientOrderId: String) async throws -> AlpacaOrder {
        let body: [String: Any] = [
            "symbol": symbol.uppercased(),
            "qty": String(quantity),
            "side": side,
            "type": "market",
            "time_in_force": timeInForce,
            "client_order_id": clientOrderId
        ]
        let data = try await send(path: "/v2/orders", method: "POST", body: body)
        return try JSONDecoder().decode(AlpacaOrder.self, from: data)
    }

    /// Vendita a mercato a quantità fissa (day). Serve alla modalità notte per
    /// chiudere SOLO le azioni di sua proprietà quando sul conto c'è anche la
    /// stessa azione comprata dalla modalità giornaliera: l'endpoint
    /// /v2/positions/{symbol} chiuderebbe l'intera posizione.
    func submitMarket(symbol: String, quantity: Int, side: String,
                      clientOrderId: String) async throws -> AlpacaOrder {
        let body: [String: Any] = [
            "symbol": symbol.uppercased(),
            "qty": String(quantity),
            "side": side,
            "type": "market",
            "time_in_force": "day",
            "client_order_id": clientOrderId
        ]
        let data = try await send(path: "/v2/orders", method: "POST", body: body)
        return try JSONDecoder().decode(AlpacaOrder.self, from: data)
    }

    /// Annulla un singolo ordine aperto (controllo manuale dal broker panel).
    func cancelOrder(id: String) async throws {
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw QuantSwarmError.invalidServerResponse("Order ID non codificabile")
        }
        _ = try await send(path: "/v2/orders/\(escaped)", method: "DELETE")
    }

    // MARK: - Crypto (v1beta3 market data + ordini `simple` frazionati)

    /// Barre 1D CHIUSE delle coppie crypto richieste (solo barre completate:
    /// l'ultima barra del giorno in corso è in formazione e viene scartata).
    /// `limit` di Alpaca conta i dati TOTALI (non per simbolo) e la risposta
    /// può paginarsi: si segue `next_page_token` finché serve.
    func cryptoDailyBars(symbols: [String], barsPerSymbol: Int = 260,
                         now: Date = Date()) async throws -> [String: [Candle]] {
        guard !symbols.isEmpty else { return [:] }
        let joined = symbols.joined(separator: ",")
        let start = ISO8601DateFormatter().string(
            from: now.addingTimeInterval(-Double(barsPerSymbol + 40) * 86_400)
        )
        var collected: [String: [Candle]] = [:]
        var pageToken: String?
        var pages = 0
        repeat {
            var query = [
                URLQueryItem(name: "symbols", value: joined),
                URLQueryItem(name: "timeframe", value: "1Day"),
                URLQueryItem(name: "start", value: start),
                URLQueryItem(name: "sort", value: "asc"),
                URLQueryItem(name: "limit", value: String(min(barsPerSymbol * symbols.count, 10_000)))
            ]
            if let pageToken { query.append(URLQueryItem(name: "page_token", value: pageToken)) }
            let data = try await send(
                baseURL: credentials.marketDataBaseURL,
                path: "/v1beta3/crypto/us/bars",
                method: "GET",
                query: query
            )
            let response = try JSONDecoder().decode(CryptoBarsResponse.self, from: data)
            for (symbol, bars) in response.bars {
                let candles = bars.compactMap(\.candle)
                collected[symbol, default: []].append(contentsOf: candles)
            }
            pageToken = response.nextPageToken
            pages += 1
        } while pageToken != nil && pages < 5
        for symbol in collected.keys {
            collected[symbol]?.sort { $0.timestamp < $1.timestamp }
            // Barra chiusa: l'inizio + 24h è già passato.
            collected[symbol] = (collected[symbol] ?? []).filter { $0.timestamp.addingTimeInterval(86_400) <= now }
        }
        return collected
    }

    /// Ultime quotazioni (bid/ask) delle coppie crypto; prezzo medio = (bp+ap)/2.
    func latestCryptoQuotes(symbols: [String]) async throws -> [String: Double] {
        guard !symbols.isEmpty else { return [:] }
        let data = try await send(
            baseURL: credentials.marketDataBaseURL,
            path: "/v1beta3/crypto/us/latest/quotes",
            method: "GET",
            query: [URLQueryItem(name: "symbols", value: symbols.joined(separator: ","))]
        )
        let response = try JSONDecoder().decode(CryptoLatestQuotesResponse.self, from: data)
        var mids: [String: Double] = [:]
        for (symbol, quote) in response.quotes {
            if let bid = quote.bp, let ask = quote.ap, bid > 0, ask > 0 {
                mids[symbol] = (bid + ask) / 2
            }
        }
        return mids
    }

    /// Ordine crypto `simple` a mercato, frazionato (qty decimale, max 8
    /// decimali). Le crypto Alpaca NON supportano bracket/oto/oco (422) e il
    /// loro time_in_force è solo gtc/ioc: qui sempre gtc.
    func submitCryptoMarket(symbol: String, quantity: Double, side: String,
                            clientOrderId: String) async throws -> AlpacaOrder {
        let body: [String: Any] = [
            "symbol": symbol.uppercased(),
            "qty": decimalString(quantity, fractionDigits: 8),
            "side": side,
            "type": "market",
            "time_in_force": "gtc",
            "order_class": "simple",
            "client_order_id": clientOrderId
        ]
        let data = try await send(path: "/v2/orders", method: "POST", body: body)
        return try JSONDecoder().decode(AlpacaOrder.self, from: data)
    }

    /// Stop protettivo crypto: vendita `stop_limit` GTC separata (sulle crypto
    /// Alpaca esistono market, limit e stop_limit: NON il "stop" semplice).
    /// `limitPrice` leggermente sotto lo stop per garantire l'esecuzione.
    func submitCryptoStopLimit(symbol: String, quantity: Double, stopPrice: Double,
                               limitPrice: Double, clientOrderId: String) async throws -> AlpacaOrder {
        let body: [String: Any] = [
            "symbol": symbol.uppercased(),
            "qty": decimalString(quantity, fractionDigits: 8),
            "side": "sell",
            "type": "stop_limit",
            "time_in_force": "gtc",
            "order_class": "simple",
            "stop_price": decimalString(stopPrice, fractionDigits: priceFractionDigits(stopPrice)),
            "limit_price": decimalString(limitPrice, fractionDigits: priceFractionDigits(limitPrice)),
            "client_order_id": clientOrderId
        ]
        let data = try await send(path: "/v2/orders", method: "POST", body: body)
        return try JSONDecoder().decode(AlpacaOrder.self, from: data)
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

// MARK: - Adattatore Alpaca → BrokerClient (ciclo giornaliero)

struct AlpacaBroker: BrokerClient {
    let service: AlpacaService

    init(credentials: AlpacaCredentials) {
        service = AlpacaService(credentials: credentials)
    }

    func isMarketOpen() async throws -> Bool { try await service.clock().isOpen }

    func account() async throws -> BrokerAccount {
        let a = try await service.account()
        return BrokerAccount(equity: a.equityValue, cash: a.cashValue, buyingPower: a.buyingPowerValue)
    }

    func positions() async throws -> [BrokerPosition] {
        try await service.positions().map {
            BrokerPosition(symbol: $0.symbol.uppercased(), quantity: $0.quantityValue,
                           averageEntryPrice: $0.averageEntryPriceValue, unrealizedPL: $0.unrealizedPLValue)
        }
    }

    func openOrders() async throws -> [BrokerOrder] {
        try await service.openOrders().map {
            BrokerOrder(id: $0.id, symbol: $0.symbol.uppercased(), side: $0.side, type: $0.type, status: $0.status,
                        quantity: $0.quantityValue, filledQuantity: $0.filledQuantityValue,
                        stopPrice: $0.stopPriceValue, parentOrderId: $0.parentOrderId, submittedAt: $0.submittedDate)
        }
    }

    func dailyBars(symbol: String) async throws -> [Candle] { try await service.dailyBars(symbol: symbol) }

    func latestPrice(symbol: String) async throws -> Double { try await service.latestTradePrice(symbol: symbol) }

    func cancelOrder(id: String) async throws { try await service.cancelOrder(id: id) }

    func closePosition(symbol: String) async throws -> String? {
        try await service.closePositionReturningOrder(symbol: symbol)?.id
    }

    func submitEntryWithStop(symbol: String, quantity: Double, limitPrice: Double,
                             stopPrice: Double, takeProfitPrice: Double?, clientOrderId: String) async throws -> String {
        try await service.submitEntryWithStop(symbol: symbol, quantity: quantity, limitPrice: limitPrice,
                                              stopPrice: stopPrice, takeProfitPrice: takeProfitPrice,
                                              clientOrderId: clientOrderId).id
    }

    func submitStop(symbol: String, quantity: Double, stopPrice: Double) async throws -> String {
        try await service.submitStop(symbol: symbol, quantity: quantity, stopPrice: stopPrice).id
    }

    func orderRef(byClientOrderId clientOrderId: String) async throws -> BrokerOrderRef? {
        guard let order = try await service.order(byClientOrderId: clientOrderId) else { return nil }
        return BrokerOrderRef(id: order.id, status: order.status)
    }

    func filledAveragePrice(orderId: String) async throws -> Double? {
        try await service.order(id: orderId).filledAveragePriceValue
    }

    func news(symbols: [String], hours: Int) async throws -> [NewsHeadline] {
        try await service.news(symbols: symbols, hours: hours)
    }
}

private struct NewsResponse: Decodable {
    struct Item: Decodable {
        let id: Int
        let headline: String
        let created_at: String
        let symbols: [String]?
        let source: String?
        let url: String?
    }
    let news: [Item]?
}

extension AlpacaBroker: NightBroker {
    func nightClock() async throws -> (isOpen: Bool, nextClose: Date?) {
        let c = try await service.clock()
        return (c.isOpen, c.nextCloseDate)
    }

    func tradingDays(from: Date, to: Date) async throws -> [TradingDay] {
        let days = try await service.calendar(start: from, end: to)
        return days.compactMap { day in
            guard let close = day.closeDate else { return nil }
            return TradingDay(date: day.date, close: close)
        }
    }

    func orderFillPrice(orderId: String) async throws -> Double? {
        try await service.order(id: orderId).filledAveragePriceValue
    }

    func auctionPrice(symbol: String, day: String, kind: AuctionKind) async throws -> Double? {
        try await service.auctionPrice(symbol: symbol, day: day, kind: kind == .open ? "open" : "close")
    }

    func submitAuction(symbol: String, quantity: Int, side: String, timeInForce: String,
                       clientOrderId: String) async throws -> String {
        try await service.submitAuction(symbol: symbol, quantity: quantity, side: side,
                                        timeInForce: timeInForce, clientOrderId: clientOrderId).id
    }

    func submitMarket(symbol: String, quantity: Int, side: String,
                      clientOrderId: String) async throws -> String {
        try await service.submitMarket(symbol: symbol, quantity: quantity, side: side,
                                       clientOrderId: clientOrderId).id
    }
}
