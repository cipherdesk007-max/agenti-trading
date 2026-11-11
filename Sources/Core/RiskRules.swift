import Foundation

/// Regole di rischio pure: nessuna rete, nessuno stato, nessuna AI.
/// Tutto ciò che decide SE e QUANTO comprare passa da qui, così è
/// verificabile con i test automatici (Tests/RiskRulesTests.swift).
enum RiskRules {
    /// Distanza minima dello stop: sotto 0,5 ATR lo stop viene preso dal
    /// rumore e la quantità esplode.
    static let minimumStopATR = 0.5
    /// Distanza massima dello stop: oltre 5 ATR il segnale non è un trade
    /// intraday sensato.
    static let maximumStopATR = 5.0
    /// Tetto di una singola posizione sul capitale (nozionale / equity).
    static let maximumPositionFraction = 0.25
    /// Margine sul prezzo riletto per il limite d'ingresso (0,05%).
    static let entryLimitSlippage = 0.0005

    struct Proposal: Sendable, Equatable {
        let action: TradeAction
        let entry: Double
        let stopLoss: Double
        let takeProfit: Double
    }

    struct Account: Sendable, Equatable {
        let equity: Double
        let cash: Double
        let buyingPower: Double
    }

    struct Sizing: Sendable, Equatable {
        let quantity: Double
        let limitPrice: Double
        let stopPrice: Double
        let takeProfitPrice: Double
        let riskPerUnit: Double
        let riskAmount: Double
        let riskReward: Double
    }

