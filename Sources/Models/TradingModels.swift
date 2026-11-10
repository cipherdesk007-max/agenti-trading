import Foundation
import SwiftData

enum SystemLimits {
    static let kimiModel = "kimi-k3.1-pro-highspeed"
    static let kimiAPIHost = "api.moonshot.ai"
    static let marketStreamHost = "stream.data.alpaca.markets/v2/iex"
    static let atrPeriod = 14
    static let decisionIntervalSeconds = 60
    static let analysisIntervalSeconds: TimeInterval = 300
    static let holdEvaluationSeconds: TimeInterval = 1800
    static let maximumRiskFraction = 0.01
    static let maximumLatencyMilliseconds = 400.0
    /// Scostamento massimo tra prezzo di snapshot e entry proposto da Kimi
    /// (sanity check: Kimi deve ancorarsi al prezzo corrente).
    static let maximumEntryAnchorATR = 2.0
    /// Bug 3: dopo la risposta di Kimi il prezzo viene riletto; se si è mosso
    /// oltre questa frazione di ATR l'ordine viene annullato.
    static let priceRetestATRFraction = 0.5
    /// Bug 2: rapporto rendimento/rischio minimo, calcolato in codice dai livelli.
    static let minimumRiskReward = 1.5
    static let closeGuardSeconds: TimeInterval = 900
    static let flatByCloseSeconds: TimeInterval = 600
    static let maxDailyLossFraction = 0.02
    /// Bug 6: drawdown massimo dal picco di equity; oltre serve sblocco manuale.
    static let maxDrawdownFraction = 0.10
    static let maxConcurrentPositions = 3
    /// Minimo di candele chiuse da 1 minuto prima di coinvolgere Kimi.
    static let minimumCandlesForKimi = 20
}

/// Vincoli di arrotondamento dello strumento: lot size, tick size e nozionale
/// minimo dell'exchange. Per le azioni USA su Alpaca: 1 azione intera.
struct InstrumentConstraints: Sendable {
    let lotSize: Double
    let tickSize: Double
    let minNotional: Double

    static let alpacaStock = InstrumentConstraints(lotSize: 1, tickSize: 0.01, minNotional: 1)

    /// Cifre decimali ammesse dalla lot size (azioni intere → 0).
    var quantityFractionDigits: Int {
        if lotSize >= 1 { return 0 }
        var digits = 0
        var lot = lotSize
        while lot < 1, digits < 8 {
            lot *= 10
            digits += 1
        }
        return digits
    }
}

/// Candela OHLCV chiusa. Quella in formazione non esce mai da CandleStore:
/// Kimi e i filtri vedono solo candele concluse.
struct Candle: Sendable, Equatable {
    let timestamp: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double
}

/// Indicatori calcolati in codice sulle candele chiuse di un timeframe.
/// nil = storico insufficiente per quell'indicatore.
struct IndicatorSnapshot: Sendable {
    let rsi14: Double?
    let ema12: Double?
    let ema26: Double?
    let sma50: Double?
    let sma200: Double?
    let atr14: Double?
    let high20: Double?
    let low20: Double?
    let avgVolume20: Double?
}

/// Contesto di mercato per Kimi: ultime 100 candele chiuse + indicatori su
/// 2 timeframe (1m e 15m), tutto calcolato in codice.
struct MarketContext: Sendable {
    let oneMinuteCandles: [Candle]
    let fifteenMinuteCandles: [Candle]
    let oneMinuteIndicators: IndicatorSnapshot
    let fifteenMinuteIndicators: IndicatorSnapshot
}

/// Stato delle protezioni di rischio, persistito (sopravvive al riavvio).
/// Lo stop giornaliero è calcolato sul giorno UTC; lo stop drawdown resta
/// attivo finché l'utente non lo sblocca manualmente.
struct RiskGuardState: Codable, Sendable {
    var dailyStopDayUTC: String?
    var peakEquity: Double
    var drawdownLocked: Bool

    static let empty = RiskGuardState(dailyStopDayUTC: nil, peakEquity: 0, drawdownLocked: false)
}

enum RiskGuardStore {
    private static let key = "com.quantswarm.alphazero.riskGuard"

    static func load() -> RiskGuardState {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(RiskGuardState.self, from: data) else {
            return .empty
        }
        return state
    }

