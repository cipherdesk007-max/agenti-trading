import Foundation
import SwiftData

enum SystemLimits {
    static let kimiModel = "kimi-k3.1-pro-highspeed"
    static let kimiAPIHost = "api.moonshot.ai"
    static let marketStreamHost = "stream.data.alpaca.markets/v2/iex"
    static let atrPeriod = 14
    static let decisionIntervalSeconds = 60
    static let maximumRiskFraction = 0.01
    static let fractionalKellyDivisor = 4.0
    static let maximumLatencyMilliseconds = 150.0
    static let maximumPriceDeviation = 0.0005
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
        rationale = receipt.decision.rationale
        netPnL = nil
        stopErrorVariance = nil
        outcomeRecorded = false
    }
}
