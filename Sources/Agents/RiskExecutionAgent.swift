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
        let proposal = RiskRules.Proposal(
            action: decision.action,
            entry: decision.entryPrice,
            stopLoss: decision.stopLoss,
            takeProfit: decision.takeProfit
        )
        // Controlli economici (short vietati, stop in ATR, R/R, ancoraggio)
        // prima di qualsiasi chiamata al broker.
        if let reason = RiskRules.precheck(proposal, lastPrice: snapshot.lastPrice, atr: atr) {
            throw QuantSwarmError.riskRejected(reason)
        }

        // Rilettura del prezzo DOPO la risposta di Kimi.
        guard let currentPrice = await freshPrice(), currentPrice > 0 else {
            throw QuantSwarmError.riskRejected("Rilettura del prezzo fallita: ordine annullato")
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

        // Dimensionamento sul prezzo reale d'ingresso, stop/target al tick,
        // rischio ≤ equity × rischio%, posizione ≤ 25% del capitale.
        let sizing: RiskRules.Sizing
        switch RiskRules.size(
            proposal,
            currentPrice: currentPrice,
            atr: atr,
            account: RiskRules.Account(
                equity: account.equityValue,
                cash: account.cashValue,
                buyingPower: account.buyingPowerValue
            ),
            riskFraction: riskFraction,
            constraints: constraints
        ) {
        case .success(let value):
            sizing = value
        case .failure(let rejection):
            throw QuantSwarmError.riskRejected(rejection.reason)
        }
        let quantity = sizing.quantity
        let limitPrice = sizing.limitPrice
        emit(
            "R/R \(format(sizing.riskReward)) · rischio \(format(sizing.riskAmount)) USD · "
                + "qty \(format(quantity, fractionDigits: constraints.quantityFractionDigits)) · "
                + "limite \(format(limitPrice)) stop \(format(sizing.stopPrice)) target \(format(sizing.takeProfitPrice)). Invio bracket."
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
                stopPrice: sizing.stopPrice,
                takeProfitPrice: sizing.takeProfitPrice,
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
