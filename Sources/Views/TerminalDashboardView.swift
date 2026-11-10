import SwiftUI

private enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
    case operations = "OPERATIVO"
    case agents = "AGENTI"
    case broker = "BROKER"
    case system = "SISTEMA"

    var id: String { rawValue }
}

private enum DashboardPalette {
    static let green = Color(red: 0.1, green: 1.0, blue: 0.55)
    static let cyan = Color(red: 0.35, green: 0.85, blue: 1.0)
}

private enum Formatters {
    static func money(_ value: Double?) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value))
            ?? String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func signedMoney(_ value: Double) -> String {
        (value >= 0 ? "+" : "-") + money(abs(value))
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), value * 100)
    }

    static func trimmed(_ raw: String) -> String {
        guard let value = Double(raw) else { return raw }
        return value == value.rounded()
            ? String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
            : String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func time(_ date: Date?) -> String {
        guard let date else { return "n/d" }
        return date.formatted(date: .omitted, time: .standard)
    }

    static func dateTime(_ date: Date?) -> String {
        guard let date else { return "n/d" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct TerminalDashboardView: View {
    @EnvironmentObject private var engine: QuantSwarmEngine
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedSection: DashboardSection = .operations
    @State private var symbols = "SPY"
    @State private var news = ""
    @State private var showKillConfirmation = false
    @State private var showLogoutConfirmation = false
    @State private var showUnlockConfirmation = false
    @State private var pulse = false

    private let terminalGreen = DashboardPalette.green

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 0) {
                    statusHeader
                    Picker("Sezione", selection: $selectedSection) {
                        ForEach(DashboardSection.allCases) { section in
                            Text(section.rawValue).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    ScrollView {
                        VStack(spacing: 14) {
                            switch selectedSection {
                            case .operations:
                                controlPanel
                                guardPanel
                                reportPanel
                                positionsPanel
                                portfolioPanel
                                kimiPanel
                                edgePanel
                                killButton
                            case .agents:
                                analysisPanel
                                decisionsPanel
                                calibrationPanel
                                metricsPanel
                                datasetPanel
                                logPanel
                            case .broker:
                                BrokerControlView()
                                ordersPanel
                                linksPanel
                            case .system:
                                SystemSettingsView()
                            }
                        }
                        .padding()
                    }
                    .refreshable {
                        await engine.refreshPortfolio()
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("QUANTSWARM · ALPHA ZERO")
                        .font(.system(.headline, design: .monospaced, weight: .black))
                        .foregroundStyle(terminalGreen)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("LOGOUT") {
                        showLogoutConfirmation = true
                    }
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(terminalGreen)
                    .disabled(engine.isKillInProgress)
                }
            }
            .alert("LOGOUT", isPresented: $showLogoutConfirmation) {
                Button("ANNULLA", role: .cancel) {}
                Button("DISCONNETTI", role: .destructive) {
                    Task { await engine.logout() }
                }
            } message: {
                Text("Ferma il motore, elimina le credenziali dal Keychain e richiede un nuovo inserimento con Face ID. Le posizioni aperte restano invariate sul broker.")
            }
            .alert("HARD KILL SWITCH", isPresented: $showKillConfirmation) {
                Button("ANNULLA", role: .cancel) {}
                Button("LIQUIDA TUTTO", role: .destructive) {
                    Task { await engine.hardKill() }
                }
            } message: {
                Text("Ferma il motore, cancella tutti gli ordini e richiede ad Alpaca la chiusura a mercato di tutte le posizioni del conto configurato.")
            }
            .alert("SBLOCCO DRAWDOWN", isPresented: $showUnlockConfirmation) {
                Button("ANNULLA", role: .cancel) {}
                Button("SBLOCCA", role: .destructive) {
                    engine.unlockDrawdown()
                }
            } message: {
                Text("Riattiva i nuovi ordini e riallinea il picco di equity all'equity corrente. Fallo solo dopo aver capito la causa del drawdown.")
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    // Snapshot su disco solo a motore attivo: se l'utente ha già
                    // premuto STOP il report esiste con il motivo corretto e non
                    // va sovrascritto con un generico "app chiusa".
                    if engine.isRunning {
                        engine.exportSessionReport(
                            reason: "App chiusa con motore ancora attivo (snapshot)"
                        )
                    }
                    engine.handleEnteredBackground()
                case .active:
                    Task { await engine.handleEnteredForeground() }
                default:
                    break
                }
            }
            .onAppear {
                if let saved = UserDefaults.standard.string(forKey: "com.quantswarm.alphazero.lastSymbols"),
                   !saved.isEmpty {
                    symbols = saved
                }
                news = UserDefaults.standard.string(forKey: "com.quantswarm.alphazero.lastNews") ?? ""
            }
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(engine.isRunning ? terminalGreen : .gray)
                .frame(width: 10, height: 10)
                .opacity(engine.isRunning ? (pulse ? 1.0 : 0.35) : 1.0)
                .animation(
                    engine.isRunning
                        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )
                .onAppear { pulse = true }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(engine.paperTrading ? "PAPER" : "LIVE")
                        .font(.system(.caption2, design: .monospaced, weight: .black))
                        .foregroundStyle(engine.paperTrading ? terminalGreen : .red)
                    if engine.isRunning {
                        Text("MOTORE ATTIVO")
                            .font(.system(.caption2, design: .monospaced, weight: .black))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(terminalGreen)
                    }
                    if let clock = engine.marketClock {
                        Text(clock.isOpen ? "MERCATO APERTO" : "MERCATO CHIUSO")
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(clock.isOpen ? terminalGreen : .orange)
                    }
                    if engine.isRunning, let beat = engine.lastLoopBeat {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let lag = max(0, Int(context.date.timeIntervalSince(beat)))
                            Text("HB \(lag)s")
                                .font(.system(.caption2, design: .monospaced, weight: .bold))
                                .foregroundStyle(lag > 120 ? .red : .gray)
                        }
                    }
                }
                if let pause = engine.pauseReason {
                    Text("PAUSA · \(pause)")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.orange)
                }
                Text(engine.statusMessage)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.gray)
                    .lineLimit(2)
            }
            Spacer()
            if let account = engine.account {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Formatters.money(account.equityValue))
                        .font(.system(.callout, design: .monospaced, weight: .black))
                        .foregroundStyle(.white)
                    if let dayPnL = account.dayPnL {
                        Text(Formatters.signedMoney(dayPnL))
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(dayPnL >= 0 ? terminalGreen : .red)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(white: 0.05))
    }

    private func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, rest)
    }

    private var edgePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("EDGE · EQUITY DELTA USD", color: terminalGreen)
            EdgeChart(points: engine.edgeHistory, color: terminalGreen)
                .frame(height: 170)
        }
        .panelStyle(terminalGreen)
    }

    /// Banner protezioni: appare solo quando un circuit breaker è scattato.
    /// Lo stop giornaliero si riapre da solo a mezzanotte UTC; il drawdown
    /// richiede sempre lo sblocco manuale con conferma.
    private var guardPanel: some View {
        Group {
            if engine.dailyStopOn || engine.drawdownLocked {
                VStack(alignment: .leading, spacing: 10) {
                    panelHeader("PROTEZIONI ATTIVE", color: .red)
                    if engine.dailyStopOn {
                        Text("STOP GIORNALIERO: perdita oltre la soglia impostata. Nuovi segnali sospesi fino alla mezzanotte UTC; le posizioni restano protette dalle gambe stop/target sul broker.")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if engine.drawdownLocked {
                        Text("STOP DRAWDOWN: equity oltre il -10% dal picco. Nessun nuovo ordine finché non sblocchi manualmente.")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                        Button("SBLOCCA DRAWDOWN") {
                            showUnlockConfirmation = true
                        }
                        .buttonStyle(TerminalButtonStyle(color: .red))
                    }
                }
                .panelStyle(.red)
            }
        }
    }

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelHeader("CONTROLLO SESSIONE", color: terminalGreen)
            Text("SYMBOLS · COMMA SEPARATED")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.gray)
            TextField("SPY,QQQ", text: $symbols)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(10)
                .background(Color(white: 0.08))
                .disabled(engine.isRunning)

            Text("NEWS / SENTIMENT INPUT")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.gray)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $news)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color(white: 0.08))
                    .frame(height: 78)
                    .disabled(engine.isRunning)
                if news.isEmpty {
                    Text("Incolla notizie con data e fonte; nessun feed news automatico.")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.gray)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 12) {
                Button("START") {
                    Task { await engine.start(symbolsText: symbols, news: news) }
                }
                .buttonStyle(TerminalButtonStyle(color: terminalGreen))
                .disabled(engine.isRunning || engine.isKillInProgress)

                Button("STOP") {
                    Task { await engine.stop() }
                }
                .buttonStyle(TerminalButtonStyle(color: .orange))
                .disabled(!engine.isRunning || engine.isKillInProgress)
            }
            if engine.isRunning, let startedAt = engine.sessionStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(
                        "AVVIATA \(Formatters.time(startedAt)) · ATTIVA DA \(elapsed(from: startedAt, to: context.date))"
                    )
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(terminalGreen)
                }
            }
        }
        .panelStyle(terminalGreen)
    }

    /// Pannello report di sessione: appare solo quando esiste un file .txt
    /// pronto (STOP, HARD KILL o chiusura app). ESPORTA apre il menu di
    /// condivisione iOS; ELIMINA cancella il file dopo l'invio.
    private var reportPanel: some View {
        Group {
            if let url = engine.sessionReportURL {
                VStack(alignment: .leading, spacing: 10) {
                    panelHeader("REPORT SESSIONE · TXT", color: terminalGreen)
                    Text(url.lastPathComponent)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.gray)
                    HStack(spacing: 12) {
                        ShareLink(item: url) {
                            Text("ESPORTA / INVIA")
                                .font(.system(.body, design: .monospaced, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(terminalGreen.opacity(0.18))
                                .foregroundStyle(terminalGreen)
                                .overlay(Rectangle().stroke(terminalGreen, lineWidth: 1))
                        }
                        Button("ELIMINA") {
                            engine.deleteSessionReport()
                        }
                        .buttonStyle(TerminalButtonStyle(color: .red))
                    }
                }
                .panelStyle(terminalGreen)
            }
        }
    }

    private var portfolioPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                panelHeader("PORTAFOGLIO · USD", color: terminalGreen)
                Spacer()
                Button("AGGIORNA") {
                    Task { await engine.refreshPortfolio() }
                }
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(terminalGreen)
                .disabled(engine.isKillInProgress)
            }
            if let account = engine.account {
                portfolioRow("EQUITY", Formatters.money(account.equityValue), color: .white)
                portfolioRow("CASH", Formatters.money(account.cashValue), color: .white)
                portfolioRow("BUYING POWER", Formatters.money(account.buyingPowerValue), color: .white)
                if let dayPnL = account.dayPnL {
                    portfolioRow(
                        "P&L OGGI",
                        Formatters.signedMoney(dayPnL),
                        color: dayPnL >= 0 ? terminalGreen : .red
                    )
                }
            } else {
                Text("Nessun dato: tocca AGGIORNA per leggere il conto.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.gray)
            }
        }
        .panelStyle(terminalGreen)
        .task {
            await engine.refreshPortfolio()
        }
    }

    private func portfolioRow(_ label: String, _ value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.gray)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(color)
        }
    }

    /// Crediti Kimi: saldo reale, chiamate del giorno e spesa misurata dal
    /// saldo (baseline UTC − saldo attuale). Se il limite impostato in
    /// SISTEMA viene raggiunto, Kimi si ferma fino a mezzanotte UTC.
    private var kimiPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("KIMI ACCOUNT · CREDITI USD", color: DashboardPalette.cyan)
            if let balance = engine.kimiBalance {
                portfolioRow("DISPONIBILE", Formatters.money(balance.availableBalance), color: .white)
                portfolioRow("VOUCHER", Formatters.money(balance.voucherBalance), color: .white)
                portfolioRow(
                    "CASH",
                    Formatters.money(balance.cashBalance),
                    color: (balance.cashBalance ?? 0) < 0 ? .red : .white
                )
            } else {
                Text("Saldo non ancora letto: tocca AGGIORNA nel pannello portafoglio.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.gray)
            }
            portfolioRow("CHIAMATE OGGI", "\(engine.kimiCallsToday)", color: .white)
            portfolioRow(
                "SPESI OGGI (DA SALDO)",
                engine.creditsSpentToday.map { Formatters.money($0) } ?? "—",
                color: .white
            )
            if engine.strategyConfig.creditLimitEnabled {
                portfolioRow(
                    "LIMITE GIORNALIERO",
                    Formatters.money(engine.strategyConfig.dailyCreditLimitUSD),
                    color: engine.creditLimitHit ? .red : .gray
                )
            }
            if engine.creditLimitHit {
                Text("LIMITE RAGGIUNTO: Kimi fermo fino a mezzanotte UTC. Le posizioni restano protette dal broker.")
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panelStyle(DashboardPalette.cyan)
    }

    /// Kimi Analyst: lettura qualitativa del mercato con cadenza configurabile
    /// (solo con dati freschi), oppure su richiesta con ANALIZZA ORA.
    private var analysisPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                panelHeader("KIMI ANALYST · LETTURA MERCATO", color: DashboardPalette.cyan)
                Spacer()
                Button("ANALIZZA ORA") {
                    Task { await engine.requestAnalysisNow() }
                }
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(DashboardPalette.cyan)
                .disabled(engine.isKillInProgress)
            }
            if let entry = engine.latestAnalysis {
                HStack(spacing: 6) {
                    analysisChip(
                        entry.analysis.regime.replacingOccurrences(of: "_", with: " ").uppercased(),
                        color: DashboardPalette.cyan
                    )
                    analysisChip("VOL \(entry.analysis.volatility.uppercased())", color: .orange)
                    analysisChip(
                        entry.analysis.bias.uppercased(),
                        color: entry.analysis.bias == "ribassista" ? .red : terminalGreen
                    )
                    Spacer()
                    Text("\(Int(entry.analysis.confidence * 100))%")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(DashboardPalette.cyan)
                }
                Text(entry.analysis.comment)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(Formatters.time(entry.timestamp)) · prima di ogni decisione → Brain e Reviewer")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.gray)
            } else {
                Text("Nessuna analisi ancora: l'Analyst parte quando il filtro trova un segnale, prima della decisione, e la sua lettura arriva a Brain e Reviewer. Puoi forzarla con ANALIZZA ORA.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panelStyle(DashboardPalette.cyan)
    }

    private func analysisChip(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(.caption2, design: .monospaced, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(Rectangle().stroke(color.opacity(0.6), lineWidth: 1))
    }

    /// Dataset di training: ogni decisione di Kimi (anche gli HOLD) viene
    /// salvata in SwiftData con prezzo, ATR, livelli ed esito misurato.
    private var datasetPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHeader("TRAINING KIMI · DATASET", color: DashboardPalette.cyan)
            portfolioRow("CAMPIONI RACCOLTI", "\(engine.datasetStats.total)", color: .white)
            portfolioRow("CON ESITO VALUTATO", "\(engine.datasetStats.completed)", color: .white)
            Button("ESPORTA DATASET JSONL") {
                engine.exportTrainingDataset()
            }
            .buttonStyle(TerminalButtonStyle(color: DashboardPalette.cyan))
            .disabled(engine.datasetStats.total == 0)
            if let url = engine.datasetExportURL {
                Text(url.lastPathComponent)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.gray)
                HStack(spacing: 12) {
                    ShareLink(item: url) {
                        Text("INVIA")
                            .font(.system(.body, design: .monospaced, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(DashboardPalette.cyan.opacity(0.18))
                            .foregroundStyle(DashboardPalette.cyan)
                            .overlay(Rectangle().stroke(DashboardPalette.cyan, lineWidth: 1))
                    }
                    Button("ELIMINA") {
                        engine.deleteDatasetExport()
                    }
                    .buttonStyle(TerminalButtonStyle(color: .red))
                }
            }
            Text("Ogni decisione (anche gli HOLD) è registrata con prezzo, ATR, livelli ed esito: win/loss per i trade eseguiti, movimento del prezzo a 30 min per gli HOLD.")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.gray)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panelStyle(DashboardPalette.cyan)
    }

    private func panelHeader(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(color)
        }
    }

    private var positionsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("POSIZIONI APERTE", color: terminalGreen)
            if engine.positions.isEmpty {
                Text("Nessuna posizione aperta.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.gray)
            } else {
                ForEach(engine.positions) { position in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(position.symbol)
                                .font(.system(.caption, design: .monospaced, weight: .bold))
                                .foregroundStyle(.white)
                            Text((position.side ?? "long").uppercased())
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(position.side == "short" ? .red : terminalGreen)
                            Spacer()
                            Text("qty \(Formatters.trimmed(position.quantity))")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.gray)
                        }
                        HStack {
                            Text(
                                "entry \(Formatters.money(position.averageEntryPriceValue)) → ora \(Formatters.money(position.currentPriceValue))"
                            )
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.gray)
                            Spacer()
                            Text(Formatters.signedMoney(position.unrealizedPLValue))
                                .font(.system(.caption, design: .monospaced, weight: .bold))
                                .foregroundStyle(position.unrealizedPLValue >= 0 ? terminalGreen : .red)
                        }
                    }
                    .padding(8)
                    .background(Color(white: 0.04))
                    .overlay(Rectangle().stroke(terminalGreen.opacity(0.2), lineWidth: 1))
                }
            }
        }
        .panelStyle(terminalGreen)
    }

    private var decisionsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("KIMI BRAIN · ULTIME DECISIONI", color: DashboardPalette.cyan)
            if engine.decisions.isEmpty {
                Text("Nessuna decisione ancora: servono 14 barre e motore avviato.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.gray)
            } else {
                ForEach(engine.decisions.suffix(5).reversed()) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(Formatters.time(entry.timestamp))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.gray)
                            Text(entry.decision.symbol)
                                .font(.system(.caption, design: .monospaced, weight: .bold))
                                .foregroundStyle(.white)
                            Text(entry.decision.action.rawValue.uppercased())
                                .font(.system(.caption, design: .monospaced, weight: .bold))
                                .foregroundStyle(actionColor(entry.decision.action))
                            Spacer()
                            Text("\(Int(entry.decision.confidence * 100))%")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(DashboardPalette.cyan)
                        }
                        Text(entry.decision.rationale)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                        if entry.decision.action != .hold {
                            Text(
                                "entry \(Formatters.money(entry.decision.entryPrice)) · stop \(Formatters.money(entry.decision.stopLoss)) · target \(Formatters.money(entry.decision.takeProfit))"
                            )
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.gray)
                        }
                    }
                    .padding(8)
                    .background(Color(white: 0.04))
                    .overlay(Rectangle().stroke(DashboardPalette.cyan.opacity(0.25), lineWidth: 1))
                }
            }
        }
        .panelStyle(DashboardPalette.cyan)
    }

    private var calibrationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("CALIBRAZIONE KIMI · AFFIDABILITÀ", color: DashboardPalette.cyan)
            if let calibration = engine.calibration {
                portfolioRow("TRADE MISURATI", "\(calibration.samples)", color: .white)
                portfolioRow(
                    "BRIER SCORE",
                    String(
                        format: "%.3f",
                        locale: Locale(identifier: "en_US_POSIX"),
                        calibration.brierScore
                    ),
                    color: calibration.brierScore < 0.25 ? terminalGreen : .orange
                )
                ForEach(calibration.buckets) { bucket in
                    portfolioRow(
                        bucket.label,
                        "WIN \(Int(bucket.winRate * 100))% · n=\(bucket.trades)",
                        color: .white
                    )
                }
            } else {
                Text("Nessun trade completato con esito: la calibrazione apparirà dopo i primi bracket chiusi.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.gray)
            }
        }
        .panelStyle(DashboardPalette.cyan)
    }

    private var metricsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("METRICHE PERFORMANCE", color: terminalGreen)
            if let stats = engine.performanceStats {
                portfolioRow("TRADE CHIUSI", "\(stats.completedTrades)", color: .white)
                portfolioRow(
                    "WIN RATE",
                    Formatters.percent(stats.winRate),
                    color: (stats.winRate ?? 0) >= 0.5 ? terminalGreen : .orange
                )
                let factorText = stats.profitFactor.map {
                    String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), $0)
                } ?? "∞"
                portfolioRow(
                    "PROFIT FACTOR",
                    factorText,
                    color: (stats.profitFactor ?? .infinity) >= 1 ? terminalGreen : .red
                )
                portfolioRow(
                    "EXPECTANCY / TRADE",
                    Formatters.signedMoney(stats.expectancy ?? 0),
                    color: (stats.expectancy ?? 0) >= 0 ? terminalGreen : .red
                )
                portfolioRow(
                    "MAX DRAWDOWN",
                    Formatters.money(stats.maxDrawdown),
                    color: .red
                )
            } else {
                Text("Nessun trade chiuso: le metriche appariranno dopo i primi esiti registrati.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.gray)
            }
        }
        .panelStyle(terminalGreen)
    }

    private var ordersPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("ORDINI RECENTI", color: terminalGreen)
            if engine.recentOrders.isEmpty {
                Text("Nessun ordine inviato in questa sessione di conto.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.gray)
            } else {
                ForEach(engine.recentOrders.prefix(8)) { order in
                    HStack(spacing: 6) {
                        Text(Formatters.time(order.submittedDate))
                            .foregroundStyle(.gray)
                        Text(order.side.uppercased())
                            .foregroundStyle(order.side == "buy" ? terminalGreen : .red)
                        Text("\(order.symbol) x\(Formatters.trimmed(order.filledQuantity ?? order.quantity ?? "0"))")
                            .foregroundStyle(.white)
                        Spacer()
                        if let price = order.filledAveragePriceValue {
                            Text("@ \(Formatters.money(price))")
                                .foregroundStyle(.gray)
                        }
                        Text(order.status.uppercased())
                            .foregroundStyle(statusColor(order.status))
                    }
                    .font(.system(.caption2, design: .monospaced))
                }
            }
        }
        .panelStyle(terminalGreen)
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("AGENT SWARM FEED", color: terminalGreen)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(engine.logs) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                Text(Formatters.time(entry.timestamp))
                                    .foregroundStyle(.gray)
                                Text(entry.agent.rawValue)
                                    .foregroundStyle(agentColor(entry.agent))
                                    .frame(width: 44, alignment: .leading)
                                Text(entry.message)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(.caption2, design: .monospaced))
                            .id(entry.id)
                        }
                    }
                }
                .frame(height: 280)
                .onChange(of: engine.logs.count) { _, _ in
                    if let id = engine.logs.last?.id {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
        }
        .panelStyle(terminalGreen)
    }

    private var linksPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("LINK RAPIDI", color: terminalGreen)
            Link(destination: URL(string: "https://app.alpaca.markets")!) {
                linkRow("ALPACA DASHBOARD · ordini e posizioni", color: terminalGreen)
            }
            Link(destination: URL(string: "https://platform.kimi.ai")!) {
                linkRow("KIMI CONSOLE · crediti e API key", color: DashboardPalette.cyan)
            }
        }
        .panelStyle(terminalGreen)
    }

    private func linkRow(_ title: String, color: Color) -> some View {
        HStack {
            Text(title)
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(color)
            Spacer()
            Text("↗ SAFARI")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.gray)
        }
        .padding(10)
        .background(Color(white: 0.04))
        .overlay(Rectangle().stroke(color.opacity(0.35), lineWidth: 1))
    }

    private func agentColor(_ agent: AgentKind) -> Color {
        switch agent {
        case .scout: return terminalGreen
        case .brain: return DashboardPalette.cyan
        case .risk: return .orange
        case .system: return .gray
        }
    }

    private func actionColor(_ action: TradeAction) -> Color {
        switch action {
        case .buy: return terminalGreen
        case .sell: return .red
        case .hold: return .gray
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "filled": return terminalGreen
        case "canceled", "expired", "rejected": return .gray
        default: return .orange
        }
    }

    private var killButton: some View {
        Button {
            showKillConfirmation = true
        } label: {
            Text("HARD KILL SWITCH")
                .font(.system(.headline, design: .monospaced, weight: .black))
                .frame(maxWidth: .infinity)
                .padding()
                .background(engine.isKillInProgress ? Color.gray : Color.red)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .disabled(engine.isKillInProgress)
        .accessibilityHint("Richiede conferma prima di liquidare tutte le posizioni")
    }
}

