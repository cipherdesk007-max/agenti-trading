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
            let b = PortfolioSplit.budgets(equity: equity, capitalCap: 3_000)
            XCTAssertEqual(b.daily, 0.30 * 3_000, accuracy: 1e-9)
            XCTAssertEqual(b.night, 0.70 * 3_000, accuracy: 1e-9)
            XCTAssertLessThanOrEqual(b.daily + b.night, 3_000 + 1e-9)
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
}
