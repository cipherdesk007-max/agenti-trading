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

    /// Quantità frazionata crypto: fino a 8 decimali, senza zeri in coda.
    static func qty(_ value: Double) -> String {
        var text = String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? "0" : text
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
    /// Catena agenti e registro nel CRUSCOTTO: si aprono a richiesta.
    @State private var showAgentsLog = false
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
                                balanceAdvisorBanner
                                guardPanel
                                heroPanel
                                todayPanel
                                if displayedMode == .crypto { cryptoPanel }
                                positionsPanel
                                DisclosureGroup(isExpanded: $showAgentsLog) {
                                    VStack(spacing: Layout.paddingM) {
                                        pipelinePanel
                                        recentLogPanel
                                    }
                                } label: {
                                    SectionHeader(title: "Catena agenti ed eventi")
                                }
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
                                if displayedMode == .intraday { councilPanel }
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
                        Text("QuantSwarm")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.accent)
                        Text("Alpha Zero")
                            .font(.subheadline.weight(.medium))
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
                        .font(.system(size: 30, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                    if let account = engine.account, let dayPnL = account.dayPnL {
                        let base = account.lastEquityValue ?? account.equityValue
                        Text(Formatters.signedAmount(dayPnL) + " $ oggi" + (base > 0 ? String(format: " · %+.2f%%", dayPnL / base * 100) : ""))
                            .font(.footnote.weight(.semibold))
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
                    StatusChip(text: engine.paperTrading ? "Paper" : "Live",
                               color: engine.paperTrading ? Theme.accent : Theme.red,
                               filled: !engine.paperTrading)
                    if engine.isRunning, engine.activeMode == .crypto, engine.cryptoLive {
                        StatusChip(text: "LIVE · 60s", color: Theme.accent, filled: true)
                    }
                    if let clock = engine.marketClock {
                        StatusChip(text: clock.isOpen ? "Mercato aperto" : "Mercato chiuso",
                                   color: clock.isOpen ? Theme.accent : Theme.amber)
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
                    StatusChip(text: "Pausa · \(pause)", color: Theme.amber)
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
        AppCard {
            VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Come si legge")
            ForEach([
                (MarketInsight.State.held, "il bot ha una posizione aperta, con lo stop sul broker"),
                (.signal, "le regole hanno trovato un ribasso in trend: decide Kimi"),
                (.trendUp, "sopra la media a 200 giorni, in attesa di un ribasso"),
                (.trendDown, "sotto la media a 200 giorni: il bot non compra"),
                (.unaffordable, "il capitale non compra 1 azione entro i limiti")
            ], id: \.0.rawValue) { state, text in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    StatusChip(text: state.rawValue, color: MarketDetailView.color(for: state))
                    Text(text).font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            }
        }
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
            panelHeader("Edge · equity delta (USD)")
            EdgeChart(points: engine.edgeHistory, color: Theme.accent)
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
                    panelHeader("Protezioni attive", color: Theme.red)
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
            panelHeader("Capitale bot · contro SPY")
            portfolioRow(
                "Impegnato",
                Formatters.amount(engine.botExposure) + (capital.map { " / " + Formatters.amount($0) } ?? "") + " USD",
                color: .white
            )
            if let summary {
                portfolioRow("Bot (\(summary.days) sedute)", pct(summary.botReturn),
                             color: summary.botReturn >= 0 ? Theme.accent : Theme.red)
                portfolioRow("SPY compra e tieni", pct(summary.benchmarkReturn), color: Theme.textSecondary)
                portfolioRow("Perdita massima dal picco", pct(summary.maxDrawdown), color: Theme.amber)
                ComparisonChart(bot: series.bot, benchmark: series.benchmark,
                                botColor: Theme.accent, benchmarkColor: Theme.textSecondary)
                    .frame(height: 150)
                Text("Verde: bot (guadagno del conto sul capitale del bot). Grigio: SPY. 100 = primo giorno registrato. Il bot investe solo in parte e sta fermo molti giorni: deve perdere meno di SPY nei cali, non batterlo nei rialzi.")
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
            panelHeader("Pagella agenti · Kimi contro regole")
            stackedRow("Regole da sole (tutti i segnali)", group(s.rules))
            stackedRow("Scelti da Kimi", group(s.chosen))
            stackedRow("Scartati da Kimi", group(s.skipped))
            stackedRow("Bocciati dal Reviewer", group(s.reviewerRejected))
            portfolioRow("Valore di Kimi", s.kimiEdge.map { String(format: "%+.2f punti", $0 * 100) } ?? "—",
                         color: (s.kimiEdge ?? 0) >= 0 ? Theme.accent : Theme.red)
            if let older = s.olderEdge, let recent = s.recentEdge {
                portfolioRow("Tendenza (prima → ora)", String(format: "%+.2f → %+.2f punti", older * 100, recent * 100),
                             color: recent >= older ? Theme.accent : Theme.amber)
            }
            portfolioRow("In corso", "\(s.pending)", color: Theme.textTertiary)
            if s.eventFlagged.count + s.eventClean.count > 0 {
                Divider().overlay(Color.gray.opacity(0.3))
                panelHeader("Filtro evento 48h · prova in ombra")
                stackedRow("Candidati CON evento (il filtro li saltava)", group(s.eventFlagged))
                stackedRow("Candidati senza evento", group(s.eventClean))
                portfolioRow(
                    "Valore del filtro",
                    s.eventFilterEdge.map { String(format: "%+.2f punti", $0 * 100) } ?? "—",
                    color: (s.eventFilterEdge ?? 0) >= 0 ? Theme.accent : Theme.amber
                )
                if s.eventFlagged.count + s.eventClean.count < 20 {
                    Text("Prova in ombra attiva: gli ingressi NON cambiano. Servono almeno 20 esiti (ora \(s.eventFlagged.count + s.eventClean.count)) prima di decidere se il filtro evento merita di diventare reale.")
                        .font(.caption)
                        .foregroundStyle(Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Valore del filtro positivo = i candidati con evento hanno reso meno: saltarli proteggeva. Negativo = il filtro avrebbe saltato occasioni buone. Decisione finale solo su questi numeri, con backtest.")
                        .font(.caption)
                        .foregroundStyle(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(verdict.0)
                .font(.caption.weight(.semibold))
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
                "Ordini eseguiti",
                stats.placed == 0 ? "—" : "\(filled)/\(stats.placed) · parziali \(stats.partial) · mai \(stats.unfilled)",
                color: .white
            )
        }
        .panelStyle(Theme.accent)
    }

    /// Consiglio degli agenti (FASE 7): report degli specialisti, divergenze,
    /// decisione del Chief e pagella retrospettiva per specialista.
    private var councilPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("Consiglio degli agenti")
            if let council = engine.lastCouncil {
                portfolioRow(
                    "Ultima seduta",
                    "\(council.symbol) · \(council.action.uppercased()) · \(council.timestamp.formatted(date: .omitted, time: .shortened))",
                    color: council.action == "buy" ? terminalGreen : Theme.textPrimary
                )
                if let approved = council.reviewerApproved {
                    portfolioRow(
                        "Contrarian (reviewer)",
                        approved ? "approva" : "respinge",
                        color: approved ? terminalGreen : Theme.red
                    )
                }
                if let note = council.divergence?.note {
                    Text(note)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(council.reports) { report in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(report.agent.title)
                                .font(.caption.weight(.bold))
                            Spacer()
                            Text(report.signal.label)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(
                                    report.signal == .long ? terminalGreen :
                                    report.signal == .short ? Theme.red : .gray
                                )
                            Text("\(Int(report.confidence * 100))%")
                                .font(.caption2)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Text(report.analysis)
                            .font(.caption)
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !report.evidence.isEmpty {
                            Text(report.evidence.prefix(3).joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(.gray)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !report.missingData.isEmpty {
                            Text("Dati mancanti: \(report.missingData.joined(separator: "; "))")
                                .font(.caption2)
                                .foregroundStyle(Theme.amber)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Invalidazione: \(report.invalidation)")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(Color.gray.opacity(0.12), in: Theme.shape(Theme.smallRadius))
                }
                Text("Decisione del Chief: \(council.rationale)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Il consiglio (tecnica, quant, notizie, fondamentali, portafoglio) si riunisce alla prossima decisione della modalità veloce.")
                    .font(.caption)
                    .foregroundStyle(.gray)
            }
            Divider().overlay(Color.gray.opacity(0.3))
            panelHeader("Pagella per specialista")
            if engine.agentScorecards.isEmpty {
                Text("Nessun parere giudicato: le pagelle arrivano dopo 30 minuti dalle prime decisioni.")
                    .font(.caption)
                    .foregroundStyle(.gray)
            } else {
                ForEach(engine.agentScorecards) { card in
                    portfolioRow(
                        card.agent.title,
                        card.hitRate.map { String(format: "%.0f%% · %d giudizi", locale: Locale(identifier: "en_US_POSIX"), $0 * 100, card.judged) }
                            ?? "\(card.hits)/\(card.judged) · servono 5 giudizi",
                        color: (card.hitRate ?? 0.5) >= 0.5 ? terminalGreen : Theme.amber
                    )
                }
                Text("Come leggerla: un parere FAVOREVOLE è vinto se il prezzo sale entro 30 minuti, un parere AVVERSO se scende. I pareri NEUTRALI e SOSPESI non si giudicano. È un'euristica di primo ordine, non una probabilità calibrata.")
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .fixedSize(horizontal: false, vertical: true)
                    .explanation()
            }
        }
        .panelStyle(Theme.accent)
    }

    private func updateBanner(_ update: UpdateChecker.Release) -> some View {
        Button {
            selectedSection = .system
        } label: {
            HStack {
                Text("Aggiornamento \(update.version) disponibile")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Sistema →").font(.caption.weight(.semibold))
            }
            .foregroundStyle(Theme.background)
            .padding(12)
            .background(Theme.accent, in: Theme.shape(Theme.smallRadius))
        }
        .buttonStyle(.plain)
    }

    private var liveBanner: some View {
        Text("Conto live · soldi veri")
            .font(.headline.weight(.bold))
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(Color.red)
            .foregroundStyle(.white)
    }

    /// BALANCE ADVISOR: consiglio automatico della modalità in base al saldo
    /// (funzione pura, nessun ordine). Visibile nel CRUSCOTTO finché la
    /// modalità configurata non coincide col consiglio; toccalo per aprire SISTEMA.
    @ViewBuilder
    private var balanceAdvisorBanner: some View {
        let hidden = Formatters.sync(engine.strategyConfig.hideAmounts)
        if let advice = BalanceAdvisor.advise(equity: engine.account?.equityValue, maskAmounts: hidden),
           engine.strategyConfig.tradingMode != advice.recommended {
            Button {
                selectedSection = .system
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "lightbulb")
                            .font(.caption.weight(.bold))
                        Text(advice.headline)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("Sistema →").font(.caption.weight(.semibold))
                    }
                    Text(advice.detail)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    if let alternative = advice.alternative {
                        Text(alternative)
                            .font(.caption.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(Theme.background)
                .padding(12)
                .background(Theme.accent.opacity(0.85), in: Theme.shape(Theme.smallRadius))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("balanceAdvisor")
        }
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
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(engineStateText)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(engineStateColor)
                Spacer()
                StatusChip(text: displayedMode.shortLabel.capitalized,
                           color: displayedMode == .intraday ? Theme.amber : Theme.accent)
            }
            Text(engine.isRunning ? engine.currentActivity : idleHint)
                .font(.callout)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if engine.isRunning, engine.activeMode?.runsOnSchedule == true, let next = engine.nextCheckAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, next.timeIntervalSince(context.date))
                    let cycle: TimeInterval = engine.activeMode == .crypto ? 60 : 15 * 60
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: 1 - min(left / cycle, 1))
                            .tint(terminalGreen)
                        Text(left > 0 ? String(format: "Prossimo controllo tra %d:%02d", Int(left) / 60, Int(left) % 60) : "Controllo in corso…")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            if engine.isRunning, engine.activeMode?.runsOnSchedule == true {
                Text(engine.activeMode == .portfolio
                     ? "PORTAFOGLIO: stop e ordini d'asta restano sul broker anche ad app chiusa. Aprila la mattina entro le 15:28 (vendita OPG della notte) e il pomeriggio entro le 21:50 (acquisto MOC)."
                     : engine.activeMode == .night
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
                        .primaryButton()
                    }
                    Button("STOP") {
                        Task { await engine.stop() }
                    }
                    .warningButton()
                    .disabled(engine.isKillInProgress)
                } else {
                    Button(engine.paperTrading ? "START" : "START LIVE") {
                        if engine.paperTrading {
                            Task { await engine.start(symbolsText: symbols, news: news) }
                        } else {
                            showLiveStartConfirmation = true
                        }
                    }
                    .primaryButton()
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
                    Text("Avviata \(Formatters.time(startedAt)) · attiva da \(elapsed(from: startedAt, to: context.date))")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(engineStateColor)
                }
            }
            }
        }
    }

    private var idleHint: String {
        switch displayedMode {
        case .portfolio:
            return "Premi START: il portafoglio divide il capitale in 30% giornaliera (ETF con stop sul broker) e 70% notte (compra in chiusura, vende all'apertura). Puoi chiudere l'app: gli ordini restano sul broker."
        case .daily:
            return "Premi START: controlla i \(DailyStrategy.basket.count) ETF, chiama Kimi solo se c'è un segnale e mette gli ordini con lo stop sul broker. Poi puoi chiudere l'app."
        case .night:
            return "Premi START: compra in chiusura S&P 500, Nasdaq-100, Russell 2000 e oro e li vende all'apertura di domani. Zero crediti Kimi. Meglio su un conto paper separato."
        case .intraday:
            return "Modalità veloce SPERIMENTALE: nei test perde. Tieni l'app aperta: chiude tutto prima della chiusura del mercato."
        case .crypto:
            return "Premi START: segue 5 coppie crypto (BTC, ETH, SOL, AVAX, LINK in USD) con rottura Donchian20 sopra la SMA200 e uscita chandelier. Aggiorna ogni 60 secondi con l'app aperta; con l'app chiusa gli stop restano sul broker, il mercato non dorme mai."
        }
    }

    private var intradayInputs: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SIMBOLI · SEPARATI DA VIRGOLA")
                .font(.caption)
                .foregroundStyle(.gray)
            TextField("SPY,QQQ", text: $symbols)
                .font(.body)
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
        return AppCard {
            VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Oggi")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                statTile(
                    "KIMI",
                    "\(engine.kimiCallsToday) chiamate",
                    spent.map { s in "\(String(format: "%.2f", s)) USD" + (limit.map { " / \(String(format: "%.2f", $0))" } ?? "") } ?? "spesa n/d",
                    engine.creditLimitHit ? Theme.red : Theme.accent
                )
                statTile("ORDINI", "\(ordersToday) inviati", "\(engine.openOrders.count) aperti sul broker", terminalGreen)
                statTile(
                    "POSIZIONI",
                    "\(engine.positions.count) aperte",
                    engine.positions.isEmpty ? "nessuna" : Formatters.signedAmount(unrealized) + " non realizzati",
                    unrealized >= 0 ? terminalGreen : .red
                )
                statTile(
                    "P&L giornata",
                    engine.account?.dayPnL.map(Formatters.signedAmount) ?? "—",
                    "equity " + Formatters.amount(engine.account?.equityValue),
                    (engine.account?.dayPnL ?? 0) >= 0 ? Theme.accent : Theme.red
                )
            }
            }
        }
    }

    private func statTile(_ title: String, _ value: String, _ detail: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.headline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Layout.paddingS)
        .background(Theme.surfaceHigh, in: Theme.shape(Theme.smallRadius))
    }

    /// La catena degli agenti: chi sta lavorando, cosa ha deciso, cosa passa avanti.
    private var pipelinePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Catena · ultimo ciclo")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            ForEach(engine.pipeline) { stage in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: stageIcon(stage.state))
                        .foregroundStyle(stageColor(stage.state))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(stage.id.title)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(stageColor(stage.state))
                            if stage.id.usesKimi {
                                StatusChip(text: "Kimi", color: Theme.textSecondary)
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
            if displayedMode != .intraday, !engine.dailyCandidates.isEmpty {
                Text("Segnali di oggi: " + engine.dailyCandidates.map { "\($0.symbol) RSI2 \(String(format: "%.1f", $0.snapshot.rsi2))" }.joined(separator: " · "))
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
        case .working: return Theme.accent
        case .done: return Theme.accent
        case .skipped: return .gray
        case .blocked: return .orange
        case .failed: return .red
        }
    }

    /// Ultime righe del registro, la più recente in alto; il registro completo
    /// è in DETTAGLI.
    private var recentLogPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ultimi eventi")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
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
                .font(.system(.caption, design: .monospaced))
            }
        }
    }

    /// Pannello report di sessione: appare solo quando esiste un file .txt
    /// pronto (STOP, HARD KILL o chiusura app). ESPORTA apre il menu di
    /// condivisione iOS; ELIMINA cancella il file dopo l'invio.
    private var reportPanel: some View {
        Group {
            if let url = engine.sessionReportURL {
                VStack(alignment: .leading, spacing: 10) {
                    panelHeader("Report di sessione · txt")
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 12) {
                        ShareLink(item: url) {
                            shareChip("Esporta / invia")
                        }
                        Button("Elimina") {
                            engine.deleteSessionReport()
                        }
                        .buttonStyle(TerminalButtonStyle(color: Theme.textSecondary))
                    }
                }
                .panelStyle(Theme.accent)
            }
        }
    }

    private var portfolioPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Portafoglio", actionLabel: "Aggiorna") {
                Task { await engine.refreshPortfolio() }
            }
            .disabled(engine.isKillInProgress)
            if let account = engine.account {
                portfolioRow("Equity", Formatters.amount(account.equityValue), color: Theme.textPrimary)
                portfolioRow("Cash", Formatters.amount(account.cashValue), color: Theme.textPrimary)
                portfolioRow("Buying power", Formatters.amount(account.buyingPowerValue), color: Theme.textPrimary)
                if let dayPnL = account.dayPnL {
                    portfolioRow(
                        "P&L oggi (totale conto)",
                        Formatters.signedAmount(dayPnL),
                        color: dayPnL >= 0 ? Theme.accent : Theme.red
                    )
                }
                if let pnl = engine.strategyPnL {
                    portfolioRow("P&L giornaliera · 30%", Formatters.signedAmount(pnl.daily.pnl),
                                 color: pnl.daily.pnl >= 0 ? Theme.accent : Theme.red)
                    portfolioRow("P&L notte · 70%", Formatters.signedAmount(pnl.night.pnl),
                                 color: pnl.night.pnl >= 0 ? Theme.accent : Theme.red)
                }
            } else {
                Text("Nessun dato: tocca Aggiorna per leggere il conto.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .panelStyle(Theme.accent)
        .task {
            await engine.refreshPortfolio()
        }
    }

    /// Riga su due livelli per valori lunghi (etichetta sopra, numeri sotto).
    private func stackedRow(_ label: String, _ value: String, color: Color = Theme.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.headline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func portfolioRow(_ label: String, _ value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.paddingS) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .padding(.vertical, 4)
    }

    /// Crediti Kimi: saldo reale, chiamate del giorno e spesa misurata dal
    /// saldo (baseline UTC − saldo attuale). Se il limite impostato in
    /// SISTEMA viene raggiunto, Kimi si ferma fino a mezzanotte UTC.
    private var kimiPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("Kimi · crediti USD")
            if let balance = engine.kimiBalance {
                portfolioRow("Disponibile", Formatters.money(balance.availableBalance), color: Theme.textPrimary)
                portfolioRow("Voucher", Formatters.money(balance.voucherBalance), color: Theme.textPrimary)
                portfolioRow(
                    "Cash",
                    Formatters.money(balance.cashBalance),
                    color: (balance.cashBalance ?? 0) < 0 ? Theme.red : Theme.textPrimary
                )
            } else {
                Text("Saldo non ancora letto: tocca Aggiorna nel pannello portafoglio.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            portfolioRow("Chiamate oggi", "\(engine.kimiCallsToday)", color: Theme.textPrimary)
            portfolioRow(
                "Spesi oggi (da saldo)",
                engine.creditsSpentToday.map { Formatters.money($0) } ?? "—",
                color: Theme.textPrimary
            )
            if engine.strategyConfig.creditLimitEnabled {
                portfolioRow(
                    "Limite giornaliero",
                    Formatters.money(engine.strategyConfig.dailyCreditLimitUSD),
                    color: engine.creditLimitHit ? Theme.red : Theme.textTertiary
                )
            }
            if engine.creditLimitHit {
                Text("Limite raggiunto: Kimi fermo fino a mezzanotte UTC. Le posizioni restano protette dal broker.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panelStyle(Theme.accent)
    }

    /// Kimi Analyst: lettura qualitativa del mercato con cadenza configurabile
    /// (solo con dati freschi), oppure su richiesta con ANALIZZA ORA.
    private var analysisPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Kimi Analyst · lettura mercato", actionLabel: "Analizza ora") {
                Task { await engine.requestAnalysisNow() }
            }
            .disabled(engine.isKillInProgress)
            if let entry = engine.latestAnalysis {
                HStack(spacing: 6) {
                    analysisChip(
                        entry.analysis.regime.replacingOccurrences(of: "_", with: " ").capitalized,
                        color: Theme.accent
                    )
                    analysisChip("Vol \(entry.analysis.volatility)", color: Theme.amber)
                    analysisChip(
                        entry.analysis.bias.capitalized,
                        color: entry.analysis.bias == "ribassista" ? Theme.red : Theme.accent
                    )
                    Spacer()
                    Text("\(Int(entry.analysis.confidence * 100))%")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.accent)
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
        .panelStyle(Theme.accent)
    }

    private func analysisChip(_ title: String, color: Color) -> some View {
        StatusChip(text: title, color: color)
    }

    /// Dataset di training: ogni decisione di Kimi (anche gli HOLD) viene
    /// salvata in SwiftData con prezzo, ATR, livelli ed esito misurato.
    private var datasetPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHeader("Training Kimi · dataset")
            portfolioRow("Campioni raccolti", "\(engine.datasetStats.total)", color: Theme.textPrimary)
            portfolioRow("Con esito valutato", "\(engine.datasetStats.completed)", color: Theme.textPrimary)
            Button("Esporta dataset JSONL") {
                engine.exportTrainingDataset()
            }
            .buttonStyle(TerminalButtonStyle(color: Theme.accent))
            .disabled(engine.datasetStats.total == 0)
            if let url = engine.datasetExportURL {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 12) {
                    ShareLink(item: url) {
                        shareChip("Invia")
                    }
                    Button("Elimina") {
                        engine.deleteDatasetExport()
                    }
                    .buttonStyle(TerminalButtonStyle(color: Theme.textSecondary))
                }
            }
            Text("Ogni decisione (anche gli HOLD) è registrata con prezzo, ATR, livelli ed esito: win/loss per i trade eseguiti, movimento del prezzo a 30 min per gli HOLD.")
                .font(.caption)
                .foregroundStyle(.gray)
                .fixedSize(horizontal: false, vertical: true)
                .explanation()
        }
        .panelStyle(Theme.accent)
    }

    /// Esportazione dei trade chiusi: vale per entrambe le modalità.
    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHeader("Esporta trade")
            Button("Esporta trade chiusi CSV") {
                engine.exportTradesCSV()
            }
            .buttonStyle(TerminalButtonStyle(color: Theme.accent))
            if let url = engine.tradesCSVURL {
                HStack(spacing: 12) {
                    ShareLink(item: url) {
                        shareChip("Invia CSV")
                    }
                    Button("Elimina") {
                        engine.deleteTradesCSV()
                    }
                    .buttonStyle(TerminalButtonStyle(color: Theme.textSecondary))
                }
            }
            Text("Un file da aprire in Numbers o Excel: data, ETF, quantità, ingresso, uscita, P&L, stop e motivazione di Kimi.")
                .font(.caption)
                .foregroundStyle(.gray)
                .fixedSize(horizontal: false, vertical: true)
                .explanation()
        }
        .panelStyle(Theme.accent)
    }

    private func panelHeader(_ title: String, color: Color = Theme.textPrimary) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(color)
    }

    /// Etichetta "notizie 48h" su una posizione aperta: SOLO interfaccia, nessun
    /// effetto sugli ordini. Se l'API notizie non risponde non compare nulla.
    private struct NewsBadge: View {
        @EnvironmentObject private var engine: QuantSwarmEngine
        let symbol: String
        @State private var count: Int?

        var body: some View {
            Group {
                if let count, count > 0 {
                    StatusChip(text: "Notizie 48h · \(count)", color: Theme.accent)
                        .accessibilityIdentifier("news-badge-\(symbol)")
                }
            }
            .task {
                if let items = await engine.headlines(symbol: symbol) { count = items.count }
            }
        }
    }

    private var positionsPanel: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Posizioni aperte")
            if engine.positions.isEmpty {
                Text("Nessuna posizione aperta.")
                    .font(.caption)
                    .foregroundStyle(.gray)
            } else {
                ForEach(engine.positions) { position in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(position.symbol)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                            Text((position.side ?? "long").uppercased())
                                .font(.caption)
                                .foregroundStyle(position.side == "short" ? .red : terminalGreen)
                            NewsBadge(symbol: position.symbol)
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
                                .font(.caption.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(position.unrealizedPLValue >= 0 ? Theme.accent : Theme.red)
                        }
                    }
                    .padding(Layout.paddingS)
                    .background(Theme.surfaceHigh, in: Theme.shape(Theme.smallRadius))
                }
            }
            }
        }
    }

    /// Pannello della modalità CRYPTO · 24/7: prezzi live, segnale per coppia e
    /// posizioni con chandelier/stop. Visibile solo in modalità crypto.
    private var cryptoPanel: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Crypto · \(CryptoStrategy.pairs.count) coppie"
                              + (engine.cryptoLive ? " · LIVE 60s" : ""))
                ForEach(CryptoStrategy.pairs, id: \.self) { pair in
                    let signal = engine.cryptoSignals[pair]
                    let price = engine.cryptoPrices[pair]
                    let position = engine.cryptoPositions.first { $0.symbol == pair }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(pair)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                            if let state = signal?.state {
                                StatusChip(text: Self.cryptoStateLabel(state), color: Self.cryptoStateColor(state))
                            }
                            Spacer()
                            Text(price.map { Formatters.money($0) + " $" } ?? "—")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.textPrimary)
                        }
                        if let position {
                            HStack {
                                Text("qty \(Formatters.qty(position.qty)) · entry \(Formatters.money(position.entryPrice)) · chandelier \(signal.flatMap { $0.chandelier }.map { Formatters.money($0) } ?? "—") · stop \(position.stopPrice.map { Formatters.money($0) } ?? "sul broker")")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    .padding(Layout.paddingS)
                    .background(Theme.surfaceHigh, in: Theme.shape(Theme.smallRadius))
                }
                Text(engine.cryptoLive
                     ? "Prezzi e segnali si aggiornano ogni 60 secondi ad app aperta."
                     : "Con l'app chiusa gli stop GTC restano sul broker: nessun controllo necessario.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private static func cryptoStateLabel(_ state: CryptoStrategy.Signal.State) -> String {
        switch state {
        case .entry: return "ENTRATA"
        case .hold: return "IN POSIZIONE"
        case .exit: return "USCITA"
        case .flat: return "FUORI"
        case .warmup: return "DATI…"
        }
    }

    private static func cryptoStateColor(_ state: CryptoStrategy.Signal.State) -> Color {
        switch state {
        case .entry, .hold: return Theme.accent
        case .exit: return Theme.red
        case .flat, .warmup: return Theme.amber
        }
    }

    private var decisionsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("Kimi Brain · ultime decisioni")
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
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(entry.decision.action.rawValue)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(actionColor(entry.decision.action))
                            Spacer()
                            Text("\(Int(entry.decision.confidence * 100))%")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(Theme.textSecondary)
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
                    .padding(.vertical, 6)
                    Divider().overlay(Theme.hairline)
                }
            }
        }
        .panelStyle(Theme.accent)
    }

    private var calibrationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("Calibrazione Kimi · affidabilità")
            if let calibration = engine.calibration {
                portfolioRow("Trade misurati", "\(calibration.samples)", color: Theme.textPrimary)
                portfolioRow(
                    "Brier score",
                    String(
                        format: "%.3f",
                        locale: Locale(identifier: "en_US_POSIX"),
                        calibration.brierScore
                    ),
                    color: calibration.brierScore < 0.25 ? Theme.accent : Theme.amber
                )
                ForEach(calibration.buckets) { bucket in
                    portfolioRow(
                        bucket.label,
                        "win \(Int(bucket.winRate * 100))% · n=\(bucket.trades)",
                        color: Theme.textPrimary
                    )
                }
            } else {
                Text("Nessun trade completato con esito: la calibrazione apparirà dopo i primi bracket chiusi.")
                    .font(.caption)
                    .foregroundStyle(.gray)
            }
        }
        .panelStyle(Theme.accent)
    }

    private var metricsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("Performance")
            if let stats = engine.performanceStats {
                portfolioRow("Trade chiusi", "\(stats.completedTrades)", color: Theme.textPrimary)
                portfolioRow(
                    "Win rate",
                    Formatters.percent(stats.winRate),
                    color: (stats.winRate ?? 0) >= 0.5 ? Theme.accent : Theme.amber
                )
                let factorText = stats.profitFactor.map {
                    String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), $0)
                } ?? "∞"
                portfolioRow(
                    "Profit factor",
                    factorText,
                    color: (stats.profitFactor ?? .infinity) >= 1 ? Theme.accent : Theme.red
                )
                portfolioRow(
                    "Expectancy / trade",
                    Formatters.signedAmount(stats.expectancy ?? 0),
                    color: (stats.expectancy ?? 0) >= 0 ? Theme.accent : Theme.red
                )
                portfolioRow(
                    "Max drawdown",
                    Formatters.amount(stats.maxDrawdown),
                    color: Theme.red
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
            panelHeader("Ordini recenti")
            if engine.recentOrders.isEmpty {
                Text("Nessun ordine inviato in questa sessione di conto.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(engine.recentOrders.prefix(8)) { order in
                    HStack(spacing: 6) {
                        Text(Formatters.time(order.submittedDate))
                            .foregroundStyle(Theme.textTertiary)
                        Text(order.side)
                            .foregroundStyle(order.side == "buy" ? Theme.accent : Theme.red)
                        Text("\(order.symbol) x\(Formatters.trimmed(order.filledQuantity ?? order.quantity ?? "0"))")
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        if let price = order.filledAveragePriceValue {
                            Text("@ \(Formatters.money(price))")
                                .monospacedDigit()
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Text(brokerStatusLabel(order.status))
                            .foregroundStyle(statusColor(order.status))
                    }
                    .font(.caption)
                }
            }
        }
        .panelStyle(Theme.accent)
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("Registro eventi")
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
                            .font(.system(.caption, design: .monospaced))
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
            panelHeader("Link rapidi")
            Link(destination: URL(string: "https://app.alpaca.markets")!) {
                linkRow("Alpaca dashboard · ordini e posizioni")
            }
            Link(destination: URL(string: "https://platform.kimi.ai")!) {
                linkRow("Kimi console · crediti e API key")
            }
        }
        .panelStyle(Theme.accent)
    }

    private func linkRow(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Spacer()
            Image(systemName: "arrow.up.right.square")
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func agentColor(_ agent: AgentKind) -> Color {
        switch agent {
        case .scout: return Theme.accent
        case .brain: return Theme.textPrimary
        case .risk: return Theme.amber
        case .system: return Theme.textTertiary
        }
    }

    private func actionColor(_ action: TradeAction) -> Color {
        switch action {
        case .buy: return Theme.accent
        case .sell: return Theme.red
        case .hold: return Theme.textTertiary
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "filled": return Theme.accent
        case "canceled", "expired", "rejected": return Theme.textTertiary
        default: return Theme.amber
        }
    }

    private var killButton: some View {
        Button {
            showKillConfirmation = true
        } label: {
            Text("HARD KILL SWITCH")
                .font(.headline.weight(.black))
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
            SectionHeader(title: "Controllo broker · Alpaca", actionLabel: "Aggiorna") {
                Task { await engine.refreshPortfolio() }
            }

            Text("Ordini aperti · \(engine.openOrders.count)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            if engine.openOrders.isEmpty {
                Text("Nessun ordine aperto.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(engine.openOrders) { order in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(order.side) \(order.symbol) x\(Formatters.trimmed(order.quantity ?? "0"))")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("\(brokerStatusLabel(order.status)) · \(brokerTypeLabel(order))")
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Button("Annulla") {
                            Task { await engine.cancelOrder(id: order.id) }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(engine.isKillInProgress)
                    }
                    .padding(.vertical, 4)
                    Divider().overlay(Theme.hairline)
                }
            }

            Text("Posizioni · \(engine.positions.count)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            if engine.positions.isEmpty {
                Text("Nessuna posizione.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(engine.positions) { position in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(position.symbol) · qty \(Formatters.trimmed(position.quantity))")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("P&L \(Formatters.signedAmount(position.unrealizedPLValue)) USD")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(position.unrealizedPLValue >= 0 ? Theme.accent : Theme.red)
                        }
                        Spacer()
                        Button("Chiudi") {
                            Task { await engine.closePosition(symbol: position.symbol) }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(engine.isKillInProgress)
                    }
                    .padding(.vertical, 4)
                    Divider().overlay(Theme.hairline)
                }
            }
            Text("Chiudi chiede ad Alpaca una chiusura a mercato della singola posizione; Annulla cancella il singolo ordine aperto. Per emergenza globale usa HARD KILL nel Cruscotto.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .explanation()
        }
        .panelStyle(Theme.accent)
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
    static func modeDescription(_ mode: TradingMode) -> String {        switch mode {
        case .portfolio:
            return "Studio 2006–oggi (run 43338377889): CAGR +5,6%, perdita max −17%, Sharpe 0,79 (1,96 sugli ultimi 3 anni). Split fisso 30% giornaliera / 70% notte, niente regole dinamiche. Stop sul broker: puoi chiudere l'app."
        case .daily:
            return "Validata dal backtest 2006–oggi: batte il caso. Stop sul broker attivo anche ad app chiusa: basta aprirla qualche minuto al giorno."
        case .night:
            return "Studio 2006–oggi: circa +8% l'anno con cali fino al −22%. Compra in chiusura, vende all'apertura. Servono due aperture al giorno: mattina entro le 15:28, pomeriggio entro le 21:50."
        case .intraday:
            return "SPERIMENTALE: nei backtest perde e non batte il caso. Richiede l'app sempre aperta; chiude tutto prima della chiusura."
        case .crypto:
            return "Studio trend 2018–oggi (run 43358878933): Donchian20 + chandelier 3 ATR sopra SMA200, +8,4%/anno, perdita max −9%, Sharpe 1,08. 5 coppie (BTC, ETH, SOL, AVAX, LINK in USD), budget 1/5 per coppia, ordini frazionati, stop sul broker attivo 24/7 anche ad app chiusa."
        }
    }

    private var buyableRow: some View {
        let snapshots = engine.basketSnapshots
        let equity = engine.account?.equityValue
        let capital = min(draft.sanitized.capitalCap, equity ?? 0)
        let risk = draft.sanitized.riskFraction
        let ok = snapshots.compactMap { symbol, s in
            RiskRules.canBuyOneShare(price: s.close, stopDistance: DailyStrategy.stopATR * s.atr14,
                                     capital: capital, freeCash: capital, riskFraction: risk) ? symbol : nil
        }.sorted()
        let missing = snapshots.keys.sorted().filter { !ok.contains($0) }
        let text: String
        if snapshots.isEmpty || equity == nil {
            text = "ETF comprabili: si calcola al primo controllo (START o CONTROLLA ORA)."
        } else {
            text = "ETF comprabili: \(ok.count)/\(snapshots.count)"
                + (missing.isEmpty ? "" : " · esclusi \(missing.joined(separator: ", "))")
        }
        let color: Color = (snapshots.isEmpty || equity == nil) ? Theme.textTertiary : (ok.count >= 8 ? Theme.accent : (ok.count >= 4 ? Theme.amber : Theme.red))
        return Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("buyableETF")
    }

    /// BALANCE ADVISOR in SISTEMA: card con il consiglio della fascia di saldo,
    /// sempre visibile (anche se coincide con la modalità già scelta).
    @ViewBuilder
    private var balanceAdvisorCard: some View {
        let hidden = Formatters.sync(engine.strategyConfig.hideAmounts)
        if let advice = BalanceAdvisor.advise(equity: engine.account?.equityValue, maskAmounts: hidden) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb")
                        .font(.caption.weight(.bold))
                    Text(advice.headline)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if draft.tradingMode == advice.recommended {
                        Text("già attiva").font(.caption.weight(.semibold))
                    }
                }
                Text(advice.detail)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if let alternative = advice.alternative {
                    Text(alternative)
                        .font(.caption.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if draft.tradingMode != advice.recommended {
                    Button("Passa a \(advice.recommended.shortLabel)") {
                        draft.tradingMode = advice.recommended
                    }
                    .font(.caption.weight(.semibold))
                }
                Text("Consiglio automatico in base al saldo: la scelta resta tua, cambia al prossimo START.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: Theme.shape(Theme.smallRadius))
            .accessibilityIdentifier("balanceAdvisorCard")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppCard {
                VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Strategia", actionLabel: "Carica modelli") {
                Task { await engine.loadAvailableKimiModels() }
            }

            Picker("Modalità", selection: $draft.tradingMode) {
                ForEach(TradingMode.selectableModes, id: \.self) { mode in
                    Text(mode.shortLabel).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("La modalità cambia al prossimo START.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                InfoButton(text: Self.modeDescription(draft.tradingMode) + " " + (draft.tradingMode != .intraday
                    ? "In giornaliera Kimi viene chiamato solo se un ETF è in trend (sopra SMA200) con RSI2 sotto 10. Nessun segnale = zero crediti."
                    : "Nella veloce Kimi decide alla chiusura della candela; il filtro gratuito pre-Kimi blocca le chiamate a vuoto."))
            }

            // BALANCE ADVISOR in SISTEMA: consiglio in base al saldo reale.
            balanceAdvisorCard

            Group {
                // Il numero che conta, scritto in chiaro: quanto usa il bot adesso.
                let equityNow = engine.account?.equityValue
                let used = equityNow.map { min(draft.sanitized.capitalCap, $0) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Capitale usato dal bot")
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
                    .font(.callout.weight(.semibold))
                    .tint(Theme.accent)
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
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
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
                }
            }

            // Impostazioni della sola modalità veloce: in giornaliera non servono.
            if draft.tradingMode == .intraday {
                AppCard {
                    VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Modalità veloce")
            Stepper("Ciclo decisioni: \(draft.decisionIntervalSeconds)s", value: $draft.decisionIntervalSeconds, in: 30...120, step: 5)
            Stepper(
                "Validità analisi Analyst: \(String(format: "%.1f", draft.analysisIntervalMinutes)) min",
                value: $draft.analysisIntervalMinutes,
                in: 2...15,
                step: 1
            )
            Text("Kimi decide alla chiusura della candela")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
            Picker("Timeframe decisione", selection: $draft.decisionTimeframeMinutes) {
                Text("1 min").tag(1)
                Text("5 min").tag(5)
                Text("15 min").tag(15)
            }
            .pickerStyle(.segmented)

            Toggle("Filtro gratuito pre-Kimi", isOn: $draft.kimiFilterEnabled)
                .font(.callout.weight(.semibold))
                .tint(Theme.accent)
            Text("Kimi viene chiamato solo se scatta un trigger in codice (setup long). Nessun trigger = zero crediti spesi.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .explanation()
                    }
                }
            }

            AppCard {
                VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Kimi")

            Toggle("Limite crediti giornaliero", isOn: $draft.creditLimitEnabled)
                .font(.callout.weight(.semibold))
                .tint(Theme.accent)
            Stepper(
                "Limite spesa: \(String(format: "%.2f", draft.dailyCreditLimitUSD)) USD/giorno",
                value: $draft.dailyCreditLimitUSD,
                in: 0.10...50.0,
                step: 0.10
            )
            .disabled(!draft.creditLimitEnabled)

            Text("Modello Kimi")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
            TextField("kimi-k3.1-pro-highspeed", text: $draft.kimiModel)
                .font(.caption)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(Theme.surfaceHigh, in: Theme.shape(Theme.smallRadius))
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
                    .foregroundStyle(Theme.red)
            }

            Toggle("Riprendi sessione al riavvio", isOn: $draft.autoResumeOnLaunch)
                .font(.callout.weight(.semibold))
                .tint(Theme.accent)

            Toggle("Promemoria 15:30 New York (21:30 Italia)", isOn: $draft.dailyReminder)
                .font(.callout.weight(.semibold))
                .tint(Theme.accent)
            Text("Lun–ven, mezz'ora prima della chiusura USA: ti ricorda di aprire l'app per la modalità giornaliera. iOS non permette di leggere le chiavi protette da Face ID in background, quindi l'app non controlla da sola: ti avvisa.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .explanation()
                }
            }

            AppCard {
                VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "App")

            Toggle("Nascondi saldo", isOn: $draft.hideAmounts)
                .font(.callout.weight(.semibold))
                .tint(Theme.accent)
            Text("Saldo, P&L e capitale diventano ••••• (anche con l'occhio in alto). I prezzi degli ETF restano visibili.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .explanation()

            Toggle("Modalità Pro", isOn: $draft.proMode)
                .font(.callout.weight(.semibold))
                .tint(Theme.accent)
            Text("Per chi conosce già l'app: toglie spiegazioni, legende e testi d'aiuto. Restano numeri, stati, avvisi e pulsanti.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Importi nel widget", isOn: $draft.widgetShowsAmounts)
                .font(.callout.weight(.semibold))
                .tint(Theme.accent)
            Text("Spento: il widget mostra solo lo stato, senza equity e P&L (il widget si vede anche a telefono bloccato).")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .explanation()
                }
            }

            Button("Applica impostazioni") {
                engine.updateStrategyConfig(draft)
            }
            .primaryButton()

            AppCard {
                VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Stato")
                let config = engine.strategyConfig
                settingRow("Versione", AppVersion.text)
                settingRow("Aggiornamenti", engine.updateStatus)
                let store = UpdateChecker.currentStore()
                HStack(spacing: 10) {
                    if let update = engine.availableUpdate, let url = UpdateChecker.installURL(for: update, store: store) {
                        Button("Aggiorna a \(update.version)") { openURL(url) }
                            .buttonStyle(TerminalButtonStyle(color: Theme.accent))
                    } else {
                        Button("Controlla aggiornamenti") { Task { await engine.checkForUpdates() } }
                            .buttonStyle(TerminalButtonStyle(color: Theme.accent))
                    }
                }
                if store != .download, let source = UpdateChecker.storeSourceURL(for: store) {
                    Button("Aggiungi sorgente a \(store.name)") { openURL(source) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                Text(store.helpText)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .explanation()
                settingRow("Modalità", config.tradingMode.label)
                settingRow("Capitale bot", (config.capitalLimitEnabled
                    ? "limitato a \(String(format: "%.0f", config.botCapitalUSD)) USD"
                    : "tutto il conto") + " · impegnati \(String(format: "%.0f", engine.botExposure)) USD")
                settingRow("Stato applicato", "rischio \(String(format: "%.2f", config.riskPerTradePercent))% · max \(config.maxOpenPositions) · stop giorno \(String(format: "%.1f", config.dailyStopPercent))%")
                settingRow("Modello attivo", config.kimiModel)
                if config.tradingMode == .night {
                    settingRow("Paniere", "S&P 500 · Nasdaq-100 · Russell 2000 · oro, peso uguale, originale o gemello secondo il saldo")
                    settingRow("Ordini", "acquisto in asta di chiusura (MOC), vendita in asta di apertura (OPG)")
                    settingRow("Kimi", "non usato: 0 crediti")
                    settingRow("Aperture", "mattina entro le 15:28 · pomeriggio 15:30–21:50 (ora italiana)")
                } else if config.tradingMode == .portfolio {
                    let budgets = PortfolioSplit.budgets(equity: engine.account?.equityValue, capitalCap: config.sanitized.capitalCap)
                    settingRow("Divisione", "30% giornaliera · 70% notte, ribilanciata a ogni ciclo sull'equity corrente (split fisso, studio run 43338377889)")
                    settingRow("Budget giornaliera ora", "\(Formatters.amount(budgets.daily)) USD")
                    settingRow("Budget notte ora", "\(Formatters.amount(budgets.night)) USD")
                    settingRow("Ordini", "giornaliera: limite + stop GTC sul broker · notte: MOC in chiusura / OPG all'apertura")
                    settingRow("Kimi", "solo la giornaliera, e solo se c'è un segnale")
                } else if config.tradingMode == .daily {
                    settingRow("Segnali", "15 ETF · sopra SMA200 e RSI2 < 10 · Kimi solo se c'è un segnale")
                    settingRow("Ordini", "limite + stop \(String(format: "%.1f", DailyStrategy.stopATR)) ATR + target \(String(format: "%.0f", DailyStrategy.takeProfitATR)) ATR, GTC sul broker")
                    settingRow("Uscite", "chiusura > SMA5 o \(DailyStrategy.maxHoldingDays) giorni, solo a mercato aperto")
                    settingRow("Dati", "barre giornaliere SIP (consolidate), ripiego IEX")
                    settingRow("Controlli", "subito, ogni 15 min ad app aperta e a ogni riapertura")
                } else if config.tradingMode == .crypto {
                    let equity = engine.account?.equityValue
                    let budget = min(equity ?? config.sanitized.capitalCap, config.sanitized.capitalCap)
                    settingRow("Paniere", CryptoStrategy.pairs.joined(separator: " · ") + ", peso uguale")
                    settingRow("Budget per coppia", Formatters.amount(budget / Double(CryptoStrategy.pairs.count)) + " USD (1/5 del capitale)")
                    settingRow("Regole", "sopra SMA200, rottura Donchian20 · uscita chandelier 3 ATR (studio run 43358878933)")
                    settingRow("Ordini", "frazionati (8 decimali), senza bracket: market, poi stop_limit GTC sul broker")
                    settingRow("Rischio", "blocco drawdown 10% dal picco · stop sul broker attivo anche ad app chiusa")
                    settingRow("Kimi", "non usato: 0 crediti · refresh prezzi e segnali ogni 60 secondi ad app aperta")
                } else {
                    settingRow("Decisioni Kimi", "chiusura candela \(config.decisionTimeframeMinutes)m · filtro \(config.kimiFilterEnabled ? "on" : "off")")
                    settingRow("Stream dati", SystemLimits.marketStreamHost)
                    settingRow("Guard chiusura", "no nuovi trade negli ultimi 15 min")
                    settingRow("Flat by close", "chiude le posizioni della veloce a T-10 min")
                    settingRow("Foreground", "motore solo ad app aperta: in background nessun ordine")
                }
                settingRow("Pause automatiche", "rete assente o batteria < 20%")
                Button("Ricalibra equity") {
                    engine.recalibrateEquityBaseline()
                }
                .secondaryButton()
                Text("Se il conto paper è stato rigenerato o c'è un prelievo, riallinea il picco del drawdown all'equity corrente: il calo fittizio non deve fermare il bot.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .explanation()
            Text(engine.strategyConfig.tradingMode.runsOnSchedule
                 ? "Nessuna app iOS resta attiva 24/7: per questo la giornaliera mette stop e target sul broker, attivi anche ad app chiusa. Basta aprirla una volta al giorno a mercato aperto."
                 : "Nessuna app iOS resta attiva 24/7: la veloce lavora solo ad app aperta con lo schermo acceso; in background nessun nuovo ordine, le posizioni restano protette dalle gambe stop/target sul broker.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .explanation()
                }
            }
        }
        .onAppear {
            draft = engine.strategyConfig
        }
        .onChange(of: engine.strategyConfig) { _, newValue in
            draft = newValue
        }
    }

    private func settingRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
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
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, Layout.paddingS)
            .background(Theme.surfaceHigh, in: Theme.shape(Theme.smallRadius))
            .foregroundStyle(color)
            .overlay(Theme.shape(Theme.smallRadius).strokeBorder(Theme.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private extension View {
    func panelStyle(_ color: Color) -> some View {
        self
            .padding(Layout.paddingM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: Theme.shape())
    }
}

/// Stato di un ordine Alpaca in italiano leggibile (invece di "held"/"new").
private func brokerStatusLabel(_ status: String) -> String {
    switch status {
    case "new", "accepted", "pending_new", "held": return "in attesa"
    case "partially_filled": return "in parte eseguito"
    case "filled": return "eseguito"
    case "canceled": return "annullato"
    case "rejected": return "rifiutato"
    case "expired": return "scaduto"
    case "done_for_day": return "chiuso per oggi"
    default: return status
    }
}

/// Tipo e prezzo dell'ordine (stop 47,85 / limite 51,40) invece di "n/d".
private func brokerTypeLabel(_ order: AlpacaOrder) -> String {
    switch order.type {
    case "stop": return "stop \(Formatters.money(order.stopPriceValue ?? 0))"
    case "stop_limit": return "stop limite \(Formatters.money(order.stopPriceValue ?? 0))"
    case "limit": return "limite \(Formatters.money(order.limitPriceValue ?? 0))"
    case "market": return "mercato"
    default: return order.type
    }
}

/// Etichetta per ShareLink: stesso look del pulsante secondario.
private func shareChip(_ title: String) -> some View {
    Text(title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Theme.accent)
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, Layout.paddingM)
        .background(Theme.surfaceHigh, in: Theme.shape())
        .overlay(Theme.shape().strokeBorder(Theme.hairline, lineWidth: 1))
}
