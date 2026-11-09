import Foundation

struct KimiBalance: Decodable, Sendable {
    let availableBalance: Double?
    let voucherBalance: Double?
    let cashBalance: Double?

    enum CodingKeys: String, CodingKey {
        case availableBalance = "available_balance"
        case voucherBalance = "voucher_balance"
        case cashBalance = "cash_balance"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableBalance = Self.flexibleDouble(container, key: .availableBalance)
        voucherBalance = Self.flexibleDouble(container, key: .voucherBalance)
        cashBalance = Self.flexibleDouble(container, key: .cashBalance)
    }

    private static func flexibleDouble(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let string = try? container.decodeIfPresent(String.self, forKey: key) {
            return string.flatMap(Double.init)
        }
        return nil
    }
}

private struct BalanceResponse: Decodable {
    let data: KimiBalance?
}

actor KimiService {
    private let apiKey: String
    private let model = SystemLimits.kimiModel
    private let endpoint = URL(string: "https://api.moonshot.ai/v1/chat/completions")!
    private let session: URLSession

    init(apiKey: String) {
        self.apiKey = apiKey
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func validateCredentials() async throws {
        let url = URL(string: "https://api.moonshot.ai/v1/models")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        _ = try await sendWithRetry(request)
    }

    func balance() async throws -> KimiBalance {
        let url = URL(string: "https://api.moonshot.ai/v1/users/me/balance")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await sendWithRetry(request)
        let response = try JSONDecoder().decode(BalanceResponse.self, from: data)
        guard let balance = response.data else {
            throw QuantSwarmError.invalidServerResponse("Saldo Kimi assente nella risposta")
        }
        return balance
    }

    func decide(
        snapshot: MarketSnapshot,
        news: String,
        performance: PerformanceMatrix
    ) async throws -> KimiDecision {
        let systemPrompt = """
        Sei il modulo decisionale di un sistema di trading. Non fornire consulenza finanziaria \
        e non affermare certezze. Valuta esclusivamente i dati forniti. Restituisci hold se i dati \
        sono insufficienti, incoerenti o il rapporto rischio/rendimento non è favorevole. Per buy \
        vale stop_loss < entry_price < take_profit; per sell vale take_profit < entry_price < \
        stop_loss. entry_price deve essere il prezzo corrente fornito. win_probability è una stima \
        soggettiva in (0,1), payoff_ratio è il rapporto reward/risk positivo. Non usare Markdown.
        """
        let payload: [String: Any] = [
            "market": [
                "symbol": snapshot.symbol,
                "last_price": snapshot.lastPrice,
                "atr_14": snapshot.atr14.map { $0 as Any } ?? NSNull(),
                "source_timestamp": ISO8601DateFormatter().string(from: snapshot.sourceTimestamp),
                "feed_latency_ms": snapshot.feedLatencyMilliseconds
            ],
            "news_text": news,
            "historical_performance": [
                "submitted_trades": performance.submittedTrades,
                "completed_trades": performance.completedTrades,
                "win_rate": performance.winRate.map { $0 as Any } ?? NSNull(),
                "average_net_pnl": performance.averageNetPnL.map { $0 as Any } ?? NSNull(),
                "stop_error_variance": performance.stopErrorVariance.map { $0 as Any } ?? NSNull(),
                "recent_outcomes": performance.recentOutcomes
            ]
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let payloadString = String(decoding: payloadData, as: UTF8.self)
        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": payloadString]
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "symbol": ["type": "string"],
                "action": ["type": "string", "enum": ["buy", "sell", "hold"]],
                "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                "entry_price": ["type": "number", "exclusiveMinimum": 0],
                "stop_loss": ["type": "number", "minimum": 0],
                "take_profit": ["type": "number", "minimum": 0],
                "win_probability": ["type": "number", "exclusiveMinimum": 0, "exclusiveMaximum": 1],
                "payoff_ratio": ["type": "number", "exclusiveMinimum": 0],
                "rationale": ["type": "string"]
            ],
            "required": [
                "symbol", "action", "confidence", "entry_price", "stop_loss",
                "take_profit", "win_probability", "payoff_ratio", "rationale"
            ],
            "additionalProperties": false
        ]
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "reasoning_effort": "low",
            "max_completion_tokens": 4096,
            "stream": false,
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "trading_decision",
                    "strict": true,
                    "schema": schema
                ]
            ]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await sendWithRetry(request)
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let choice = response.choices.first else {
            throw QuantSwarmError.invalidServerResponse("Nessuna choice Kimi")
        }
        guard choice.finishReason != "length" else {
            throw QuantSwarmError.invalidServerResponse("JSON Kimi troncato")
        }
        guard let content = choice.message.content, !content.isEmpty else {
            throw QuantSwarmError.invalidServerResponse("Contenuto Kimi vuoto")
        }

        let json = try extractJSONObject(from: content)
        let decision = try JSONDecoder().decode(KimiDecision.self, from: Data(json.utf8))
        guard decision.symbol.uppercased() == snapshot.symbol.uppercased() else {
            throw QuantSwarmError.invalidDecision("Simbolo non corrispondente")
        }
        guard decision.action == .hold || decision.isExecutable else {
            throw QuantSwarmError.invalidDecision("Campi o livelli di prezzo incoerenti")
        }
        return decision
    }

    private func sendWithRetry(_ request: URLRequest) async throws -> Data {
        let retryableStatuses: Set<Int> = [429, 500, 502, 503, 504]
        for attempt in 0..<4 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw QuantSwarmError.invalidServerResponse("Risposta non HTTP")
                }
                if (200..<300).contains(http.statusCode) {
                    return data
                }
                let body = String(decoding: data.prefix(1_000), as: UTF8.self)
                if retryableStatuses.contains(http.statusCode), attempt < 3 {
                    try await backoff(attempt: attempt)
                    continue
                }
                throw QuantSwarmError.httpStatus(http.statusCode, body)
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                if attempt == 3 { throw error }
                try await backoff(attempt: attempt)
            }
        }
        throw QuantSwarmError.invalidServerResponse("Retry Kimi esauriti")
    }

    private func backoff(attempt: Int) async throws {
        let base = pow(2.0, Double(attempt))
        let nanoseconds = UInt64((base + Double.random(in: 0...0.25)) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    private func extractJSONObject(from content: String) throws -> String {
        var sanitized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let fencePattern = #"(?s)^```(?:json)?\s*(.*?)\s*```$"#
        if let regex = try? NSRegularExpression(pattern: fencePattern) {
            let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
            if let match = regex.firstMatch(in: sanitized, range: range),
               let bodyRange = Range(match.range(at: 1), in: sanitized) {
                sanitized = String(sanitized[bodyRange])
            }
        }
        guard let start = sanitized.firstIndex(of: "{"),
              let end = sanitized.lastIndex(of: "}"),
              start <= end else {
            throw QuantSwarmError.invalidServerResponse("Nessun oggetto JSON")
        }
        let candidate = String(sanitized[start...end])
        let object = try JSONSerialization.jsonObject(with: Data(candidate.utf8))
        guard object is [String: Any] else {
            throw QuantSwarmError.invalidServerResponse("JSON non è un oggetto")
        }
        return candidate
    }
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Message: Decodable {
        let content: String?
    }
}
