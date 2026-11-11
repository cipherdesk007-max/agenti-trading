import SwiftUI

private enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
    case operations = "CRUSCOTTO"
    case markets = "MERCATI"
    case agents = "DETTAGLI"
    case broker = "BROKER"
    case system = "SISTEMA"

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .operations: return "gauge.with.dots.needle.67percent"
        case .markets: return "chart.bar.xaxis"
        case .agents: return "list.bullet.rectangle.portrait"
        case .broker: return "building.columns"
        case .system: return "gearshape"
        }
    }
}

private enum DashboardPalette {
    static let green = Theme.green
    static let cyan = Theme.cyan
}

private enum Formatters {
    /// NASCONDI SALDO: saldi e guadagni diventano "•••••" (i prezzi no).
    /// Aggiornato a ogni disegno del cruscotto dall'impostazione salvata.
    nonisolated(unsafe) static var hidden = false

    static func sync(_ hide: Bool) -> Bool {
        hidden = hide
        return hide
    }

    /// Saldo o guadagno: nascosto se NASCONDI SALDO è attivo.
    static func amount(_ value: Double?) -> String { hidden ? "•••••" : money(value) }
    static func signedAmount(_ value: Double) -> String { hidden ? "•••••" : signedMoney(value) }

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
    @State private var selectedSection: DashboardSection = Self.initialSection

    private static var initialSection: DashboardSection {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-QSTab"), index + 1 < args.count,
           let section = DashboardSection.allCases.first(where: { $0.rawValue == args[index + 1] }) {
            return section
        }
        #endif
        return .operations
    }
    @State private var symbols = "SPY"
    @State private var news = ""
    @State private var showKillConfirmation = false
    @State private var showLogoutConfirmation = false
    @State private var showUnlockConfirmation = false
    @State private var showLiveStartConfirmation = false
    @State private var pulse = false

