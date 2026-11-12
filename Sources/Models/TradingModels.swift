import Foundation
import SwiftData

enum SystemLimits {
    static let kimiModel = "kimi-k3.1-pro-highspeed"
    /// Prefisso del client_order_id dello stop d'emergenza del flat-by-close:
    /// lo stop si riconosce da qui, NON dal tipo d'ordine (anche la gamba stop del
    /// bracket è una vendita stop).
    static let emergencyStopPrefix = "qsv-emg-"
    static let marketStreamHost = "stream.data.alpaca.markets/v2/iex"
    static let atrPeriod = 14
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
    /// Bug 6: drawdown massimo dal picco di equity; oltre serve sblocco manuale.
    static let maxDrawdownFraction = 0.10
    static let maxConcurrentPositions = 3
    /// Minimo di candele chiuse del timeframe decisionale prima di chiamare Kimi.
    static let minimumCandlesForKimi = 20
    /// Timeframe decisionali ammessi (minuti): Kimi solo a chiusura candela.
    static let decisionTimeframesMinutes = [1, 5, 15]
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
struct Candle: Codable, Sendable, Equatable {
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
    /// Conto a cui si riferiscono picco e blocchi (nil = versioni precedenti).
    var accountNumber: String?

    static let empty = RiskGuardState(dailyStopDayUTC: nil, peakEquity: 0, drawdownLocked: false)

    /// Il conto letto dal broker è diverso da quello delle protezioni salvate?
    /// Allora picco e blocchi ripartono dal patrimonio del nuovo conto (un
    /// nuovo conto paper da 10.000 non deve far scattare il drawdown di uno da
    /// 100.000). Al primo avvio dopo l'aggiornamento il conto viene solo
    /// registrato e il picco riallineato; un blocco già attivo resta.
    func adopting(account: String?, equity: Double) -> (state: RiskGuardState, changed: Bool) {
        guard let account, !account.isEmpty, account != accountNumber else { return (self, false) }
        var copy = self
        let changed = accountNumber != nil
        copy.accountNumber = account
        copy.peakEquity = max(equity, 0)
        if changed {
            copy.drawdownLocked = false
            copy.dailyStopDayUTC = nil
        }
        return (copy, changed)
    }
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

/// Contatore crediti Kimi, persistito sul giorno UTC. La spesa è misurata
/// dal saldo reale dell'account (baseline a inizio giornata − saldo attuale),
/// non da stime sui token: il numero mostrato è quello vero.
struct CreditGuardState: Codable, Sendable {
    var dayUTC: String
    var baselineBalance: Double?
    var calls: Int

    static func empty(day: String) -> CreditGuardState {
        CreditGuardState(dayUTC: day, baselineBalance: nil, calls: 0)
    }
}

enum CreditGuardStore {
    private static let key = "com.quantswarm.alphazero.creditGuard"

    static func load() -> CreditGuardState? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(CreditGuardState.self, from: data) else {
            return nil
        }
        return state
    }

