import Foundation
import SwiftData

struct AgentLogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let message: String
}

@MainActor
final class QuantSwarmEngine: ObservableObject {
    @Published private(set) var isConfigured = false
    @Published private(set) var isRunning = false
    @Published private(set) var isKillInProgress = false
    @Published private(set) var paperTrading = true
    @Published private(set) var statusMessage = "Credenziali richieste"
    @Published private(set) var logs: [AgentLogEntry] = []
    @Published private(set) var edgeHistory: [EdgePoint] = []

    private let keychain: KeychainManager
    private let background: BackgroundPersistenceManager
    private let modelContext: ModelContext
    private let marketScout = MarketScoutAgent()
    private let riskAgent = RiskExecutionAgent()
    private var kimiService: KimiService?
    private var credentials: StoredCredentials?
    private var analysisTask: Task<Void, Never>?
    private var marketTask: Task<Void, Never>?
    private var snapshots: [String: MarketSnapshot] = [:]
    private var configuredSymbols: [String] = ["SPY"]
    private var configuredNews = ""
    private var baselineEquity: Double?
    private var waitingLogEmitted: Set<String> = []

    init(
        keychain: KeychainManager,
        background: BackgroundPersistenceManager,
        container: ModelContainer
    ) {
        self.keychain = keychain
        self.background = background
        modelContext = ModelContext(container)
        background.setRefreshHandler { [weak self] in
            await self?.performBackgroundRefresh()
        }
    }

    func restoreCredentials() async {
        do {
            let data = try await keychain.read()
            let stored = try JSONDecoder().decode(StoredCredentials.self, from: data)
            apply(stored: stored)
            log("Credenziali sbloccate; ambiente \(stored.paperTrading ? "paper" : "live").")
        } catch QuantSwarmError.credentialsMissing {
            isConfigured = false
            statusMessage = "Credenziali richieste"
        } catch {
            isConfigured = false
            statusMessage = "Sblocco credenziali annullato o non riuscito"
            log(error.localizedDescription)
        }
    }

    func validateAndSave(
        moonshotAPIKey: String,
        alpacaKeyID: String,
        alpacaSecretKey: String,
        paperTrading: Bool
    ) async throws {
        let moonshot = moonshotAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let alpacaID = alpacaKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let alpacaSecret = alpacaSecretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !moonshot.isEmpty, !alpacaID.isEmpty, !alpacaSecret.isEmpty else {
            throw QuantSwarmError.invalidCredentialInput
        }
        let stored = StoredCredentials(
            moonshotAPIKey: moonshot,
            alpacaKeyID: alpacaID,
            alpacaSecretKey: alpacaSecret,
            paperTrading: paperTrading
        )
        let kimi = KimiService(apiKey: moonshot)
        let alpaca = AlpacaService(credentials: stored.alpaca)
        async let kimiValidation: Void = kimi.validateCredentials()
        async let alpacaValidation: Void = alpaca.validateCredentials()
        _ = try await (kimiValidation, alpacaValidation)
        let data = try JSONEncoder().encode(stored)
        try await keychain.save(data: data)
        apply(stored: stored)
        log("API Kimi e Alpaca convalidate; credenziali salvate con Face ID.")
    }

    func logout() async {
        await stop()
        try? await keychain.delete()
        credentials = nil
        kimiService = nil
        isConfigured = false
        baselineEquity = nil
        edgeHistory = []
        statusMessage = "Credenziali richieste"
    }

