import Foundation
import Network

enum MarketEvent: Sendable {
    case snapshot(MarketSnapshot)
    case log(String)
    case disconnected(String)
}

actor MarketScoutAgent {
    private var credentials: AlpacaCredentials?
    private var symbols: [String] = []
    private var continuation: AsyncStream<MarketEvent>.Continuation?
    private var lifecycleTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var running = false
    private var retryAttempt = 0
    private var monitoring = false
    private var lastNetworkSatisfied: Bool?
    private var atrStates: [String: ATRState] = [:]
    private var lastPrices: [String: Double] = [:]
    private let session: URLSession
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.quantswarm.alphazero.network")
    private let fractionalTimestampFormatter = ISO8601DateFormatter()
    private let standardTimestampFormatter = ISO8601DateFormatter()

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 0
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
        fractionalTimestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func start(
        credentials: AlpacaCredentials,
        symbols: [String]
    ) -> AsyncStream<MarketEvent> {
        stop()
        self.credentials = credentials
        self.symbols = Array(Set(symbols.map { $0.uppercased() })).sorted()
        self.atrStates = Dictionary(uniqueKeysWithValues: self.symbols.map { ($0, ATRState()) })
        self.lastPrices = [:]
        self.retryAttempt = 0
        self.lastNetworkSatisfied = nil
        self.running = true
        startNetworkMonitoring()

        return AsyncStream(bufferingPolicy: .bufferingNewest(512)) { continuation in
            self.continuation = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.stop() }
            }
            lifecycleTask = Task { await self.run() }
        }
    }

    func stop() {
        running = false
        lifecycleTask?.cancel()
        lifecycleTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        continuation?.finish()
        continuation = nil
    }

    private func startNetworkMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { await self?.networkStatusChanged(satisfied) }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    private func networkStatusChanged(_ satisfied: Bool) {
        guard running else { return }
        guard lastNetworkSatisfied != satisfied else { return }
        lastNetworkSatisfied = satisfied
        if satisfied {
            continuation?.yield(.log("Rete disponibile: verifica dello stream Alpaca."))
        } else {
            continuation?.yield(.disconnected("Rete assente; stream sospeso."))
            socket?.cancel(with: .goingAway, reason: nil)
        }
    }

    private func run() async {
        while running && !Task.isCancelled {
            do {
                try await connectAndListen()
                if running {
                    throw QuantSwarmError.invalidServerResponse("WebSocket Alpaca chiuso")
                }
            } catch is CancellationError {
                break
            } catch {
                guard running else { break }
                continuation?.yield(.disconnected(error.localizedDescription))
                var seconds = min(60, pow(2.0, Double(retryAttempt))) + Double.random(in: 0...0.5)
                retryAttempt = min(retryAttempt + 1, 6)
                // 406 connection limit: il piano IEX permette una sola connessione
                // e il server impiega ~30 s a rilasciare lo slot della precedente.
                if case QuantSwarmError.httpStatus(let code, _) = error, code == 406 {
                    seconds = max(seconds, 30)
                    continuation?.yield(.log(
                        "Slot connessione Alpaca occupato: attesa del rilascio da parte del server."
                    ))
                }
                continuation?.yield(.log("Riconnessione tra \(String(format: "%.1f", seconds)) s."))
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } catch {
                    break
                }
            }
        }
    }

    private func connectAndListen() async throws {
        guard let credentials, !symbols.isEmpty else {
            throw QuantSwarmError.credentialsMissing
        }
        let task = session.webSocketTask(with: credentials.marketDataStreamURL)
        socket = task
        task.resume()
        defer { socket = nil }

        let connected = try await receiveMessages(from: task)
        // Errore gia' in fase di handshake (es. 406 slot ancora occupato): va
        // propagato come httpStatus per attivare il backoff dedicato del 406
        // invece del backoff generico da 1 s che martellerebbe lo slot.
        if let error = connected.first(where: { $0.type == "error" }) {
            throw QuantSwarmError.httpStatus(
                error.code ?? 500,
                error.message ?? "Errore stream in handshake"
            )
        }
        guard connected.contains(where: { $0.type == "success" && $0.message == "connected" }) else {
            throw QuantSwarmError.invalidServerResponse("Handshake Alpaca non riuscito")
        }

        try await sendJSONObject([
            "action": "auth",
            "key": credentials.keyID,
            "secret": credentials.secretKey
        ], over: task)

        let authentication = try await receiveMessages(from: task)
        if let error = authentication.first(where: { $0.type == "error" }) {
            throw QuantSwarmError.httpStatus(error.code ?? 401, error.message ?? "Autenticazione stream")
        }
        guard authentication.contains(where: {
            $0.type == "success" && $0.message == "authenticated"
        }) else {
            throw QuantSwarmError.invalidServerResponse("Autenticazione stream non riuscita")
        }

        try await sendJSONObject([
            "action": "subscribe",
            "trades": symbols,
            "bars": symbols
        ], over: task)
        retryAttempt = 0
        continuation?.yield(.log("Stream Alpaca autenticato: \(symbols.joined(separator: ", "))."))

        // Watchdog ping: una connessione "mezza morta" (es. cambio Wi-Fi/cellulare
        // o NAT scaduto) non e' rilevata da NWPathMonitor e lascerebbe receive()
        // appesa all'infinito con l'app apparentemente viva ma muta. Nessun pong
        // entro 10 s -> chiusura forzata -> il loop run() gestisce la riconnessione.
        let watchdog = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 25_000_000_000)
                    try await pingWithTimeout(task, timeoutSeconds: 10)
                } catch is CancellationError {
                    return
                } catch {
                    task.cancel(with: .abnormalClosure, reason: nil)
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        while running && !Task.isCancelled {
            let messages = try await receiveMessages(from: task)
            for message in messages {
                // Un frame di errore Alpaca (es. 406 connection limit) precede la
                // chiusura del socket: lo propaghiamo per attivare il backoff dedicato.
                if message.type == "error" {
                    throw QuantSwarmError.httpStatus(
                        message.code ?? 500,
                        message.message ?? "errore stream"
                    )
                }
                process(message)
            }
        }
    }

    /// Invia un WebSocket ping e attende il pong. Allo scadere del timeout il
    /// socket viene cancellato: questo sblocca anche il pong-handler in attesa,
    /// cosi' il task group non resta appeso su una connessione morta.
    private func pingWithTimeout(
        _ task: URLSessionWebSocketTask,
        timeoutSeconds: UInt64
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    task.sendPing { error in
                        if let error {
                            cont.resume(throwing: error)
                        } else {
                            cont.resume()
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                task.cancel(with: .abnormalClosure, reason: nil)
                throw QuantSwarmError.invalidServerResponse("Ping stream senza risposta")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func sendJSONObject(
        _ object: [String: Any],
        over task: URLSessionWebSocketTask
    ) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receiveMessages(from task: URLSessionWebSocketTask) async throws -> [StreamMessage] {
        let data: Data
        switch try await task.receive() {
        case .data(let receivedData):
            data = receivedData
        case .string(let text):
            data = Data(text.utf8)
        @unknown default:
            continuation?.yield(.log("Frame WebSocket non riconosciuto; ignorato."))
            return []
        }
        // Decodifica tollerante: un solo frame malformato non deve mai far cadere
        // lo stream (il piano IEX permette una sola connessione e la riconnessione
        // immediata scatena il 406 connection limit sullo slot ancora occupato).
        if let messages = try? JSONDecoder().decode([StreamMessage].self, from: data) {
            return messages
        }
        if let single = try? JSONDecoder().decode(StreamMessage.self, from: data) {
            return [single]
        }
        let preview = String(decoding: data.prefix(120), as: UTF8.self)
        continuation?.yield(.log("Frame stream ignorato (non decodificabile): \(preview)"))
        return []
    }

    private func process(_ message: StreamMessage) {
        guard let symbol = message.symbol else { return }
        let receivedAt = Date()
        let sourceTimestamp = message.timestamp.flatMap(parseTimestamp) ?? receivedAt

        if message.type == "b",
           let open = message.open,
           let high = message.high,
           let low = message.low,
           let close = message.close {
            var state = atrStates[symbol] ?? ATRState()
            let atr = state.update(open: open, high: high, low: low, close: close)
            atrStates[symbol] = state
            lastPrices[symbol] = close
            // Il timestamp di una barra Alpaca e' l'INIZIO del minuto, quindi un
            // snapshot da barra avrebbe una "latenza" naturale di ~60 s e verrebbe
            // respinto dal guard di latenza del risk manager. Per le barre il
            // riferimento e' l'arrivo della barra; la freschezza e' garantita dal
            // guard di staleness (120 s) e dal controllo di deviazione prezzo.
            continuation?.yield(.snapshot(MarketSnapshot(
                symbol: symbol,
                lastPrice: close,
                atr14: atr,
                sourceTimestamp: receivedAt,
                receivedAt: receivedAt
            )))
            return
        }

        if message.type == "t", let price = message.price {
            lastPrices[symbol] = price
            continuation?.yield(.snapshot(MarketSnapshot(
                symbol: symbol,
                lastPrice: price,
                atr14: atrStates[symbol]?.atr,
                sourceTimestamp: sourceTimestamp,
                receivedAt: receivedAt
            )))
        }
    }

    private func parseTimestamp(_ value: String) -> Date? {
        fractionalTimestampFormatter.date(from: value)
            ?? standardTimestampFormatter.date(from: value)
    }
}

private struct ATRState {
    private let period: Int
    private var initialTrueRanges: [Double] = []
    private var previousClose: Double?
    private(set) var atr: Double?

    init(period: Int = SystemLimits.atrPeriod) {
        self.period = max(2, period)
    }

    mutating func update(open: Double, high: Double, low: Double, close: Double) -> Double? {
        let trueRange: Double
        if let previousClose {
            trueRange = max(
                high - low,
                abs(high - previousClose),
                abs(low - previousClose)
            )
        } else {
            trueRange = high - low
        }
        previousClose = close

        if let currentATR = atr {
            atr = ((currentATR * Double(period - 1)) + trueRange) / Double(period)
        } else {
            initialTrueRanges.append(trueRange)
            if initialTrueRanges.count == period {
                atr = initialTrueRanges.reduce(0, +) / Double(period)
                initialTrueRanges.removeAll(keepingCapacity: false)
            }
        }
        return atr
    }
}

private struct StreamMessage: Decodable {
    let type: String
    let message: String?
    let code: Int?
    let symbol: String?
    let price: Double?
    let open: Double?
    let high: Double?
    let low: Double?
    let close: Double?
    let timestamp: String?

    enum CodingKeys: String, CodingKey {
        case type = "T"
        case message = "msg"
        case code
        case symbol = "S"
        case price = "p"
        case open = "o"
        case high = "h"
        case low = "l"
        case close = "c"
        case timestamp = "t"
    }
}
