import Foundation

/// Split fisso della modalità PORTAFOGLIO (studio `tools/backtest_portfolio.py`,
/// run 43338377889, documentato in docs/STATO.md): 30% GIORNALIERA / 70% NOTTE
/// sull'equity corrente del conto. NIENTE allocazione dinamica: lo studio scarta
/// le regole "insegui chi guadagna" (winner-tilt: Sharpe 0,25 sulla prima metà
/// del campione, mai sopra lo split fisso).
enum PortfolioSplit {
    static let dailyFraction = 0.30
    static let nightFraction = 0.70

    /// Budget per strategia, ri-bilanciati a ogni ciclo. Il tetto capitale si
    /// applica al TOTALE prima dello split: E_eff = min(equity, capitalCap);
    /// giornaliera = 0,30·E_eff, notte = 0,70·E_eff (la somma non supera mai il
    /// cap). Se né equity né cap sono noti il motore si comporta come prima
    /// (entrambi infiniti). Il budget dimensiona SOLO i nuovi ingressi: le
    /// posizioni già aperte corrono fino alla loro uscita normale.
    static func budgets(equity: Double?, capitalCap: Double) -> (daily: Double, night: Double) {
        let cap = capitalCap.isFinite ? max(capitalCap, 0) : .infinity
        let eq: Double? = (equity != nil && equity!.isFinite && equity! > 0) ? equity : nil
        if eq == nil, !cap.isFinite { return (.infinity, .infinity) }
        let eff = min(eq ?? cap, cap)
        return (dailyFraction * eff, nightFraction * eff)
    }
}

/// P&L di una strategia del portafoglio: aperto (non realizzato, dal broker) +
/// realizzato cumulativo.
struct StrategyLegPnL: Sendable, Equatable {
    var open: Double = 0
    var realized: Double = 0
    var pnl: Double { open + realized }
}

/// P&L separato per strategia (il totale del conto resta il P&L giornata
/// dell'account, non la somma delle gambe).
struct StrategyPnL: Sendable, Equatable {
    var daily: StrategyLegPnL = .init()
    var night: StrategyLegPnL = .init()

    /// Attribuisce le posizioni aperte del broker ai registri delle due
    /// strategie. Un simbolo presente in ENTRAMBI i registri (stessa azione
    /// detenuta da giornaliera e notte, pattern B1) viene contato UNA sola
    /// volta, nella gamba giornaliera: la somma delle due gambe non supera mai
    /// il non realizzato totale delle posizioni del bot.
    static func legs(positions: [(symbol: String, unrealizedPL: Double)],
                     dailySymbols: Set<String>, nightSymbols: Set<String>,
                     realizedDaily: Double, realizedNight: Double) -> StrategyPnL {
        var daily = StrategyLegPnL(open: 0, realized: realizedDaily)
        var night = StrategyLegPnL(open: 0, realized: realizedNight)
        for p in positions {
            let sym = p.symbol.uppercased()
            if dailySymbols.contains(sym) {
                daily.open += p.unrealizedPL
            } else if nightSymbols.contains(sym) {
                night.open += p.unrealizedPL
            }
        }
        return StrategyPnL(daily: daily, night: night)
    }
}

/// P&L realizzato cumulativo per strategia, persistito per conto (stesso pattern
/// dei registri DailyBookStore/NightBookStore).
struct StrategyPnLState: Codable, Sendable, Equatable {
    var dailyRealized: Double = 0
    var nightRealized: Double = 0
}

enum StrategyPnLStore {
    private static let base = "quantswarm.portfolio.pnl"

    private static func key(_ account: String?) -> String {
        account.map { "\(base).\($0)" } ?? base
    }

    static func load(account: String?, defaults: UserDefaults = .standard) -> StrategyPnLState {
        guard let data = defaults.data(forKey: key(account)),
              let state = try? JSONDecoder().decode(StrategyPnLState.self, from: data) else { return StrategyPnLState() }
        return state
    }

    static func save(_ state: StrategyPnLState, account: String?, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key(account)) }
    }
}

extension RiskRules {
    /// Riallinea il picco del drawdown all'equity corrente (conto paper
    /// rigenerato o prelievo): il calo fittizio non deve far scattare il blocco.
    static func recalibratedPeak(equity: Double, currentPeak: Double) -> Double {
        equity.isFinite && equity > 0 ? equity : currentPeak
    }
}