    func start(symbolsText: String, news: String) async {
        guard let credentials, let kimiService else {
            statusMessage = "Credenziali mancanti"
            return
        }
        guard !isRunning else { return }
        let parsedSymbols = Array(Set(
            symbolsText
                .uppercased()
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )).sorted()
        guard !parsedSymbols.isEmpty else {
            statusMessage = "Inserisci almeno un simbolo"
            return
        }
        let validCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard parsedSymbols.allSatisfy({ $0.rangeOfCharacter(from: validCharacters.inverted) == nil }) else {
            statusMessage = "Simboli non validi"
            return
        }

        configuredSymbols = parsedSymbols
        configuredNews = news.trimmingCharacters(in: .whitespacesAndNewlines)
        snapshots = [:]
        waitingLogEmitted = []
        isRunning = true
        statusMessage = "Sessione \(credentials.paperTrading ? "paper" : "live") attiva"
        background.start()
        log("Motore avviato su \(parsedSymbols.joined(separator: ", ")); ATR richiesto prima dei segnali.")

        let stream = await marketScout.start(
            credentials: credentials.alpaca,
            symbols: parsedSymbols
        )
        marketTask = Task { [weak self] in
            for await event in stream {
                self?.handle(event)
            }
        }
        analysisTask = Task { [weak self] in
            await self?.analysisLoop(kimi: kimiService)
        }
    }

    func stop() async {
        guard isRunning || analysisTask != nil || marketTask != nil else { return }
        isRunning = false
        analysisTask?.cancel()
        marketTask?.cancel()
        analysisTask = nil
        marketTask = nil
        await marketScout.stop()
        background.stop()
        statusMessage = "Motore fermo; posizioni invariate"
        log("Motore fermato. Usa HARD KILL SWITCH per liquidare le posizioni.")
    }

    func hardKill() async {
        guard !isKillInProgress else { return }
        isKillInProgress = true
        defer { isKillInProgress = false }
        await stop()
        statusMessage = "Liquidazione di emergenza in corso"
        log("HARD KILL: cancellazione ordini e liquidazione avviate.")
        guard let credentials else {
            statusMessage = "Credenziali mancanti"
            return
        }
        do {
            try await riskAgent.emergencyFlatten(credentials: credentials.alpaca)
            statusMessage = "HARD KILL completato"
            log("Alpaca ha accettato cancellazione globale e chiusura delle posizioni.")
            await updateEquity()
        } catch {
            statusMessage = "HARD KILL: verifica immediata sul broker"
            log("HARD KILL errore: \(error.localizedDescription)")
        }
    }

    private func apply(stored: StoredCredentials) {
        credentials = stored
        kimiService = KimiService(apiKey: stored.moonshotAPIKey)
        paperTrading = stored.paperTrading
        isConfigured = true
        statusMessage = "Pronto in modalità \(stored.paperTrading ? "paper" : "live")"
    }

    private func handle(_ event: MarketEvent) {
        switch event {
        case .snapshot(let snapshot):
            snapshots[snapshot.symbol] = snapshot
        case .log(let message):
            log(message)
        case .disconnected(let message):
            statusMessage = "Stream disconnesso"
            log(message)
        }
    }