/// Controllo manuale del broker: ordini aperti cancellabili e posizioni
/// chiudibili a mercato, con refresh immediato dopo ogni azione.
private struct BrokerControlView: View {
    @EnvironmentObject private var engine: QuantSwarmEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                panelHeader("CONTROLLO BROKER · ALPACA", color: DashboardPalette.green)
                Spacer()
                Button("REFRESH") {
                    Task { await engine.refreshPortfolio() }
                }
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(DashboardPalette.green)
            }

            Text("ORDINI APERTI: \(engine.openOrders.count)")
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(.gray)
            if engine.openOrders.isEmpty {
                Text("Nessun ordine aperto.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.gray)
            } else {
                ForEach(engine.openOrders) { order in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(order.side.uppercased()) \(order.symbol) x\(Formatters.trimmed(order.quantity ?? "0"))")
                                .font(.system(.caption, design: .monospaced, weight: .bold))
                                .foregroundStyle(.white)
                            Text("\(order.status.uppercased()) · \(Formatters.time(order.submittedDate))")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.gray)
                        }
                        Spacer()
                        Button("ANNULLA") {
                            Task { await engine.cancelOrder(id: order.id) }
                        }
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.red)
                        .disabled(engine.isKillInProgress)
                    }
                    .padding(8)
                    .background(Color(white: 0.04))
                    .overlay(Rectangle().stroke(Color.orange.opacity(0.35), lineWidth: 1))
                }
            }

            Text("POSIZIONI: \(engine.positions.count)")
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(.gray)
            if engine.positions.isEmpty {
                Text("Nessuna posizione.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.gray)
            } else {
                ForEach(engine.positions) { position in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(position.symbol) · qty \(Formatters.trimmed(position.quantity))")
                                .font(.system(.caption, design: .monospaced, weight: .bold))
                                .foregroundStyle(.white)
                            Text("P&L \(Formatters.signedMoney(position.unrealizedPLValue)) USD")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(position.unrealizedPLValue >= 0 ? DashboardPalette.green : .red)
                        }
                        Spacer()
                        Button("CHIUDI") {
                            Task { await engine.closePosition(symbol: position.symbol) }
                        }
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.red)
                        .disabled(engine.isKillInProgress)
                    }
                    .padding(8)
                    .background(Color(white: 0.04))
                    .overlay(Rectangle().stroke(Color.red.opacity(0.3), lineWidth: 1))
                }
            }
            Text("CHIUDI chiede ad Alpaca una chiusura a mercato della singola posizione; ANNULLA cancella il singolo ordine aperto. Per emergenza globale usa HARD KILL in OPERATIVO.")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.gray)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panelStyle(DashboardPalette.green)
    }

    private func panelHeader(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(color)
        }
    }
}