    private let terminalGreen = DashboardPalette.green

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    statusHeader
                    ScrollView {
                        VStack(spacing: 14) {
                            switch selectedSection {
                            case .operations:
                                if let update = engine.availableUpdate { updateBanner(update) }
                                if !engine.paperTrading { liveBanner }
                                guardPanel
                                heroPanel
                                todayPanel
                                pipelinePanel
                                positionsPanel
                                recentLogPanel
                                reportPanel
                                killButton
                            case .markets:
                                MarketsPanel()
                                if !engine.strategyConfig.proMode { marketsLegend }
                            case .agents:
                                capitalPanel
                                decisionsPanel
                                shadowPanel
                                // Pannelli della sola modalità veloce (stream 1m,
                                // analisi a richiesta, dataset): in giornaliera non servono.
                                if displayedMode == .intraday { analysisPanel }
                                portfolioPanel
                                kimiPanel
                                if displayedMode == .intraday {
                                    edgePanel
                                    calibrationPanel
                                }
                                metricsPanel
                                if displayedMode == .intraday { datasetPanel }
                                exportPanel
                                logPanel
                            case .broker:
                                BrokerControlView()
                                ordersPanel
                                linksPanel
                            case .system:
                                AccountsView()
                                SystemSettingsView()
                            }
                        }
                        .padding()
                        .animation(.snappy(duration: 0.25), value: selectedSection)
                    }
                    .scrollIndicators(.hidden)
                    .refreshable {
                        await engine.refreshPortfolio()
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
            .environment(\.proMode, engine.strategyConfig.proMode)
            .sensoryFeedback(.selection, trigger: selectedSection)
            .sensoryFeedback(.success, trigger: engine.isRunning)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Text("QUANTSWARM")
                            .font(.system(.subheadline, design: .monospaced, weight: .black))
                            .foregroundStyle(terminalGreen)
                        Text("ALPHA ZERO")
                            .font(.system(.subheadline, design: .monospaced, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showLogoutConfirmation = true
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityLabel("LOGOUT")
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

    /// Intestazione: patrimonio e risultato del giorno in grande, poi lo stato
    /// del motore in una riga. Tutto ciò che conta, senza aprire niente.
    private var statusHeader: some View {
        let hidden = Formatters.sync(engine.strategyConfig.hideAmounts)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.account.map { Formatters.amount($0.equityValue) + " $" } ?? "— $")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                    if let account = engine.account, let dayPnL = account.dayPnL {
                        let base = account.lastEquityValue ?? account.equityValue
                        Text(Formatters.signedAmount(dayPnL) + " $ oggi" + (base > 0 ? String(format: " · %+.2f%%", dayPnL / base * 100) : ""))
                            .font(.system(.footnote, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.signed(dayPnL))
                    }
                }
                Button {
                    var config = engine.strategyConfig
                    config.hideAmounts.toggle()
                    engine.updateStrategyConfig(config)
                } label: {
                    Image(systemName: hidden ? "eye.slash" : "eye")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hidden ? "Mostra saldo" : "Nascondi saldo")
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(engine.paperTrading ? "PAPER" : "LIVE")
                        .themedChip(engine.paperTrading ? Theme.green : Theme.red, filled: !engine.paperTrading)
                    if let clock = engine.marketClock {
                        Text(clock.isOpen ? "MERCATO APERTO" : "MERCATO CHIUSO")
                            .themedChip(clock.isOpen ? Theme.green : Theme.amber)
                    }
                }
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(engine.isRunning ? terminalGreen : Theme.textTertiary)
                    .frame(width: 8, height: 8)
                    .opacity(engine.isRunning ? (pulse ? 1.0 : 0.35) : 1.0)
                    .animation(
                        engine.isRunning
                            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                            : .default,
                        value: pulse
                    )
                    .onAppear { pulse = true }
                Text(engine.isRunning ? "Motore attivo · \(displayedMode.label.lowercased())" : "Motore fermo")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(engine.isRunning ? Theme.textPrimary : Theme.textSecondary)
                if let pause = engine.pauseReason {
                    Text("PAUSA · \(pause)").themedChip(Theme.amber)
                }
                Spacer()
                if engine.isRunning, let beat = engine.lastLoopBeat {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let lag = max(0, Int(context.date.timeIntervalSince(beat)))
                        Label("\(lag)s", systemImage: "waveform.path.ecg")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(lag > 120 ? Theme.red : Theme.textTertiary)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .background(Theme.surface.opacity(0.6))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }

    /// Barra delle sezioni in basso, alla portata del pollice.
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(DashboardSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: section.icon)
                            .font(.system(size: 19, weight: selectedSection == section ? .semibold : .regular))
                            .symbolVariant(selectedSection == section ? .fill : .none)
                        Text(section.label)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(selectedSection == section ? terminalGreen : Theme.textTertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.rawValue)
                .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }

    /// Come leggere la griglia MERCATI.
    private var marketsLegend: some View {
        VStack(alignment: .leading, spacing: 6) {
            panelHeader("COME SI LEGGE", color: Theme.textSecondary)
            ForEach([
                (MarketInsight.State.held, "il bot ha una posizione aperta, con lo stop sul broker"),
                (.signal, "le regole hanno trovato un ribasso in trend: decide Kimi"),
                (.trendUp, "sopra la media a 200 giorni, in attesa di un ribasso"),
                (.trendDown, "sotto la media a 200 giorni: il bot non compra"),
                (.unaffordable, "il capitale non compra 1 azione entro i limiti")
            ], id: \.0.rawValue) { state, text in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(state.rawValue).themedChip(MarketDetailView.color(for: state))
                    Text(text).font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .panelStyle(Theme.textTertiary)
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
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if engine.drawdownLocked {
                        Text("STOP DRAWDOWN: persi oltre il 10% del capitale bot dal picco. Nessun nuovo ordine finché non sblocchi manualmente.")
                            .font(.caption)
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

    // MARK: - Cruscotto

    /// Kimi aggiunge valore? Esito ipotetico, con le stesse regole, dei
    /// candidati scelti e di quelli scartati.
    /// Curva del capitale del bot contro SPY "compra e tieni", stessa scala
    /// (100 = primo giorno), più quanto del capitale è già impegnato.
    private var capitalPanel: some View {
        let points = engine.equityHistory
        let summary = EquityHistory.summary(points)
        let series = EquityHistory.normalized(points)
        let capital = engine.account.map { min(engine.strategyConfig.capitalCap, $0.equityValue) }
        func pct(_ v: Double?) -> String { v.map { String(format: "%+.2f%%", $0 * 100) } ?? "—" }
        return VStack(alignment: .leading, spacing: 8) {
            panelHeader("CAPITALE BOT · CONTRO SPY", color: terminalGreen)
            portfolioRow(
                "IMPEGNATO",
                Formatters.amount(engine.botExposure) + (capital.map { " / " + Formatters.amount($0) } ?? "") + " USD",
                color: .white
            )
            if let summary {
                portfolioRow("BOT (\(summary.days) sedute)", pct(summary.botReturn),
                             color: summary.botReturn >= 0 ? terminalGreen : .red)
                portfolioRow("SPY COMPRA E TIENI", pct(summary.benchmarkReturn), color: DashboardPalette.cyan)
                portfolioRow("PERDITA MASSIMA DAL PICCO", pct(summary.maxDrawdown), color: .orange)
                ComparisonChart(bot: series.bot, benchmark: series.benchmark,
                                botColor: terminalGreen, benchmarkColor: DashboardPalette.cyan)
                    .frame(height: 150)
                Text("Verde: bot (guadagno del conto sul capitale del bot). Azzurro: SPY. 100 = primo giorno registrato. Il bot investe solo in parte e sta fermo molti giorni: deve perdere meno di SPY nei cali, non batterlo nei rialzi.")
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .fixedSize(horizontal: false, vertical: true)
                    .explanation()
            } else {
                Text("La curva parte dalla prima seduta con l'app aperta a mercato aperto: un punto al giorno.")
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .fixedSize(horizontal: false, vertical: true)
                    .explanation()
            }
        }
        .panelStyle(terminalGreen)
    }

    /// Pagella degli agenti: le regole da sole contro le scelte di Kimi, sugli
    /// stessi segnali e con le stesse uscite dell'app (esiti ipotetici).
    private var shadowPanel: some View {
        let s = engine.shadowSummary
        let stats = engine.entryStats
        func pct(_ v: Double?) -> String { v.map { String(format: "%+.2f%%", $0 * 100) } ?? "—" }
        func win(_ v: Double?) -> String { v.map { String(format: "%.0f%% in guadagno", $0 * 100) } ?? "—" }
        func group(_ g: ShadowSummary.Group) -> String { g.count == 0 ? "—" : "\(g.count) · \(pct(g.average)) · \(win(g.winRate))" }
        let verdict: (String, Color) = {
            switch s.verdict {
            case .notEnoughData(let have, let need):
                return ("GIUDIZIO: servono \(need) esiti, ora \(have). Fino ad allora i numeri sono rumore.", .gray)
            case .kimiAddsValue:
                return ("GIUDIZIO: Kimi aggiunge valore, le sue scelte rendono più delle regole da sole.", terminalGreen)
            case .kimiNeutral:
                return ("GIUDIZIO: Kimi non cambia il risultato; le regole da sole basterebbero (e costano zero).", .orange)
            case .kimiHurts:
                return ("GIUDIZIO: Kimi peggiora il risultato. Va corretto il prompt o lasciato decidere alle regole.", .red)
            }
        }()
        return VStack(alignment: .leading, spacing: 8) {
            panelHeader("PAGELLA AGENTI · KIMI CONTRO REGOLE", color: DashboardPalette.cyan)
            stackedRow("REGOLE DA SOLE (tutti i segnali)", group(s.rules))
            stackedRow("SCELTI DA KIMI", group(s.chosen))
            stackedRow("SCARTATI DA KIMI", group(s.skipped))
            stackedRow("BOCCIATI DAL REVIEWER", group(s.reviewerRejected))
            portfolioRow("VALORE DI KIMI", s.kimiEdge.map { String(format: "%+.2f punti", $0 * 100) } ?? "—",
                         color: (s.kimiEdge ?? 0) >= 0 ? terminalGreen : .red)
            if let older = s.olderEdge, let recent = s.recentEdge {
                portfolioRow("TENDENZA (prima → ora)", String(format: "%+.2f → %+.2f punti", older * 100, recent * 100),
                             color: recent >= older ? terminalGreen : .orange)
            }
            portfolioRow("IN CORSO", "\(s.pending)", color: .gray)
            Text(verdict.0)
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(verdict.1)
                .fixedSize(horizontal: false, vertical: true)
            Text("Come leggerla: VALORE DI KIMI è quanto rendono in media le sue scelte rispetto a tutti i segnali delle regole. Sopra zero aiuta, sotto zero danneggia. Il Reviewer lavora bene se i bocciati rendono meno degli scelti. TENDENZA confronta la metà più vecchia degli esiti con quella recente: se sale, gli agenti stanno migliorando.")
                .font(.caption)
                .foregroundStyle(.gray)
                .fixedSize(horizontal: false, vertical: true)
                .explanation()
            Divider().overlay(Color.gray.opacity(0.3))
            let filled = max(stats.placed - stats.unfilled - stats.partial, 0)
            portfolioRow(
                "ORDINI ESEGUITI",
                stats.placed == 0 ? "—" : "\(filled)/\(stats.placed) · parziali \(stats.partial) · mai \(stats.unfilled)",
                color: .white
            )
        }
        .panelStyle(DashboardPalette.cyan)
    }

    private func updateBanner(_ update: UpdateChecker.Release) -> some View {
        Button {
            selectedSection = .system
        } label: {
            HStack {
                Text("AGGIORNAMENTO \(update.version) DISPONIBILE")
                    .font(.system(.caption, design: .monospaced, weight: .heavy))
                Spacer()
                Text("SISTEMA →").font(.system(.caption2, design: .monospaced, weight: .bold))
            }
            .foregroundStyle(Theme.background)
            .padding(12)
            .background(Theme.cyan, in: Theme.shape(Theme.smallRadius))
        }
        .buttonStyle(.plain)
    }

    private var liveBanner: some View {
        Text("CONTO LIVE · SOLDI VERI")
            .font(.system(.headline, design: .monospaced, weight: .black))
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(Color.red)
            .foregroundStyle(.white)
    }

    private var displayedMode: TradingMode {
        engine.activeMode ?? engine.strategyConfig.tradingMode
    }

    private var engineStateColor: Color {
        if !engine.isRunning { return .gray }
        if engine.pauseReason != nil || engine.dailyStopOn || engine.drawdownLocked { return .orange }
        return terminalGreen
    }

    private var engineStateText: String {
        if !engine.isRunning { return "FERMO" }
        if engine.pauseReason != nil { return "IN PAUSA" }
        if engine.drawdownLocked || engine.dailyStopOn { return "PROTEZIONE ATTIVA" }
        return "IN FUNZIONE"
    }

    /// Stato, cosa sta facendo adesso, START/STOP: tutto in un colpo d'occhio.
    private var heroPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(engineStateText)
                    .font(.system(.title2, design: .monospaced, weight: .black))
                    .foregroundStyle(engineStateColor)
                Spacer()
                Text(displayedMode.label)
                    .font(.system(.caption2, design: .monospaced, weight: .black))
                    .foregroundStyle(displayedMode == .intraday ? .orange : terminalGreen)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .overlay(Theme.shape(Theme.smallRadius).strokeBorder(displayedMode == .intraday ? .orange : terminalGreen, lineWidth: 1))
            }
            Text(engine.isRunning ? engine.currentActivity : idleHint)
                .font(.callout)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if engine.isRunning, engine.activeMode?.runsOnSchedule == true, let next = engine.nextCheckAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, next.timeIntervalSince(context.date))
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: 1 - min(left / (15 * 60), 1))
                            .tint(terminalGreen)
                        Text(left > 0 ? String(format: "Prossimo controllo tra %d:%02d", Int(left) / 60, Int(left) % 60) : "Controllo in corso…")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            if engine.isRunning, engine.activeMode?.runsOnSchedule == true {
                Text(engine.activeMode == .night
                     ? "Gli ordini d'asta restano sul broker anche ad app chiusa. Aprila la mattina entro le 15:28 (vendita all'apertura) e il pomeriggio entro le 21:50 (acquisto in chiusura)."
                     : "Puoi lasciare l'app aperta o chiuderla: gli stop restano attivi sul broker. Riaprendola parte subito un controllo.")
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .fixedSize(horizontal: false, vertical: true)
                    .explanation()
            }
            if displayedMode == .intraday, !engine.isRunning {
                intradayInputs
            }
            HStack(spacing: 12) {
                if engine.isRunning {
                    if engine.activeMode?.runsOnSchedule == true {
                        Button("CONTROLLA ORA") {
                            engine.requestDailyCheck()
                        }
                        .buttonStyle(TerminalButtonStyle(color: DashboardPalette.cyan))
                    }
                    Button("STOP") {
                        Task { await engine.stop() }
                    }
                    .buttonStyle(TerminalButtonStyle(color: .orange))
                    .disabled(engine.isKillInProgress)
                } else {
                    Button(engine.paperTrading ? "START" : "START LIVE") {
                        if engine.paperTrading {
                            Task { await engine.start(symbolsText: symbols, news: news) }
                        } else {
                            showLiveStartConfirmation = true
                        }
                    }
                    .buttonStyle(TerminalButtonStyle(color: engine.paperTrading ? terminalGreen : .red))
                    .disabled(engine.isKillInProgress)
                    .alert("AVVIO CON SOLDI VERI", isPresented: $showLiveStartConfirmation) {
                        Button("ANNULLA", role: .cancel) {}
                        Button("AVVIA LIVE", role: .destructive) {
                            Task { await engine.start(symbolsText: symbols, news: news) }
                        }
                    } message: {
                        Text("Il motore può inviare subito ordini reali sul conto Alpaca live. Le perdite sono reali.")
                    }
                }
            }
            if engine.isRunning, let startedAt = engine.sessionStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("AVVIATA \(Formatters.time(startedAt)) · ATTIVA DA \(elapsed(from: startedAt, to: context.date))")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(engineStateColor)
                }
            }
        }
        .panelStyle(engineStateColor)
    }

    private var idleHint: String {
        switch displayedMode {
        case .daily:
            return "Premi START: controlla i \(DailyStrategy.basket.count) ETF, chiama Kimi solo se c'è un segnale e mette gli ordini con lo stop sul broker. Poi puoi chiudere l'app."
        case .night:
            return "Premi START: compra in chiusura S&P 500, Nasdaq-100, Russell 2000 e oro e li vende all'apertura di domani. Zero crediti Kimi. Meglio su un conto paper separato."
        case .intraday:
            return "Modalità veloce SPERIMENTALE: nei test perde. Tieni l'app aperta: chiude tutto prima della chiusura del mercato."
        }
    }

    private var intradayInputs: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SIMBOLI · SEPARATI DA VIRGOLA")
                .font(.caption)
                .foregroundStyle(.gray)
            TextField("SPY,QQQ", text: $symbols)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(10)
                .background(Theme.surfaceHigh, in: Theme.shape(Theme.smallRadius))
            if let equity = engine.account?.equityValue, equity > 0 {
                let capital = min(engine.strategyConfig.sanitized.capitalCap, equity)
                Text("Con \(String(format: "%.0f", capital)) USD scegli titoli liquidi sotto \(String(format: "%.0f", capital * RiskRules.maximumPositionFraction)) USD ad azione (25% del capitale): si compra almeno 1 azione intera.")
                    .font(.caption)
                    .foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("NOTIZIE (FACOLTATIVE, CON DATA E FONTE)")
                .font(.caption)
                .foregroundStyle(.gray)
            TextEditor(text: $news)
                .font(.caption)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Theme.surfaceHigh, in: Theme.shape(Theme.smallRadius))
                .frame(height: 60)
        }
    }

    private var ordersToday: Int {
        let calendar = Calendar.current
        return engine.recentOrders.filter { order in
            order.parentOrderId == nil && (order.submittedDate.map { calendar.isDateInToday($0) } ?? false)
        }.count
    }

    /// Quattro numeri: quanto consuma, quanto compra, cosa ha in mano, come va.
    private var todayPanel: some View {
        let unrealized = engine.positions.reduce(0) { $0 + $1.unrealizedPLValue }
        let spent = engine.creditsSpentToday
        let limit = engine.strategyConfig.creditLimitEnabled ? engine.strategyConfig.dailyCreditLimitUSD : nil
        return VStack(alignment: .leading, spacing: 10) {
            panelHeader("OGGI", color: terminalGreen)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                statTile(
                    "KIMI",
                    "\(engine.kimiCallsToday) chiamate",
                    spent.map { s in "\(String(format: "%.2f", s)) USD" + (limit.map { " / \(String(format: "%.2f", $0))" } ?? "") } ?? "spesa n/d",
                    engine.creditLimitHit ? .red : DashboardPalette.cyan
                )
                statTile("ORDINI", "\(ordersToday) inviati", "\(engine.openOrders.count) aperti sul broker", terminalGreen)
                statTile(
                    "POSIZIONI",
                    "\(engine.positions.count) aperte",
                    engine.positions.isEmpty ? "nessuna" : Formatters.signedAmount(unrealized) + " non realizzati",
                    unrealized >= 0 ? terminalGreen : .red
                )
                statTile(
                    "P&L GIORNATA",
                    engine.account?.dayPnL.map(Formatters.signedAmount) ?? "—",
                    "equity " + Formatters.amount(engine.account?.equityValue),
                    (engine.account?.dayPnL ?? 0) >= 0 ? terminalGreen : .red
                )
            }
        }
        .panelStyle(terminalGreen)
    }

    private func statTile(_ title: String, _ value: String, _ detail: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(.gray)
            Text(value)
                .font(.system(.headline, design: .monospaced, weight: .black))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.surface, in: Theme.shape(Theme.smallRadius))
        .overlay(Theme.shape(Theme.smallRadius).strokeBorder(color.opacity(0.3), lineWidth: 1))
    }

    /// La catena degli agenti: chi sta lavorando, cosa ha deciso, cosa passa avanti.
    private var pipelinePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHeader("CATENA AGENTI · ULTIMO CICLO", color: DashboardPalette.cyan)
            ForEach(engine.pipeline) { stage in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: stageIcon(stage.state))
                        .foregroundStyle(stageColor(stage.state))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(stage.id.title)
                                .font(.system(.caption, design: .monospaced, weight: .black))
                                .foregroundStyle(stageColor(stage.state))
                            if stage.id.usesKimi {
                                Text("KIMI")
                                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                                    .foregroundStyle(DashboardPalette.cyan)
                            }
                            Spacer()
                            if let at = stage.updatedAt {
                                Text(Formatters.time(at))
                                    .font(.caption)
                                    .foregroundStyle(.gray)
                            }
                        }
                        Text(stage.detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(stage.id.role)
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                }
            }
            if displayedMode == .daily, !engine.dailyCandidates.isEmpty {
                Text("Segnali di oggi: " + engine.dailyCandidates.map { "\($0.symbol) RSI2 \(String(format: "%.1f", $0.snapshot.rsi2))" }.joined(separator: " · "))
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(terminalGreen)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panelStyle(DashboardPalette.cyan)
    }

    private func stageIcon(_ state: PipelineState) -> String {
        switch state {
        case .idle: return "circle"
        case .working: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        case .blocked: return "hand.raised.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func stageColor(_ state: PipelineState) -> Color {
        switch state {
        case .idle: return .gray
        case .working: return DashboardPalette.cyan
        case .done: return terminalGreen
        case .skipped: return .gray
        case .blocked: return .orange
        case .failed: return .red
        }
    }

    /// Ultime righe del registro, la più recente in alto; il registro completo
    /// è in DETTAGLI.
    private var recentLogPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("ULTIMI EVENTI", color: terminalGreen)
            if engine.logs.isEmpty {
                Text("Nessun evento: premi START.")
                    .font(.caption)
                    .foregroundStyle(.gray)
            }
            ForEach(Array(engine.logs.suffix(8).reversed())) { entry in
                HStack(alignment: .top, spacing: 6) {
                    Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                        .foregroundStyle(.gray)
                    Text(entry.agent.rawValue)
                        .foregroundStyle(agentColor(entry.agent))
                        .frame(width: 40, alignment: .leading)
                    Text(entry.message)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(3)
                }
                .font(.caption)
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
                        .font(.caption)
                        .foregroundStyle(.gray)
                    HStack(spacing: 12) {
                        ShareLink(item: url) {
                            Text("ESPORTA / INVIA")
                                .font(.system(.body, design: .monospaced, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(terminalGreen.opacity(0.18), in: Theme.shape(Theme.smallRadius))
                                .foregroundStyle(terminalGreen)
                                .overlay(Theme.shape(Theme.smallRadius).strokeBorder(terminalGreen, lineWidth: 1))
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
                portfolioRow("EQUITY", Formatters.amount(account.equityValue), color: .white)
                portfolioRow("CASH", Formatters.amount(account.cashValue), color: .white)
                portfolioRow("BUYING POWER", Formatters.amount(account.buyingPowerValue), color: .white)
                if let dayPnL = account.dayPnL {
                    portfolioRow(
                        "P&L OGGI",
                        Formatters.signedAmount(dayPnL),
                        color: dayPnL >= 0 ? terminalGreen : .red
                    )
                }
            } else {
                Text("Nessun dato: tocca AGGIORNA per leggere il conto.")
                    .font(.caption)
                    .foregroundStyle(.gray)
            }
        }
        .panelStyle(terminalGreen)
        .task {
            await engine.refreshPortfolio()
        }
    }

    /// Riga su due livelli per valori lunghi (etichetta sopra, numeri sotto).
    private func stackedRow(_ label: String, _ value: String, color: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.gray)
            Text(value)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func portfolioRow(_ label: String, _ value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.caption)
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
                    .font(.caption)
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
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(Formatters.time(entry.timestamp)) · prima di ogni decisione → Brain e Reviewer")
                    .font(.caption)
                    .foregroundStyle(.gray)
            } else {
                Text("Nessuna analisi ancora: l'Analyst parte quando il filtro trova un segnale, prima della decisione, e la sua lettura arriva a Brain e Reviewer. Puoi forzarla con ANALIZZA ORA.")
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .fixedSize(horizontal: false, vertical: true)
                    .explanation()
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
            .overlay(Theme.shape(Theme.smallRadius).strokeBorder(color.opacity(0.6), lineWidth: 1))
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
                    .font(.caption)
                    .foregroundStyle(.gray)
                HStack(spacing: 12) {
                    ShareLink(item: url) {
                        Text("INVIA")
                            .font(.system(.body, design: .monospaced, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(DashboardPalette.cyan.opacity(0.18), in: Theme.shape(Theme.smallRadius))
                            .foregroundStyle(DashboardPalette.cyan)
                            .overlay(Theme.shape(Theme.smallRadius).strokeBorder(DashboardPalette.cyan, lineWidth: 1))
                    }
                    Button("ELIMINA") {
                        engine.deleteDatasetExport()
                    }
                    .buttonStyle(TerminalButtonStyle(color: .red))
                }
            }
            Text("Ogni decisione (anche gli HOLD) è registrata con prezzo, ATR, livelli ed esito: win/loss per i trade eseguiti, movimento del prezzo a 30 min per gli HOLD.")
                .font(.caption)
                .foregroundStyle(.gray)
                .fixedSize(horizontal: false, vertical: true)
                .explanation()
        }
        .panelStyle(DashboardPalette.cyan)
    }

    /// Esportazione dei trade chiusi: vale per entrambe le modalità.
    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHeader("ESPORTA TRADE", color: terminalGreen)
            Button("ESPORTA TRADE CHIUSI CSV") {
                engine.exportTradesCSV()
            }
            .buttonStyle(TerminalButtonStyle(color: terminalGreen))
            if let url = engine.tradesCSVURL {
                HStack(spacing: 12) {
                    ShareLink(item: url) {
                        Text("INVIA CSV")
                            .font(.system(.body, design: .monospaced, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(terminalGreen.opacity(0.18), in: Theme.shape(Theme.smallRadius))
                            .foregroundStyle(terminalGreen)
                            .overlay(Theme.shape(Theme.smallRadius).strokeBorder(terminalGreen, lineWidth: 1))
                    }
                    Button("ELIMINA") {
                        engine.deleteTradesCSV()
                    }
                    .buttonStyle(TerminalButtonStyle(color: .red))
                }
            }
            Text("Un file da aprire in Numbers o Excel: data, ETF, quantità, ingresso, uscita, P&L, stop e motivazione di Kimi.")
                .font(.caption)
                .foregroundStyle(.gray)
                .fixedSize(horizontal: false, vertical: true)
                .explanation()
        }
        .panelStyle(terminalGreen)
    }

    private func panelHeader(_ title: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Capsule()
                .fill(color)
                .frame(width: 3, height: 12)
            Text(title)
                .font(.system(.caption, design: .monospaced, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(color)
        }
    }

    private var positionsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("POSIZIONI APERTE", color: terminalGreen)
            if engine.positions.isEmpty {
                Text("Nessuna posizione aperta.")
                    .font(.caption)
                    .foregroundStyle(.gray)
            } else {
                ForEach(engine.positions) { position in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(position.symbol)
                                .font(.system(.caption, design: .monospaced, weight: .bold))
                                .foregroundStyle(.white)
                            Text((position.side ?? "long").uppercased())
                                .font(.caption)
                                .foregroundStyle(position.side == "short" ? .red : terminalGreen)
                            Spacer()
                            Text("qty \(Formatters.trimmed(position.quantity))")
                                .font(.caption)
                                .foregroundStyle(.gray)
                        }
                        HStack {
                            Text(
                                "entry \(Formatters.money(position.averageEntryPriceValue)) → ora \(Formatters.money(position.currentPriceValue))"
                            )
                            .font(.caption)
                            .foregroundStyle(.gray)
                            Spacer()
                            Text(Formatters.signedAmount(position.unrealizedPLValue))
                                .font(.system(.caption, design: .monospaced, weight: .bold))
                                .foregroundStyle(position.unrealizedPLValue >= 0 ? terminalGreen : .red)
                        }
                    }
                    .padding(8)
                    .background(Theme.surface, in: Theme.shape(Theme.smallRadius))
                    .overlay(Theme.shape(Theme.smallRadius).strokeBorder(terminalGreen.opacity(0.2), lineWidth: 1))
                }
            }
        }
        .panelStyle(terminalGreen)
    }

    private var decisionsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("KIMI BRAIN · ULTIME DECISIONI", color: DashboardPalette.cyan)
            if engine.decisions.isEmpty {
                Text("Nessuna decisione ancora: Kimi viene chiamato solo quando la Strategia trova un segnale.")
                    .font(.caption)
                    .foregroundStyle(.gray)
            } else {
                ForEach(engine.decisions.suffix(5).reversed()) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(Formatters.time(entry.timestamp))
                                .font(.caption)
                                .foregroundStyle(.gray)
                            Text(entry.decision.symbol)
                                .font(.system(.caption, design: .monospaced, weight: .bold))
                                .foregroundStyle(.white)
                            Text(entry.decision.action.rawValue.uppercased())
                                .font(.system(.caption, design: .monospaced, weight: .bold))
                                .foregroundStyle(actionColor(entry.decision.action))
                            Spacer()
                            Text("\(Int(entry.decision.confidence * 100))%")
                                .font(.caption)
                                .foregroundStyle(DashboardPalette.cyan)
                        }
                        Text(entry.decision.rationale)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                        if entry.decision.action != .hold {
                            Text(
                                "entry \(Formatters.money(entry.decision.entryPrice)) · stop \(Formatters.money(entry.decision.stopLoss)) · target \(Formatters.money(entry.decision.takeProfit))"
                            )
                            .font(.caption)
                            .foregroundStyle(.gray)
                        }
                    }
                    .padding(8)
                    .background(Theme.surface, in: Theme.shape(Theme.smallRadius))
                    .overlay(Theme.shape(Theme.smallRadius).strokeBorder(DashboardPalette.cyan.opacity(0.25), lineWidth: 1))
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
                    .font(.caption)
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
                    Formatters.signedAmount(stats.expectancy ?? 0),
                    color: (stats.expectancy ?? 0) >= 0 ? terminalGreen : .red
                )
                portfolioRow(
                    "MAX DRAWDOWN",
                    Formatters.amount(stats.maxDrawdown),
                    color: .red
                )
            } else {
                Text("Nessun trade chiuso: le metriche appariranno dopo i primi esiti registrati.")
                    .font(.caption)
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
                    .font(.caption)
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
                    .font(.caption)
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
                            .font(.caption)
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
                .font(.caption)
                .foregroundStyle(.gray)
        }
        .padding(10)
        .background(Theme.surface, in: Theme.shape(Theme.smallRadius))
        .overlay(Theme.shape(Theme.smallRadius).strokeBorder(color.opacity(0.35), lineWidth: 1))
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
                    .font(.caption)
                    .foregroundStyle(.gray)
            } else {
                ForEach(engine.openOrders) { order in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(order.side.uppercased()) \(order.symbol) x\(Formatters.trimmed(order.quantity ?? "0"))")
                                .font(.system(.caption, design: .monospaced, weight: .bold))
                                .foregroundStyle(.white)
                            Text("\(order.status.uppercased()) · \(Formatters.time(order.submittedDate))")
                                .font(.caption)
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
                    .background(Theme.surface, in: Theme.shape(Theme.smallRadius))
                    .overlay(Theme.shape(Theme.smallRadius).strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
                }
            }

            Text("POSIZIONI: \(engine.positions.count)")
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(.gray)
            if engine.positions.isEmpty {
                Text("Nessuna posizione.")
                    .font(.caption)
                    .foregroundStyle(.gray)
            } else {
                ForEach(engine.positions) { position in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(position.symbol) · qty \(Formatters.trimmed(position.quantity))")
                                .font(.system(.caption, design: .monospaced, weight: .bold))
                                .foregroundStyle(.white)
                            Text("P&L \(Formatters.signedAmount(position.unrealizedPLValue)) USD")
                                .font(.caption)
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
                    .background(Theme.surface, in: Theme.shape(Theme.smallRadius))
                    .overlay(Theme.shape(Theme.smallRadius).strokeBorder(Color.red.opacity(0.3), lineWidth: 1))
                }
            }
            Text("CHIUDI chiede ad Alpaca una chiusura a mercato della singola posizione; ANNULLA cancella il singolo ordine aperto. Per emergenza globale usa HARD KILL nel CRUSCOTTO.")
                .font(.caption)
                .foregroundStyle(.gray)
                .fixedSize(horizontal: false, vertical: true)
                .explanation()
        }
        .panelStyle(DashboardPalette.green)
    }

    private func panelHeader(_ title: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Capsule()
                .fill(color)
                .frame(width: 3, height: 12)
            Text(title)
                .font(.system(.caption, design: .monospaced, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(color)
        }
    }
}

