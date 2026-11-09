import Foundation
import SwiftData

enum AgentKind: String, Sendable {
    case scout = "SCOUT"
    case brain = "KIMI"
    case risk = "RISK"
    case system = "SYS"
}

struct AgentLogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let agent: AgentKind
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
    @Published private(set) var account: AccountSnapshot?
    @Published private(set) var positions: [AlpacaPosition] = []
    @Published private(set) var recentOrders: [AlpacaOrder] = []
    @Published private(set) var decisions: [DecisionEntry] = []
    @Published private(set) var marketClock: AlpacaClock?
    @Published private(set) var kimiBalance: KimiBalance?
    @Published private(set) var calibration: CalibrationStats?
    @Published private(set) var sessionStartedAt: Date?
    @Published private(set) var sessionReportURL: URL?
    @Published private(set) var latestAnalysis: AnalysisEntry?
    @Published private(set) var datasetStats = DatasetStats(total: 0, completed: 0)
    @Published private(set) var datasetExportURL: URL?
    @Published private(set) var lastLoopBeat: Date?
    @Published private(set) var performanceStats: PerformanceStats?

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
    private var staleLogEmitted: Set<String> = []
    private var closeGuardLogged: Set<String> = []
    private var regimeLogged: Set<String> = []
    private var atrHistory: [String: [Double]] = [:]
    private var lastHoldPrice: [String: (price: Double, at: Date)] = [:]
    private var flatByCloseTriggered = false
    private var maxPositionsLogged = false
    private var dailyStopDay: String?
    private var lastClockRefresh: Date?
    private var lastBalanceRefresh: Date?
    private var lastAnalysisAt: Date?
    private var analysisInFlight = false
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatAlerted = false

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
        // Report .txt di un'eventuale sessione precedente (es. generato alla
        // chiusura dell'app): riappare in dashboard per export/eliminazione.
        sessionReportURL = SessionReportBuilder.existingReportURL()
        datasetExportURL = DatasetExporter.existingExportURL()
        refreshDatasetStats()
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

        do {
            try await KimiService(apiKey: moonshot).validateCredentials()
        } catch {
            throw QuantSwarmError.validationFailed(
                stage: "Kimi",
                message: describeValidationError(error)
            )
        }

        do {
            try await AlpacaService(credentials: stored.alpaca).validateCredentials()
        } catch {
            throw QuantSwarmError.validationFailed(
                stage: paperTrading ? "Alpaca paper" : "Alpaca live",
                message: describeValidationError(error)
            )
        }

        let data: Data
        do {
            data = try JSONEncoder().encode(stored)
        } catch {
            throw QuantSwarmError.validationFailed(
                stage: "encoding credenziali",
                message: describeValidationError(error)
            )
        }

        do {
            try await keychain.save(data: data)
        } catch {
            throw QuantSwarmError.validationFailed(
                stage: "Keychain/Face ID",
                message: describeValidationError(error)
            )
        }

        apply(stored: stored)
        log("API Kimi e Alpaca convalidate; credenziali salvate con Face ID.")
    }

    private func describeValidationError(_ error: Error) -> String {
        if let error = error as? QuantSwarmError, let description = error.errorDescription {
            return description
        }
        if let urlError = error as? URLError {
            return "URLError \(urlError.code.rawValue): \(urlError.localizedDescription)"
        }
        if error is DecodingError {
            return "JSON di risposta vuoto o non decodificabile."
        }
        return error.localizedDescription
    }

    func logout() async {
        await stop(reason: "LOGOUT")
        try? await keychain.delete()
        credentials = nil
        kimiService = nil
        isConfigured = false
        baselineEquity = nil
        edgeHistory = []
        account = nil
        positions = []
        recentOrders = []
        decisions = []
        marketClock = nil
        kimiBalance = nil
        sessionStartedAt = nil
        latestAnalysis = nil
        lastAnalysisAt = nil
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
        staleLogEmitted = []
        closeGuardLogged = []
        regimeLogged = []
        atrHistory = [:]
        lastHoldPrice = [:]
        flatByCloseTriggered = false
        maxPositionsLogged = false
        lastAnalysisAt = nil
        NotificationManager.shared.requestAuthorizationIfNeeded()
        isRunning = true
        sessionStartedAt = Date()
        statusMessage = "Sessione \(credentials.paperTrading ? "paper" : "live") attiva"
        background.start()
        log("════════ SESSIONE AVVIATA · ORE \(Date().formatted(date: .omitted, time: .standard)) ════════")
        log("Motore avviato su \(parsedSymbols.joined(separator: ", ")); ATR richiesto prima dei segnali.")
        if let clock = try? await AlpacaService(credentials: credentials.alpaca).clock() {
            marketClock = clock
            if clock.isOpen {
                let chiude = clock.nextCloseDate?.formatted(date: .abbreviated, time: .shortened) ?? "n/d"
                log("Mercato APERTO; chiusura prevista \(chiude).", agent: .scout)
            } else {
                let apre = clock.nextOpenDate?.formatted(date: .abbreviated, time: .shortened) ?? "n/d"
                log("Mercato CHIUSO; prossima apertura \(apre). Le barre arriveranno da quel momento.", agent: .scout)
            }
        }
        await riskAgent.setLogHandler { [weak self] message in
            Task { @MainActor [weak self] in
                self?.log(message, agent: .risk)
            }
        }

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
            await self?.analysisLoop(kimi: kimiService, credentials: credentials)
        }
        heartbeatTask = Task { [weak self] in
            await self?.heartbeatMonitor()
        }
    }

    /// Heartbeat monitor: il ciclo di analisi batte ogni ~60 s. Se il battito
    /// si ferma oltre 150 s a motore attivo (ciclo appeso), avvisa subito:
    /// l'app sembrerebbe viva ma non starebbe più operando.
    private func heartbeatMonitor() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                return
            }
            guard isRunning, !heartbeatAlerted else { continue }
            guard let beat = lastLoopBeat else { continue }
            let silence = Date().timeIntervalSince(beat)
            guard silence > 150 else { continue }
            heartbeatAlerted = true
            log(
                "HEARTBEAT: ciclo di analisi fermo da \(Int(silence)) s a motore attivo; "
                    + "verifica connessione o riavvia con STOP → START.",
                agent: .system
            )
            NotificationManager.shared.notify(
                "HEARTBEAT PERSO",
                body: "Il ciclo del motore non risponde da oltre 150 secondi."
            )
        }
    }

    func stop(reason: String = "STOP manuale") async {
        guard isRunning || analysisTask != nil || marketTask != nil else { return }
        isRunning = false
        analysisTask?.cancel()
        marketTask?.cancel()
        heartbeatTask?.cancel()
        analysisTask = nil
        marketTask = nil
        heartbeatTask = nil
        lastLoopBeat = nil
        heartbeatAlerted = false
        await marketScout.stop()
        background.stop()
        statusMessage = "Motore fermo; posizioni invariate"
        log("Motore fermato. Usa HARD KILL SWITCH per liquidare le posizioni.")
        log("════════ SESSIONE CHIUSA · ORE \(Date().formatted(date: .omitted, time: .standard)) · \(reason) ════════")
        exportSessionReport(reason: reason)
    }

    /// Genera/aggiorna il report .txt della sessione. Chiamato a STOP, HARD KILL
    /// e su chiusura dell'app (snapshot): durante il trading nessuna scrittura
    /// su disco, i log restano solo in RAM.
    func exportSessionReport(reason: String) {
        guard let startedAt = sessionStartedAt else { return }
        sessionReportURL = SessionReportBuilder.write(
            startedAt: startedAt,
            stoppedAt: Date(),
            reason: reason,
            symbols: configuredSymbols,
            paperTrading: paperTrading,
            logs: logs,
            decisions: decisions,
            account: account,
            positions: positions,
            performance: performanceStats
        )
    }

    /// Cancella il report dal dispositivo dopo l'invio: zero spazio occupato.
    func deleteSessionReport() {
        if let url = sessionReportURL {
            SessionReportBuilder.delete(url)
        }
        sessionReportURL = nil
        log("Report di sessione eliminato dal dispositivo.")
    }

    func hardKill() async {
        guard !isKillInProgress else { return }
        isKillInProgress = true
        defer { isKillInProgress = false }
        await stop(reason: "HARD KILL")
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
            NotificationManager.shared.notify(
                "HARD KILL COMPLETATO",
                body: "Cancellazione ordini e chiusura posizioni accettate da Alpaca."
            )
            await refreshPortfolio()
        } catch {
            statusMessage = "HARD KILL: verifica immediata sul broker"
            log("HARD KILL errore: \(error.localizedDescription)")
            NotificationManager.shared.notify(
                "HARD KILL: VERIFICA IL BROKER",
                body: error.localizedDescription
            )
        }
        // Rigenera il report includendo l'esito della liquidazione.
        exportSessionReport(reason: "HARD KILL")
    }

    // MARK: - Kimi Analyst

    /// Analisi manuale dal pulsante ANALIZZA ORA. Throttle di 60 s per non
    /// bruciare crediti con tocchi ripetuti.
    func requestAnalysisNow() async {
        guard let kimiService else {
            statusMessage = "Credenziali mancanti"
            return
        }
        if let last = lastAnalysisAt, Date().timeIntervalSince(last) < 60 {
            log("Analisi manuale troppo ravvicinata: attendi un minuto tra due richieste.", agent: .brain)
            return
        }
        await performAnalysis(kimi: kimiService, manual: true)
    }

    /// Analisi automatica: una chiamata ogni 5 minuti, solo con dati freschi.
    private func runScheduledAnalysis(kimi: KimiService) async {
        guard isRunning, !Task.isCancelled else { return }
        let now = Date()
        let due = lastAnalysisAt.map {
            now.timeIntervalSince($0) >= SystemLimits.analysisIntervalSeconds
        } ?? true
        guard due else { return }
        await performAnalysis(kimi: kimi, manual: false)
    }

    private func performAnalysis(kimi: KimiService, manual: Bool) async {
        guard !analysisInFlight else { return }
        let fresh = snapshots.values
            .filter { Date().timeIntervalSince($0.receivedAt) <= 300 }
            .sorted { $0.symbol < $1.symbol }
        guard !fresh.isEmpty else {
            if manual {
                statusMessage = "Dati fermi: analisi impossibile"
                log("Analisi richiesta ma i dati di mercato sono fermi (mercato chiuso o stream muto).", agent: .brain)
            }
            return
        }
        analysisInFlight = true
        defer { analysisInFlight = false }
        do {
            let analysis = try await kimi.analyze(
                snapshots: fresh,
                positions: positions,
                account: account,
                news: configuredNews,
                recentDecisions: decisions.suffix(5).map(\.decision)
            )
            lastAnalysisAt = Date()
            latestAnalysis = AnalysisEntry(timestamp: Date(), analysis: analysis)
            log(
                "ANALISI: \(analysis.regime.replacingOccurrences(of: "_", with: " ")) · vol \(analysis.volatility) · bias \(analysis.bias) — \(analysis.comment)",
                agent: .brain
            )
        } catch is CancellationError {
            // STOP durante la chiamata: esito atteso, niente da loggare.
        } catch {
            // Throttle anche i fallimenti: un errore ripetuto ogni 60 s
            // brucerebbe crediti Kimi senza produrre nulla.
            lastAnalysisAt = Date()
            log("Analisi Kimi fallita: \(error.localizedDescription)", agent: .brain)
        }
    }

    // MARK: - Dataset training

    /// Esporta tutti i campioni (decisioni + esiti) in un file JSONL unico,
    /// pronto per essere inviato e usato come base di training/calibrazione.
    func exportTrainingDataset() {
        let descriptor = FetchDescriptor<DecisionSample>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        guard let samples = try? modelContext.fetch(descriptor), !samples.isEmpty else {
            log("Dataset vuoto: serve almeno una decisione registrata.", agent: .brain)
            return
        }
        datasetExportURL = DatasetExporter.write(samples: samples)
        if datasetExportURL != nil {
            log("Dataset training esportato: \(samples.count) campioni in JSONL.", agent: .brain)
        } else {
            log("Export dataset fallito.", agent: .brain)
        }
    }

    func deleteDatasetExport() {
        if let url = datasetExportURL {
            DatasetExporter.delete(url)
        }
        datasetExportURL = nil
        log("Export dataset eliminato dal dispositivo.")
    }

    private func refreshDatasetStats() {
        let total = (try? modelContext.fetchCount(FetchDescriptor<DecisionSample>())) ?? 0
        let completed = (try? modelContext.fetchCount(
            FetchDescriptor<DecisionSample>(predicate: #Predicate { $0.evaluated })
        )) ?? 0
        datasetStats = DatasetStats(total: total, completed: completed)
    }

    /// Collega l'esito di un trade (P&L registrato) al campione della
    /// decisione che lo ha generato, tramite order ID.
    private func linkOutcomeToSample(_ record: TradeRecord) {
        var descriptor = FetchDescriptor<DecisionSample>(
            predicate: #Predicate<DecisionSample> { $0.executed && !$0.evaluated }
        )
        descriptor.fetchLimit = 100
        guard let samples = try? modelContext.fetch(descriptor) else { return }
        for sample in samples where sample.orderID == record.orderID {
            sample.netPnL = record.netPnL
            sample.evaluated = true
        }
    }

    /// Valuta gli HOLD più vecchi di 30 minuti: quanto si è mosso il prezzo
    /// da quando Kimi ha deciso di non operare (opportunità persa o rischio
    /// evitato). Serve al dataset per giudicare anche le non-decisioni.
    private func evaluateHoldSamples() {
        let cutoff = Date().addingTimeInterval(-SystemLimits.holdEvaluationSeconds)
        var descriptor = FetchDescriptor<DecisionSample>(
            predicate: #Predicate<DecisionSample> {
                $0.action == "hold" && !$0.evaluated && $0.createdAt < cutoff
            }
        )
        descriptor.fetchLimit = 50
        guard let samples = try? modelContext.fetch(descriptor), !samples.isEmpty else { return }
        var changed = false
        for sample in samples {
            guard let snapshot = snapshots[sample.symbol],
                  snapshot.lastPrice > 0,
                  sample.price > 0 else { continue }
            sample.postHoldMovePct = (snapshot.lastPrice - sample.price) / sample.price * 100
            sample.evaluated = true
            changed = true
        }
        if changed {
            try? modelContext.save()
            refreshDatasetStats()
        }
    }

    // MARK: - Loop principale

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
            log(message, agent: .scout)
        case .disconnected(let message):
            statusMessage = "Stream disconnesso"
            log(message, agent: .scout)
        }
    }

    private var dailyStopActive: Bool {
        guard let day = dailyStopDay else { return false }
        return day == Self.dayStamp()
    }

    private static func dayStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Il circuit breaker giornaliero segue la giornata di borsa USA,
        // non la mezzanotte italiana del dispositivo.
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        return formatter.string(from: Date())
    }

    private func analysisLoop(kimi: KimiService, credentials: StoredCredentials) async {
        while isRunning && !Task.isCancelled {
            // Battito cardiaco del motore: monitorato da heartbeatMonitor().
            lastLoopBeat = Date()
            heartbeatAlerted = false
            await refreshTradeRecords()
            await refreshPortfolioThrottled()
            evaluateHoldSamples()
            await runScheduledAnalysis(kimi: kimi)
            // Flat by close: a T-10 minuti chiude tutto a mercato; una strategia
            // intraday non resta esposta overnight con le gambe del bracket scadute.
            if let clock = marketClock, clock.isOpen, let close = clock.nextCloseDate {
                let toClose = close.timeIntervalSinceNow
                if toClose > 0, toClose <= SystemLimits.flatByCloseSeconds,
                   !positions.isEmpty, !flatByCloseTriggered {
                    flatByCloseTriggered = true
                    log(
                        "T-\(Int(toClose / 60)) min alla chiusura: chiusura totale "
                            + "a mercato (flat by close).",
                        agent: .risk
                    )
                    do {
                        try await riskAgent.emergencyFlatten(credentials: credentials.alpaca)
                        log("Flat by close eseguito.", agent: .risk)
                        NotificationManager.shared.notify(
                            "FLAT BY CLOSE",
                            body: "Posizioni chiuse a mercato prima della chiusura."
                        )
                    } catch {
                        flatByCloseTriggered = false
                        log("Flat by close fallito: \(error.localizedDescription)", agent: .risk)
                    }
                }
            }
            if dailyStopActive {
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    return
                }
                continue
            }
            for symbol in configuredSymbols {
                guard isRunning && !Task.isCancelled else { break }
                guard let snapshot = snapshots[symbol], let atr = snapshot.atr14 else {
                    if !waitingLogEmitted.contains(symbol) {
                        waitingLogEmitted.insert(symbol)
                        log("\(symbol): attesa di \(SystemLimits.atrPeriod) barre per ATR e prezzi correnti.", agent: .scout)
                    }
                    continue
                }
                waitingLogEmitted.remove(symbol)
                let dataAge = Date().timeIntervalSince(snapshot.receivedAt)
                guard dataAge <= 120 else {
                    if !staleLogEmitted.contains(symbol) {
                        staleLogEmitted.insert(symbol)
                        log(
                            "\(symbol): dati fermi da \(Int(dataAge)) s; analisi Kimi in pausa "
                                + "(mercato chiuso o stream fermo), crediti risparmiati.",
                            agent: .scout
                        )
                    }
                    continue
                }
                staleLogEmitted.remove(symbol)
                // Tetto di portafoglio: oltre N posizioni aperte niente nuovi segnali,
                // il rischio per-simbolo altrimenti si somma oltre il previsto.
                if positions.count >= SystemLimits.maxConcurrentPositions {
                    if !maxPositionsLogged {
                        maxPositionsLogged = true
                        log(
                            "Tetto di \(SystemLimits.maxConcurrentPositions) posizioni aperte "
                                + "raggiunto; nuovi segnali sospesi.",
                            agent: .risk
                        )
                    }
                    continue
                }
                maxPositionsLogged = false
                // Guard di chiusura: i bracket hanno time-in-force "day" e le gambe
                // scadono a fine sessione; niente nuove posizioni negli ultimi 15 minuti.
                if let clock = marketClock, clock.isOpen, let close = clock.nextCloseDate {
                    let toClose = close.timeIntervalSinceNow
                    if toClose > 0, toClose <= SystemLimits.closeGuardSeconds {
                        if !closeGuardLogged.contains(symbol) {
                            closeGuardLogged.insert(symbol)
                            log(
                                "\(symbol): \(Int(toClose / 60)) min alla chiusura; "
                                    + "nuove posizioni sospese fino a domani.",
                                agent: .risk
                            )
                        }
                        continue
                    }
                }
                closeGuardLogged.remove(symbol)
                // Filtro regime: ATR oltre 2 sigma dalla propria media = volatilita'
                // anomala; in quel contesto slippage e livelli di Kimi valgono meno.
                var history = atrHistory[symbol] ?? []
                if history.count >= 20 {
                    let mean = history.reduce(0, +) / Double(history.count)
                    let variance = history.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                        / Double(history.count)
                    let deviation = variance.squareRoot()
                    if deviation > 0, atr > mean + 2 * deviation {
                        if !regimeLogged.contains(symbol) {
                            regimeLogged.insert(symbol)
                            log(
                                "\(symbol): ATR \(format(atr)) oltre 2σ dalla media "
                                    + "\(format(mean)); volatilità anomala, simbolo in pausa.",
                                agent: .risk
                            )
                        }
                        continue
                    }
                }
                regimeLogged.remove(symbol)
                history.append(atr)
                if history.count > 240 { history.removeFirst(history.count - 240) }
                atrHistory[symbol] = history
                log(
                    "\(symbol): prezzo \(format(snapshot.lastPrice)), ATR \(format(atr)) "
                        + "→ dati inviati a Kimi.",
                    agent: .scout
                )
                do {
                    let decision = try await kimi.decide(
                        snapshot: snapshot,
                        news: configuredNews,
                        performance: performanceMatrix(),
                        calibration: calibration
                    )
                    decisions.append(DecisionEntry(timestamp: Date(), decision: decision))
                    if decisions.count > 500 { decisions.removeFirst(decisions.count - 500) }
                    log(
                        "\(symbol): \(decision.action.rawValue.uppercased()) "
                            + "confidenza \(Int(decision.confidence * 100))% — \(decision.rationale)",
                        agent: .brain
                    )
                    // Dataset training: OGNI decisione (anche HOLD) diventa un
                    // campione con contesto; l'esito arriva dopo (P&L o
                    // movimento post-HOLD a 30 minuti).
                    let sample = DecisionSample(
                        decision: decision,
                        price: snapshot.lastPrice,
                        atr: atr
                    )
                    modelContext.insert(sample)
                    do {
                        try modelContext.save()
                    } catch {
                        log("Dataset: \(error.localizedDescription)")
                    }
                    refreshDatasetStats()
                    // Opportunity check: quanto si e' mosso il prezzo dall'HOLD precedente.
                    if decision.action == .hold {
                        if let previous = lastHoldPrice[symbol], previous.price > 0 {
                            let change = (snapshot.lastPrice - previous.price) / previous.price * 100
                            log(
                                "\(symbol): dall'HOLD delle "
                                    + "\(previous.at.formatted(date: .omitted, time: .shortened)) "
                                    + "il prezzo si è mosso di \(format(change))%.",
                                agent: .brain
                            )
                        }
                        lastHoldPrice[symbol] = (snapshot.lastPrice, Date())
                    }
                    // Race STOP: se l'utente ha fermato il motore mentre Kimi
                    // rispondeva, nessun ordine deve partire dopo lo STOP.
                    guard isRunning, !Task.isCancelled else { return }
                    if let receipt = try await riskAgent.execute(
                        decision: decision,
                        snapshot: snapshot,
                        credentials: credentials.alpaca
                    ) {
                        sample.orderID = receipt.orderID
                        sample.executed = true
                        try persist(receipt: receipt, atr: atr)
                        let description = orderDescription(receipt)
                        log("Bracket inviato: \(description).", agent: .risk)
                        NotificationManager.shared.notify(
                            "ORDINE INVIATO",
                            body: description
                        )
                    }
                } catch is CancellationError {
                    return
                } catch QuantSwarmError.riskRejected(let reason) {
                    log("\(symbol): ordine annullato — \(reason).", agent: .risk)
                } catch {
                    log("\(symbol): \(error.localizedDescription)", agent: .brain)
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
        await refreshPortfolio()
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
                predicate: #Predicate<TradeRecord> { !$0.outcomeRecorded },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            descriptor.fetchLimit = 100
            let records = try modelContext.fetch(descriptor)
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
                    linkOutcomeToSample(record)
                    let pnlText = format(record.netPnL ?? 0)
                    log("Esito \(record.symbol): P&L \(pnlText) USD.")
                    NotificationManager.shared.notify(
                        "ESITO \(record.symbol)",
                        body: "P&L \(pnlText) USD"
                    )
                } catch {
                    log("Aggiornamento ordine \(record.orderID): \(error.localizedDescription)")
                }
            }
            if !records.isEmpty {
                try modelContext.save()
                refreshDatasetStats()
            }
        } catch {
            log("SwiftData refresh: \(error.localizedDescription)")
        }
        computeCalibration()
    }

    /// Calibrazione di Kimi: Brier score e win rate per fascia di probabilità
    /// dichiarata, calcolati solo su trade con esito registrato.
    private func computeCalibration() {
        let descriptor = FetchDescriptor<TradeRecord>(
            predicate: #Predicate<TradeRecord> { $0.outcomeRecorded }
        )
        guard let records = try? modelContext.fetch(descriptor) else { return }
        let scored: [(probability: Double, won: Double)] = records.compactMap { record in
            guard let probability = record.winProbability, let pnl = record.netPnL else {
                return nil
            }
            return (probability, pnl > 0 ? 1 : 0)
        }
        guard !scored.isEmpty else {
            calibration = nil
            computePerformance()
            return
        }
        let brier = scored.reduce(0) {
            $0 + pow($1.probability - $1.won, 2)
        } / Double(scored.count)
        let ranges: [(String, Range<Double>)] = [
            ("CONF 55–70%", 0.55..<0.70),
            ("CONF 70–85%", 0.70..<0.85),
            ("CONF 85–100%", 0.85..<1.000_001)
        ]
        let buckets: [CalibrationBucket] = ranges.compactMap { label, range in
            let inBucket = scored.filter { range.contains($0.probability) }
            guard !inBucket.isEmpty else { return nil }
            let wins = inBucket.filter { $0.won > 0 }.count
            return CalibrationBucket(
                id: label,
                label: label,
                trades: inBucket.count,
                winRate: Double(wins) / Double(inBucket.count)
            )
        }
        calibration = CalibrationStats(samples: scored.count, brierScore: brier, buckets: buckets)
        computePerformance()
    }

    /// Metriche sui trade chiusi: win rate, profit factor (profitti lordi /
    /// perdite lorde), expectancy per trade e max drawdown della curva P&L
    /// cumulata. Sono i numeri che dicono se il sistema sta davvero funzionando.
    private func computePerformance() {
        let descriptor = FetchDescriptor<TradeRecord>(
            predicate: #Predicate<TradeRecord> { $0.outcomeRecorded },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        guard let records = try? modelContext.fetch(descriptor) else { return }
        let pnls = records.compactMap(\.netPnL)
        guard !pnls.isEmpty else {
            performanceStats = nil
            return
        }
        let wins = pnls.filter { $0 > 0 }
        let losses = pnls.filter { $0 < 0 }
        let grossProfit = wins.reduce(0, +)
        let grossLoss = abs(losses.reduce(0, +))
        var cumulative = 0.0
        var peak = 0.0
        var maxDrawdown = 0.0
        for pnl in pnls {
            cumulative += pnl
            peak = max(peak, cumulative)
            maxDrawdown = max(maxDrawdown, peak - cumulative)
        }
        performanceStats = PerformanceStats(
            completedTrades: pnls.count,
            winRate: Double(wins.count) / Double(pnls.count),
            profitFactor: grossLoss > 0 ? grossProfit / grossLoss : nil,
            expectancy: pnls.reduce(0, +) / Double(pnls.count),
            maxDrawdown: maxDrawdown
        )
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

    /// Circuit breaker giornaliero: P&L oltre -2% di equity = nuovi segnali
    /// sospesi fino al giorno successivo. Le posizioni aperte restano
    /// protette dalle gambe del bracket.
    private func checkDailyLoss(_ snapshot: AccountSnapshot) {
        guard let lastEquity = snapshot.lastEquityValue, lastEquity > 0 else { return }
        let dayPnL = snapshot.equityValue - lastEquity
        let limit = SystemLimits.maxDailyLossFraction * lastEquity
        guard dayPnL <= -limit, !dailyStopActive else { return }
        dailyStopDay = Self.dayStamp()
        let percent = Int(SystemLimits.maxDailyLossFraction * 100)
        log(
            "STOP GIORNALIERO: P&L \(format(dayPnL)) USD oltre il -\(percent)% di equity; "
                + "nuovi segnali sospesi fino a domani.",
            agent: .risk
        )
        NotificationManager.shared.notify(
            "STOP GIORNALIERO -\(percent)%",
            body: "P&L \(format(dayPnL)) USD; nuovi segnali sospesi fino a domani."
        )
    }

    func refreshPortfolio() async {
        guard let credentials else { return }
        let service = AlpacaService(credentials: credentials.alpaca)
        do {
            let snapshot = try await service.account()
            account = snapshot
            checkDailyLoss(snapshot)
            if baselineEquity == nil { baselineEquity = snapshot.equityValue }
            let edge = snapshot.equityValue - (baselineEquity ?? snapshot.equityValue)
            edgeHistory.append(EdgePoint(timestamp: Date(), value: edge))
            if edgeHistory.count > 500 { edgeHistory.removeFirst(edgeHistory.count - 500) }
            if !isRunning { statusMessage = "Equity \(snapshot.equityValue) USD" }
        } catch {
            logUnlessCancelled("Portafoglio", error)
        }
        do {
            positions = try await service.positions()
        } catch {
            logUnlessCancelled("Posizioni", error)
        }
        do {
            recentOrders = try await service.recentOrders()
        } catch {
            logUnlessCancelled("Ordini", error)
        }
        do {
            marketClock = try await service.clock()
            lastClockRefresh = Date()
        } catch {
            logUnlessCancelled("Orologio mercato", error)
        }
        if let kimiService {
            do {
                kimiBalance = try await kimiService.balance()
                lastBalanceRefresh = Date()
            } catch {
                logUnlessCancelled("Crediti Kimi", error)
            }
        }
        computeCalibration()
    }

    /// Variante con throttling per il ciclo automatico: orologio ogni 5 min, crediti ogni 10 min.
    private func refreshPortfolioThrottled() async {
        guard let credentials else { return }
        let service = AlpacaService(credentials: credentials.alpaca)
        do {
            let snapshot = try await service.account()
            account = snapshot
            checkDailyLoss(snapshot)
            if baselineEquity == nil { baselineEquity = snapshot.equityValue }
            let edge = snapshot.equityValue - (baselineEquity ?? snapshot.equityValue)
            edgeHistory.append(EdgePoint(timestamp: Date(), value: edge))
            if edgeHistory.count > 500 { edgeHistory.removeFirst(edgeHistory.count - 500) }
        } catch {
            logUnlessCancelled("Portafoglio", error)
        }
        do {
            positions = try await service.positions()
        } catch {
            logUnlessCancelled("Posizioni", error)
        }
        do {
            recentOrders = try await service.recentOrders()
        } catch {
            logUnlessCancelled("Ordini", error)
        }
        let now = Date()
        if lastClockRefresh.map({ now.timeIntervalSince($0) > 300 }) ?? true {
            do {
                marketClock = try await service.clock()
                lastClockRefresh = now
            } catch {
                logUnlessCancelled("Orologio mercato", error)
            }
        }
        if let kimiService, lastBalanceRefresh.map({ now.timeIntervalSince($0) > 600 }) ?? true {
            do {
                kimiBalance = try await kimiService.balance()
                lastBalanceRefresh = now
            } catch {
                logUnlessCancelled("Crediti Kimi", error)
            }
        }
    }

    private func orderDescription(_ receipt: ExecutionReceipt) -> String {
        "\(receipt.decision.symbol) \(receipt.decision.action.rawValue) qty \(receipt.quantity), latenza \(receipt.measuredLatencyMilliseconds) ms"
    }

    private func log(_ message: String, agent: AgentKind = .system) {
        logs.append(AgentLogEntry(timestamp: Date(), agent: agent, message: message))
        if logs.count > 1000 { logs.removeFirst(logs.count - 1000) }
    }

    /// Ignora le cancellazioni: su STOP o chiusura task sono esiti attesi, non errori.
    private func logUnlessCancelled(_ label: String, _ error: Error) {
        if error is CancellationError { return }
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        log("\(label): \(error.localizedDescription)")
    }

    private func format(_ value: Double, fractionDigits: Int = 2) -> String {
        String(
            format: "%.\(fractionDigits)f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
    }
}
