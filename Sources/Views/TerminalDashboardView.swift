import SwiftUI

struct TerminalDashboardView: View {
    @EnvironmentObject private var engine: QuantSwarmEngine
    @State private var symbols = "SPY"
    @State private var news = ""
    @State private var showKillConfirmation = false

    private let terminalGreen = Color(red: 0.1, green: 1.0, blue: 0.55)

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        statusPanel
                        portfolioPanel
                        kimiPanel
                        positionsPanel
                        decisionsPanel
                        edgePanel
                        controlPanel
                        ordersPanel
                        settingsPanel
                        logPanel
                        killButton
                    }
                    .padding()
                }
                .refreshable {
                    await engine.refreshPortfolio()
                }
            }
            .navigationTitle("QUANTSWARM")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("LOGOUT") {
                        Task { await engine.logout() }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(terminalGreen)
                    .disabled(engine.isKillInProgress)
                }
            }
            .alert("HARD KILL SWITCH", isPresented: $showKillConfirmation) {
                Button("ANNULLA", role: .cancel) {}
                Button("LIQUIDA TUTTO", role: .destructive) {
                    Task { await engine.hardKill() }
                }
            } message: {
                Text("Ferma il motore, cancella tutti gli ordini e richiede ad Alpaca la chiusura a mercato di tutte le posizioni del conto configurato.")
            }
        }
    }

    private var statusPanel: some View {
        HStack {
            Circle()
                .fill(engine.isRunning ? terminalGreen : .gray)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 4) {
                Text(engine.paperTrading ? "PAPER ENVIRONMENT" : "LIVE CAPITAL")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(engine.paperTrading ? terminalGreen : .red)
                Text(engine.statusMessage)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.gray)
                if let clock = engine.marketClock {
                    Text(
                        clock.isOpen
                            ? "MERCATO APERTO · chiude \(formatDate(clock.nextCloseDate))"
                            : "MERCATO CHIUSO · apre \(formatDate(clock.nextOpenDate))"
                    )
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(clock.isOpen ? terminalGreen : .orange)
                }
            }
            Spacer()
        }
        .panelStyle(terminalGreen)
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "n/d" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var edgePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EDGE · EQUITY DELTA USD")
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(terminalGreen)
            EdgeChart(points: engine.edgeHistory, color: terminalGreen)
                .frame(height: 180)
        }
        .panelStyle(terminalGreen)
    }

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    .frame(height: 80)
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
        }
        .panelStyle(terminalGreen)
    }

    private var portfolioPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PORTAFOGLIO · USD")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(terminalGreen)
                Spacer()
                Button("AGGIORNA") {
                    Task { await engine.refreshPortfolio() }
                }
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(terminalGreen)
                .disabled(engine.isKillInProgress)
            }
            if let account = engine.account {
                portfolioRow("EQUITY", money(account.equityValue), color: .white)
                portfolioRow("CASH", money(account.cashValue), color: .white)
                portfolioRow("BUYING POWER", money(account.buyingPowerValue), color: .white)
                if let dayPnL = account.dayPnL {
                    portfolioRow(
                        "P&L OGGI",
                        signedMoney(dayPnL),
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

    private var kimiPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("KIMI ACCOUNT · CREDITI USD")
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(brainColor)
            if let balance = engine.kimiBalance {
                portfolioRow("DISPONIBILE", money(balance.availableBalance), color: .white)
                portfolioRow("VOUCHER", money(balance.voucherBalance), color: .white)
                portfolioRow(
                    "CASH",
                    money(balance.cashBalance),
                    color: (balance.cashBalance ?? 0) < 0 ? .red : .white
                )
            } else {
                Text("Saldo non ancora letto: tocca AGGIORNA nel pannello portafoglio.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.gray)
            }
        }
        .panelStyle(brainColor)
    }

    private var positionsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("POSIZIONI APERTE")
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(terminalGreen)
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
                            Text("qty \(trimmed(position.quantity))")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.gray)
                        }
                        HStack {
                            Text(
                                "entry \(money(position.averageEntryPriceValue)) → ora \(money(position.currentPriceValue))"
                            )
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.gray)
                            Spacer()
                            Text(signedMoney(position.unrealizedPLValue))
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
            Text("KIMI BRAIN · ULTIME DECISIONI")
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(brainColor)
            if engine.decisions.isEmpty {
                Text("Nessuna decisione ancora: servono \(SystemLimits.atrPeriod) barre e motore avviato.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.gray)
            } else {
                ForEach(engine.decisions.suffix(5).reversed()) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
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
                                .foregroundStyle(brainColor)
                        }
                        Text(entry.decision.rationale)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                        if entry.decision.action != .hold {
                            Text(
                                "entry \(money(entry.decision.entryPrice)) · stop \(money(entry.decision.stopLoss)) · target \(money(entry.decision.takeProfit))"
                            )
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.gray)
                        }
                    }
                    .padding(8)
                    .background(Color(white: 0.04))
                    .overlay(Rectangle().stroke(brainColor.opacity(0.25), lineWidth: 1))
                }
            }
        }
        .panelStyle(brainColor)
    }

    private var ordersPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ORDINI RECENTI")
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(terminalGreen)
            if engine.recentOrders.isEmpty {
                Text("Nessun ordine inviato in questa sessione di conto.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.gray)
            } else {
                ForEach(engine.recentOrders.prefix(8)) { order in
                    HStack(spacing: 6) {
                        Text(order.submittedDate?.formatted(date: .omitted, time: .standard) ?? "--:--")
                            .foregroundStyle(.gray)
                        Text(order.side.uppercased())
                            .foregroundStyle(order.side == "buy" ? terminalGreen : .red)
                        Text("\(order.symbol) x\(trimmed(order.filledQuantity ?? order.quantity ?? "0"))")
                            .foregroundStyle(.white)
                        Spacer()
                        if let price = order.filledAveragePriceValue {
                            Text("@ \(money(price))")
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

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CONFIG SISTEMA")
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(terminalGreen)
            settingRow("MODELLO KIMI", SystemLimits.kimiModel)
            settingRow("API KIMI", SystemLimits.kimiAPIHost)
            settingRow(
                "BROKER",
                engine.paperTrading ? "paper-api.alpaca.markets" : "api.alpaca.markets"
            )
            settingRow("STREAM DATI", SystemLimits.marketStreamHost)
            settingRow("RISCHIO MAX / TRADE", "1% equity")
            settingRow("KELLY", "frazionato /4")
            settingRow("LATENZA MAX ORDINI", "150 ms")
            settingRow("DEVIAZIONE MAX PREZZO", "0,05%")
            settingRow("ATR", "\(SystemLimits.atrPeriod) barre da 1 min")
            settingRow("CICLO DECISIONI", "\(SystemLimits.decisionIntervalSeconds) s")
        }
        .panelStyle(terminalGreen)
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

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AGENT SWARM FEED")
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(terminalGreen)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(engine.logs) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
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
                .frame(height: 260)
                .onChange(of: engine.logs.count) { _, _ in
                    if let id = engine.logs.last?.id {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
        }
        .panelStyle(terminalGreen)
    }

    private var brainColor: Color {
        Color(red: 0.35, green: 0.85, blue: 1.0)
    }

    private func agentColor(_ agent: AgentKind) -> Color {
        switch agent {
        case .scout: return terminalGreen
        case .brain: return brainColor
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

    private func money(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(
            format: "%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
    }

    private func signedMoney(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : "-"
        return sign + money(abs(value))
    }

    private func trimmed(_ raw: String) -> String {
        guard let value = Double(raw) else { return raw }
        return value == value.rounded()
            ? String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
            : String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
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
