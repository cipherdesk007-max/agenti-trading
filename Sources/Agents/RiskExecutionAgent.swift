import Foundation

actor RiskExecutionAgent {
    private let maximumLatencyMilliseconds = SystemLimits.maximumLatencyMilliseconds
    private var logHandler: (@Sendable (String) -> Void)?

    func setLogHandler(_ handler: (@Sendable (String) -> Void)?) {
        logHandler = handler
    }

    private func emit(_ message: String) {
        logHandler?(message)
    }

    private func format(_ value: Double, fractionDigits: Int = 2) -> String {
        String(
            format: "%.\(fractionDigits)f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
    }

    /// Esegue un segnale non-HOLD con tutti i controlli di rischio.
    ///
    /// Sizing deterministico (niente Kelly): quantità = (equity × rischio%) /
    /// distanza dallo stop, arrotondata per difetto a lot size / tick size /
    /// nozionale minimo dello strumento. Il rapporto rendimento/rischio è
    /// calcolato in codice dai livelli (minimo 1,5), mai da stime del modello.
    ///
    /// - Parameter freshPrice: rilettura del prezzo DOPO la risposta di Kimi;
    ///   se si è mosso oltre 0,5 × ATR l'ordine viene annullato.
    /// - Parameter alreadyCommittedThisCycle: simboli per cui un ordine è già
    ///   partito in questo ciclo (conta nell'esposizione complessiva).
    func execute(
        decision: KimiDecision,
        snapshot: MarketSnapshot,
        credentials: AlpacaCredentials,
        riskFraction: Double = SystemLimits.maximumRiskFraction,
        atr: Double,
        maxOpenPositions: Int = SystemLimits.maxConcurrentPositions,
        alreadyCommittedThisCycle: Set<String> = [],
        constraints: InstrumentConstraints = .alpacaStock,
        freshPrice: @Sendable () async -> Double?
    ) async throws -> ExecutionReceipt? {
        guard decision.action != .hold else { return nil }
        guard decision.isExecutable else {
            throw QuantSwarmError.riskRejected("Segnale non eseguibile o livelli incoerenti")
        }
        let symbol = decision.symbol.uppercased()
        guard symbol == snapshot.symbol.uppercased() else {
            throw QuantSwarmError.riskRejected("Snapshot e segnale hanno simboli diversi")
        }
        guard snapshot.feedLatencyMilliseconds <= maximumLatencyMilliseconds else {
            throw QuantSwarmError.riskRejected(
                "Feed oltre \(format(maximumLatencyMilliseconds, fractionDigits: 0)) ms"
            )
        }
        let riskBudgetFraction = min(max(riskFraction, 0.000_1), 0.05)

        // Sanity anchor: Kimi deve aver ancorato l'entry al prezzo visto
        // (soglia larga, 2×ATR); la verifica fine avviene sulla rilettura.
        let anchorLimit = max(atr * SystemLimits.maximumEntryAnchorATR, constraints.tickSize * 2)
        let anchorDrift = abs(snapshot.lastPrice - decision.entryPrice)
        guard anchorDrift <= anchorLimit else {
            throw QuantSwarmError.riskRejected(
                "Entry scollegato dal prezzo visto (\(format(anchorDrift)) oltre \(format(anchorLimit)))"
            )
        }

        // Bug 3: rilettura del prezzo DOPO la risposta di Kimi. Se nel
        // frattempo si è mosso oltre 0,5×ATR, i livelli proposti non valgono più.
        guard let currentPrice = await freshPrice(), currentPrice > 0 else {
            throw QuantSwarmError.riskRejected("Rilettura del prezzo fallita: ordine annullato")
        }
        let retestLimit = max(atr * SystemLimits.priceRetestATRFraction, constraints.tickSize)
        let drift = abs(currentPrice - decision.entryPrice)
        guard drift <= retestLimit else {
            throw QuantSwarmError.riskRejected(
                "Prezzo mosso di \(format(drift)) oltre \(format(retestLimit)) (0,5×ATR) dopo Kimi: ordine annullato"
            )
        }

        let service = AlpacaService(credentials: credentials)
        async let openOrdersRequest = service.openOrders()
        async let positionsRequest = service.positions()
        let (openOrders, positions) = try await (openOrdersRequest, positionsRequest)
        guard !openOrders.contains(where: { $0.symbol == symbol }),
              !positions.contains(where: { $0.symbol == symbol }) else {
            throw QuantSwarmError.riskRejected("Posizione o ordine già presente sul simbolo")
        }

        // Bug 4: esposizione complessiva = posizioni + ordini di ingresso
        // pendenti (le gambe stop/target non contano: hanno parent_order_id) +
        // ordini già inviati in questo ciclo. Oltre il tetto, niente ingressi.
        var exposure = Set(positions.map { $0.symbol.uppercased() })
        exposure.formUnion(openOrders.filter(\.isEntryOrder).map { $0.symbol.uppercased() })
        exposure.formUnion(alreadyCommittedThisCycle.map { $0.uppercased() })
        guard exposure.count < maxOpenPositions else {
            throw QuantSwarmError.riskRejected(
                "Tetto esposizione: \(exposure.count) simboli impegnati su max \(maxOpenPositions)"
            )
        }

        let clock = ContinuousClock()
        let start = clock.now
        let account = try await service.account()
        let elapsed = start.duration(to: clock.now).components
        let latency = Double(elapsed.seconds) * 1_000
            + Double(elapsed.attoseconds) / 1_000_000_000_000_000
        guard latency <= maximumLatencyMilliseconds else {
            throw QuantSwarmError.riskRejected(
                "Latenza REST \(format(latency, fractionDigits: 0)) ms oltre "
                    + "\(format(maximumLatencyMilliseconds, fractionDigits: 0)) ms"
            )
        }
        guard !account.tradingBlocked, !account.tradeSuspendedByEmail else {
            throw QuantSwarmError.riskRejected("Trading bloccato sul conto Alpaca")
        }
        guard account.equityValue > 0 else {
            throw QuantSwarmError.riskRejected("Patrimonio non positivo")
        }
        emit("Controlli OK: latenza REST \(format(latency, fractionDigits: 0)) ms, equity \(format(account.equityValue)) USD.")

        // Bug 2: R/R calcolato in codice dai livelli (minimo 1,5).
        let stopDistance = abs(decision.entryPrice - decision.stopLoss)
        let rewardDistance = abs(decision.takeProfit - decision.entryPrice)
        guard stopDistance > 0 else {
            throw QuantSwarmError.riskRejected("Distanza stop nulla")
        }
        let riskReward = rewardDistance / stopDistance
        guard riskReward >= SystemLimits.minimumRiskReward else {
            throw QuantSwarmError.riskRejected(
                "R/R \(format(riskReward)) sotto il minimo \(format(SystemLimits.minimumRiskReward))"
            )
        }

        let limitPrice = decision.action == .buy
            ? currentPrice * 1.0005
            : currentPrice * 0.9995
        let riskBudget = account.equityValue * riskBudgetFraction
        let riskQuantity = riskBudget / stopDistance
        let availableCapital = decision.action == .buy
            ? min(account.cashValue, account.buyingPowerValue)
            : account.buyingPowerValue
        let capitalQuantity = availableCapital / limitPrice
        let rawQuantity = min(riskQuantity, capitalQuantity)

        // Arrotondamento ai vincoli dello strumento, sempre per difetto.
        let quantity = (rawQuantity / constraints.lotSize).rounded(.down) * constraints.lotSize
        guard quantity >= constraints.lotSize else {
            throw QuantSwarmError.riskRejected(
                "Quantità sotto il lotto minimo \(format(constraints.lotSize, fractionDigits: constraints.quantityFractionDigits))"
            )
        }
        guard quantity * limitPrice >= constraints.minNotional else {
            throw QuantSwarmError.riskRejected("Nozionale sotto il minimo dell'exchange")
        }
        guard quantity * stopDistance <= riskBudget + 0.000_001 else {
            throw QuantSwarmError.riskRejected(
                "Rischio calcolato oltre il \(format(riskBudgetFraction * 100))%"
            )
        }
        emit(
            "R/R \(format(riskReward)) · stop \(format(stopDistance)) · qty \(format(quantity, fractionDigits: constraints.quantityFractionDigits)) "
                + "entro il \(format(riskBudgetFraction * 100))% di equity. Invio bracket."
        )

        // Bug 5: client_order_id deterministico per la decisione. Se l'invio
        // fallisce (timeout, rete), prima di dichiarare errore si controlla se
        // il broker ha comunque registrato l'ordine: niente duplicati e ogni
        // ordine resta registrato nel registro locale.
        let clientOrderId = Self.clientOrderId(for: decision)
        do {
            let order = try await service.submitBracket(
                decision: decision,
                quantity: quantity,
                quantityFractionDigits: constraints.quantityFractionDigits,
                limitPrice: limitPrice,
                clientOrderId: clientOrderId
            )
            return ExecutionReceipt(
                orderID: order.id,
                decision: decision,
                quantity: quantity,
                equity: account.equityValue,
                measuredLatencyMilliseconds: latency
            )
        } catch {
            if let existing = try? await service.order(byClientOrderId: clientOrderId) {
                emit("Invio fallito ma l'ordine esiste sul broker (\(existing.id)): recuperato, nessun duplicato.")
                return ExecutionReceipt(
                    orderID: existing.id,
                    decision: decision,
                    quantity: quantity,
                    equity: account.equityValue,
                    measuredLatencyMilliseconds: latency
                )
            }
            throw error
        }
    }

    /// client_order_id deterministico: stesso simbolo, livelli e finestra di
    /// 5 minuti producono lo stesso id, quindi un retry ravvicinato è
    /// riconoscibile; un segnale nuovo (livelli diversi) ha un id diverso.
    /// Alpaca accetta al massimo 48 caratteri.
    static func clientOrderId(for decision: KimiDecision) -> String {
        let bucket = Int(Date().timeIntervalSince1970 / 300)
        let raw = "\(decision.symbol.uppercased())|\(decision.action.rawValue)"
            + "|\(decision.entryPrice)|\(decision.stopLoss)|\(decision.takeProfit)|\(bucket)"
        var hash: UInt64 = 5_381
        for byte in raw.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        let shortSymbol = String(decision.symbol.uppercased().prefix(8))
        return "qsw-\(shortSymbol)-\(String(hash, radix: 36))"
    }

    func emergencyFlatten(credentials: AlpacaCredentials) async throws {
        let service = AlpacaService(credentials: credentials)
        try await service.cancelAllAndFlatten()
    }
}