    static func save(_ state: RiskGuardState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// Impostazioni operative modificabili dall'app (tab SISTEMA), persistite in
/// UserDefaults come JSON: nessuna ricompilazione per cambiare strategia.
/// Il motore legge questi valori a ogni ciclo, quindi le modifiche sono attive
/// dal ciclo di decisioni successivo.
struct StrategyConfig: Codable, Sendable, Equatable {
    /// Rischio massimo per singolo trade, in % di equity (0,25 – 2).
    var riskPerTradePercent: Double
    /// Tetto di posizioni aperte simultanee (1 – 3).
    var maxOpenPositions: Int
    /// Circuit breaker giornaliero, perdita in % di equity (0,5 – 5).
    var dailyStopPercent: Double
    /// Pausa tra due cicli di decisione completi (30 – 120 s).
    var decisionIntervalSeconds: Int
    /// Intervallo del Kimi Analyst, in minuti (2 – 15).
    var analysisIntervalMinutes: Double
    /// Modello Kimi usato per decisioni e analisi (lista caricabile via API).
    var kimiModel: String
    /// Se l'app viene chiusa col motore attivo, al riavvio la sessione
    /// riparte da sola sugli stessi simboli.
    var autoResumeOnLaunch: Bool

    init(
        riskPerTradePercent: Double = 1.0,
        maxOpenPositions: Int = 3,
        dailyStopPercent: Double = 2.0,
        decisionIntervalSeconds: Int = 60,
        analysisIntervalMinutes: Double = 5.0,
        kimiModel: String = SystemLimits.kimiModel,
        autoResumeOnLaunch: Bool = true
    ) {
        self.riskPerTradePercent = riskPerTradePercent
        self.maxOpenPositions = maxOpenPositions
        self.dailyStopPercent = dailyStopPercent
        self.decisionIntervalSeconds = decisionIntervalSeconds
        self.analysisIntervalMinutes = analysisIntervalMinutes
        self.kimiModel = kimiModel
        self.autoResumeOnLaunch = autoResumeOnLaunch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            riskPerTradePercent: try container.decodeIfPresent(Double.self, forKey: .riskPerTradePercent) ?? 1.0,
            maxOpenPositions: try container.decodeIfPresent(Int.self, forKey: .maxOpenPositions) ?? 3,
            dailyStopPercent: try container.decodeIfPresent(Double.self, forKey: .dailyStopPercent) ?? 2.0,
            decisionIntervalSeconds: try container.decodeIfPresent(Int.self, forKey: .decisionIntervalSeconds) ?? 60,
            analysisIntervalMinutes: try container.decodeIfPresent(Double.self, forKey: .analysisIntervalMinutes) ?? 5.0,
            kimiModel: try container.decodeIfPresent(String.self, forKey: .kimiModel) ?? SystemLimits.kimiModel,
            autoResumeOnLaunch: try container.decodeIfPresent(Bool.self, forKey: .autoResumeOnLaunch) ?? true
        )
    }

    /// Limiti già pronti per il motore, con clamp di sicurezza: anche un JSON
    /// corrotto o un valore fuori scala non può mandare l'app fuori guardrail.
    var sanitized: StrategyConfig {
        var copy = self
        copy.riskPerTradePercent = min(max(copy.riskPerTradePercent, 0.25), 2.0)
        copy.maxOpenPositions = min(max(copy.maxOpenPositions, 1), 3)
        copy.dailyStopPercent = min(max(copy.dailyStopPercent, 0.5), 5.0)
        copy.decisionIntervalSeconds = min(max(copy.decisionIntervalSeconds, 30), 120)
        copy.analysisIntervalMinutes = min(max(copy.analysisIntervalMinutes, 2.0), 15.0)
        let model = copy.kimiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.kimiModel = model.isEmpty ? SystemLimits.kimiModel : model
        return copy
    }

    var riskFraction: Double { riskPerTradePercent / 100 }
    var dailyStopFraction: Double { dailyStopPercent / 100 }
    var decisionInterval: TimeInterval { TimeInterval(decisionIntervalSeconds) }
    var analysisInterval: TimeInterval { analysisIntervalMinutes * 60 }
}

enum StrategyConfigStore {
    private static let key = "com.quantswarm.alphazero.strategyConfig"

    static func load() -> StrategyConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let config = try? JSONDecoder().decode(StrategyConfig.self, from: data) else {
            return StrategyConfig()
        }
        return config.sanitized
    }

