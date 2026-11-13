import XCTest
@testable import QuantSwarmAlphaZero

/// Test della modalità PORTAFOGLIO: split 30/70 con tetto sul totale,
/// migrazione dalle modalità legacy, P&L separato per strategia e
/// ricalibrazione della baseline del drawdown. I test a livello di ciclo
/// (budget notte rispettato, posizioni esistenti non forzate) sono in
/// NightCycleTests/DailyCycleTests, che hanno già i broker finti.
final class PortfolioModeTests: XCTestCase {

    // MARK: - split 30/70 sull'equity corrente

    func testBudgetsSplit30_70OnCurrentEquity() {
        let b = PortfolioSplit.budgets(equity: 10_000, capitalCap: .infinity)
        XCTAssertEqual(b.daily, 3_000, accuracy: 1e-9)
        XCTAssertEqual(b.night, 7_000, accuracy: 1e-9)
    }

    /// Tetto attivo: il cap si applica al TOTALE prima dello split e la somma
    /// dei due budget non lo supera mai.
    func testBudgetsCapAppliedToTotalBeforeSplit() {
        for equity in [500.0, 3_000.0, 10_000.0, 1_000_000.0] {
            let eff = min(equity, 3_000)   // E_eff = min(equity, capitalCap)
            let b = PortfolioSplit.budgets(equity: equity, capitalCap: 3_000)
            XCTAssertEqual(b.daily, 0.30 * eff, accuracy: 1e-9)
            XCTAssertEqual(b.night, 0.70 * eff, accuracy: 1e-9)
            XCTAssertLessThanOrEqual(b.daily + b.night, 3_000 + 1e-9, "la somma dei due budget non supera mai il cap")
        }
    }