/// Impostazioni vere: persistite in UserDefaults e lette dal motore a ogni
/// ciclo. Il modello Kimi può essere scritto a mano o scelto dalla lista API.
private struct SystemSettingsView: View {
    @EnvironmentObject private var engine: QuantSwarmEngine
    @State private var draft = StrategyConfig()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                panelHeader("CONFIG SISTEMA · LIVE", color: DashboardPalette.green)
                Spacer()
                Button("CARICA MODELLI") {
                    Task { await engine.loadAvailableKimiModels() }
                }
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(DashboardPalette.cyan)
            }

            Group {
                Stepper(
                    "Rischio per trade: \(String(format: "%.2f", draft.riskPerTradePercent))% equity",
                    value: $draft.riskPerTradePercent,
                    in: 0.25...2.0,
                    step: 0.25
                )
                Stepper("Max posizioni aperte: \(draft.maxOpenPositions)", value: $draft.maxOpenPositions, in: 1...3)
                Stepper(
                    "Stop giornaliero: \(String(format: "%.1f", draft.dailyStopPercent))% equity",
                    value: $draft.dailyStopPercent,
                    in: 0.5...5.0,
                    step: 0.5
                )
                Stepper("Ciclo decisioni: \(draft.decisionIntervalSeconds)s", value: $draft.decisionIntervalSeconds, in: 30...120, step: 5)
                Stepper(
                    "Validità analisi Analyst: \(String(format: "%.1f", draft.analysisIntervalMinutes)) min",
                    value: $draft.analysisIntervalMinutes,
                    in: 2...15,
                    step: 1
                )
            }
            .font(.system(.caption, design: .monospaced, weight: .bold))
            .foregroundStyle(.white)

            Text("KIMI DECIDE ALLA CHIUSURA DELLA CANDELA")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.gray)
            Picker("Timeframe decisione", selection: $draft.decisionTimeframeMinutes) {
                Text("1 min").tag(1)
                Text("5 min").tag(5)
                Text("15 min").tag(15)
            }
            .pickerStyle(.segmented)

            Toggle("FILTRO GRATUITO PRE-KIMI", isOn: $draft.kimiFilterEnabled)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .tint(DashboardPalette.green)
            Text("Kimi viene chiamato solo se scatta un trigger in codice: incrocio EMA 12/26, rottura massimo/minimo a 20 candele o RSI estremo. Nessun trigger = zero crediti spesi.")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.gray)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("LIMITE CREDITI GIORNALIERO", isOn: $draft.creditLimitEnabled)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .tint(DashboardPalette.green)
            Stepper(
                "Limite spesa: \(String(format: "%.2f", draft.dailyCreditLimitUSD)) USD/giorno",
                value: $draft.dailyCreditLimitUSD,
                in: 0.10...50.0,
                step: 0.10
            )
            .font(.system(.caption, design: .monospaced, weight: .bold))
            .foregroundStyle(.white)
            .disabled(!draft.creditLimitEnabled)

            Text("MODELLO KIMI")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.gray)
            TextField("kimi-k3.1-pro-highspeed", text: $draft.kimiModel)
                .font(.system(.caption, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(Color(white: 0.08))
            if !engine.availableKimiModels.isEmpty {
                Picker("Modelli disponibili", selection: $draft.kimiModel) {
                    if !engine.availableKimiModels.contains(draft.kimiModel) {
                        Text(draft.kimiModel).tag(draft.kimiModel)
                    }
                    ForEach(engine.availableKimiModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(.caption, design: .monospaced))
            }
            if let error = engine.modelListError {
                Text(error)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.red)
            }

            Toggle("RIPRENDI SESSIONE AL RIAVVIO", isOn: $draft.autoResumeOnLaunch)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .tint(DashboardPalette.green)

            Button("APPLICA IMPOSTAZIONI") {
                engine.updateStrategyConfig(draft)
            }
            .buttonStyle(TerminalButtonStyle(color: DashboardPalette.green))

            VStack(alignment: .leading, spacing: 6) {
                settingRow("STATO APPLICATO", "rischio \(String(format: "%.2f", engine.strategyConfig.riskPerTradePercent))% · max \(engine.strategyConfig.maxOpenPositions) · stop \(String(format: "%.1f", engine.strategyConfig.dailyStopPercent))%")
                settingRow("DECISIONI KIMI", "chiusura candela \(engine.strategyConfig.decisionTimeframeMinutes)m · filtro \(engine.strategyConfig.kimiFilterEnabled ? "ON" : "OFF")")
                settingRow("MODELLO ATTIVO", engine.strategyConfig.kimiModel)
                settingRow("STREAM DATI", SystemLimits.marketStreamHost)
                settingRow("GUARD CHIUSURA", "no nuovi trade negli ultimi 15 min")
                settingRow("FLAT BY CLOSE", "chiusura totale a T-10 min")
                settingRow("FOREGROUND", "motore solo ad app aperta: in background nessun ordine, rientro con riconciliazione")
                settingRow("PAUSE AUTOMATICHE", "rete assente o batteria < 20%")
            }
            Text("Verità tecnica: nessuna app iOS può garantire un WebSocket attivo 24/7 se chiusa o sospesa. Il motore gira solo in foreground con schermo tenuto acceso e indicatore MOTORE ATTIVO; in background le posizioni restano protette dalle gambe stop/target sul broker. Per operatività 24/7 reale serve un servizio server-side.")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.gray)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panelStyle(DashboardPalette.green)
        .onAppear {
            draft = engine.strategyConfig
        }
        .onChange(of: engine.strategyConfig) { _, newValue in
            draft = newValue
        }
    }

    private func panelHeader(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(color)
        }
    }

    private func settingRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.gray)
            Spacer()
            Text(value)
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
        }
        .font(.system(.caption2, design: .monospaced))
    }
}