    static func save(_ config: StrategyConfig) {
        let sanitized = config.sanitized
        guard let data = try? JSONEncoder().encode(sanitized) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum TradeAction: String, Codable, Sendable {
    case buy
    case sell
    case hold
}

struct KimiDecision: Codable, Sendable {
    let symbol: String
    let action: TradeAction
    let confidence: Double
    let entryPrice: Double
    let stopLoss: Double
    let takeProfit: Double
    let winProbability: Double
    let payoffRatio: Double
    let rationale: String

    enum CodingKeys: String, CodingKey {
        case symbol
        case action
        case confidence
        case entryPrice = "entry_price"
        case stopLoss = "stop_loss"
        case takeProfit = "take_profit"
        case winProbability = "win_probability"
        case payoffRatio = "payoff_ratio"
        case rationale
    }

    var isExecutable: Bool {
        guard action != .hold,
              confidence >= 0.55,
              entryPrice > 0,
              stopLoss > 0,
              takeProfit > 0,
              winProbability > 0,
              winProbability < 1,
              payoffRatio > 0 else {
            return false
        }
        return action == .buy
            ? stopLoss < entryPrice && entryPrice < takeProfit
            : takeProfit < entryPrice && entryPrice < stopLoss
    }

    /// R/R calcolato in codice dai livelli (mai fidarsi del payoff dichiarato).
    var riskRewardRatio: Double? {
        let risk = abs(entryPrice - stopLoss)
        guard risk > 0 else { return nil }
        return abs(takeProfit - entryPrice) / risk
    }
}

/// Lettura qualitativa del mercato prodotta dal Kimi Analyst ogni 5 minuti
/// (o su richiesta manuale). Nessuna decisione operativa: solo contesto.
struct KimiAnalysis: Codable, Sendable {
    let regime: String
    let volatility: String
    let bias: String
    let confidence: Double
    let comment: String
}

struct AnalysisEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let analysis: KimiAnalysis
}

struct MarketSnapshot: Sendable {
    let symbol: String
    let lastPrice: Double
    let atr14: Double?
    let sourceTimestamp: Date
    let receivedAt: Date

    var feedLatencyMilliseconds: Double {
        max(0, receivedAt.timeIntervalSince(sourceTimestamp) * 1_000)
    }
}

struct StoredCredentials: Codable, Sendable {
    let moonshotAPIKey: String
    let alpacaKeyID: String
    let alpacaSecretKey: String
    let paperTrading: Bool

    var alpaca: AlpacaCredentials {
        AlpacaCredentials(
            keyID: alpacaKeyID,
            secretKey: alpacaSecretKey,
            paperTrading: paperTrading
        )
    }
}

struct AlpacaCredentials: Sendable {
    let keyID: String
    let secretKey: String
    let paperTrading: Bool

    var tradingBaseURL: URL {
        URL(string: paperTrading
            ? "https://paper-api.alpaca.markets"
            : "https://api.alpaca.markets")!
    }

    var marketDataBaseURL: URL {
        URL(string: "https://data.alpaca.markets")!
    }

    var marketDataStreamURL: URL {
        URL(string: "wss://stream.data.alpaca.markets/v2/iex")!
    }
}

struct AccountSnapshot: Decodable, Sendable {
    let cash: String
    let equity: String
    let buyingPower: String
    let lastEquity: String?
    let tradingBlocked: Bool
    let tradeSuspendedByEmail: Bool

    enum CodingKeys: String, CodingKey {
        case cash
        case equity
        case buyingPower = "buying_power"
        case lastEquity = "last_equity"
        case tradingBlocked = "trading_blocked"
        case tradeSuspendedByEmail = "trade_suspended_by_email"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cash = try container.decodeIfPresent(String.self, forKey: .cash) ?? "0"
        equity = try container.decodeIfPresent(String.self, forKey: .equity) ?? "0"
        buyingPower = try container.decodeIfPresent(String.self, forKey: .buyingPower) ?? "0"
        lastEquity = try container.decodeIfPresent(String.self, forKey: .lastEquity)
        tradingBlocked = try container.decodeIfPresent(Bool.self, forKey: .tradingBlocked) ?? false
        tradeSuspendedByEmail = try container.decodeIfPresent(Bool.self, forKey: .tradeSuspendedByEmail) ?? false
    }

    var cashValue: Double { Double(cash) ?? 0 }
    var equityValue: Double { Double(equity) ?? 0 }
    var buyingPowerValue: Double { Double(buyingPower) ?? 0 }
    var lastEquityValue: Double? { lastEquity.flatMap(Double.init) }
    var dayPnL: Double? { lastEquityValue.map { equityValue - $0 } }
}

struct ExecutionReceipt: Sendable {
    let orderID: String
    let decision: KimiDecision
    let quantity: Double
    let equity: Double
    let measuredLatencyMilliseconds: Double
}

struct EdgePoint: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let value: Double
}

struct DecisionEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let decision: KimiDecision
}

struct PerformanceMatrix: Sendable {
    let submittedTrades: Int
    let completedTrades: Int
    let winRate: Double?
    let averageNetPnL: Double?
    let stopErrorVariance: Double?
    let recentOutcomes: [Double]
}