    static func save(_ state: CreditGuardState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// Impostazioni operative modificabili dall'app (tab SISTEMA), persistite in
/// UserDefaults come JSON: nessuna ricompilazione per cambiare strategia.
/// Il motore legge questi valori a ogni ciclo, quindi le modifiche sono attive
/// dal ciclo di decisioni successivo.
/// Modalità operativa del motore.
enum TradingMode: String, Codable, Sendable, CaseIterable {
    /// Trend + Pullback su ETF, decisione su barre giornaliere, stop GTC sul
    /// broker: l'unica validata dal backtest (batte il caso). Default.
    case daily
    /// Candele 15m in giornata: SPERIMENTALE, nei backtest perde e non batte
    /// il caso. Richiede l'app aperta e chiude tutto prima della chiusura.
    case intraday
    /// Compra in chiusura (asta MOC) e vende all'apertura (asta OPG) su
    /// S&P 500, Nasdaq-100, Russell 2000 e oro. Solo regole, zero crediti Kimi.
    case night

    var label: String {
        switch self {
        case .daily: return "GIORNALIERA · ETF"
        case .intraday: return "VELOCE · SPERIMENTALE"
        case .night: return "NOTTE · ETF"
        }
    }

    /// Etichetta corta per il selettore.
    var shortLabel: String {
        switch self {
        case .daily: return "GIORNALIERA"
        case .intraday: return "VELOCE"
        case .night: return "NOTTE"
        }
    }

    /// Giornaliera e notte lavorano a controlli periodici con ordini che
    /// restano sul broker: chiudere l'app è previsto.
    var runsOnSchedule: Bool { self != .intraday }
}

struct StrategyConfig: Codable, Sendable, Equatable {
    /// Modalità operativa (default giornaliera, l'unica validata).
    var tradingMode: TradingMode
    /// Rischio massimo per singolo trade, in % di equity (0,25 – 2).
    var riskPerTradePercent: Double
    /// Tetto di posizioni aperte simultanee (1 – 5; nel backtest 5 rende un po' di più).
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
    /// Timeframe della candela alla cui CHIUSURA Kimi viene chiamato (1/5/15 min).
    var decisionTimeframeMinutes: Int
    /// Filtro gratuito in codice (EMA cross, rottura high/low 20, RSI estremo):
    /// se nessun trigger scatta, Kimi non viene chiamato e i crediti restano.
    var kimiFilterEnabled: Bool
    /// Limite di spesa giornaliera Kimi (giorno UTC) misurato dal saldo reale.
    var creditLimitEnabled: Bool
    /// Limite di spesa in USD (0,10 – 50).
    var dailyCreditLimitUSD: Double
    /// Il widget mostra equity e P&L (visibili anche a telefono bloccato).
    var widgetShowsAmounts: Bool
    /// Promemoria lun–ven 15:30 New York per aprire l'app (giornaliera).
    var dailyReminder: Bool
    /// Limite manuale al capitale del bot (default spento: il bot usa tutto il
    /// saldo del conto, che segue da solo guadagni e perdite). Serve solo se
    /// sullo stesso conto ci sono altri soldi da non toccare.
    var capitalLimitEnabled: Bool
    /// Tetto in USD quando il limite è acceso: rischio e tetti si calcolano su
    /// min(patrimonio, tetto) e il bot non impegna mai di più.
    var botCapitalUSD: Double

    /// MODALITÀ PRO: interfaccia senza spiegazioni (default spenta).
    var proMode: Bool
    /// NASCONDI SALDO: saldi e guadagni coperti da ••••• (default spento).
    var hideAmounts: Bool

    /// Tetto effettivo per il motore: infinito = tutto il conto.
    var capitalCap: Double { capitalLimitEnabled ? botCapitalUSD : .infinity }

    static let botCapitalRange: ClosedRange<Double> = 500...1_000_000

    init(
        tradingMode: TradingMode = .daily,
        riskPerTradePercent: Double = 1.0,
        maxOpenPositions: Int = 3,
        dailyStopPercent: Double = 2.0,
        decisionIntervalSeconds: Int = 60,
        analysisIntervalMinutes: Double = 5.0,
        kimiModel: String = SystemLimits.kimiModel,
        autoResumeOnLaunch: Bool = true,
        decisionTimeframeMinutes: Int = 15,
        kimiFilterEnabled: Bool = true,
        creditLimitEnabled: Bool = true,
        dailyCreditLimitUSD: Double = 1.0,
        widgetShowsAmounts: Bool = false,
        dailyReminder: Bool = true,
        capitalLimitEnabled: Bool = false,
        botCapitalUSD: Double = 10_000,
        proMode: Bool = false,
        hideAmounts: Bool = false
    ) {
        self.tradingMode = tradingMode
        self.riskPerTradePercent = riskPerTradePercent
        self.maxOpenPositions = maxOpenPositions
        self.dailyStopPercent = dailyStopPercent
        self.decisionIntervalSeconds = decisionIntervalSeconds
        self.analysisIntervalMinutes = analysisIntervalMinutes
        self.kimiModel = kimiModel
        self.autoResumeOnLaunch = autoResumeOnLaunch
        self.decisionTimeframeMinutes = decisionTimeframeMinutes
        self.kimiFilterEnabled = kimiFilterEnabled
        self.creditLimitEnabled = creditLimitEnabled
        self.dailyCreditLimitUSD = dailyCreditLimitUSD
        self.widgetShowsAmounts = widgetShowsAmounts
        self.dailyReminder = dailyReminder
        self.capitalLimitEnabled = capitalLimitEnabled
        self.botCapitalUSD = botCapitalUSD
        self.proMode = proMode
        self.hideAmounts = hideAmounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            tradingMode: try container.decodeIfPresent(TradingMode.self, forKey: .tradingMode) ?? .daily,
            riskPerTradePercent: try container.decodeIfPresent(Double.self, forKey: .riskPerTradePercent) ?? 1.0,
            maxOpenPositions: try container.decodeIfPresent(Int.self, forKey: .maxOpenPositions) ?? 3,
            dailyStopPercent: try container.decodeIfPresent(Double.self, forKey: .dailyStopPercent) ?? 2.0,
            decisionIntervalSeconds: try container.decodeIfPresent(Int.self, forKey: .decisionIntervalSeconds) ?? 60,
            analysisIntervalMinutes: try container.decodeIfPresent(Double.self, forKey: .analysisIntervalMinutes) ?? 5.0,
            kimiModel: try container.decodeIfPresent(String.self, forKey: .kimiModel) ?? SystemLimits.kimiModel,
            autoResumeOnLaunch: try container.decodeIfPresent(Bool.self, forKey: .autoResumeOnLaunch) ?? true,
            decisionTimeframeMinutes: try container.decodeIfPresent(Int.self, forKey: .decisionTimeframeMinutes) ?? 15,
            kimiFilterEnabled: try container.decodeIfPresent(Bool.self, forKey: .kimiFilterEnabled) ?? true,
            creditLimitEnabled: try container.decodeIfPresent(Bool.self, forKey: .creditLimitEnabled) ?? true,
            dailyCreditLimitUSD: try container.decodeIfPresent(Double.self, forKey: .dailyCreditLimitUSD) ?? 1.0,
            widgetShowsAmounts: try container.decodeIfPresent(Bool.self, forKey: .widgetShowsAmounts) ?? false,
            dailyReminder: try container.decodeIfPresent(Bool.self, forKey: .dailyReminder) ?? true,
            capitalLimitEnabled: try container.decodeIfPresent(Bool.self, forKey: .capitalLimitEnabled) ?? false,
            botCapitalUSD: try container.decodeIfPresent(Double.self, forKey: .botCapitalUSD) ?? 10_000,
            proMode: try container.decodeIfPresent(Bool.self, forKey: .proMode) ?? false,
            hideAmounts: try container.decodeIfPresent(Bool.self, forKey: .hideAmounts) ?? false
        )
    }

    /// Limiti già pronti per il motore, con clamp di sicurezza: anche un JSON
    /// corrotto o un valore fuori scala non può mandare l'app fuori guardrail.
    var sanitized: StrategyConfig {
        var copy = self
        copy.riskPerTradePercent = min(max(copy.riskPerTradePercent, 0.25), 2.0)
        copy.dailyStopPercent = min(max(copy.dailyStopPercent, 0.5), 5.0)
        copy.decisionIntervalSeconds = min(max(copy.decisionIntervalSeconds, 30), 120)
        copy.analysisIntervalMinutes = min(max(copy.analysisIntervalMinutes, 2.0), 15.0)
        let model = copy.kimiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.kimiModel = model.isEmpty ? SystemLimits.kimiModel : model
        copy.maxOpenPositions = min(max(copy.maxOpenPositions, 1), 5)
        if !SystemLimits.decisionTimeframesMinutes.contains(copy.decisionTimeframeMinutes) {
            copy.decisionTimeframeMinutes = 15
        }
        copy.dailyCreditLimitUSD = min(max(copy.dailyCreditLimitUSD, 0.10), 50.0)
        copy.botCapitalUSD = copy.botCapitalUSD.isFinite
            ? min(max(copy.botCapitalUSD, Self.botCapitalRange.lowerBound), Self.botCapitalRange.upperBound)
            : 10_000
        return copy
    }

    var riskFraction: Double { riskPerTradePercent / 100 }
    var dailyStopFraction: Double { dailyStopPercent / 100 }
    var decisionInterval: TimeInterval { TimeInterval(decisionIntervalSeconds) }
    var analysisInterval: TimeInterval { analysisIntervalMinutes * 60 }
    var decisionFrameSeconds: Int { decisionTimeframeMinutes * 60 }
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
}

/// Scelta del Brain giornaliero su un candidato.
struct DailyVerdict: Codable, Sendable, Equatable {
    let symbol: String
    let action: String
    let confidence: Double
    let rationale: String