/// Impostazioni vere: persistite in UserDefaults e lette dal motore a ogni
/// ciclo. Il modello Kimi può essere scritto a mano o scelto dalla lista API.
private struct SystemSettingsView: View {
    @EnvironmentObject private var engine: QuantSwarmEngine
    @Environment(\.openURL) private var openURL
    @State private var draft = StrategyConfig()

    /// Gradini del capitale del bot (USD).
    static let capitalSteps: [Double] = [500, 750, 1_000, 1_500, 2_000, 3_000, 5_000, 7_500, 10_000, 15_000, 20_000, 25_000,
                                         50_000, 75_000, 100_000, 250_000, 500_000, 1_000_000]
    static func nextCapital(after value: Double) -> Double {
        capitalSteps.first { $0 > value + 0.5 } ?? capitalSteps[capitalSteps.count - 1]
    }
    static func previousCapital(before value: Double) -> Double {
        capitalSteps.last { $0 < value - 0.5 } ?? capitalSteps[0]
    }

    /// Quanti ETF del paniere il capitale (e il rischio) impostati possono
    /// comprare con almeno 1 azione intera, sui prezzi dell'ultimo controllo.
    static func modeDescription(_ mode: TradingMode) -> String {
        switch mode {
        case .daily:
            return "Validata dal backtest 2006–oggi: batte il caso. Stop sul broker attivo anche ad app chiusa: basta aprirla qualche minuto al giorno."
        case .night:
            return "Studio 2006–oggi: circa +8% l'anno con cali fino al −22%. Compra in chiusura, vende all'apertura. Servono due aperture al giorno: mattina entro le 15:28, pomeriggio entro le 21:50."
        case .intraday:
            return "SPERIMENTALE: nei backtest perde e non batte il caso. Richiede l'app sempre aperta; chiude tutto prima della chiusura."
        }
    }