struct CalibrationBucket: Identifiable, Sendable {
    let id: String
    let label: String
    let trades: Int
    let winRate: Double
}

/// Misura se la win_probability dichiarata da Kimi corrisponde alla realtà.
/// Brier score: 0 = previsione perfetta, 0.25 = equivalente a lanciare una moneta.
struct CalibrationStats: Sendable {
    let samples: Int
    let brierScore: Double
    let buckets: [CalibrationBucket]
}

struct DatasetStats: Sendable {
    let total: Int
    let completed: Int
}

/// Metriche di performance sui trade chiusi, calcolate dai TradeRecord.
/// Profit factor = profitti lordi / perdite lorde (nil se non ci sono
/// perdite: il fattore è infinito). Max drawdown = peggior discesa
/// picco → valle della curva del P&L cumulato.
struct PerformanceStats: Sendable {
    let completedTrades: Int
    let winRate: Double?
    let profitFactor: Double?
    let expectancy: Double?
    let maxDrawdown: Double?
}

enum QuantSwarmError: LocalizedError {
    case credentialsMissing
    case invalidCredentialInput
    case invalidServerResponse(String)
    case httpStatus(Int, String)
    case invalidDecision(String)
    case riskRejected(String)
    case validationFailed(stage: String, message: String)
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .credentialsMissing:
            return "Credenziali non configurate."
        case .invalidCredentialInput:
            return "Tutti i campi credenziali sono obbligatori."
        case .invalidServerResponse(let message):
            return "Risposta non valida: \(message)"
        case .httpStatus(let status, let body):
            return "Errore HTTP \(status): \(body)"
        case .invalidDecision(let message):
            return "Segnale Kimi rifiutato: \(message)"
        case .riskRejected(let message):
            return "Ordine bloccato dal risk manager: \(message)"
        case .validationFailed(let stage, let message):
            return "Validazione \(stage) fallita: \(message)"
        case .persistence(let message):
            return "Persistenza SwiftData: \(message)"
        }
    }
}

@Model
final class TradeRecord {
    var id: UUID
    var orderID: String
    var createdAt: Date
    var symbol: String
    var action: String
    var requestedQuantity: Double
    var expectedEntry: Double
    var actualEntry: Double?
    var stopLoss: Double
    var takeProfit: Double
    var expectedATR: Double
    var confidence: Double
    var winProbability: Double?
    var rationale: String
    var netPnL: Double?
    var stopErrorVariance: Double?
    var outcomeRecorded: Bool

    init(receipt: ExecutionReceipt, atr: Double) {
        id = UUID()
        orderID = receipt.orderID
        createdAt = Date()
        symbol = receipt.decision.symbol
        action = receipt.decision.action.rawValue
        requestedQuantity = receipt.quantity
        expectedEntry = receipt.decision.entryPrice
        actualEntry = nil
        stopLoss = receipt.decision.stopLoss
        takeProfit = receipt.decision.takeProfit
        expectedATR = atr
        confidence = receipt.decision.confidence
        winProbability = receipt.decision.winProbability
        rationale = receipt.decision.rationale
        netPnL = nil
        stopErrorVariance = nil
        outcomeRecorded = false
    }
}

/// Campione di training: ogni decisione di Kimi (compresi gli HOLD) con il
/// contesto di mercato e, quando disponibile, l'esito misurato. È la base del
/// dataset JSONL esportabile per allenare/calibrare il comportamento del modello.
@Model
final class DecisionSample {
    var id: UUID
    var createdAt: Date
    var symbol: String
    var action: String
    var price: Double
    var atr14: Double
    var confidence: Double
    var entryPrice: Double
    var stopLoss: Double
    var takeProfit: Double
    var winProbability: Double
    var payoffRatio: Double
    var rationale: String
    var executed: Bool
    var orderID: String?
    var netPnL: Double?
    /// Per gli HOLD: movimento % del prezzo 30 minuti dopo la decisione
    /// (opportunità persa o perdita evitata).
    var postHoldMovePct: Double?
    var evaluated: Bool

    init(decision: KimiDecision, price: Double, atr: Double) {
        id = UUID()
        createdAt = Date()
        symbol = decision.symbol
        action = decision.action.rawValue
        self.price = price
        atr14 = atr
        confidence = decision.confidence
        entryPrice = decision.entryPrice
        stopLoss = decision.stopLoss
        takeProfit = decision.takeProfit
        winProbability = decision.winProbability
        payoffRatio = decision.payoffRatio
        rationale = decision.rationale
        executed = false
        orderID = nil
        netPnL = nil
        postHoldMovePct = nil
        evaluated = false
    }
}