    private func analysisLoop(kimi: KimiService) async {
        while isRunning && !Task.isCancelled {
            await refreshTradeRecords()
            await updateEquity()
            for symbol in configuredSymbols {
                guard isRunning && !Task.isCancelled else { break }
                guard let snapshot = snapshots[symbol], snapshot.atr14 != nil else {
                    if !waitingLogEmitted.contains(symbol) {
                        waitingLogEmitted.insert(symbol)
                        log("\(symbol): attesa di 14 barre per ATR e prezzi correnti.")
                    }
                    continue
                }
                waitingLogEmitted.remove(symbol)
                do {
                    let decision = try await kimi.decide(
                        snapshot: snapshot,
                        news: configuredNews,
                        performance: performanceMatrix()
                    )
                    log("\(symbol): Kimi \(decision.action.rawValue.uppercased()), confidenza \(decision.confidence).")
                    if let receipt = try await riskAgent.execute(
                        decision: decision,
                        snapshot: snapshot,
                        credentials: credentials!.alpaca
                    ) {
                        try persist(receipt: receipt, atr: snapshot.atr14 ?? 0)
                        log("Bracket inviato: \(orderDescription(receipt)).")
                    }
                } catch is CancellationError {
                    return
                } catch QuantSwarmError.riskRejected(let reason) {
                    log("\(symbol): ordine annullato — \(reason).")
                } catch {
                    log("\(symbol): \(error.localizedDescription)")
                }
            }
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                return
            }
        }
    }

    private func performBackgroundRefresh() async {
        guard credentials != nil else { return }
        await refreshTradeRecords()
        await updateEquity()
        log("Refresh BGTask completato nei limiti concessi da iOS.")
    }

    private func persist(receipt: ExecutionReceipt, atr: Double) throws {
        modelContext.insert(TradeRecord(receipt: receipt, atr: atr))
        do {
            try modelContext.save()
        } catch {
            throw QuantSwarmError.persistence(error.localizedDescription)
        }
    }

    private func refreshTradeRecords() async {
        guard let credentials else { return }
        let service = AlpacaService(credentials: credentials.alpaca)
        do {
            var descriptor = FetchDescriptor<TradeRecord>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            descriptor.fetchLimit = 100
            let records = try modelContext.fetch(descriptor).filter { !$0.outcomeRecorded }
            for record in records {
                do {
                    let order = try await service.order(id: record.orderID)
                    if let entry = order.filledAveragePriceValue {
                        record.actualEntry = entry
                    }
                    guard let entry = record.actualEntry,
                          let exit = order.legs?.first(where: {
                              $0.side != order.side
                                  && $0.filledQuantityValue > 0
                                  && $0.filledAveragePriceValue != nil
                          }),
                          let exitPrice = exit.filledAveragePriceValue else {
                        continue
                    }
                    let quantity = exit.filledQuantityValue
                    let direction = order.side == "buy" ? 1.0 : -1.0
                    record.netPnL = (exitPrice - entry) * quantity * direction
                    if exit.type == "stop" || exit.type == "stop_limit" {
                        record.stopErrorVariance = pow(exitPrice - record.stopLoss, 2)
                    }
                    record.outcomeRecorded = true
                    log("Esito \(record.symbol): P&L \(record.netPnL ?? 0).")
                } catch {
                    log("Aggiornamento ordine \(record.orderID): \(error.localizedDescription)")
                }
            }
            if !records.isEmpty { try modelContext.save() }
        } catch {
            log("SwiftData refresh: \(error.localizedDescription)")
        }
    }

    private func performanceMatrix() -> PerformanceMatrix {
        let descriptor = FetchDescriptor<TradeRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        guard let records = try? modelContext.fetch(descriptor) else {
            return PerformanceMatrix(
                submittedTrades: 0,
                completedTrades: 0,
                winRate: nil,
                averageNetPnL: nil,
                stopErrorVariance: nil,
                recentOutcomes: []
            )
        }
        let outcomes = records.compactMap(\.netPnL)
        let completed = records.filter(\.outcomeRecorded)
        let wins = outcomes.filter { $0 > 0 }.count
        let stopErrors = records.compactMap(\.stopErrorVariance)
        return PerformanceMatrix(
            submittedTrades: records.count,
            completedTrades: completed.count,
            winRate: outcomes.isEmpty ? nil : Double(wins) / Double(outcomes.count),
            averageNetPnL: outcomes.isEmpty ? nil : outcomes.reduce(0, +) / Double(outcomes.count),
            stopErrorVariance: stopErrors.isEmpty ? nil : stopErrors.reduce(0, +) / Double(stopErrors.count),
            recentOutcomes: Array(outcomes.prefix(20))
        )
    }

    private func updateEquity() async {
        guard let credentials else { return }
        do {
            let account = try await AlpacaService(credentials: credentials.alpaca).account()
            if baselineEquity == nil { baselineEquity = account.equityValue }
            let edge = account.equityValue - (baselineEquity ?? account.equityValue)
            edgeHistory.append(EdgePoint(timestamp: Date(), value: edge))
            if edgeHistory.count > 500 { edgeHistory.removeFirst(edgeHistory.count - 500) }
            if !isRunning { statusMessage = "Equity \(account.equityValue) USD" }
        } catch {
            log("Equity: \(error.localizedDescription)")
        }
    }

    private func orderDescription(_ receipt: ExecutionReceipt) -> String {
        "\(receipt.decision.symbol) \(receipt.decision.action.rawValue) qty \(receipt.quantity), latenza \(receipt.measuredLatencyMilliseconds) ms"
    }

    private func log(_ message: String) {
        logs.append(AgentLogEntry(timestamp: Date(), message: message))
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }
}