    var wantsBuy: Bool { action == "buy" }
}

struct DailyVerdictList: Codable, Sendable {
    let decisions: [DailyVerdict]
}

/// Verdetto del Kimi Reviewer avversario: parte dal presupposto che la
/// decisione sia sbagliata e approva solo se non trova obiezioni concrete.
struct KimiReview: Codable, Sendable {
    let verdict: String
    let reason: String

    var approved: Bool { verdict == "approve" }
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

/// Un conto Alpaca salvato (paper o live). La chiave Kimi è una sola per tutti.
struct AlpacaProfile: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var name: String
    let keyID: String
    let secretKey: String
    let paperTrading: Bool
}

struct StoredCredentials: Codable, Sendable {
    let moonshotAPIKey: String
    let alpacaKeyID: String
    let alpacaSecretKey: String
    let paperTrading: Bool
    /// Altri conti salvati (nil nelle versioni precedenti: solo quello attivo).
    var profiles: [AlpacaProfile]? = nil
    var activeProfileID: String? = nil

    /// Tutti i conti, con quello attivo sempre presente.
    var allProfiles: [AlpacaProfile] {
        var list = profiles ?? []
        if !list.contains(where: { $0.keyID == alpacaKeyID && $0.paperTrading == paperTrading }) {
            list.insert(AlpacaProfile(id: activeProfileID ?? "principale",
                                      name: paperTrading ? "Paper principale" : "Live principale",
                                      keyID: alpacaKeyID, secretKey: alpacaSecretKey, paperTrading: paperTrading), at: 0)
        }
        return list
    }

