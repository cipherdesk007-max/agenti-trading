import Foundation
import Network
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

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
    @Published private(set) var openOrders: [AlpacaOrder] = []
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
    @Published var strategyConfig = StrategyConfigStore.load()
    @Published private(set) var availableKimiModels: [String] = []
    @Published private(set) var modelListError: String?
    /// Motivo di pausa visibile (rete assente / batteria < 20%): niente Kimi
    /// né ordini finché resta attivo.
    @Published private(set) var pauseReason: String?
    /// Stop giornaliero (giorno UTC, persistito): sopravvive al riavvio.
    @Published private(set) var dailyStopOn = false
    /// Stop drawdown -10% dal picco: sblocco solo manuale.
    @Published private(set) var drawdownLocked = false
    /// Contatore crediti Kimi del giorno UTC: chiamate effettuate e spesa
    /// misurata dal saldo reale dell'account (baseline − saldo attuale).
    @Published private(set) var kimiCallsToday = 0
    @Published private(set) var creditsSpentToday: Double?
    @Published private(set) var creditLimitHit = false
    /// Catena agenti: stato di ogni agente, per la schermata principale.
    @Published private(set) var pipeline: [PipelineStage] = PipelineStage.initial()
    /// Frase unica "cosa sta facendo adesso" mostrata in cima al cruscotto.
    @Published private(set) var currentActivity = "Motore fermo"
    /// Prossimo controllo della modalità giornaliera.
    @Published private(set) var nextCheckAt: Date?
    /// Candidati di oggi (modalità giornaliera) per la UI.
    @Published private(set) var dailyCandidates: [DailyStrategy.Candidate] = []
    /// Modalità attiva della sessione in corso.
    @Published private(set) var activeMode: TradingMode?

    private let keychain: KeychainManager
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
    private var waitingCandlesLogged: Set<String> = []
    private var filterSkipLogged: Set<String> = []
    private var atrHistory: [String: [Double]] = [:]
    private var lastHoldPrice: [String: (price: Double, at: Date)] = [:]
    private var flatByCloseTriggered = false
    private var maxPositionsLogged = false
    private var creditLimitLogged = false
    private var lastClockRefresh: Date?
    private var lastBalanceRefresh: Date?
    private var lastAnalysisAt: Date?
    private var analysisInFlight = false
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatAlerted = false
    /// Protezioni persistite (stop giornaliero UTC + drawdown): un riavvio
    /// dell'app non azzera i circuit breaker.
    private var guardState = RiskGuardStore.load()
    /// Storico candele chiuse per simbolo (1m dallo stream/backfill, 15m
    /// aggregate in codice): è il contesto che Kimi riceve a ogni decisione.
    private var candleStores: [String: CandleStore] = [:]
    /// Simboli per cui un ordine è già partito in questo ciclo: contano
    /// nell'esposizione complessiva anche prima della conferma del broker.
    private var cycleCommittedSymbols: Set<String> = []
    /// Ultima candela del timeframe decisionale già valutata da Kimi:
    /// Kimi viene chiamato solo alla chiusura di una candela nuova.
    private var lastDecisionBucket: [String: Date] = [:]
    /// Contatore crediti persistito sul giorno UTC.
    private var creditGuard: CreditGuardState
    /// Foreground-only: in background nessun nuovo ordine né chiamata Kimi;
    /// al rientro riconciliazione completa col broker.
    private var acceptsNewOrders = true
    private var networkSatisfied = true
    private var lastRiskRejectedNotice: [String: Date] = [:]
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.quantswarm.alphazero.engine.network")

    private let backgroundReminderIdentifier = "quantswarm.background.reminder"
    private let lastSymbolsKey = "com.quantswarm.alphazero.lastSymbols"
    private let lastNewsKey = "com.quantswarm.alphazero.lastNews"

    init(
        keychain: KeychainManager,
        container: ModelContainer
    ) {
        self.keychain = keychain
        modelContext = ModelContext(container)
        creditGuard = CreditGuardStore.load() ?? .empty(day: Self.dayStampUTC())
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.networkSatisfied = satisfied
            }
        }
        pathMonitor.start(queue: monitorQueue)
        drawdownLocked = guardState.drawdownLocked
        dailyStopOn = guardState.dailyStopDayUTC == Self.dayStampUTC()
        rolloverCreditGuardIfNeeded()
        kimiCallsToday = creditGuard.calls
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
            await resumeSavedSessionIfNeeded()
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
        openOrders = []
        recentOrders = []
        decisions = []
        marketClock = nil
        kimiBalance = nil
        sessionStartedAt = nil
        latestAnalysis = nil
        lastAnalysisAt = nil
        availableKimiModels = []
        modelListError = nil
        pauseReason = nil
        acceptsNewOrders = true
        statusMessage = "Credenziali richieste"
    }

    // MARK: - Impostazioni live

    /// Aggiorna la strategia senza ricompilare: salva in UserDefaults, applica
    /// subito il modello Kimi e lascia che il ciclo successivo usi i nuovi limiti.
    func updateStrategyConfig(_ config: StrategyConfig) {
        let sanitized = config.sanitized
        strategyConfig = sanitized
        StrategyConfigStore.save(sanitized)
        kimiService?.setModel(sanitized.kimiModel)
        applyIdleTimer()
        // Il promemoria "motore in background" si programma solo quando l'app
        // va davvero in background (handleEnteredBackground), mai ad app aperta.
        if !isRunning {
            NotificationManager.shared.cancelPending(identifier: backgroundReminderIdentifier)
        }
        log(
            "Impostazioni aggiornate: rischio \(format(sanitized.riskPerTradePercent))%, "
                + "max posizioni \(sanitized.maxOpenPositions), stop giorno \(format(sanitized.dailyStopPercent))%, "
                + "ciclo \(sanitized.decisionIntervalSeconds)s, validità analisi \(format(sanitized.analysisIntervalMinutes, fractionDigits: 1)) min, "
                + "timeframe \(sanitized.decisionTimeframeMinutes)m, filtro \(sanitized.kimiFilterEnabled ? "ON" : "OFF"), "
                + "limite crediti \(sanitized.creditLimitEnabled ? format(sanitized.dailyCreditLimitUSD) + " USD" : "OFF"), "
                + "modello \(sanitized.kimiModel)."
        )
    }

    /// Carica dall'API Kimi la lista reale dei modelli disponibili per la
    /// chiave configurata: il picker SISTEMA parla da solo con Moonshot.
    func loadAvailableKimiModels() async {
        guard let kimiService else {
            modelListError = "Credenziali Kimi mancanti."
            return
        }
        do {
            let models = try await kimiService.listModels()
            availableKimiModels = models
            modelListError = nil
            log("Lista modelli Kimi aggiornata: \(models.count) disponibili.", agent: .brain)
        } catch {
            modelListError = error.localizedDescription
            log("Lista modelli Kimi fallita: \(error.localizedDescription)", agent: .brain)
        }
    }

    // MARK: - Controllo broker manuale

    func cancelOrder(id: String) async {
        guard let credentials else {
            statusMessage = "Credenziali mancanti"
            return
        }
        do {
            try await AlpacaService(credentials: credentials.alpaca).cancelOrder(id: id)
            log("Ordine \(id) cancellato manualmente dal pannello broker.", agent: .risk)
            NotificationManager.shared.notify("ORDINE CANCELLATO", body: id)
            await refreshPortfolio()
        } catch {
            log("Cancellazione ordine \(id) fallita: \(error.localizedDescription)", agent: .risk)
            statusMessage = "Cancellazione ordine fallita"
        }
    }

    func closePosition(symbol: String) async {
        guard let credentials else {
            statusMessage = "Credenziali mancanti"
            return
        }
        do {
            try await AlpacaService(credentials: credentials.alpaca).closePosition(symbol: symbol)
            log("Chiusura a mercato richiesta per \(symbol) dal pannello broker.", agent: .risk)
            NotificationManager.shared.notify("CHIUSURA POSIZIONE", body: symbol)
            await refreshPortfolio()
        } catch {
            log("Chiusura \(symbol) fallita: \(error.localizedDescription)", agent: .risk)
            statusMessage = "Chiusura posizione fallita"
        }
    }

    // MARK: - Sessione

    func start(symbolsText: String, news: String) async {
        guard let credentials, let kimiService else {
            statusMessage = "Credenziali mancanti"
            return
        }
        guard !isRunning else { return }
        if strategyConfig.sanitized.tradingMode == .daily {
            await startDaily(credentials: credentials, kimi: kimiService)
            return
        }
        activeMode = .intraday
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
        UserDefaults.standard.set(symbolsText, forKey: lastSymbolsKey)
        UserDefaults.standard.set(configuredNews, forKey: lastNewsKey)
        snapshots = [:]
        waitingLogEmitted = []
        staleLogEmitted = []
        closeGuardLogged = []
        regimeLogged = []
        waitingCandlesLogged = []
        filterSkipLogged = []
        atrHistory = [:]
        lastHoldPrice = [:]
        flatByCloseTriggered = false
        maxPositionsLogged = false
        creditLimitLogged = false
        lastAnalysisAt = nil
        acceptsNewOrders = true
        pauseReason = nil
        cycleCommittedSymbols = []
        lastRiskRejectedNotice = [:]
        lastDecisionBucket = [:]
        candleStores = Dictionary(uniqueKeysWithValues: parsedSymbols.map { ($0, CandleStore()) })
        drawdownLocked = guardState.drawdownLocked
        dailyStopOn = guardState.dailyStopDayUTC == Self.dayStampUTC()
        rolloverCreditGuardIfNeeded()
        kimiCallsToday = creditGuard.calls
        NotificationManager.shared.requestAuthorizationIfNeeded()
        isRunning = true
        applyIdleTimer()
        // App in primo piano: nessun promemoria, eventuali residui annullati.
        NotificationManager.shared.cancelPending(identifier: backgroundReminderIdentifier)
        sessionStartedAt = Date()
        statusMessage = "Sessione \(credentials.paperTrading ? "paper" : "live") attiva"
        log("════════ SESSIONE AVVIATA · ORE \(Date().formatted(date: .omitted, time: .standard)) ════════")
        let tf = strategyConfig.sanitized.decisionTimeframeMinutes
        log("Motore avviato su \(parsedSymbols.joined(separator: ", ")); Kimi alla chiusura della candela \(tf)m, solo se il filtro gratuito scatta.")
        if drawdownLocked {
            log("ATTENZIONE: stop drawdown attivo da una sessione precedente; sblocco manuale in OPERATIVO.", agent: .risk)
        }
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

        // Backfill candele: Kimi ragiona su storico vero fin dal primo ciclo,
        // non solo sulle barre arrivate dopo l'avvio dello stream. L'ultima
        // candela REST può essere in formazione e viene scartata da seed().
        let alpaca = AlpacaService(credentials: credentials.alpaca)
        var backfilledOneMinute: [String: [Candle]] = [:]
        for symbol in parsedSymbols {
            do {
                async let oneMinuteRequest = alpaca.bars(symbol: symbol, timeframe: "1Min", limit: 100)
                async let fifteenMinuteRequest = alpaca.bars(symbol: symbol, timeframe: "15Min", limit: 100)
                let (oneMinute, fifteenMinute) = try await (oneMinuteRequest, fifteenMinuteRequest)
                candleStores[symbol]?.seed(oneMinute: oneMinute, fifteenMinute: fifteenMinute)
                // Solo barre chiuse per l'ATR: l'ultima può essere in formazione.
                var closedOneMinute = oneMinute
                if let last = closedOneMinute.last, Date() < last.timestamp.addingTimeInterval(60) {
                    closedOneMinute.removeLast()
                }
                backfilledOneMinute[symbol] = closedOneMinute
                log(
                    "\(symbol): storico candele caricato (1m \(oneMinute.count), 15m \(fifteenMinute.count)).",
                    agent: .scout
                )
            } catch is CancellationError {
                return
            } catch {
                log(
                    "\(symbol): backfill candele non riuscito; lo storico si costruirà dallo stream.",
                    agent: .scout
                )
            }
        }

        let stream = await marketScout.start(
            credentials: credentials.alpaca,
            symbols: parsedSymbols
        )
        // start() azzera gli stati ATR: il seed dallo storico va fatto dopo.
        for (symbol, candles) in backfilledOneMinute {
            await marketScout.seedATR(symbol: symbol, oneMinute: candles)
        }
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

    /// Ripresa automatica opzionale: se l'app è stata chiusa col motore attivo,
    /// al prossimo sblocco Face ID riparte la sessione sugli stessi simboli.
    private func resumeSavedSessionIfNeeded() async {
        guard strategyConfig.autoResumeOnLaunch, !isRunning else { return }
        if strategyConfig.sanitized.tradingMode == .daily {
            log("Ripresa automatica della modalità giornaliera sul paniere ETF.")
            await start(symbolsText: "", news: "")
            return
        }
        guard let symbolsText = UserDefaults.standard.string(forKey: lastSymbolsKey),
              !symbolsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let news = UserDefaults.standard.string(forKey: lastNewsKey) ?? ""
        log("Ripresa automatica della sessione salvata su \(symbolsText).")
        await start(symbolsText: symbolsText, news: news)
    }

    /// Schermo sempre acceso mentre il motore gira: l'app è fatta per restare
    /// in foreground durante la sessione, con l'indicatore MOTORE ATTIVO
    /// ben visibile in cima alla dashboard.
    private func applyIdleTimer() {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = isRunning
        #endif
    }

    /// Promemoria locale: se iOS sospende l'app in background, l'utente viene
    /// richiamato. Non è un WebSocket permanente: è il massimo consentito da iOS.
    private func scheduleBackgroundReminder() {
        NotificationManager.shared.cancelPending(identifier: backgroundReminderIdentifier)
        NotificationManager.shared.schedule(
            identifier: backgroundReminderIdentifier,
            title: "MOTORE IN BACKGROUND",
            body: "iOS può sospendere stream e cicli: riapri QuantSwarm per verificare che sia ancora attivo.",
            after: 20 * 60
        )
    }

    /// Heartbeat monitor: il ciclo di analisi batte a ogni giro. Se il battito
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
        applyIdleTimer()
        NotificationManager.shared.cancelPending(identifier: backgroundReminderIdentifier)
        analysisTask?.cancel()
        marketTask?.cancel()
        heartbeatTask?.cancel()
        analysisTask = nil
        marketTask = nil
        heartbeatTask = nil
        lastLoopBeat = nil
        heartbeatAlerted = false
        pauseReason = nil
        acceptsNewOrders = true
        await marketScout.stop()
        statusMessage = "Motore fermo; posizioni invariate"
        currentActivity = "Motore fermo"
        nextCheckAt = nil
        activeMode = nil
        pipeline = PipelineStage.initial()
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

    // MARK: - Foreground / background

    /// L'app va in background: nessun nuovo ordine né chiamata Kimi. Le
    /// posizioni aperte restano protette dalle gambe stop/target già sul broker.
    func handleEnteredBackground() {
        guard acceptsNewOrders else { return }
        acceptsNewOrders = false
        if isRunning {
            log("App in background: nuovi ordini e chiamate Kimi sospesi; posizioni protette sul broker.", agent: .system)
            // Solo ora, ad app davvero in background, parte il promemoria.
            scheduleBackgroundReminder()
        }
    }

    /// Rientro in foreground: riconciliazione completa con il broker (esiti,
    /// posizioni, ordini, equity) PRIMA di riabilitare i nuovi ordini.
    func handleEnteredForeground() async {
        // Di nuovo in primo piano: il promemoria non serve più.
        NotificationManager.shared.cancelPending(identifier: backgroundReminderIdentifier)
        let wasSuspended = !acceptsNewOrders
        if wasSuspended, credentials != nil {
            log("App di nuovo in foreground: riconciliazione col broker in corso…", agent: .system)
            await refreshTradeRecords()
            await refreshPortfolio()
            log("Riconciliazione completata: nuovi ordini riabilitati.", agent: .system)
        }
        acceptsNewOrders = true
    }

    /// Sblocco manuale dello stop drawdown: il picco viene riallineato
    /// all'equity corrente, altrimenti il blocco scattarebbe di nuovo al
    /// primo ciclo.
    func unlockDrawdown() {
        if let equity = account?.equityValue, equity > 0 {
            guardState.peakEquity = equity
        }
        guardState.drawdownLocked = false
        RiskGuardStore.save(guardState)
        drawdownLocked = false
        log("Stop drawdown sbloccato manualmente; picco equity riallineato all'equity corrente.", agent: .risk)
        NotificationManager.shared.notify(
            "DRAWDOWN SBLOCCATO",
            body: "Nuovi ordini riabilitati manualmente."
        )
    }

    /// Motivi di pausa gratuiti e locali: rete assente o batteria sotto il 20%
    /// (e non in carica). Finché la pausa resta, niente Kimi né ordini.
    private func computePauseReason() -> String? {
        if !networkSatisfied { return "RETE ASSENTE" }
        #if canImport(UIKit)
        let device = UIDevice.current
        if device.batteryLevel >= 0, device.batteryLevel < 0.20,
           device.batteryState != .charging, device.batteryState != .full {
            return "BATTERIA SOTTO 20%"
        }
        #endif
        return nil
    }

    // MARK: - Contatore crediti Kimi

    /// A mezzanotte UTC il contatore riparte: nuovo giorno, nuova baseline
    /// di saldo (letta al primo refresh utile), chiamate azzerate.
    private func rolloverCreditGuardIfNeeded() {
        let today = Self.dayStampUTC()
        guard creditGuard.dayUTC != today else { return }
        creditGuard = .empty(day: today)
        CreditGuardStore.save(creditGuard)
        creditsSpentToday = nil
        creditLimitHit = false
        creditLimitLogged = false
    }

    /// Ogni chiamata Kimi (decisione, review, analisi) viene conteggiata.
    private func registerKimiCall() {
        rolloverCreditGuardIfNeeded()
        creditGuard.calls += 1
        kimiCallsToday = creditGuard.calls
        CreditGuardStore.save(creditGuard)
    }

    /// Spesa reale del giorno: baseline del saldo a inizio giornata meno il
    /// saldo attuale. Niente stime sui token: è il numero dell'account Kimi.
    private func trackCredits(balance: KimiBalance) {
        rolloverCreditGuardIfNeeded()
        guard let available = balance.availableBalance else { return }
        if creditGuard.baselineBalance == nil {
            creditGuard.baselineBalance = available
            CreditGuardStore.save(creditGuard)
        }
        if let baseline = creditGuard.baselineBalance {
            creditsSpentToday = max(0, baseline - available)
        }
    }

    /// Limite di spesa giornaliera: misurato sul saldo reale. Se il saldo non
    /// è ancora stato letto non si blocca (la prima lettura fissa la baseline).
    private var creditLimitExceeded: Bool {
        let config = strategyConfig.sanitized
        guard config.creditLimitEnabled else { return false }
        guard let spent = creditsSpentToday else { return false }
        return spent >= config.dailyCreditLimitUSD
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
        registerKimiCall()
        // L'Analyst vede le stesse candele e indicatori del Brain.
        var contexts: [String: MarketContext] = [:]
        for snapshot in fresh {
            if let context = candleStores[snapshot.symbol]?.context() {
                contexts[snapshot.symbol] = context
            }
        }
        do {
            let analysis = try await kimi.analyze(
                snapshots: fresh,
                positions: positions,
                account: account,
                news: configuredNews,
                recentDecisions: decisions.suffix(5).map(\.decision),
                contexts: contexts
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
        let service = KimiService(apiKey: stored.moonshotAPIKey)
        service.setModel(strategyConfig.kimiModel)
        kimiService = service
        paperTrading = stored.paperTrading
        isConfigured = true
        statusMessage = "Pronto in modalità \(stored.paperTrading ? "paper" : "live")"
    }

    private func handle(_ event: MarketEvent) {
        switch event {
        case .snapshot(let snapshot):
            snapshots[snapshot.symbol] = snapshot
        case .candle(let symbol, let candle):
            candleStores[symbol]?.ingest(candle)
        case .log(let message):
            log(message, agent: .scout)
        case .disconnected(let message):
            statusMessage = "Stream disconnesso"
            log(message, agent: .scout)
        }
    }

    private var dailyStopActive: Bool {
        guard let day = guardState.dailyStopDayUTC else { return false }
        return day == Self.dayStampUTC()
    }

    /// Lo stop giornaliero e il contatore crediti seguono il giorno UTC:
    /// chiudere e riaprire l'app non azzera circuit breaker né spesa.
    private static func dayStampUTC() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }

    private func analysisLoop(kimi: KimiService, credentials: StoredCredentials) async {
        while isRunning && !Task.isCancelled {
            let config = strategyConfig.sanitized
            // Battito cardiaco del motore: monitorato da heartbeatMonitor().
            lastLoopBeat = Date()
            heartbeatAlerted = false

            // Pausa locale (rete/batteria): log e notifica solo alle transizioni.
            let pause = computePauseReason()
            if pause != pauseReason {
                pauseReason = pause
                if let pause {
                    log(
                        "MOTORE IN PAUSA: \(pause). Kimi e nuovi ordini sospesi; posizioni protette sul broker.",
                        agent: .system
                    )
                    NotificationManager.shared.notify("MOTORE IN PAUSA", body: pause)
                } else {
                    log("Pausa rientrata: motore di nuovo operativo.", agent: .system)
                }
            }
            if dailyStopOn != dailyStopActive { dailyStopOn = dailyStopActive }
            rolloverCreditGuardIfNeeded()
            if creditLimitHit != creditLimitExceeded { creditLimitHit = creditLimitExceeded }
            cycleCommittedSymbols = []

            await refreshTradeRecords()
            await refreshPortfolioThrottled()
            evaluateHoldSamples()
            // L'Analyst non gira più a orologio: parte solo prima di una
            // decisione (catena Scout → filtro → Analyst → Brain → Reviewer →
            // Rischio) o su ANALIZZA ORA. Niente crediti spesi a vuoto.
            // Flat by close: a T-10 minuti chiude tutto a mercato; una strategia
            // intraday non resta esposta overnight con le gambe del bracket scadute.
            // Resta attivo anche in pausa: è protezione del capitale, non un nuovo ingresso.
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
            // Gate globale: pausa, background, stop giornaliero, drawdown o
            // limite crediti bloccano nuovi segnali e ordini; il monitoraggio
            // continua (posizioni sempre riconciliate col broker).
            guard pauseReason == nil, acceptsNewOrders, !dailyStopActive, !drawdownLocked else {
                do {
                    try await Task.sleep(nanoseconds: UInt64(config.decisionInterval * 1_000_000_000))
                } catch {
                    return
                }
                continue
            }
            if creditLimitExceeded {
                if !creditLimitLogged {
                    creditLimitLogged = true
                    log(
                        "LIMITE CREDITI raggiunto: spesi \(format(creditsSpentToday ?? 0)) USD su "
                            + "limite \(format(config.dailyCreditLimitUSD)) USD; Kimi sospeso fino a mezzanotte UTC.",
                        agent: .brain
                    )
                    NotificationManager.shared.notify(
                        "LIMITE CREDITI KIMI",
                        body: "Spesa giornaliera oltre \(format(config.dailyCreditLimitUSD)) USD; nuovi segnali sospesi."
                    )
                }
                do {
                    try await Task.sleep(nanoseconds: UInt64(config.decisionInterval * 1_000_000_000))
                } catch {
                    return
                }
                continue
            }
            creditLimitLogged = false
            for symbol in configuredSymbols {
                guard isRunning && !Task.isCancelled else { break }
                guard let streamSnapshot = snapshots[symbol], let streamATR = streamSnapshot.atr14 else {
                    if !waitingLogEmitted.contains(symbol) {
                        waitingLogEmitted.insert(symbol)
                        let reason = snapshots[symbol] == nil
                            ? "in attesa del primo prezzo dallo stream"
                            : "in attesa di \(SystemLimits.atrPeriod) barre per l'ATR"
                        log("\(symbol): \(reason).", agent: .scout)
                    }
                    continue
                }
                waitingLogEmitted.remove(symbol)
                let dataAge = Date().timeIntervalSince(streamSnapshot.receivedAt)
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
                if positions.count >= config.maxOpenPositions {
                    if !maxPositionsLogged {
                        maxPositionsLogged = true
                        log(
                            "Tetto di \(config.maxOpenPositions) posizioni aperte "
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
                    if deviation > 0, streamATR > mean + 2 * deviation {
                        if !regimeLogged.contains(symbol) {
                            regimeLogged.insert(symbol)
                            log(
                                "\(symbol): ATR \(format(streamATR)) oltre 2σ dalla media "
                                    + "\(format(mean)); volatilità anomala, simbolo in pausa.",
                                agent: .risk
                            )
                        }
                        continue
                    }
                }
                regimeLogged.remove(symbol)
                history.append(streamATR)
                if history.count > 240 { history.removeFirst(history.count - 240) }
                atrHistory[symbol] = history
                // Kimi solo alla CHIUSURA di una candela nuova del timeframe
                // decisionale (default 15m): niente chiamate a ogni ciclo.
                let decisionCandles = candleStores[symbol]?.decisionCandles(frameSeconds: config.decisionFrameSeconds) ?? []
                guard decisionCandles.count >= SystemLimits.minimumCandlesForKimi,
                      let lastClosed = decisionCandles.last else {
                    if !waitingCandlesLogged.contains(symbol) {
                        waitingCandlesLogged.insert(symbol)
                        log(
                            "\(symbol): attesa candele \(config.decisionTimeframeMinutes)m chiuse (\(decisionCandles.count)/\(SystemLimits.minimumCandlesForKimi)).",
                            agent: .scout
                        )
                    }
                    continue
                }
                waitingCandlesLogged.remove(symbol)
                // ATR del timeframe DECISIONALE (es. 15m): è su queste candele che
                // Kimi ragiona e mette lo stop. L'ATR 1m dello stream resta solo
                // per il filtro di volatilità anomala qui sopra.
                let atr = Indicators.atr(decisionCandles, period: SystemLimits.atrPeriod) ?? streamATR
                let snapshot = MarketSnapshot(
                    symbol: streamSnapshot.symbol,
                    lastPrice: streamSnapshot.lastPrice,
                    atr14: atr,
                    sourceTimestamp: streamSnapshot.sourceTimestamp,
                    receivedAt: streamSnapshot.receivedAt
                )
                guard lastDecisionBucket[symbol] != lastClosed.timestamp else { continue }
                lastDecisionBucket[symbol] = lastClosed.timestamp
                // Filtro gratuito in codice: EMA cross, rottura high/low 20 o
                // RSI estremo. Nessun trigger = Kimi non chiamato, zero crediti.
                if config.kimiFilterEnabled {
                    setStage(.scout, .done, "\(symbol): candela \(config.decisionTimeframeMinutes)m chiusa, prezzo \(format(snapshot.lastPrice))")
                    guard let trigger = FilterTrigger.evaluate(candles: decisionCandles) else {
                        setStage(.strategy, .done, "\(symbol): nessun segnale")
                        skipStages(after: .strategy, "nessun segnale · 0 crediti")
                        if !filterSkipLogged.contains(symbol) {
                            filterSkipLogged.insert(symbol)
                            log(
                                "\(symbol): filtro gratuito senza trigger a chiusura candela; Kimi non chiamato, crediti risparmiati.",
                                agent: .scout
                            )
                        }
                        continue
                    }
                    filterSkipLogged.remove(symbol)
                    log(
                        "\(symbol): trigger \(trigger) sulla candela \(config.decisionTimeframeMinutes)m "
                            + "→ dati inviati a Kimi (prezzo \(format(snapshot.lastPrice)), ATR \(format(atr))).",
                        agent: .scout
                    )
                } else {
                    log(
                        "\(symbol): chiusura candela \(config.decisionTimeframeMinutes)m → dati inviati a Kimi "
                            + "(prezzo \(format(snapshot.lastPrice)), ATR \(format(atr))).",
                        agent: .scout
                    )
                }
                setStage(.strategy, .done, "\(symbol): segnale")
                let context = candleStores[symbol]?.context()
                // Catena agenti: se la lettura dell'Analyst è più vecchia di
                // "validità analisi" (impostazioni), viene aggiornata PRIMA del
                // Brain e gli viene passata.
                let analysisValidity = strategyConfig.sanitized.analysisInterval
                let analysisAge = latestAnalysis.map { Date().timeIntervalSince($0.timestamp) }
                if (analysisAge ?? .infinity) > analysisValidity, !creditLimitExceeded {
                    await performAnalysis(kimi: kimi, manual: false)
                }
                let analystView = latestAnalysis.flatMap {
                    Date().timeIntervalSince($0.timestamp) <= analysisValidity ? $0.analysis : nil
                }
                setStage(.analyst, .done, latestAnalysis.map { "\($0.analysis.regime) · bias \($0.analysis.bias)" } ?? "nessuna lettura")
                setStage(.brain, .working, "Kimi decide su \(symbol)")
                do {
                    let decision = try await kimi.decide(
                        snapshot: snapshot,
                        news: configuredNews,
                        performance: performanceMatrix(),
                        calibration: calibration,
                        marketContext: context,
                        analystView: analystView
                    )
                    registerKimiCall()
                    setStage(.brain, .done, "\(symbol): \(decision.action.rawValue.uppercased()) \(Int(decision.confidence * 100))%")
                    if decision.action == .hold { skipStages(after: .brain, "Brain: hold") }
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
                    // Race background/pausa: l'utente può aver chiuso l'app o
                    // la rete può essere caduta mentre Kimi rispondeva.
                    guard acceptsNewOrders, pauseReason == nil, !dailyStopActive, !drawdownLocked else {
                        log("\(symbol): segnale scartato, motore non più operativo.", agent: .risk)
                        continue
                    }
                    // Controlli a regole fisse PRIMA del reviewer: una proposta
                    // che il rischio boccerebbe comunque (short, stop fuori ATR,
                    // R/R basso) non deve costare una seconda chiamata Kimi.
                    if decision.action != .hold,
                       let reason = RiskRules.precheck(
                           RiskRules.Proposal(
                               action: decision.action,
                               entry: decision.entryPrice,
                               stopLoss: decision.stopLoss,
                               takeProfit: decision.takeProfit
                           ),
                           lastPrice: snapshot.lastPrice,
                           atr: atr
                       ) {
                        log("\(symbol): proposta scartata dalle regole — \(reason).", agent: .risk)
                        continue
                    }
                    // Kimi Reviewer avversario: gira solo sui trade proposti e
                    // parte dal presupposto che la decisione sia sbagliata.
                    // Errore del reviewer = nessun ordine (fail-closed).
                    if decision.action != .hold {
                        let review: KimiReview
                        do {
                            review = try await kimi.review(
                                decision: decision,
                                snapshot: snapshot,
                                marketContext: context,
                                analystView: analystView
                            )
                            registerKimiCall()
                        } catch is CancellationError {
                            return
                        } catch {
                            log(
                                "\(symbol): reviewer Kimi fallito (\(error.localizedDescription)); ordine annullato.",
                                agent: .brain
                            )
                            continue
                        }
                        guard review.approved else {
                            setStage(.reviewer, .done, "\(symbol) bocciato")
                            skipStages(after: .reviewer, "bocciato dal Reviewer")
                            log("\(symbol): REVIEWER respinge — \(review.reason)", agent: .brain)
                            continue
                        }
                        setStage(.reviewer, .done, "\(symbol) approvato")
                        setStage(.risk, .working, "dimensiono \(symbol)")
                        log("\(symbol): reviewer approva — \(review.reason)", agent: .brain)
                    }
                    if let receipt = try await riskAgent.execute(
                        decision: decision,
                        snapshot: snapshot,
                        credentials: credentials.alpaca,
                        riskFraction: config.riskFraction,
                        atr: atr,
                        maxOpenPositions: config.maxOpenPositions,
                        alreadyCommittedThisCycle: cycleCommittedSymbols,
                        constraints: .alpacaStock,
                        freshPrice: { [weak self] in
                            if let streamed = await self?.freshStreamPrice(for: symbol) {
                                return streamed
                            }
                            return try? await AlpacaService(credentials: credentials.alpaca)
                                .latestTradePrice(symbol: symbol)
                        }
                    ) {
                        cycleCommittedSymbols.insert(symbol)
                        setStage(.risk, .done, "\(symbol): \(Int(receipt.quantity)) az.")
                        setStage(.executor, .done, "\(symbol): bracket inviato")
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
                    setStage(.risk, .blocked, "\(symbol): \(reason)")
                    log("\(symbol): ordine annullato — \(reason).", agent: .risk)
                    // Notifica throttled: i rifiuti del risk manager sono
                    // importanti ma non devono tempestare l'utente a ogni ciclo.
                    let now = Date()
                    if now.timeIntervalSince(lastRiskRejectedNotice[symbol] ?? .distantPast) > 600 {
                        lastRiskRejectedNotice[symbol] = now
                        NotificationManager.shared.notify("ORDINE BLOCCATO", body: "\(symbol): \(reason)")
                    }
                } catch {
                    log("\(symbol): \(error.localizedDescription)", agent: .brain)
                }
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(config.decisionInterval * 1_000_000_000))
            } catch {
                return
            }
        }
    }

    /// Rilettura post-Kimi dallo stream: prezzo fresco (≤ 10 s) già in memoria,
    /// senza un giro REST extra. Se lo stream tace, il risk agent usa il REST.
    private func freshStreamPrice(for symbol: String) -> Double? {
        guard let snapshot = snapshots[symbol],
              Date().timeIntervalSince(snapshot.receivedAt) <= 10 else { return nil }
        return snapshot.lastPrice
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

    /// Circuit breaker giornaliero: P&L oltre la soglia impostata = nuovi
    /// segnali sospesi fino alla mezzanotte UTC. Persistito su disco: un
    /// riavvio dell'app non azzera il blocco. Le posizioni aperte restano
    /// protette dalle gambe del bracket.
    private func checkDailyLoss(_ snapshot: AccountSnapshot) {
        guard let lastEquity = snapshot.lastEquityValue, lastEquity > 0 else { return }
        let config = strategyConfig.sanitized
        let dayPnL = snapshot.equityValue - lastEquity
        let limit = config.dailyStopFraction * lastEquity
        guard dayPnL <= -limit, !dailyStopActive else { return }
        guardState.dailyStopDayUTC = Self.dayStampUTC()
        RiskGuardStore.save(guardState)
        dailyStopOn = true
        let percent = format(config.dailyStopPercent)
        log(
            "STOP GIORNALIERO: P&L \(format(dayPnL)) USD oltre il -\(percent)% di equity; "
                + "nuovi segnali sospesi fino alla mezzanotte UTC.",
            agent: .risk
        )
        NotificationManager.shared.notify(
            "STOP GIORNALIERO -\(percent)%",
            body: "P&L \(format(dayPnL)) USD; nuovi segnali sospesi fino alla mezzanotte UTC."
        )
    }

    /// Stop drawdown: equity oltre il -10% dal picco storico = nuovi ordini
    /// bloccati finché l'utente non sblocca manualmente. Persistito su disco.
    private func updateDrawdownGuard(equity: Double) {
        guard equity > 0 else { return }
        if equity > guardState.peakEquity {
            guardState.peakEquity = equity
            RiskGuardStore.save(guardState)
        }
        let floor = guardState.peakEquity * (1 - SystemLimits.maxDrawdownFraction)
        guard guardState.peakEquity > 0, equity <= floor, !guardState.drawdownLocked else { return }
        guardState.drawdownLocked = true
        RiskGuardStore.save(guardState)
        drawdownLocked = true
        log(
            "STOP DRAWDOWN: equity \(format(equity)) USD sotto il -10% dal picco "
                + "\(format(guardState.peakEquity)) USD; nuovi ordini bloccati fino a sblocco manuale.",
            agent: .risk
        )
        NotificationManager.shared.notify(
            "STOP DRAWDOWN -10%",
            body: "Equity \(format(equity)) USD dal picco \(format(guardState.peakEquity)) USD; sblocco manuale in OPERATIVO."
        )
    }

    func refreshPortfolio() async {
        guard let credentials else { return }
        let service = AlpacaService(credentials: credentials.alpaca)
        do {
            let snapshot = try await service.account()
            account = snapshot
            checkDailyLoss(snapshot)
            updateDrawdownGuard(equity: snapshot.equityValue)
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
            openOrders = try await service.openOrders()
        } catch {
            logUnlessCancelled("Ordini aperti", error)
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
                let balance = try await kimiService.balance()
                kimiBalance = balance
                trackCredits(balance: balance)
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
            updateDrawdownGuard(equity: snapshot.equityValue)
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
            openOrders = try await service.openOrders()
        } catch {
            logUnlessCancelled("Ordini aperti", error)
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
                let balance = try await kimiService.balance()
                kimiBalance = balance
                trackCredits(balance: balance)
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

// MARK: - Modalità giornaliera (Trend + Pullback ETF)

extension QuantSwarmEngine {
    /// Aggiorna lo stato di un agente della catena (e la frase "cosa sta facendo").
    func setStage(_ id: PipelineStageID, _ state: PipelineState, _ detail: String) {
        guard let index = pipeline.firstIndex(where: { $0.id == id }) else { return }
        pipeline[index].state = state
        pipeline[index].detail = detail
        pipeline[index].updatedAt = Date()
        lastLoopBeat = Date()
        if state == .working {
            currentActivity = "\(id.title): \(detail)"
        }
    }

    /// Mette in "saltato" gli agenti successivi quando la catena si ferma prima.
    func skipStages(after id: PipelineStageID, _ detail: String) {
        guard let start = PipelineStageID.allCases.firstIndex(of: id) else { return }
        for stage in PipelineStageID.allCases.dropFirst(start + 1) {
            setStage(stage, .skipped, detail)
        }
    }

    fileprivate func startDaily(credentials: StoredCredentials, kimi: KimiService) async {
        activeMode = .daily
        configuredSymbols = DailyStrategy.basket
        acceptsNewOrders = true
        pauseReason = nil
        maxPositionsLogged = false
        creditLimitLogged = false
        drawdownLocked = guardState.drawdownLocked
        dailyStopOn = guardState.dailyStopDayUTC == Self.dayStampUTC()
        rolloverCreditGuardIfNeeded()
        kimiCallsToday = creditGuard.calls
        pipeline = PipelineStage.initial()
        dailyCandidates = []
        NotificationManager.shared.requestAuthorizationIfNeeded()
        isRunning = true
        applyIdleTimer()
        NotificationManager.shared.cancelPending(identifier: backgroundReminderIdentifier)
        sessionStartedAt = Date()
        statusMessage = "Giornaliera \(credentials.paperTrading ? "paper" : "live") attiva"
        log("════════ SESSIONE AVVIATA · ORE \(Date().formatted(date: .omitted, time: .standard)) ════════")
        log(
            "Modalità GIORNALIERA su \(DailyStrategy.basket.count) ETF: Trend (sopra SMA200) + Pullback (RSI2 < 10), "
                + "stop \(DailyStrategy.stopATR) ATR sul broker (GTC, attivo anche ad app chiusa), "
                + "uscita a chiusura > SMA5 o dopo \(DailyStrategy.maxHoldingDays) giorni. Kimi solo se c'è un segnale."
        )
        if drawdownLocked {
            log("ATTENZIONE: stop drawdown attivo da una sessione precedente; sblocco manuale in OPERATIVO.", agent: .risk)
        }
        analysisTask = Task { [weak self] in
            await self?.dailyLoop(kimi: kimi, credentials: credentials)
        }
        heartbeatTask = Task { [weak self] in
            await self?.heartbeatMonitor()
        }
    }

    /// Un ciclo completo subito, poi ogni 15 minuti finché l'app è aperta.
    /// Il battito resta vivo ogni minuto (niente falsi allarmi heartbeat).
    fileprivate func dailyLoop(kimi: KimiService, credentials: StoredCredentials) async {
        while isRunning, !Task.isCancelled {
            lastLoopBeat = Date()
            heartbeatAlerted = false
            await runDailyCycle(kimi: kimi, credentials: credentials)
            let next = Date().addingTimeInterval(15 * 60)
            nextCheckAt = next
            if isRunning {
                currentActivity = "In attesa · prossimo controllo alle \(next.formatted(date: .omitted, time: .shortened))"
            }
            while isRunning, !Task.isCancelled, Date() < next {
                lastLoopBeat = Date()
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    fileprivate func runDailyCycle(kimi: KimiService, credentials: StoredCredentials) async {
        let config = strategyConfig.sanitized
        let alpaca = AlpacaService(credentials: credentials.alpaca)
        pipeline = PipelineStage.initial()

        // 1. SCOUT: conto, posizioni, ordini, orologio, barre giornaliere.
        if let pause = computePauseReason() {
            pauseReason = pause
            setStage(.scout, .blocked, "motore in pausa: \(pause)")
            skipStages(after: .scout, "pausa")
            log("MOTORE IN PAUSA: \(pause). Nessun controllo finché non rientra.", agent: .system)
            return
        }
        pauseReason = nil
        setStage(.scout, .working, "leggo conto, posizioni e \(DailyStrategy.basket.count) ETF")
        await refreshPortfolio()
        await refreshTradeRecords()
        let clock = try? await alpaca.clock()
        if let clock { marketClock = clock }
        let marketOpen = clock?.isOpen ?? false
        var barsBySymbol: [String: [Candle]] = [:]
        var failed: [String] = []
        for symbol in DailyStrategy.basket {
            guard isRunning, !Task.isCancelled else { return }
            do {
                let bars = try await alpaca.dailyBars(symbol: symbol)
                barsBySymbol[symbol] = DailyStrategy.closedBars(bars, marketOpen: marketOpen)
            } catch is CancellationError {
                return
            } catch {
                failed.append(symbol)
            }
        }
        guard !barsBySymbol.isEmpty else {
            setStage(.scout, .failed, "nessuna barra ricevuta da Alpaca")
            skipStages(after: .scout, "dati mancanti")
            log("Scout: barre giornaliere non disponibili; ciclo annullato (nessun ordine).", agent: .scout)
            return
        }
        setStage(
            .scout, .done,
            "\(barsBySymbol.count)/\(DailyStrategy.basket.count) ETF aggiornati"
                + (failed.isEmpty ? "" : " · mancano \(failed.joined(separator: ", "))")
                + " · mercato \(marketOpen ? "aperto" : "chiuso")"
        )
        var market: [String: DailyStrategy.Snapshot] = [:]
        for symbol in ["SPY", "QQQ", "IWM", "TLT", "GLD"] {
            if let bars = barsBySymbol[symbol], let snap = DailyStrategy.snapshot(of: bars) {
                market[symbol] = snap
            }
        }

        // 2. STRATEGIA: uscite a regole, poi segnali d'ingresso. Zero crediti.
        setStage(.strategy, .working, "controllo uscite e segnali")
        let today = DailyStrategy.tradingDay(Date())
        var book = DailyBookStore.load()
        let held = Set(positions.map { $0.symbol.uppercased() })
        let entryOrders = openOrders.filter { $0.parentOrderId == nil && $0.side == "buy" }
        let pendingEntry = Set(entryOrders.map { $0.symbol.uppercased() })

        // Posizioni già chiuse dal broker (stop toccato): via dal registro.
        for (symbol, _) in book.entries where !held.contains(symbol) && !pendingEntry.contains(symbol) {
            book.entries.removeValue(forKey: symbol)
            log("\(symbol): posizione non più presente sul broker (stop eseguito o chiusa a mano); registro aggiornato.", agent: .risk)
        }
        // Ordini d'ingresso dei giorni precedenti mai eseguiti: annullati.
        for order in entryOrders where DailyStrategy.basket.contains(order.symbol.uppercased()) {
            let symbol = order.symbol.uppercased()
            guard let day = book.entries[symbol], day < today, !held.contains(symbol) else { continue }
            do {
                try await alpaca.cancelOrder(id: order.id)
                book.entries.removeValue(forKey: symbol)
                log("\(symbol): ordine d'ingresso del \(day) non eseguito; annullato.", agent: .risk)
            } catch {
                log("\(symbol): annullo ordine vecchio non riuscito: \(error.localizedDescription)", agent: .risk)
            }
        }
        // Uscite a regole (anche con stop giornaliero attivo: proteggono il capitale).
        var exited: [String] = []
        for (symbol, day) in book.entries where held.contains(symbol) {
            guard let bars = barsBySymbol[symbol],
                  let reason = DailyStrategy.exitReason(bars: bars, entryDay: day) else { continue }
            setStage(.executor, .working, "chiudo \(symbol): \(reason.rawValue)")
            let position = positions.first { $0.symbol.uppercased() == symbol }
            do {
                try await alpaca.exitPosition(symbol: symbol)
                exited.append(symbol)
                book.entries.removeValue(forKey: symbol)
                recordDailyExit(symbol: symbol, pnl: position?.unrealizedPLValue)
                log("\(symbol): USCITA — \(reason.rawValue). Stop annullato e vendita a mercato inviata.", agent: .risk)
                NotificationManager.shared.notify("USCITA \(symbol)", body: reason.rawValue)
            } catch {
                log("\(symbol): uscita non riuscita (\(error.localizedDescription)); lo stop sul broker resta la protezione.", agent: .risk)
            }
        }
        DailyBookStore.save(book)

        let candidates = DailyStrategy.basket.compactMap { symbol -> DailyStrategy.Candidate? in
            guard !held.contains(symbol), !pendingEntry.contains(symbol), !exited.contains(symbol),
                  let bars = barsBySymbol[symbol] else { return nil }
            return DailyStrategy.entryCandidate(symbol: symbol, bars: bars)
        }
        dailyCandidates = candidates
        let fresh = candidates.filter { !book.alreadyDecided($0.symbol, day: today) }
        let exitText = exited.isEmpty ? "" : " · uscite: \(exited.joined(separator: ", "))"
        guard !fresh.isEmpty else {
            let text = candidates.isEmpty
                ? "nessun segnale oggi\(exitText)"
                : "segnali già valutati oggi: \(candidates.map(\.symbol).joined(separator: ", "))\(exitText)"
            setStage(.strategy, .done, text)
            skipStages(after: .strategy, "nessun segnale nuovo · 0 crediti")
            log("Strategia: \(text). Kimi non chiamato.", agent: .scout)
            return
        }
        let list = fresh.map { "\($0.symbol) (RSI2 \(format($0.snapshot.rsi2, fractionDigits: 1)))" }.joined(separator: ", ")
        setStage(.strategy, .done, "segnali: \(list)\(exitText)")
        log("Strategia: segnali Trend+Pullback su \(list).", agent: .scout)

        // Guardrail prima di spendere crediti.
        let slots = config.maxOpenPositions - held.subtracting(exited).count - pendingEntry.count
        var blockReason: String?
        if !acceptsNewOrders { blockReason = "app in background" }
        else if drawdownLocked { blockReason = "stop drawdown attivo (sblocco manuale)" }
        else if dailyStopActive { blockReason = "stop giornaliero attivo" }
        else if creditLimitExceeded { blockReason = "limite crediti Kimi raggiunto" }
        else if slots <= 0 { blockReason = "già \(config.maxOpenPositions) posizioni/ordini aperti" }
        if let blockReason {
            setStage(.analyst, .blocked, blockReason)
            skipStages(after: .analyst, blockReason)
            log("Segnali non operati: \(blockReason).", agent: .risk)
            return
        }

        // 3. ANALYST: in giornaliera il quadro di mercato (SPY/QQQ/IWM/TLT/GLD)
        //    è calcolato in codice e passato al Brain: nessun credito extra.
        let marketText = market.keys.sorted().map { key -> String in
            let m = market[key]!
            return "\(key) \(m.close > m.sma200 ? "sopra" : "sotto") SMA200"
        }.joined(separator: " · ")
        setStage(.analyst, .done, marketText.isEmpty ? "quadro non disponibile" : marketText)

        // 4. BRAIN (Kimi): sceglie fra i candidati.
        setStage(.brain, .working, "Kimi valuta \(fresh.count) candidati, \(slots) posti liberi")
        let verdicts: [DailyVerdict]
        do {
            registerKimiCall()
            verdicts = try await kimi.dailyDecide(
                candidates: fresh,
                market: market,
                openPositions: Array(held),
                slotsAvailable: slots
            )
        } catch is CancellationError {
            return
        } catch {
            setStage(.brain, .failed, "Kimi non ha risposto: nessun ordine")
            skipStages(after: .brain, "Brain fallito")
            log("Brain Kimi fallito (\(error.localizedDescription)): nessun ordine.", agent: .brain)
            return
        }
        for candidate in fresh { book.markDecided(candidate.symbol, day: today) }
        DailyBookStore.save(book)
        for verdict in verdicts {
            let decision = KimiDecision(
                symbol: verdict.symbol.uppercased(),
                action: verdict.wantsBuy ? .buy : .hold,
                confidence: verdict.confidence,
                entryPrice: fresh.first { $0.symbol == verdict.symbol.uppercased() }?.snapshot.close ?? 0,
                stopLoss: 0,
                takeProfit: 0,
                winProbability: min(max(verdict.confidence, 0.01), 0.99),
                payoffRatio: 1,
                rationale: verdict.rationale
            )
            decisions.append(DecisionEntry(timestamp: Date(), decision: decision))
            log("\(verdict.symbol): \(verdict.wantsBuy ? "BUY" : "SKIP") \(Int(verdict.confidence * 100))% — \(verdict.rationale)", agent: .brain)
        }
        if decisions.count > 500 { decisions.removeFirst(decisions.count - 500) }
        let buys = verdicts.filter(\.wantsBuy).sorted { $0.confidence > $1.confidence }.prefix(slots)
        guard !buys.isEmpty else {
            setStage(.brain, .done, "nessun acquisto scelto")
            skipStages(after: .brain, "Brain: nessun acquisto")
            return
        }
        setStage(.brain, .done, "sceglie \(buys.map(\.symbol).joined(separator: ", "))")

        var sent: [String] = []
        for verdict in buys {
            guard isRunning, !Task.isCancelled, acceptsNewOrders else { return }
            let symbol = verdict.symbol.uppercased()
            guard let candidate = fresh.first(where: { $0.symbol == symbol }) else { continue }

            // 5. REVIEWER (Kimi): cerca motivi per bocciare.
            setStage(.reviewer, .working, "contesta \(symbol)")
            let review: KimiReview
            do {
                registerKimiCall()
                review = try await kimi.dailyReview(candidate: candidate, verdict: verdict, market: market)
            } catch is CancellationError {
                return
            } catch {
                setStage(.reviewer, .failed, "\(symbol): revisore non raggiungibile, ordine annullato")
                log("\(symbol): reviewer fallito (\(error.localizedDescription)); ordine annullato.", agent: .brain)
                continue
            }
            guard review.approved else {
                setStage(.reviewer, .done, "\(symbol) bocciato: \(review.reason)")
                log("\(symbol): REVIEWER respinge — \(review.reason)", agent: .brain)
                continue
            }
            setStage(.reviewer, .done, "\(symbol) approvato")
            log("\(symbol): reviewer approva — \(review.reason)", agent: .brain)

            // 6. RISCHIO (codice): prezzo riletto, quantità, stop.
            setStage(.risk, .working, "dimensiono \(symbol)")
            guard let price = try? await alpaca.latestTradePrice(symbol: symbol), price > 0 else {
                setStage(.risk, .failed, "\(symbol): prezzo non disponibile")
                log("\(symbol): prezzo attuale non disponibile; ordine annullato.", agent: .risk)
                continue
            }
            let snap = candidate.snapshot
            guard abs(price - snap.close) <= 3 * snap.atr14 else {
                setStage(.risk, .blocked, "\(symbol): prezzo lontano dal segnale")
                log("\(symbol): prezzo \(format(price)) a oltre 3 ATR dalla chiusura del segnale; ordine annullato.", agent: .risk)
                continue
            }
            guard let account else {
                setStage(.risk, .failed, "conto non disponibile")
                continue
            }
            let sizing: RiskRules.StopSizing
            switch RiskRules.sizeStopOnly(
                currentPrice: price,
                stopDistance: candidate.stopDistance,
                account: RiskRules.Account(
                    equity: account.equityValue,
                    cash: account.cashValue,
                    buyingPower: account.buyingPowerValue
                ),
                riskFraction: config.riskFraction,
                constraints: .alpacaStock
            ) {
            case .success(let value):
                sizing = value
            case .failure(let rejection):
                setStage(.risk, .blocked, "\(symbol): \(rejection.reason)")
                log("\(symbol): ordine bloccato dal rischio — \(rejection.reason).", agent: .risk)
                continue
            }
            setStage(
                .risk, .done,
                "\(symbol): \(Int(sizing.quantity)) az. · rischio \(format(sizing.riskAmount)) USD · stop \(format(sizing.stopPrice))"
            )

            // 7. ESECUTORE: ordine limite + stop GTC sul broker.
            setStage(.executor, .working, "invio \(symbol)")
            let clientOrderId = "qsd-\(symbol)-\(today)"
            do {
                let order: AlpacaOrder
                do {
                    order = try await alpaca.submitEntryWithStop(
                        symbol: symbol,
                        quantity: sizing.quantity,
                        limitPrice: sizing.limitPrice,
                        stopPrice: sizing.stopPrice,
                        clientOrderId: clientOrderId
                    )
                } catch {
                    // Timeout: l'ordine potrebbe essere comunque arrivato.
                    guard let existing = try? await alpaca.order(byClientOrderId: clientOrderId) else { throw error }
                    order = existing
                }
                book.entries[symbol] = today
                DailyBookStore.save(book)
                let decision = KimiDecision(
                    symbol: symbol, action: .buy, confidence: verdict.confidence,
                    entryPrice: sizing.limitPrice, stopLoss: sizing.stopPrice, takeProfit: 0,
                    winProbability: min(max(verdict.confidence, 0.01), 0.99), payoffRatio: 1,
                    rationale: verdict.rationale
                )
                try? persist(
                    receipt: ExecutionReceipt(
                        orderID: order.id, decision: decision, quantity: sizing.quantity,
                        equity: account.equityValue, measuredLatencyMilliseconds: 0
                    ),
                    atr: snap.atr14
                )
                sent.append(symbol)
                let text = "\(symbol) \(Int(sizing.quantity)) az. limite \(format(sizing.limitPrice)) · stop \(format(sizing.stopPrice)) (GTC)"
                setStage(.executor, .done, "inviato \(text)")
                log("ORDINE INVIATO: \(text)\(marketOpen ? "" : " · in coda per l'apertura").", agent: .risk)
                NotificationManager.shared.notify("ORDINE INVIATO", body: text)
            } catch {
                setStage(.executor, .failed, "\(symbol): \(error.localizedDescription)")
                log("\(symbol): invio ordine fallito: \(error.localizedDescription)", agent: .risk)
            }
        }
        if sent.isEmpty, pipeline.first(where: { $0.id == .executor })?.state == .idle {
            setStage(.executor, .skipped, "nessun ordine da inviare")
        }
        await refreshPortfolio()
    }

    /// Esito di una posizione chiusa dalla regola d'uscita: il P&L è quello
    /// non realizzato al momento della chiusura (lo stop non è stato eseguito).
    fileprivate func recordDailyExit(symbol: String, pnl: Double?) {
        var descriptor = FetchDescriptor<TradeRecord>(
            predicate: #Predicate<TradeRecord> { !$0.outcomeRecorded },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 50
        guard let records = try? modelContext.fetch(descriptor),
              let record = records.first(where: { $0.symbol.uppercased() == symbol }) else { return }
        record.netPnL = pnl ?? 0
        record.outcomeRecorded = true
        linkOutcomeToSample(record)
        try? modelContext.save()
        refreshDatasetStats()
        computeCalibration()
    }
}
