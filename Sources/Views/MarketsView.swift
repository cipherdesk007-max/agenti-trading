import Charts
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// Livelli reali sul broker per un simbolo: prezzo di carico, stop, target,
/// ingresso in attesa. Letti da posizioni e ordini aperti (gambe comprese).
struct BrokerLevels: Equatable {
    var entry: Double?
    var stop: Double?
    var target: Double?
    var pendingEntry: Double?

    @MainActor
    static func from(_ engine: QuantSwarmEngine, symbol: String) -> BrokerLevels {
        let s = symbol.uppercased()
        var levels = BrokerLevels()
        levels.entry = engine.positions.first { $0.symbol.uppercased() == s }?.averageEntryPriceValue
        for order in engine.openOrders.flatMap(\.withLegs) where order.symbol.uppercased() == s {
            if order.side == "sell", order.type == "stop" || order.type == "stop_limit" {
                levels.stop = order.stopPriceValue ?? levels.stop
            } else if order.side == "sell", order.type == "limit" {
                levels.target = order.limitPriceValue ?? levels.target
            } else if order.side == "buy", order.parentOrderId == nil {
                levels.pendingEntry = order.limitPriceValue ?? levels.pendingEntry
            }
        }
        return levels
    }
}

// MARK: - Griglia "dove opera" (CRUSCOTTO)

struct MarketsPanel: View {
    @EnvironmentObject private var engine: QuantSwarmEngine
    @State private var selected: String?

    private var isIntraday: Bool {
        (engine.activeMode ?? engine.strategyConfig.tradingMode) == .intraday
    }

