import Foundation

actor RiskExecutionAgent {
    private let maximumLatencyMilliseconds = SystemLimits.maximumLatencyMilliseconds
    private let maximumPriceDeviation = SystemLimits.maximumPriceDeviation
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
    /// `riskFraction` e `kellyDivisor` arrivano dalle impostazioni dell'app
    /// (StrategyConfig): il sizing si aggiorna senza ricompilare.
    func execute(
        decision: KimiDecision,
        snapshot: MarketSnapshot,
        credentials: AlpacaCredentials,
        riskFraction: Double = SystemLimits.maximumRiskFraction,
        kellyDivisor: Double = SystemLimits.fractionalKellyDivisor
    ) async throws -> ExecutionReceipt? {
        guard decision.action != .hold else { return nil }
        guard decision.isExecutable else {
            throw QuantSwarmError.riskRejected("Segnale non eseguibile o livelli incoerenti")
        }
        guard decision.symbol.uppercased() == snapshot.symbol.uppercased() else {
            throw QuantSwarmError.riskRejected("Snapshot e segnale hanno simboli diversi")
        }
        guard snapshot.feedLatencyMilliseconds <= maximumLatencyMilliseconds else {
            throw QuantSwarmError.riskRejected(
                "Feed oltre \(format(maximumLatencyMilliseconds, fractionDigits: 0)) ms"
            )
        }
        let riskBudgetFraction = min(max(riskFraction, 0.000_1), 0.05)
        let kellyCut = max(kellyDivisor, 1)

        let deviation = abs(snapshot.lastPrice - decision.entryPrice) / decision.entryPrice
        guard deviation <= maximumPriceDeviation else {
            throw QuantSwarmError.riskRejected("Prezzo spostato oltre lo 0,05%")
        }

        let service = AlpacaService(credentials: credentials)
        async let openOrdersRequest = service.openOrders()
        async let positionsRequest = service.positions()
        let (openOrders, positions) = try await (openOrdersRequest, positionsRequest)
        guard !openOrders.contains(where: { $0.symbol == decision.symbol.uppercased() }),
              !positions.contains(where: { $0.symbol == decision.symbol.uppercased() }) else {
            throw QuantSwarmError.riskRejected("Posizione o ordine già presente sul simbolo")
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

        let limitPrice = decision.action == .buy
            ? decision.entryPrice * (1 + maximumPriceDeviation)
            : decision.entryPrice * (1 - maximumPriceDeviation)
        let riskPerShare = abs(limitPrice - decision.stopLoss)
        guard riskPerShare > 0 else {
            throw QuantSwarmError.riskRejected("Distanza stop nulla")
        }

        let probability = decision.winProbability
        let payoff = decision.payoffRatio
        let fullKelly = max(0, probability - ((1 - probability) / payoff))
        let fractionalKelly = fullKelly / kellyCut
        guard fractionalKelly > 0 else {
            throw QuantSwarmError.riskRejected("Kelly frazionato non positivo")
        }

        let riskBudget = account.equityValue * riskBudgetFraction
        let riskQuantity = riskBudget / riskPerShare
        let kellyQuantity = (account.equityValue * fractionalKelly) / limitPrice
        let availableCapital = decision.action == .buy
            ? min(account.cashValue, account.buyingPowerValue)
            : account.buyingPowerValue
        let capitalQuantity = availableCapital / limitPrice
        let quantity = floor(min(riskQuantity, kellyQuantity, capitalQuantity))
        guard quantity >= 1 else {
            throw QuantSwarmError.riskRejected("Quantità inferiore a un'azione intera")
        }
        guard quantity * riskPerShare <= riskBudget + 0.000_001 else {
            throw QuantSwarmError.riskRejected(
                "Rischio calcolato oltre il \(format(riskBudgetFraction * 100))%"
            )
        }
        emit(
            "Kelly \(format(fullKelly * 100))% → /\(format(kellyCut, fractionDigits: 0)) = \(format(fractionalKelly * 100))%; "
                + "rischio/azione \(format(riskPerShare)); qty \(format(quantity, fractionDigits: 0)) "
                + "entro il \(format(riskBudgetFraction * 100))% di equity. Invio bracket."
        )

        let order = try await service.submitBracket(
            decision: decision,
            quantity: quantity,
            limitPrice: limitPrice
        )
        return ExecutionReceipt(
            orderID: order.id,
            decision: decision,
            quantity: quantity,
            equity: account.equityValue,
            measuredLatencyMilliseconds: latency
        )
    }

    func emergencyFlatten(credentials: AlpacaCredentials) async throws {
        let service = AlpacaService(credentials: credentials)
        try await service.cancelAllAndFlatten()
    }
}