    private var buyableRow: some View {
        let snapshots = engine.basketSnapshots
        let equity = engine.account?.equityValue
        let capital = min(draft.sanitized.capitalCap, equity ?? 0)
        let risk = draft.sanitized.riskFraction
        let ok = snapshots.keys.sorted().filter { symbol in
            let s = snapshots[symbol]!
            return RiskRules.canBuyOneShare(price: s.close, stopDistance: DailyStrategy.stopATR * s.atr14,
                                            capital: capital, freeCash: capital, riskFraction: risk)
        }
        let missing = snapshots.keys.sorted().filter { !ok.contains($0) }
        let text: String
        if snapshots.isEmpty || equity == nil {
            text = "ETF COMPRABILI: si calcola al primo controllo (START o CONTROLLA ORA)."
        } else {
            text = "ETF COMPRABILI: \(ok.count)/\(snapshots.count)"
                + (missing.isEmpty ? "" : " · esclusi \(missing.joined(separator: ", "))")
        }
        let color: Color = (snapshots.isEmpty || equity == nil) ? .gray : (ok.count >= 8 ? DashboardPalette.green : (ok.count >= 4 ? .orange : .red))
        return Text(text)
            .font(.system(.caption2, design: .monospaced, weight: .bold))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("buyableETF")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                panelHeader("IMPOSTAZIONI", color: DashboardPalette.green)
                Spacer()
                Button("CARICA MODELLI") {
                    Task { await engine.loadAvailableKimiModels() }
                }
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(DashboardPalette.cyan)
            }

