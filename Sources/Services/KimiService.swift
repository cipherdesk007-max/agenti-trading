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
        if let string = try? container.decodeIfPresent(String.self, forKey: key),
           let value = Double(string) {
            return value
        }
        return nil
    }
}

private struct BalanceResponse: Decodable {
    let data: KimiBalance?
}

private struct ModelsListResponse: Decodable {
    struct ModelEntry: Decodable {
        let id: String
    }
    let data: [ModelEntry]
}

/// Box thread-safe per il modello Kimi: il tab SISTEMA può cambiarlo senza
/// attendere l'actor, mentre chat() legge sempre il valore corrente.
private final class KimiModelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    init(_ value: String) {
        self.value = value
    }

    func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        value = trimmed
        lock.unlock()
    }
}

actor KimiService {
    private let apiKey: String
    /// Modello usato per decisioni e analisi; configurabile dalle impostazioni
    /// dell'app (tab SISTEMA) senza ricompilare.
    private let modelBox: KimiModelBox
    private let endpoint = URL(string: "https://api.moonshot.ai/v1/chat/completions")!
    private let session: URLSession

    init(apiKey: String, model: String = SystemLimits.kimiModel) {
        self.apiKey = apiKey
        self.modelBox = KimiModelBox(model)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    nonisolated func setModel(_ newModel: String) {
        modelBox.set(newModel)
    }

    func validateCredentials() async throws {
        _ = try await listModels()
    }

    /// Elenco reale dei modelli disponibili sulla API key configurata:
    /// serve al picker del tab SISTEMA, così la scelta del modello si fa
    /// dall'app senza aprire la console web Moonshot.
    func listModels() async throws -> [String] {
        let url = URL(string: "https://api.moonshot.ai/v1/models")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await sendWithRetry(request)
        let response = try JSONDecoder().decode(ModelsListResponse.self, from: data)
        let ids = response.data.map(\.id).sorted()
        guard !ids.isEmpty else {
            throw QuantSwarmError.invalidServerResponse("Lista modelli Kimi vuota")
        }
        return ids
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

    /// Decisione operativa. Oltre a prezzo/ATR/news/performance, Kimi riceve
    /// il contesto candele: ultime 100 candele CHIUSE e indicatori calcolati
    /// in codice (RSI, EMA 12/26, SMA 50/200, ATR, massimi/minimi, volumi)
    /// su due timeframe (1m e 15m). Nessun indicatore stimato dal modello.
    func decide(
        snapshot: MarketSnapshot,
        news: String,
        performance: PerformanceMatrix,
        calibration: CalibrationStats? = nil,
        marketContext: MarketContext? = nil
    ) async throws -> KimiDecision {
        let systemPrompt = """
        Sei il modulo decisionale di un sistema di trading. Non fornire consulenza finanziaria \
        e non affermare certezze. Valuta esclusivamente i dati forniti. Restituisci hold se i dati \
        sono insufficienti, incoerenti o il rapporto rischio/rendimento non è favorevole. Il conto \
        opera SOLO in acquisto: le vendite allo scoperto non sono permesse, quindi le uniche \
        azioni valide sono buy o hold (in un quadro ribassista rispondi hold). Per buy vale \
        stop_loss < entry_price < take_profit, con stop tra 0,5 e 5 volte atr_14 sotto \
        l'ingresso e (take_profit - entry_price) almeno 1,5 volte (entry_price - stop_loss). \
        entry_price deve essere il prezzo corrente fornito. win_probability è una stima \
        soggettiva in (0,1), payoff_ratio è il rapporto reward/risk positivo. Il campo \
        candles_two_timeframes contiene le ultime candele CHIUSE (t = secondi unix di inizio \
        candela, o/h/l/c/v) e gli indicatori calcolati in codice sui timeframe 1m e 15m: usali \
        per il giudizio e non inventare dati assenti. Se è presente calibration_feedback, usalo \
        per correggere la tua win_probability: se in passato una fascia di confidenza ha vinto \
        meno del dichiarato, abbassa la stima; se ha vinto di più, puoi alzarla con prudenza. \
        Non usare Markdown.
        """
        var payload: [String: Any] = [
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
        payload["candles_two_timeframes"] = marketContext.map(Self.contextPayload) ?? NSNull()
        // Apprendimento in-context: la calibrazione misurata sui trade passati
        // rientra nel prompt, così Kimi corregge da solo l'over/under-confidence.
        if let calibration {
            payload["calibration_feedback"] = [
                "samples": calibration.samples,
                "brier_score": calibration.brierScore,
                "buckets": calibration.buckets.map { bucket in
                    [
                        "range": bucket.label,
                        "trades": bucket.trades,
                        "win_rate": bucket.winRate
                    ] as [String: Any]
                }
            ]
        } else {
            payload["calibration_feedback"] = NSNull()
        }
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
                "action": ["type": "string", "enum": ["buy", "hold"]],
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
        let content = try await chat(
            messages: messages,
            schema: schema,
            schemaName: "trading_decision",
            maxTokens: 4096
        )
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

    /// Kimi Reviewer avversario: gira SOLO quando l'analyst propone un trade.
    /// Parte dal presupposto che la decisione sia sbagliata e cerca motivi
    /// concreti per respingerla. Un trade respinto non diventa mai un ordine;
    /// un errore del reviewer vale come rifiuto (fail-closed, gestito dal motore).
    func review(
        decision: KimiDecision,
        snapshot: MarketSnapshot,
        marketContext: MarketContext? = nil
    ) async throws -> KimiReview {
        let systemPrompt = """
        Sei il revisore avversario di un sistema di trading. Assumi che la decisione proposta sia \
        SBAGLIATA e cerca attivamente motivi concreti per respingerla: livelli incoerenti con le \
        candele chiuse fornite, rapporto rischio/rendimento reale insufficiente, volatilità anomala \
        rispetto all'ATR, dati contraddittori o stantii, ancoraggio errato al prezzo corrente. \
        Approva solo se non trovi nulla di concreto da obiettare. Non usare Markdown.
        """
        var payload: [String: Any] = [
            "proposal": [
                "symbol": decision.symbol,
                "action": decision.action.rawValue,
                "confidence": decision.confidence,
                "entry_price": decision.entryPrice,
                "stop_loss": decision.stopLoss,
                "take_profit": decision.takeProfit,
                "win_probability": decision.winProbability,
                "payoff_ratio": decision.payoffRatio,
                "rationale": decision.rationale
            ],
            "market": [
                "last_price": snapshot.lastPrice,
                "atr_14": snapshot.atr14.map { $0 as Any } ?? NSNull(),
                "data_age_seconds": Int(Date().timeIntervalSince(snapshot.receivedAt))
            ]
        ]
        payload["candles_two_timeframes"] = marketContext.map(Self.contextPayload) ?? NSNull()
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let payloadString = String(decoding: payloadData, as: UTF8.self)
        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": payloadString]
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "verdict": ["type": "string", "enum": ["approve", "reject"]],
                "reason": ["type": "string"]
            ],
            "required": ["verdict", "reason"],
            "additionalProperties": false
        ]
        let content = try await chat(
            messages: messages,
            schema: schema,
            schemaName: "adversarial_review",
            maxTokens: 1024
        )
        let json = try extractJSONObject(from: content)
        return try JSONDecoder().decode(KimiReview.self, from: Data(json.utf8))
    }

    /// Serializzazione compatta del contesto candele: numeri a 4 decimali e
    /// timestamp in secondi unix per contenere i token spesi a ogni chiamata.
    private static func contextPayload(_ context: MarketContext) -> [String: Any] {
        [
            "timeframe_1m": timeframePayload(context.oneMinuteCandles, context.oneMinuteIndicators),
            "timeframe_15m": timeframePayload(context.fifteenMinuteCandles, context.fifteenMinuteIndicators)
        ]
    }

    private static func timeframePayload(
        _ candles: [Candle],
        _ indicators: IndicatorSnapshot
    ) -> [String: Any] {
        [
            "closed_candles": candles.count,
            "indicators": indicatorsPayload(indicators),
            "last_candles": candles.map(candlePayload)
        ]
    }

    private static func candlePayload(_ candle: Candle) -> [String: Any] {
        [
            "t": Int(candle.timestamp.timeIntervalSince1970),
            "o": round4(candle.open),
            "h": round4(candle.high),
            "l": round4(candle.low),
            "c": round4(candle.close),
            "v": round4(candle.volume)
        ]
    }

    private static func indicatorsPayload(_ snapshot: IndicatorSnapshot) -> [String: Any] {
        [
            "rsi_14": snapshot.rsi14.map { round4($0) as Any } ?? NSNull(),
            "ema_12": snapshot.ema12.map { round4($0) as Any } ?? NSNull(),
            "ema_26": snapshot.ema26.map { round4($0) as Any } ?? NSNull(),
            "sma_50": snapshot.sma50.map { round4($0) as Any } ?? NSNull(),
            "sma_200": snapshot.sma200.map { round4($0) as Any } ?? NSNull(),
            "atr_14": snapshot.atr14.map { round4($0) as Any } ?? NSNull(),
            "high_20": snapshot.high20.map { round4($0) as Any } ?? NSNull(),
            "low_20": snapshot.low20.map { round4($0) as Any } ?? NSNull(),
            "avg_volume_20": snapshot.avgVolume20.map { round4($0) as Any } ?? NSNull()
        ]
    }

    private static func round4(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }

    /// Lettura qualitativa del mercato: regime, volatilità e bias sui simboli
    /// seguiti, più un commento sintetico. Nessuna decisione operativa.
    func analyze(
        snapshots: [MarketSnapshot],
        positions: [AlpacaPosition],
        account: AccountSnapshot?,
        news: String,
        recentDecisions: [KimiDecision]
    ) async throws -> KimiAnalysis {
        let systemPrompt = """
        Sei l'analista di mercato di un sistema di trading algoritmico. Commenta in italiano, \
        con al massimo tre frasi, il regime, la volatilità e il bias dei simboli forniti usando \
        solo i dati ricevuti. Non fornire consulenza finanziaria e non affermare certezze. \
        Segnala rischi concreti se presenti (volatilità anomala rispetto all'ATR, posizioni \
        aperte in perdita, dati fermi). Non usare Markdown.
        """
        let now = Date()
        let symbolsPayload: [[String: Any]] = snapshots.map { snapshot in
            [
                "symbol": snapshot.symbol,
                "last_price": snapshot.lastPrice,
                "atr_14": snapshot.atr14.map { $0 as Any } ?? NSNull(),
                "atr_pct_of_price": snapshot.atr14.map { ($0 / snapshot.lastPrice * 100) as Any } ?? NSNull(),
                "data_age_seconds": Int(now.timeIntervalSince(snapshot.receivedAt))
            ]
        }
        let positionsPayload: [[String: Any]] = positions.map { position in
            [
                "symbol": position.symbol,
                "side": position.side ?? "long",
                "qty": position.quantityValue,
                "unrealized_pnl": position.unrealizedPLValue
            ]
        }
        var accountPayload: [String: Any] = [:]
        if let account {
            accountPayload["equity"] = account.equityValue
            accountPayload["day_pnl"] = account.dayPnL.map { $0 as Any } ?? NSNull()
        }
        let decisionsPayload: [[String: Any]] = recentDecisions.map { decision in
            [
                "symbol": decision.symbol,
                "action": decision.action.rawValue,
                "confidence": decision.confidence
            ]
        }
        let payload: [String: Any] = [
            "symbols": symbolsPayload,
            "open_positions": positionsPayload,
            "account": accountPayload,
            "news_text": news,
            "recent_decisions": decisionsPayload
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
                "regime": [
                    "type": "string",
                    "enum": ["trend_rialzista", "trend_ribassista", "laterale", "volatile", "indefinito"]
                ],
                "volatility": [
                    "type": "string",
                    "enum": ["bassa", "normale", "alta", "estrema"]
                ],
                "bias": [
                    "type": "string",
                    "enum": ["rialzista", "ribassista", "neutro"]
                ],
                "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                "comment": ["type": "string"]
            ],
            "required": ["regime", "volatility", "bias", "confidence", "comment"],
            "additionalProperties": false
        ]
        let content = try await chat(
            messages: messages,
            schema: schema,
            schemaName: "market_analysis",
            maxTokens: 2048
        )
        let json = try extractJSONObject(from: content)
        let decoded = try JSONDecoder().decode(KimiAnalysis.self, from: Data(json.utf8))
        guard !decoded.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuantSwarmError.invalidServerResponse("Commento analisi vuoto")
        }
        return KimiAnalysis(
            regime: decoded.regime,
            volatility: decoded.volatility,
            bias: decoded.bias,
            confidence: min(1, max(0, decoded.confidence)),
            comment: decoded.comment
        )
    }

    private func chat(
        messages: [[String: String]],
        schema: [String: Any],
        schemaName: String,
        maxTokens: Int
    ) async throws -> String {
        let body: [String: Any] = [
            "model": modelBox.get(),
            "messages": messages,
            "reasoning_effort": "low",
            "max_completion_tokens": maxTokens,
            "stream": false,
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": schemaName,
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
        return content
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
