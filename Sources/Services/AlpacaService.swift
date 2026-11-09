import Foundation

struct AlpacaOrder: Decodable, Sendable {
    let id: String
    let status: String
    let symbol: String
    let side: String
    let type: String
    let quantity: String?
    let filledQuantity: String?
    let filledAveragePrice: String?
    let legs: [AlpacaOrder]?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case symbol
        case side
        case type
        case quantity = "qty"
        case filledQuantity = "filled_qty"
        case filledAveragePrice = "filled_avg_price"
        case legs
    }

    var filledQuantityValue: Double { Double(filledQuantity ?? "0") ?? 0 }
    var filledAveragePriceValue: Double? { Double(filledAveragePrice ?? "") }
}

struct AlpacaPosition: Decodable, Sendable {
    let symbol: String
    let quantity: String

    enum CodingKeys: String, CodingKey {
        case symbol
        case quantity = "qty"
    }
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

    func positions() async throws -> [AlpacaPosition] {
        let data = try await send(path: "/v2/positions", method: "GET")
        return try JSONDecoder().decode([AlpacaPosition].self, from: data)
    }

    func order(id: String) async throws -> AlpacaOrder {
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw QuantSwarmError.invalidServerResponse("Order ID non codificabile")
        }
        let data = try await send(path: "/v2/orders/\(escaped)", method: "GET")
        return try JSONDecoder().decode(AlpacaOrder.self, from: data)
    }

    func submitBracket(
        decision: KimiDecision,
        quantity: Double,
        limitPrice: Double
    ) async throws -> AlpacaOrder {
        let body: [String: Any] = [
            "symbol": decision.symbol.uppercased(),
            "qty": decimalString(quantity, fractionDigits: 0),
            "side": decision.action.rawValue,
            "type": "limit",
            "time_in_force": "day",
            "limit_price": decimalString(limitPrice, fractionDigits: 4),
            "order_class": "bracket",
            "client_order_id": "qswarm-\(UUID().uuidString.lowercased())",
            "extended_hours": false,
            "take_profit": [
                "limit_price": decimalString(decision.takeProfit, fractionDigits: 4)
            ],
            "stop_loss": [
                "stop_price": decimalString(decision.stopLoss, fractionDigits: 4)
            ]
        ]
        let data = try await send(path: "/v2/orders", method: "POST", body: body)
        return try JSONDecoder().decode(AlpacaOrder.self, from: data)
    }

    func cancelAllAndFlatten() async throws {
        _ = try await send(path: "/v2/orders", method: "DELETE")
        _ = try await send(path: "/v2/positions", method: "DELETE")
    }

    private func send(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) async throws -> Data {
        let absoluteURL = credentials.tradingBaseURL.absoluteString + path
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
}