    func testBudgetsWithoutEquityUsesCapAsBase() {
        let b = PortfolioSplit.budgets(equity: nil, capitalCap: 2_000)
        XCTAssertEqual(b.daily, 600, accuracy: 1e-9)
        XCTAssertEqual(b.night, 1_400, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(b.daily + b.night, 2_000 + 1e-9)
    }

    func testBudgetsNoDataFallsBackToInfinity() {
        let b = PortfolioSplit.budgets(equity: nil, capitalCap: .infinity)
        XCTAssertTrue(b.daily.isInfinite && b.night.isInfinite)
        let bNeg = PortfolioSplit.budgets(equity: -5, capitalCap: .infinity)
        XCTAssertTrue(bNeg.daily.isInfinite && bNeg.night.isInfinite)
    }

    // MARK: - migrazione dalle modalità legacy

    func testLegacyDailyAndNightMigrateToPortfolio() throws {
        for raw in ["daily", "night"] {
            let config = try JSONDecoder().decode(StrategyConfig.self, from: Data("{\"tradingMode\":\"\(raw)\"}".utf8))
            XCTAssertEqual(config.tradingMode, .portfolio)
            XCTAssertEqual(config.sanitized.tradingMode, .portfolio)
        }
    }

    func testIntradayAndPortfolioDoNotMigrate() throws {
        for raw in ["intraday", "portfolio"] {
            let config = try JSONDecoder().decode(StrategyConfig.self, from: Data("{\"tradingMode\":\"\(raw)\"}".utf8))
            XCTAssertEqual(config.tradingMode.rawValue, raw)
            XCTAssertEqual(config.sanitized.tradingMode.rawValue, raw)
        }
    }

    func testMissingModeDefaultsToPortfolio() throws {
        let config = try JSONDecoder().decode(StrategyConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(config.tradingMode, .portfolio)
    }

    func testSelectableModesArePortfolioAndIntraday() {
        XCTAssertEqual(TradingMode.selectableModes, [.portfolio, .intraday])
    }

    // MARK: - P&L separato per strategia, mai doppio conteggio

    func testPnLLegsAreSeparatedAndNeverDoubleCounted() {
        let positions = [
            (symbol: "SPY", unrealizedPL: 100.0),   // in entrambi i registri: contato una sola volta (daily)
            (symbol: "QQQ", unrealizedPL: -40.0),   // solo notte
            (symbol: "GLD", unrealizedPL: 25.0),    // solo giornaliera
            (symbol: "TSLA", unrealizedPL: 999.0)   // nessuna strategia: ignorato
        ]
        let pnl = StrategyPnL.legs(positions: positions,
                                   dailySymbols: ["SPY", "GLD"],
                                   nightSymbols: ["SPY", "QQQ"],
                                   realizedDaily: 10.0, realizedNight: -5.0)
        XCTAssertEqual(pnl.daily.open, 125.0, accuracy: 1e-9)
        XCTAssertEqual(pnl.night.open, -40.0, accuracy: 1e-9)
        XCTAssertEqual(pnl.daily.pnl, 135.0, accuracy: 1e-9)
        XCTAssertEqual(pnl.night.pnl, -45.0, accuracy: 1e-9)
        XCTAssertEqual(pnl.daily.open + pnl.night.open, 85.0, accuracy: 1e-9,
                       "la somma delle gambe non supera il non realizzato totale del bot")
    }

    // MARK: - ricalibrazione della baseline del drawdown

    /// Conto paper rigenerato / prelievo: picco vecchio 10.000, equity 9.000.
    /// Prima della ricalibrazione il drawdown scatterebbe (floor = 9.000);
    /// dopo la ricalibrazione del picco no.
    func testRecalibratedPeakPreventsFakeDrawdownLock() {
        let peak = RiskRules.recalibratedPeak(equity: 9_000, currentPeak: 10_000)
        XCTAssertEqual(peak, 9_000)
        let before = RiskRules.drawdownCheck(equity: 9_000, peak: 10_000,
                                             maxDrawdownFraction: SystemLimits.maxDrawdownFraction,
                                             capitalCap: .infinity)
        XCTAssertEqual(before?.shouldLock, true)
        let after = RiskRules.drawdownCheck(equity: 9_000, peak: peak,
                                            maxDrawdownFraction: SystemLimits.maxDrawdownFraction,
                                            capitalCap: .infinity)
        XCTAssertEqual(after?.shouldLock, false)
    }

    func testRecalibratedPeakKeepsPeakWhenEquityMissing() {
        XCTAssertEqual(RiskRules.recalibratedPeak(equity: 0, currentPeak: 10_000), 10_000)
        XCTAssertEqual(RiskRules.recalibratedPeak(equity: .nan, currentPeak: 10_000), 10_000)
    }

    // MARK: - test a livello di ciclo (broker finti condivisi con NightCycleTests/DailyCycleTests)

    private func et(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.calendar = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")
        c.year = 2026; c.month = 11; c.day = day; c.hour = hour; c.minute = minute
        return c.date!
    }

    private let candleStart = Date(timeIntervalSince1970: 1_735_732_800)

    private func candles(_ closes: [Double]) -> [Candle] {
        closes.enumerated().map { i, close in
            Candle(timestamp: candleStart.addingTimeInterval(Double(i) * 86_400),
                   open: close, high: close * 1.005, low: close * 0.995, close: close, volume: 1_000)
        }
    }

    /// Trend lungo + 3 giorni di ribasso: segnale d'ingresso, ma chiusura sotto SMA5 (nessuna uscita).
    private var pullback: [Candle] { candles((0..<247).map { 100 + 0.2 * Double($0) } + [146, 144, 142]) }

    /// La notte compra entro il SUO budget: in PORTAFOGLIO il motore passa capitalCap = 0,70 · min(equity, tetto).
    func testNightCycleBuysWithinNightBudgetCap() async {
        let broker = FakeNightBroker(isOpen: true, nextClose: et(day: 12, 16))
        await broker.set(account: BrokerAccount(equity: 1_000, cash: 1_000, buyingPower: 1_000))
        let budgets = PortfolioSplit.budgets(equity: 1_000, capitalCap: .infinity)
        XCTAssertEqual(budgets.night, 700, accuracy: 1e-9)
        let input = NightCycleInput(book: NightBook(), today: "2026-11-12",
                                    now: et(day: 12, 10), capitalCap: budgets.night)
        let result = await NightCycleRunner(broker: broker, settleWaitSeconds: 0).run(input) { _ in }
        let sent = await broker.submitted
        let prices: [String: Double] = ["SPY": 760, "SPYM": 89.5, "QQQ": 692, "QQQM": 285,
                                        "IWM": 283, "VTWO": 114, "GLD": 365, "GLDM": 79]
        let buys = sent.filter { $0.side == "buy" && $0.tif == "cls" }
        let spent = buys.reduce(0.0) { $0 + Double($1.qty) * (prices[$1.symbol] ?? 0) }
        XCTAssertFalse(result.aborted)
        XCTAssertFalse(buys.isEmpty, "con 700 USD di budget la notte compra (usa i gemelli economici)")
        XCTAssertLessThanOrEqual(spent, budgets.night * (1 - NightStrategy.cashBuffer) + 1e-6,
                                 "la spesa della notte non supera il suo budget (cashBuffer 3%)")
    }

    /// Il budget si applica SOLO ai nuovi ingressi: una posizione già aperta nel
    /// registro (es. migrazione da .daily/.night legacy) NON viene forzata né
    /// ridimensionata: esce solo per le sue regole normali.
    func testDailyCycleSmallBudgetDoesNotForceExistingPosition() async {
        let broker = FakeBroker(bars: ["SPY": pullback])
        await broker.set(positions: [BrokerPosition(symbol: "SPY", quantity: 10, averageEntryPrice: 140, unrealizedPL: 20)])
        await broker.set(orders: [BrokerOrder(id: "s1", symbol: "SPY", side: "sell", type: "stop", status: "new",
                                               quantity: 10, filledQuantity: 0, stopPrice: 135,
                                               parentOrderId: "p1", submittedAt: nil)])
        var book = DailyBook()
        book.entries["SPY"] = "2026-11-10"   // aperta oggi: niente uscita per tempo
        book.stops["SPY"] = 135
        // budget giornaliera = 30% di E_eff: qui il motore passa un cap piccolo
        let input = DailyCycleInput(book: book, today: "2026-11-10", riskFraction: 0.01,
                                    maxOpenPositions: 3, entryBlock: nil, capitalCap: 50)
        let result = await DailyCycleRunner(broker: broker, brain: FakeBrain(), basket: ["SPY"],
                                            exitFillWaitSeconds: 0).run(input) { _ in }
        let closed = await broker.closed
        XCTAssertTrue(closed.isEmpty, "la posizione esistente non va chiusa a forza: esce solo per SMA5, giorni max o stop eseguito")
        XCTAssertTrue(result.book.entries.keys.contains("SPY"), "resta nel registro fino alla sua uscita normale")
    }

    /// Col budget piccolo i nuovi ingressi sono bloccati dal dimensionamento:
    /// le regole di ingresso non cambiano, è il capitale che manca.
    func testDailyCycleSmallBudgetBlocksNewEntriesOnly() async {
        let broker = FakeBroker(bars: ["SPY": pullback])
        let input = DailyCycleInput(book: DailyBook(), today: "2026-11-10", riskFraction: 0.01,
                                    maxOpenPositions: 3, entryBlock: nil, capitalCap: 50)
        let result = await DailyCycleRunner(broker: broker, brain: FakeBrain(), basket: ["SPY"],
                                            exitFillWaitSeconds: 0).run(input) { _ in }
        let entries = await broker.entryCalls
        XCTAssertTrue(entries.isEmpty, "budget 50 USD: nessun nuovo ordine")
        XCTAssertTrue(result.orders.isEmpty)
    }
}