    var activeID: String? {
        allProfiles.first { $0.keyID == alpacaKeyID && $0.paperTrading == paperTrading }?.id
    }

    /// Stesse credenziali con un altro conto attivo.
    func activating(_ profile: AlpacaProfile, in list: [AlpacaProfile]) -> StoredCredentials {
        StoredCredentials(moonshotAPIKey: moonshotAPIKey, alpacaKeyID: profile.keyID,
                          alpacaSecretKey: profile.secretKey, paperTrading: profile.paperTrading,
                          profiles: list, activeProfileID: profile.id)
    }

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
    /// Numero del conto Alpaca: cambia quando si crea un nuovo conto paper.
    let accountNumber: String?

    enum CodingKeys: String, CodingKey {
        case accountNumber = "account_number"
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
        accountNumber = try container.decodeIfPresent(String.self, forKey: .accountNumber)
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

/// Memoria del consiglio: i report degli specialisti locali, la divergenza
/// rilevata e la decisione finale del Chief, con l'esito retrospettivo
/// valutato dopo `SystemLimits.holdEvaluationSeconds` (pattern di
/// DecisionSample.postHoldMovePct). Serve per la pagella per agente
/// (AgentScorecard) e per ricostruire ogni decisione dalle evidenze.
@Model
final class CouncilRecord {
    var id: UUID
    var createdAt: Date
    var symbol: String
    /// Report standardizzati del consiglio, codificati in JSON.
    var reportsJSON: String
    /// Esito del confronto divergenze (JSON di CouncilDivergence.Assessment).
    var divergenceJSON: String?
    /// Decisione finale del Chief: buy / hold.
    var action: String
    var rationale: String
    var confidence: Double
    /// Prezzo di riferimento al momento della decisione (per l'esito).
    var referencePrice: Double
    /// Movimento % del prezzo dopo l'orizzonte di valutazione.
    var outcomeMovePct: Double?
    var evaluated: Bool
    var executed: Bool
    var orderID: String?
    /// Se il Contrarian (Reviewer) ha approvato la proposta.
    var reviewerApproved: Bool