            Picker("Modalità", selection: $draft.tradingMode) {
                ForEach(TradingMode.allCases, id: \.self) { mode in
                    Text(mode.shortLabel).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(Self.modeDescription(draft.tradingMode))
                .font(.caption)
                .foregroundStyle(draft.tradingMode == .intraday ? .orange : DashboardPalette.green)
            Text("La modalità cambia al prossimo START.")
                .font(.caption)
                .foregroundStyle(.gray)

            Group {
                // Il numero che conta, scritto in chiaro: quanto usa il bot adesso.
                let equityNow = engine.account?.equityValue
                let used = equityNow.map { min(draft.sanitized.capitalCap, $0) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("CAPITALE USATO DAL BOT")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text(used.map { Formatters.amount($0) + " $" } ?? "saldo in arrivo…")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                    Text(draft.capitalLimitEnabled
                         ? "solo una parte del conto" + (equityNow.map { " (conto: \(Formatters.amount($0)) $)" } ?? "")
                         : "tutto il conto: segue da solo guadagni e perdite")
                        .font(.caption)
                        .foregroundStyle(draft.capitalLimitEnabled ? Theme.amber : Theme.green)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: Theme.shape(Theme.smallRadius))
                Toggle("Usa solo una parte del conto", isOn: $draft.capitalLimitEnabled)
                    .tint(DashboardPalette.green)
                if draft.capitalLimitEnabled {
                    Stepper(
                        "Capitale bot: \(String(format: "%.0f", draft.botCapitalUSD)) USD",
                        onIncrement: { draft.botCapitalUSD = Self.nextCapital(after: draft.botCapitalUSD) },
                        onDecrement: { draft.botCapitalUSD = Self.previousCapital(before: draft.botCapitalUSD) }
                    )
                }
                Text(draft.capitalLimitEnabled
                     ? "Il bot non impegna mai più di questa cifra (USD), anche se sul conto c'è di più. Utile solo se sul conto tieni altri soldi."
                     : "Il bot usa tutto il saldo del conto" + (engine.account.map { " (\(Formatters.amount($0.equityValue)) USD)" } ?? "") + ": cresce e cala da solo con guadagni e perdite. Rischio e tetto del 25% si ricalcolano a ogni controllo.")
                    .font(.system(.caption2, design: .monospaced, weight: .regular))
                    .foregroundStyle(.gray)
                    .fixedSize(horizontal: false, vertical: true)
                    .explanation()
                if draft.tradingMode != .night { buyableRow }
                Stepper(
                    "Rischio per trade: \(String(format: "%.2f", draft.riskPerTradePercent))% capitale",
                    value: $draft.riskPerTradePercent,
                    in: 0.25...2.0,
                    step: 0.25
                )
                Stepper("Max posizioni aperte: \(draft.maxOpenPositions)", value: $draft.maxOpenPositions, in: 1...5)
                Stepper(
                    "Stop giornaliero: \(String(format: "%.1f", draft.dailyStopPercent))% capitale",
                    value: $draft.dailyStopPercent,
                    in: 0.5...5.0,
                    step: 0.5
                )
            }
            .font(.system(.caption, design: .monospaced, weight: .bold))
            .foregroundStyle(.white)

            // Impostazioni della sola modalità veloce: in giornaliera non servono.
            if draft.tradingMode == .intraday {
                Group {
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
                    .font(.caption)
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
                Text("Kimi viene chiamato solo se scatta un trigger in codice (setup long). Nessun trigger = zero crediti spesi.")
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .fixedSize(horizontal: false, vertical: true)
                    .explanation()
            } else {
                Text("GIORNALIERA: Kimi viene chiamato solo se un ETF è in trend (sopra SMA200) con RSI2 sotto 10. Nessun segnale = zero crediti.")
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .fixedSize(horizontal: false, vertical: true)
                    .explanation()
            }

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
                .font(.caption)
                .foregroundStyle(.gray)
            TextField("kimi-k3.1-pro-highspeed", text: $draft.kimiModel)
                .font(.caption)
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
                .font(.caption)
            }
            if let error = engine.modelListError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Toggle("RIPRENDI SESSIONE AL RIAVVIO", isOn: $draft.autoResumeOnLaunch)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .tint(DashboardPalette.green)

            Toggle("PROMEMORIA 15:30 NEW YORK (21:30 ITALIA)", isOn: $draft.dailyReminder)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .tint(DashboardPalette.green)
            Text("Lun–ven, mezz'ora prima della chiusura USA: ti ricorda di aprire l'app per la modalità giornaliera. iOS non permette di leggere le chiavi protette da Face ID in background, quindi l'app non controlla da sola: ti avvisa.")
                .font(.caption)
                .foregroundStyle(.gray)
                .fixedSize(horizontal: false, vertical: true)
                .explanation()

            Toggle("NASCONDI SALDO", isOn: $draft.hideAmounts)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .tint(DashboardPalette.green)
            Text("Saldo, P&L e capitale diventano ••••• (anche con l'occhio in alto). I prezzi degli ETF restano visibili.")
                .font(.caption)
                .foregroundStyle(.gray)
                .fixedSize(horizontal: false, vertical: true)
                .explanation()

            Toggle("MODALITÀ PRO", isOn: $draft.proMode)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .tint(DashboardPalette.green)
            Text("Per chi conosce già l'app: toglie spiegazioni, legende e testi d'aiuto. Restano numeri, stati, avvisi e pulsanti.")
                .font(.caption)
                .foregroundStyle(.gray)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("IMPORTI NEL WIDGET", isOn: $draft.widgetShowsAmounts)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .tint(DashboardPalette.green)
            Text("Spento: il widget mostra solo lo stato, senza equity e P&L (il widget si vede anche a telefono bloccato).")
                .font(.caption)
                .foregroundStyle(.gray)
                .fixedSize(horizontal: false, vertical: true)
                .explanation()

            Button("APPLICA IMPOSTAZIONI") {
                engine.updateStrategyConfig(draft)
            }
            .buttonStyle(TerminalButtonStyle(color: DashboardPalette.green))

            VStack(alignment: .leading, spacing: 6) {
                let config = engine.strategyConfig
                settingRow("VERSIONE", AppVersion.text)
                settingRow("AGGIORNAMENTI", engine.updateStatus)
                HStack(spacing: 10) {
                    if let update = engine.availableUpdate, let url = UpdateChecker.liveContainerInstallURL(for: update) {
                        Button("AGGIORNA A \(update.version)") { openURL(url) }
                            .buttonStyle(TerminalButtonStyle(color: DashboardPalette.cyan))
                    } else {
                        Button("CONTROLLA AGGIORNAMENTI") { Task { await engine.checkForUpdates() } }
                            .buttonStyle(TerminalButtonStyle(color: DashboardPalette.cyan))
                    }
                }
                if let source = UpdateChecker.liveContainerSourceURL {
                    Button("AGGIUNGI SORGENTE A LIVECONTAINER") { openURL(source) }
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(DashboardPalette.cyan)
                }
                Text("AGGIORNA apre LiveContainer, che installa la nuova IPA sopra questa: dati, chiavi e impostazioni restano. Con la sorgente aggiunta, LiveContainer mostra da solo le versioni nuove.")
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .fixedSize(horizontal: false, vertical: true)
                    .explanation()
                settingRow("MODALITÀ", config.tradingMode.label)
                settingRow("CAPITALE BOT", (config.capitalLimitEnabled
                    ? "limitato a \(String(format: "%.0f", config.botCapitalUSD)) USD"
                    : "tutto il conto") + " · impegnati \(String(format: "%.0f", engine.botExposure)) USD")
                settingRow("STATO APPLICATO", "rischio \(String(format: "%.2f", config.riskPerTradePercent))% · max \(config.maxOpenPositions) · stop giorno \(String(format: "%.1f", config.dailyStopPercent))%")
                settingRow("MODELLO ATTIVO", config.kimiModel)
                if config.tradingMode == .night {
                    settingRow("PANIERE", "S&P 500 · Nasdaq-100 · Russell 2000 · oro, peso uguale, originale o gemello secondo il saldo")
                    settingRow("ORDINI", "acquisto in asta di chiusura (MOC), vendita in asta di apertura (OPG)")
                    settingRow("KIMI", "non usato: 0 crediti")
                    settingRow("APERTURE", "mattina entro le 15:28 · pomeriggio 15:30–21:50 (ora italiana)")
                } else if config.tradingMode == .daily {
                    settingRow("SEGNALI", "15 ETF · sopra SMA200 e RSI2 < 10 · Kimi solo se c'è un segnale")
                    settingRow("ORDINI", "limite + stop \(String(format: "%.1f", DailyStrategy.stopATR)) ATR + target \(String(format: "%.0f", DailyStrategy.takeProfitATR)) ATR, GTC sul broker")
                    settingRow("USCITE", "chiusura > SMA5 o \(DailyStrategy.maxHoldingDays) giorni, solo a mercato aperto")
                    settingRow("DATI", "barre giornaliere SIP (consolidate), ripiego IEX")
                    settingRow("CONTROLLI", "subito, ogni 15 min ad app aperta e a ogni riapertura")
                } else {
                    settingRow("DECISIONI KIMI", "chiusura candela \(config.decisionTimeframeMinutes)m · filtro \(config.kimiFilterEnabled ? "ON" : "OFF")")
                    settingRow("STREAM DATI", SystemLimits.marketStreamHost)
                    settingRow("GUARD CHIUSURA", "no nuovi trade negli ultimi 15 min")
                    settingRow("FLAT BY CLOSE", "chiude le posizioni della veloce a T-10 min")
                    settingRow("FOREGROUND", "motore solo ad app aperta: in background nessun ordine")
                }
                settingRow("PAUSE AUTOMATICHE", "rete assente o batteria < 20%")
            }
            Text(engine.strategyConfig.tradingMode.runsOnSchedule
                 ? "Nessuna app iOS resta attiva 24/7: per questo la giornaliera mette stop e target sul broker, attivi anche ad app chiusa. Basta aprirla una volta al giorno a mercato aperto."
                 : "Nessuna app iOS resta attiva 24/7: la veloce lavora solo ad app aperta con lo schermo acceso; in background nessun nuovo ordine, le posizioni restano protette dalle gambe stop/target sul broker.")
                .font(.caption)
                .foregroundStyle(.gray)
                .fixedSize(horizontal: false, vertical: true)
                .explanation()
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
        HStack(spacing: 7) {
            Capsule()
                .fill(color)
                .frame(width: 3, height: 12)
            Text(title)
                .font(.system(.caption, design: .monospaced, weight: .heavy))
                .tracking(0.6)
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
        .font(.caption)
    }
}

/// Due linee sulla stessa scala (bot e riferimento), con la linea 100 tratteggiata.
private struct ComparisonChart: View {
    let bot: [Double]
    let benchmark: [Double?]
    let botColor: Color
    let benchmarkColor: Color

    var body: some View {
        Canvas { context, size in
            let all = bot + benchmark.compactMap { $0 } + [100]
            let minimum = all.min() ?? 99
            let maximum = all.max() ?? 101
            let span = max(maximum - minimum, 0.000_001)
            let count = max(bot.count, benchmark.count)
            func point(_ index: Int, _ value: Double) -> CGPoint {
                let x = count <= 1 ? size.width / 2 : size.width * Double(index) / Double(count - 1)
                let y = size.height - (value - minimum) / span * size.height
                return CGPoint(x: x, y: y)
            }
            let base = Path { path in
                path.move(to: CGPoint(x: 0, y: point(0, 100).y))
                path.addLine(to: CGPoint(x: size.width, y: point(0, 100).y))
            }
            context.stroke(base, with: .color(.gray.opacity(0.5)), style: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
            var benchLine = Path()
            var started = false
            for (index, value) in benchmark.enumerated() {
                guard let value else { started = false; continue }
                if started { benchLine.addLine(to: point(index, value)) } else { benchLine.move(to: point(index, value)); started = true }
            }
            context.stroke(benchLine, with: .color(benchmarkColor.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            let botLine = Path { path in
                for (index, value) in bot.enumerated() {
                    if index == 0 { path.move(to: point(index, value)) } else { path.addLine(to: point(index, value)) }
                }
            }
            context.stroke(botLine, with: .color(botColor), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
        .background(Theme.surface, in: Theme.shape(Theme.smallRadius))
        .overlay(Theme.shape(Theme.smallRadius).strokeBorder(botColor.opacity(0.4), lineWidth: 1))
        .accessibilityLabel("Curva del capitale del bot contro SPY")
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
                    Text("ATTESA DATI EQUITY").font(.caption),
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
        .background(Theme.surface, in: Theme.shape(Theme.smallRadius))
        .overlay(Theme.shape(Theme.smallRadius).strokeBorder(color.opacity(0.4), lineWidth: 1))
    }
}

private struct TerminalButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .monospaced, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .padding()
            .background(color.opacity(configuration.isPressed ? 0.35 : 0.18), in: Theme.shape(Theme.smallRadius))
            .foregroundStyle(color)
            .overlay(Theme.shape(Theme.smallRadius).strokeBorder(color, lineWidth: 1))
    }
}

private extension View {
    func panelStyle(_ color: Color) -> some View {
        themedCard(color)
    }
}