    /// Controlli economici PRIMA di spendere crediti sul reviewer.
    /// Ritorna il motivo del rifiuto, oppure nil se la proposta è ammessa.
    static func precheck(
        _ p: Proposal,
        lastPrice: Double,
        atr: Double,
        minimumRiskReward: Double = SystemLimits.minimumRiskReward,
        anchorATR: Double = SystemLimits.maximumEntryAnchorATR
    ) -> String? {
        switch p.action {
        case .hold:
            return "Nessuna operazione"
        case .sell:
            return "Vendite allo scoperto non permesse: solo acquisti"
        case .buy:
            break
        }
        guard [p.entry, p.stopLoss, p.takeProfit, lastPrice, atr].allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return "Livelli o dati mancanti/non validi"
        }
        guard p.stopLoss < p.entry, p.entry < p.takeProfit else {
            return "Per un acquisto serve stop < ingresso < target"
        }
        guard abs(lastPrice - p.entry) <= atr * anchorATR else {
            return "Ingresso scollegato dal prezzo visto (oltre \(fmt(anchorATR)) ATR)"
        }
        let stopATR = (p.entry - p.stopLoss) / atr
        guard stopATR >= minimumStopATR else {
            return "Stop troppo stretto (\(fmt(stopATR)) ATR, minimo \(fmt(minimumStopATR)))"
        }
        guard stopATR <= maximumStopATR else {
            return "Stop troppo largo (\(fmt(stopATR)) ATR, massimo \(fmt(maximumStopATR)))"
        }
        let rr = (p.takeProfit - p.entry) / (p.entry - p.stopLoss)
        guard rr >= minimumRiskReward else {
            return "R/R \(fmt(rr)) sotto il minimo \(fmt(minimumRiskReward))"
        }
        return nil
    }

    /// Dimensionamento sul prezzo REALE d'ingresso (prezzo riletto + margine),
    /// con stop e target arrotondati al tick. Il rischio effettivo non supera
    /// mai equity × riskFraction.
    static func size(
        _ p: Proposal,
        currentPrice: Double,
        atr: Double,
        account: Account,
        riskFraction: Double,
        constraints: InstrumentConstraints,
        minimumRiskReward: Double = SystemLimits.minimumRiskReward,
        retestATR: Double = SystemLimits.priceRetestATRFraction,
        maxPositionFraction: Double = maximumPositionFraction
    ) -> Result<Sizing, RiskRejection> {
        if let reason = precheck(p, lastPrice: currentPrice, atr: atr, minimumRiskReward: minimumRiskReward) {
            return .failure(RiskRejection(reason))
        }
        guard account.equity > 0 else {
            return .failure(RiskRejection("Patrimonio non positivo"))
        }
        let retestLimit = max(atr * retestATR, constraints.tickSize)
        guard abs(currentPrice - p.entry) <= retestLimit else {
            return .failure(RiskRejection(
                "Prezzo mosso di \(fmt(abs(currentPrice - p.entry))) oltre \(fmt(retestLimit)) dopo Kimi"
            ))
        }

        let tick = constraints.tickSize
        let limit = roundUp(currentPrice * (1 + entryLimitSlippage), tick: tick)
        // Stop arrotondato verso il basso e target verso il basso: il rischio
        // si calcola sui prezzi che il broker riceverà davvero.
        let stop = roundDown(p.stopLoss, tick: tick)
        let target = roundDown(p.takeProfit, tick: tick)
        guard stop > 0, stop < limit, limit < target else {
            return .failure(RiskRejection(
                "Dopo la rilettura il prezzo (\(fmt(limit))) non è più tra stop \(fmt(stop)) e target \(fmt(target))"
            ))
        }
        let riskPerUnit = limit - stop
        // Se il prezzo è sceso verso lo stop, lo stop reale può diventare
        // rumore: si ricontrolla la distanza minima sul prezzo d'ingresso vero.
        guard riskPerUnit / atr >= minimumStopATR else {
            return .failure(RiskRejection(
                "Stop a \(fmt(riskPerUnit / atr)) ATR dal prezzo reale: troppo vicino"
            ))
        }
        let rr = (target - limit) / riskPerUnit
        guard rr >= minimumRiskReward else {
            return .failure(RiskRejection(
                "R/R effettivo \(fmt(rr)) sotto il minimo \(fmt(minimumRiskReward)) al prezzo reale"
            ))
        }

        let budgetFraction = min(max(riskFraction, 0.000_1), 0.05)
        let riskBudget = account.equity * budgetFraction
        let byRisk = riskBudget / riskPerUnit
        let byCash = min(account.cash, account.buyingPower) / limit
        let byPosition = account.equity * maxPositionFraction / limit
        let raw = min(byRisk, byCash, byPosition)
        let lot = constraints.lotSize
        let quantity = (raw / lot + 1e-9).rounded(.down) * lot
        guard quantity >= lot else {
            return .failure(RiskRejection("Quantità sotto il lotto minimo"))
        }
        guard quantity * limit >= constraints.minNotional else {
            return .failure(RiskRejection("Nozionale sotto il minimo dell'exchange"))
        }
        let riskAmount = quantity * riskPerUnit
        guard riskAmount <= riskBudget + 1e-6 else {
            return .failure(RiskRejection("Rischio oltre il \(fmt(budgetFraction * 100))% del capitale"))
        }
        return .success(Sizing(
            quantity: quantity,
            limitPrice: limit,
            stopPrice: stop,
            takeProfitPrice: target,
            riskPerUnit: riskPerUnit,
            riskAmount: riskAmount,
            riskReward: rr
        ))
    }

    struct StopSizing: Sendable, Equatable {
        let quantity: Double
        let limitPrice: Double
        let stopPrice: Double
        let riskAmount: Double
    }

    /// Dimensionamento della modalità giornaliera: niente target fisso
    /// (l'uscita è a regole), solo stop protettivo sul broker. Il rischio
    /// reale (limite − stop) × quantità non supera equity × riskFraction e la
    /// posizione non supera il 25% del capitale.
    static func sizeStopOnly(
        currentPrice: Double,
        stopDistance: Double,
        account: Account,
        riskFraction: Double,
        constraints: InstrumentConstraints,
        maxPositionFraction: Double = maximumPositionFraction
    ) -> Result<StopSizing, RiskRejection> {
        guard currentPrice.isFinite, currentPrice > 0, stopDistance.isFinite, stopDistance > 0 else {
            return .failure(RiskRejection("Prezzo o distanza stop non validi"))
        }
        guard account.equity > 0 else {
            return .failure(RiskRejection("Patrimonio non positivo"))
        }
        let tick = constraints.tickSize
        let limit = roundUp(currentPrice * (1 + entryLimitSlippage), tick: tick)
        let stop = roundDown(limit - stopDistance, tick: tick)
        guard stop > 0, stop < limit else {
            return .failure(RiskRejection("Stop non valido rispetto al prezzo d'ingresso"))
        }
        let riskPerUnit = limit - stop
        let budgetFraction = min(max(riskFraction, 0.000_1), 0.05)
        let riskBudget = account.equity * budgetFraction
        let raw = min(
            riskBudget / riskPerUnit,
            min(account.cash, account.buyingPower) / limit,
            account.equity * maxPositionFraction / limit
        )
        let lot = constraints.lotSize
        let quantity = (raw / lot + 1e-9).rounded(.down) * lot
        guard quantity >= lot else {
            return .failure(RiskRejection("Quantità sotto il lotto minimo"))
        }
        guard quantity * limit >= constraints.minNotional else {
            return .failure(RiskRejection("Nozionale sotto il minimo dell'exchange"))
        }
        let riskAmount = quantity * riskPerUnit
        guard riskAmount <= riskBudget + 1e-6 else {
            return .failure(RiskRejection("Rischio oltre il \(fmt(budgetFraction * 100))% del capitale"))
        }
        return .success(StopSizing(quantity: quantity, limitPrice: limit, stopPrice: stop, riskAmount: riskAmount))
    }

    /// Capitale del bot: il dimensionamento vede al massimo `capital` dollari,
    /// meno quanto il bot ha già investito (`exposure`). Il rischio per trade e
    /// il tetto del 25% si calcolano sul capitale del bot, non sull'intero conto;
    /// contante e buying power non superano mai la parte ancora libera.
    static func capped(_ account: Account, capital: Double, exposure: Double) -> Account {
        let limit = capital.isFinite && capital > 0 ? capital : account.equity
        let base = max(min(account.equity, limit), 0)
        let free = max(base - max(exposure.isFinite ? exposure : base, 0), 0)
        return Account(equity: base,
                       cash: max(min(account.cash, free), 0),
                       buyingPower: max(min(account.buyingPower, free), 0))
    }

    static func roundUp(_ value: Double, tick: Double) -> Double {
        guard tick > 0 else { return value }
        return ((value / tick) - 1e-9).rounded(.up) * tick
    }

    static func roundDown(_ value: Double, tick: Double) -> Double {
        guard tick > 0 else { return value }
        return ((value / tick) + 1e-9).rounded(.down) * tick
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

struct RiskRejection: Error, Sendable, Equatable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}