    init(reports: [AgentReport], divergence: CouncilDivergence.Assessment?, decision: KimiDecision, price: Double) {
        id = UUID()
        createdAt = Date()
        symbol = decision.symbol
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        reportsJSON = (try? encoder.encode(reports)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        divergenceJSON = divergence.flatMap {
            (try? encoder.encode($0)).flatMap { String(data: $0, encoding: .utf8) }
        }
        action = decision.action.rawValue
        rationale = decision.rationale
        confidence = decision.confidence
        referencePrice = price
        outcomeMovePct = nil
        evaluated = false
        executed = false
        orderID = nil
        reviewerApproved = false
    }

    /// Report decodificati (se il JSON non è decodificabile, lista vuota).
    var reports: [AgentReport] {
        guard let data = reportsJSON.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AgentReport].self, from: data)) ?? []
    }

    var divergence: CouncilDivergence.Assessment? {
        guard let text = divergenceJSON, let data = text.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CouncilDivergence.Assessment.self, from: data)
    }
}

// MARK: - Catena agenti

/// Gli agenti in ordine: ognuno riceve solo i dati che gli servono dal
/// precedente e passa al successivo il suo risultato.
enum PipelineStageID: String, CaseIterable, Sendable, Identifiable {
    case scout, strategy, analyst, brain, reviewer, risk, executor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scout: return "SCOUT"
        case .strategy: return "STRATEGIA"
        case .analyst: return "ANALYST"
        case .brain: return "BRAIN"
        case .reviewer: return "REVIEWER"
        case .risk: return "RISCHIO"
        case .executor: return "ESECUTORE"
        }
    }

    /// Cosa fa e cosa passa avanti (testo mostrato nell'app).
    var role: String {
        switch self {
        case .scout: return "dati di mercato, conto e posizioni → Strategia"
        case .strategy: return "segnali a regole fisse, zero crediti → Analyst/Brain"
        case .analyst: return "lettura del mercato (Kimi) → Brain e Reviewer"
        case .brain: return "sceglie cosa comprare (Kimi) → Reviewer"
        case .reviewer: return "cerca motivi per bocciare (Kimi) → Rischio"
        case .risk: return "quantità, stop e limiti in codice → Esecutore"
        case .executor: return "invia l'ordine con stop sul broker"
        }
    }

    /// Usa crediti Kimi?
    var usesKimi: Bool { self == .analyst || self == .brain || self == .reviewer }
}

enum PipelineState: String, Sendable {
    case idle, working, done, skipped, blocked, failed
}

struct PipelineStage: Identifiable, Sendable {
    let id: PipelineStageID
    var state: PipelineState
    var detail: String
    var updatedAt: Date?

    static func initial() -> [PipelineStage] {
        PipelineStageID.allCases.map { PipelineStage(id: $0, state: .idle, detail: "in attesa", updatedAt: nil) }
    }
}