private struct EdgeChart: View {
    let points: [EdgePoint]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let gridPath = Path { path in
                for index in 0...4 {
                    let y = size.height * Double(index) / 4
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
            context.stroke(gridPath, with: .color(.gray.opacity(0.25)), lineWidth: 0.5)

            guard !points.isEmpty else {
                context.draw(
                    Text("ATTESA DATI EQUITY").font(.system(.caption, design: .monospaced)),
                    at: CGPoint(x: size.width / 2, y: size.height / 2)
                )
                return
            }

            let values = points.map(\.value)
            let minimum = min(values.min() ?? 0, 0)
            let maximum = max(values.max() ?? 0, 0)
            let span = max(maximum - minimum, 0.000_001)
            let line = Path { path in
                for (index, point) in points.enumerated() {
                    let x = points.count == 1
                        ? size.width / 2
                        : size.width * Double(index) / Double(points.count - 1)
                    let y = size.height - ((point.value - minimum) / span) * size.height
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
        .background(Color(white: 0.04))
        .overlay(Rectangle().stroke(color.opacity(0.4), lineWidth: 1))
    }
}

private struct TerminalButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .monospaced, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding()
            .background(color.opacity(configuration.isPressed ? 0.35 : 0.18))
            .foregroundStyle(color)
            .overlay(Rectangle().stroke(color, lineWidth: 1))
    }
}

private extension View {
    func panelStyle(_ color: Color) -> some View {
        padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.06))
            .overlay(Rectangle().stroke(color.opacity(0.35), lineWidth: 1))
    }
}