    private var capital: Double? {
        engine.account.map { min(engine.strategyConfig.sanitized.capitalCap, $0.equityValue) }
    }

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isIntraday ? "Mercati · modalità veloce" : "Mercati · 15 ETF")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(isIntraday || engine.marketBarsDate == nil
                     ? "tocca per il grafico"
                     : "dati \(engine.marketBarsDate!.formatted(date: .omitted, time: .shortened)) · tocca")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            if isIntraday {
                intradayGrid
            } else if engine.marketBars.isEmpty {
                Text("I grafici compaiono dopo il primo controllo (START o CONTROLLA ORA).")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                dailyGrid
            }
        }
        }
        .onAppear {
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if selected == nil, let i = args.firstIndex(of: "-QSMarket"), i + 1 < args.count {
                let symbol = args[i + 1]
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    selected = symbol
                }
            }
            #endif
        }
        .sheet(item: Binding(get: { selected.map(SymbolID.init) }, set: { selected = $0?.id })) { item in
            MarketDetailView(symbol: item.id, intraday: isIntraday)
                .environmentObject(engine)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 8), count: 3) }

    private var dailyGrid: some View {
        let held = Set(engine.positions.map { $0.symbol.uppercased() })
        let risk = engine.strategyConfig.sanitized.riskFraction
        let insights = DailyStrategy.basket.map { symbol in
            MarketInsight.evaluate(symbol: symbol, bars: engine.marketBars[symbol] ?? [], held: held.contains(symbol),
                                   capital: capital, riskFraction: risk)
        }
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(insights, id: \.symbol) { insight in
                Button { selected = insight.symbol } label: { MarketTile(insight: insight) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("market-\(insight.symbol)")
            }
        }
    }

    private var intradayGrid: some View {
        Group {
            if engine.intradaySymbols.isEmpty {
                Text("Avvia la modalità veloce: qui compaiono i simboli scelti con le candele \(engine.strategyConfig.sanitized.decisionTimeframeMinutes)m.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(engine.intradaySymbols, id: \.self) { symbol in
                            let candles = engine.intradayCandles(for: symbol)
                            let last = engine.intradayLastPrice(for: symbol) ?? candles.last?.close
                            let first = candles.first?.open
                            let change = (last != nil && first != nil && first! > 0) ? last! / first! - 1 : nil
                            Button { selected = symbol } label: {
                                MarketTile(insight: MarketInsight(
                                    symbol: symbol, state: candles.isEmpty ? .noData : .trendUp, close: last,
                                    dayChange: change, snapshot: nil, reason: ""
                                ), intraday: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

private struct SymbolID: Identifiable { let id: String }

private struct MarketTile: View {
    let insight: MarketInsight
    var intraday = false

    private var color: Color { MarketDetailView.color(for: insight.state) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(insight.symbol)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text(insight.close.map { String(format: "%.2f", $0) } ?? "—")
                .tabularNumber(.caption, .semibold)
                .foregroundStyle(Theme.textSecondary)
            if let change = insight.dayChange {
                Text(String(format: "%+.2f%%", change * 100))
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.signed(change))
            }
            StatusChip(text: intraday ? (insight.state == .noData ? "In attesa" : "Stream") : insight.state.rawValue.capitalized,
                       color: color)
        }
        .padding(Layout.paddingS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceHigh, in: Theme.shape(Theme.smallRadius))
    }
}

// MARK: - Dettaglio: candele, medie, livelli

/// Intervallo del grafico. Tutti funzionano anche a mercato chiuso (storico
/// del broker); LIVE sono le candele dello stream della modalità veloce.
enum ChartInterval: String, CaseIterable, Identifiable {
    case live = "LIVE"
    case day = "1G"
    case hour = "1H"
    case m15 = "15M"
    case m5 = "5M"

    var id: String { rawValue }
    /// Timeframe Alpaca e giorni di storico da chiedere.
    var request: (timeframe: String, days: Int)? {
        switch self {
        case .live: return nil
        case .day: return ("1Day", 450)
        case .hour: return ("1Hour", 30)
        case .m15: return ("15Min", 10)
        case .m5: return ("5Min", 4)
        }
    }
    var slowPeriod: Int { self == .day ? 200 : 20 }
    var slowLabel: String { self == .day ? "SMA200" : "MEDIA 20" }
    var visible: Int { self == .day ? 90 : 80 }
}

struct MarketDetailView: View {
    @EnvironmentObject private var engine: QuantSwarmEngine
    @Environment(\.dismiss) private var dismiss
    let symbol: String
    let intraday: Bool
    @State private var interval: ChartInterval
    @State private var fetched: [Candle]?
    @State private var loading = false
    @State private var news: [NewsHeadline]?
    @State private var showTranslation = false

    init(symbol: String, intraday: Bool) {
        self.symbol = symbol
        self.intraday = intraday
        _interval = State(initialValue: intraday ? .live : .day)
    }

    private var intervals: [ChartInterval] {
        intraday ? [.live, .m5, .m15, .hour, .day] : [.day, .hour, .m15, .m5]
    }

    static func color(for state: MarketInsight.State) -> Color {
        switch state {
        case .held: return Theme.green
        case .signal: return Theme.cyan
        case .unaffordable: return Theme.amber
        case .trendUp: return Theme.textSecondary
        case .trendDown: return Theme.red
        case .noData: return Theme.textTertiary
        }
    }

    /// Barre giornaliere del paniere già scaricate dal controllo (subito, anche dalla cache).
    private var basketDaily: [Candle]? {
        let bars = engine.marketBars[symbol] ?? []
        return bars.isEmpty ? nil : bars
    }

    private var allCandles: [Candle] {
        switch interval {
        case .live: return engine.intradayCandles(for: symbol)
        case .day: return basketDaily ?? fetched ?? []
        default: return fetched ?? []
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Intervallo", selection: $interval) {
                        ForEach(intervals) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("interval-picker")
                    if interval == .live {
                        TimelineView(.periodic(from: .now, by: 5)) { _ in content }
                    } else {
                        content
                    }
                }
                .padding()
            }
            .task { news = await engine.headlines(symbol: symbol) }
            .task(id: interval) {
                fetched = nil
                guard let request = interval.request, !(interval == .day && basketDaily != nil) else { return }
                loading = true
                fetched = await engine.chartCandles(symbol: symbol, timeframe: request.timeframe, days: request.days)
                loading = false
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(symbol)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Chiudi") { dismiss() }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        let candles = allCandles
        let visibleCount = interval.visible
        let closes = candles.map(\.close)
        let slow = MarketInsight.movingAverage(closes, period: interval.slowPeriod)
        let fast = MarketInsight.movingAverage(closes, period: 5)
        // Spiegazione della regola solo sul giornaliero dei 15 ETF (è lì che decide).
        let explains = interval == .day && DailyStrategy.basket.contains(symbol.uppercased())
        let start = max(candles.count - visibleCount, 0)
        let levels = BrokerLevels.from(engine, symbol: symbol)
        let held = engine.positions.contains { $0.symbol.uppercased() == symbol.uppercased() }
        let capital = engine.account.map { min(engine.strategyConfig.sanitized.capitalCap, $0.equityValue) }
        let insight = MarketInsight.evaluate(symbol: symbol, bars: candles, held: held, capital: capital,
                                             riskFraction: engine.strategyConfig.sanitized.riskFraction)

        // Prezzo in alto sempre visibile: ultima candela dell'intervallo, oppure
        // ultimo prezzo noto del simbolo (stream o barre giornaliere) quando le
        // candele sono in caricamento o non sono arrivate.
        let fallbackPrice = engine.intradayLastPrice(for: symbol) ?? engine.marketBars[symbol]?.last?.close
        if explains {
            HStack {
                StatusChip(text: insight.state.rawValue.capitalized,
                           color: Self.color(for: insight.state),
                           filled: insight.state == .held)
                Spacer()
                if let close = insight.close ?? fallbackPrice {
                    Text(String(format: "%.2f", close))
                        .tabularNumber(.title3, .heavy)
                        .accessibilityIdentifier("chart-price")
                }
            }
            Text(insight.reason)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let price = candles.last?.close ?? fallbackPrice {
            // Sugli altri intervalli (1H, 15M, 5M, live) il prezzo resta sempre
            // visibile: ultima candela dell'intervallo e variazione sulla precedente.
            let previous = candles.count > 1 ? candles[candles.count - 2].close : candles.last?.close
            let change = (previous ?? 0) > 0 ? (price / previous! - 1) * 100 : nil
            HStack(alignment: .firstTextBaseline) {
                Text("Ultimo prezzo · \(interval.rawValue)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if let change {
                    Text(String(format: "%+.2f%%", change))
                        .tabularNumber(.footnote, .semibold)
                        .foregroundStyle(change >= 0 ? Theme.green : Theme.red)
                }
                Text(String(format: "%.2f", price))
                    .tabularNumber(.title3, .heavy)
                    .accessibilityIdentifier("chart-price")
            }
        }

        if candles.isEmpty {
            HStack(spacing: 8) {
                if loading { ProgressView().tint(Theme.green) }
                Text(loading ? "Carico le candele \(interval.rawValue) dal broker…"
                     : interval == .live ? "In attesa delle prime candele dallo stream."
                     : "Candele non disponibili: controlla la connessione e le chiavi Alpaca.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        } else {
            CandleChart(candles: Array(candles[start...]),
                        slow: Array(slow[start...]), fast: Array(fast[start...]),
                        slowLabel: interval.slowLabel, fastLabel: "MEDIA 5",
                        levels: levels)
                .frame(height: 300)
                .themedCard(Theme.green, padding: 10)

            legend(slowLabel: interval.slowLabel, levels: levels)
            if let last = candles.last {
                Text("Ultima candela: \(last.timestamp.formatted(date: .abbreviated, time: interval == .day ? .omitted : .shortened))")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }

        newsSection

        if let snap = insight.snapshot, explains {
            VStack(alignment: .leading, spacing: 8) {
                row("Chiusura", snap.close)
                row("Media 200 giorni", snap.sma200)
                row("Media 5 giorni", snap.sma5)
                row("RSI 2", snap.rsi2, digits: 1)
                row("ATR 14 (oscillazione media)", snap.atr14)
                row("Stop se compra (2,5 ATR)", snap.close - DailyStrategy.stopATR * snap.atr14)
                row("Target se compra (2 ATR)", snap.close + DailyStrategy.takeProfitATR * snap.atr14)
            }
            .themedCard(Theme.cyan)

            Text("Regola: compra se sopra la media a 200 giorni e RSI2 sotto 10 (ribasso forte in un trend che sale). Esce sopra la media a 5 giorni, dopo \(DailyStrategy.maxHoldingDays) sedute, allo stop o al target.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .explanation()
        }
    }

    /// Notizie Benzinga delle ultime 48 ore (le stesse che riceve Kimi).
    @ViewBuilder private var newsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("NOTIZIE · 48 ORE")
                    .font(.system(.caption, design: .monospaced, weight: .heavy))
                    .foregroundStyle(Theme.cyan)
                Spacer()
                if let news, !news.isEmpty, translationAvailable {
                    Button {
                        showTranslation = true
                    } label: {
                        Label("TRADUCI", systemImage: "character.bubble")
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(Theme.cyan)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let news {
                if news.isEmpty {
                    Text("Nessuna notizia su \(symbol) nelle ultime 48 ore.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(news.prefix(8)) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.headline).font(.footnote).foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened) + " · " + item.source.capitalized)
                                .font(.caption2).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            } else {
                Text("Notizie non disponibili (connessione o chiavi Alpaca).")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .themedCard(Theme.cyan)
        .modifier(NewsTranslation(isPresented: $showTranslation,
                                  text: (news ?? []).prefix(8).map(\.headline).joined(separator: "\n\n")))
    }

    /// Traduzione di Apple (sul telefono, gratis, niente crediti): iOS 17.4+.
    private var translationAvailable: Bool {
        if #available(iOS 17.4, *) { return true }
        return false
    }

    private func legend(slowLabel: String, levels: BrokerLevels) -> some View {
        HStack(spacing: 12) {
            legendItem(Theme.amber, slowLabel)
            legendItem(Theme.cyan, "MEDIA 5")
            if levels.entry != nil || levels.pendingEntry != nil { legendItem(.white, "INGRESSO") }
            if levels.stop != nil { legendItem(Theme.red, "STOP") }
            if levels.target != nil { legendItem(Theme.green, "TARGET") }
        }
        .font(.system(.caption2, design: .monospaced, weight: .bold))
    }

    private func legendItem(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 12, height: 3)
            Text(text).foregroundStyle(Theme.textSecondary)
        }
    }

    private func row(_ label: String, _ value: Double, digits: Int = 2) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(String(format: "%.\(digits)f", value)).foregroundStyle(Theme.textPrimary).monospacedDigit()
        }
        .font(.system(.caption, design: .monospaced, weight: .semibold))
    }
}

/// Grafico a candele con due medie e i livelli del broker.
private struct CandleChart: View {
    let candles: [Candle]
    let slow: [Double?]
    let fast: [Double?]
    let slowLabel: String
    let fastLabel: String
    let levels: BrokerLevels

    /// Corpo della candela: circa il 60% dello spazio di una seduta.
    private var bodyWidth: CGFloat { CGFloat(max(1.5, min(8, 300.0 / Double(max(candles.count, 1)) * 0.6))) }

    private var domain: ClosedRange<Double> {
        var values = candles.flatMap { [$0.low, $0.high] }
        values += slow.compactMap { $0 } + fast.compactMap { $0 }
        values += [levels.entry, levels.stop, levels.target, levels.pendingEntry].compactMap { $0 }
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        let pad = max((hi - lo) * 0.06, 0.01)
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        Chart {
            ForEach(Array(candles.enumerated()), id: \.offset) { index, candle in
                let up = candle.close >= candle.open
                RuleMark(x: .value("Seduta", index), yStart: .value("Min", candle.low), yEnd: .value("Max", candle.high))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle((up ? Theme.green : Theme.red).opacity(0.8))
                RectangleMark(x: .value("Seduta", index),
                              yStart: .value("Apertura", min(candle.open, candle.close)),
                              yEnd: .value("Chiusura", max(candle.open, candle.close, min(candle.open, candle.close) + 0.0001)),
                              width: .fixed(bodyWidth))
                    .foregroundStyle(up ? Theme.green : Theme.red)
            }
            ForEach(Array(slow.enumerated()), id: \.offset) { index, value in
                if let value {
                    LineMark(x: .value("Seduta", index), y: .value(slowLabel, value), series: .value("Serie", slowLabel))
                        .foregroundStyle(Theme.amber)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            ForEach(Array(fast.enumerated()), id: \.offset) { index, value in
                if let value {
                    LineMark(x: .value("Seduta", index), y: .value(fastLabel, value), series: .value("Serie", fastLabel))
                        .foregroundStyle(Theme.cyan.opacity(0.9))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            if let entry = levels.entry ?? levels.pendingEntry {
                RuleMark(y: .value("Ingresso", entry))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) { tag(levels.entry == nil ? "IN ATTESA" : "INGRESSO", entry, .white) }
            }
            if let stop = levels.stop {
                RuleMark(y: .value("Stop", stop))
                    .foregroundStyle(Theme.red)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .bottom, alignment: .leading) { tag("STOP", stop, Theme.red) }
            }
            if let target = levels.target {
                RuleMark(y: .value("Target", target))
                    .foregroundStyle(Theme.green)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) { tag("TARGET", target, Theme.green) }
            }
        }
        .chartYScale(domain: domain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(Theme.stroke)
                AxisValueLabel().font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.textTertiary)
            }
        }
        .accessibilityLabel("Grafico a candele")
    }

    private func tag(_ text: String, _ value: Double, _ color: Color) -> some View {
        Text("\(text) \(String(format: "%.2f", value))")
            .font(.system(size: 9, weight: .heavy, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .background(Theme.background.opacity(0.8), in: Capsule())
    }
}


/// Foglio di traduzione di sistema per i titoli delle notizie (iOS 17.4+):
/// lingua rilevata da sola, traduzione nella lingua del telefono.
private struct NewsTranslation: ViewModifier {
    @Binding var isPresented: Bool
    let text: String

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(iOS 17.4, *) {
            content.translationPresentation(isPresented: $isPresented, text: text)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
