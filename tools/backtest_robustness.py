"""Validazione quantitativa della strategia giornaliera dell'app (FASE 5).

Risponde a tre domande che il backtest semplice non copre:
1. WALK-FORWARD: i parametri scelti sui dati passati sopravvivono fuori dal
   campione? A ogni fold si scelgono i parametri SOLO sui dati IS (in-sample)
   e si testano una volta sola sui dati OOS successivi (out-of-sample), mai
   visti prima. L'ingresso avviene all'apertura successiva al segnale, con
   costi a ogni lato e stop eseguiti con i gap: niente look-ahead bias né
   prezzi di esecuzione irrealistici.
2. MONTE CARLO: che distribuzione di risultati dà la strategia ri-campionando
   i suoi rendimenti giornalieri (bootstrap iid, 1000 percorsi)? Guarda la
   dispersione dei CAGR, il max drawdown tipico e la probabilità di finire sotto
   il capitale iniziale.
3. METRICHE COMPLETE: Sharpe, Sortino, profit factor, win rate, expectancy,
   R-multiplo medio, max drawdown, durata media dei trade.

Importa le REGOLE ESATTE dell'app da backtest_app (stessa simulate, stessi
costi): niente ri-implementazioni che divergono dal codice iOS. Gli indicatori
si calcolano UNA volta sulla serie completa e poi si affettano: il warmup di
SMA200/ATR non mangia l'inizio di ogni fold.
"""
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).parent))
from backtest_app import ETFS, START_EQUITY, indicators, load, metrics, simulate

BASE = dict(rsi_thr=10, exit_sma=5, stop_atr=2.5, risk=0.01, max_pos=3)
GRID = [dict(rsi_thr=thr, exit_sma=sma, stop_atr=k)
        for thr in (5, 10, 15) for sma in (5, 10) for k in (2.0, 2.5, 3.0)]
IS_YEARS, OOS_YEARS, STEP_YEARS = 8, 2, 2
N_BOOT = 1_000


def main():
    o, h, l, c = load()
    n = len(c)
    # Indicatori una volta per uscita SMA, sulla serie COMPLETA (warmup fuori
    # dai fold): slicing posizionale allineato ai dati.
    ind_full = {sma: indicators(o, h, l, c, sma) for sma in (5, 10)}

    def run(a, b, p):
        """Run su [a, b) posizionale con indicatori pre-calcolati e affettati."""
        oo, hh, ll, cc = (d.iloc[a:b] for d in (o, h, l, c))
        ind = {k: v[a:b] for k, v in ind_full[p["exit_sma"]].items()}
        eq, trades, _ = simulate(oo, hh, ll, cc, ind=ind, **p)
        return eq, trades

    def bounds(start, end):
        return c.index.searchsorted(pd.Timestamp(start)), c.index.searchsorted(pd.Timestamp(end))

    print(f"Validazione quantitativa · ETF: {', '.join(ETFS)} · bootstrap {N_BOOT} percorsi\n")

    # ---------------- 1. Walk-forward ----------------
    print("### 1. Walk-forward: parametri scelti in-sample, testati out-of-sample\n")
    print("| fold (IS → OOS) | parametri scelti su IS | IS Sharpe | OOS CAGR / maxDD / Sharpe | SPY OOS CAGR |")
    print("|---|---|---|---|---|")
    data_end = c.index[-1]
    oos_sharpes, oos_cagrs, spy_cagrs = [], [], []
    for start_year in range(2006, data_end.year - IS_YEARS - OOS_YEARS + 2, STEP_YEARS):
        is_start = pd.Timestamp(f"{start_year}-01-01")
        oos_start = pd.Timestamp(f"{start_year + IS_YEARS}-01-01")
        oos_end = pd.Timestamp(f"{start_year + IS_YEARS + OOS_YEARS}-01-01")
        a_is, b_is = bounds(is_start, oos_start)
        a_oos, b_oos = bounds(oos_start, min(oos_end, data_end))
        # Scelta parametri SOLO sul campione IS.
        best, best_sh = None, float("-inf")
        for p in GRID:
            eq, _ = run(a_is, b_is, p)
            m = metrics(eq, is_start, oos_start)
            if m and m["sharpe"] > best_sh:
                best, best_sh = p, m["sharpe"]
        if best is None:
            continue
        # Test UNA volta sola fuori dal campione.
        eq_oos, _ = run(a_oos, b_oos, best)
        m = metrics(eq_oos, oos_start, oos_end)
        spy = c["SPY"].iloc[a_oos:b_oos].dropna()
        spy_cagr = (spy.iloc[-1] / spy.iloc[0]) ** (252 / len(spy)) - 1 if len(spy) > 100 else float("nan")
        label = f"{is_start.year}–{is_start.year + IS_YEARS - 1} → {oos_start.year}–{min(oos_end, data_end).year}"
        ps = f"RSI2<{best['rsi_thr']}, SMA{best['exit_sma']}, stop {best['stop_atr']} ATR"
        if m:
            oos_sharpes.append(m["sharpe"])
            oos_cagrs.append(m["cagr"])
            spy_cagrs.append(spy_cagr)
            print(f"| {label} | {ps} | {best_sh:.2f} | "
                  f"{m['cagr']:+.1%} / {m['dd']:.0%} / {m['sharpe']:.2f} | {spy_cagr:+.1%} |")
        else:
            print(f"| {label} | {ps} | {best_sh:.2f} | dati insufficienti | — |")
    if oos_sharpes:
        beat = float(np.mean([a > b for a, b in zip(oos_cagrs, spy_cagrs)]))
        print(f"\nOOS aggregato: Sharpe medio {np.mean(oos_sharpes):.2f} (min {min(oos_sharpes):.2f}), "
              f"CAGR medio {np.mean(oos_cagrs):+.1%} · batte SPY nello stesso periodo nel "
              f"{beat:.0%} dei fold. Un fold OOS negativo isolato non condanna la strategia: "
              f"si guarda la serie, non il singolo periodo.")

    # ---------------- 2. Monte Carlo ----------------
    print("\n### 2. Monte Carlo (bootstrap iid dei rendimenti giornalieri, regole attuali)\n")
    eq, trades = run(0, n, BASE)
    r = eq.pct_change().dropna().values
    rng = np.random.default_rng(7)
    idx = rng.integers(0, len(r), size=(N_BOOT, len(r)))
    paths = START_EQUITY * np.cumprod(1 + r[idx], axis=1)
    finals = paths[:, -1]
    run_max = np.maximum.accumulate(paths, axis=1)
    dds = (paths / run_max - 1).min(axis=1)
    cagrs = (finals / START_EQUITY) ** (252 / len(r)) - 1
    print("| metrica | p5 | mediana | p95 |\n|---|---|---|---|")
    print(f"| CAGR | {np.percentile(cagrs, 5):+.1%} | {np.median(cagrs):+.1%} | {np.percentile(cagrs, 95):+.1%} |")
    print(f"| max drawdown | {np.percentile(dds, 5):.0%} | {np.median(dds):.0%} | {np.percentile(dds, 95):.0%} |")
    print(f"| equity finale | {np.percentile(finals, 5):,.0f} | {np.median(finals):,.0f} | {np.percentile(finals, 95):,.0f} |")
    print(f"\nProbabilità di finire SOTTO il capitale iniziale: {(finals < START_EQUITY).mean():.1%}. "
          "Il bootstrap iid ignora l'eventuale autocorrelazione dei rendimenti (limitazione dichiarata).")

    # ---------------- 3. Metriche complete sui trade ----------------
    print("\n### 3. Metriche per trade (regole attuali, 2006–oggi)\n")
    tm = trade_metrics(trades)
    years = len(eq) / 252
    print(f"- trade: {tm['n']} (~{tm['n'] / years:.0f}/anno), durata media {tm['avg_days']:.1f} giorni")
    print(f"- win rate: {tm['win']:.0%} · profit factor: {tm['pf']:.2f} · expectancy: {tm['expectancy']:+.2%}")
    print(f"- R-multiplo medio: {tm['avg_r']:+.2f}R · Sortino (per trade): {tm['sortino']:.2f}")
    base_m = metrics(eq, "2006-01-01", None)
    print(f"- Sharpe annuo: {base_m['sharpe']:.2f} · max drawdown: {base_m['dd']:.0%} · vol: {base_m['vol']:.0%}")
    print("\nNota: il calibration error della confidence (Brier) è misurato dall'app sui trade REALI "
          "(calibrazione Kimi in dashboard): qui si valuta la strategia a regole, che non dichiara "
          "probabilità. Nessuna metrica qui sopra è una promessa di rendimento futuro: sono stime "
          "storiche con i costi applicati.")


def trade_metrics(trades):
    """Sharpe/Sortino/profit factor/win rate/expectancy/avg R dai trade."""
    if not trades:
        return dict(n=0, win=0, pf=0, expectancy=0, avg_r=0, sortino=0, avg_days=0)
    rets = np.array([t["ret"] for t in trades])
    rs = np.array([t["r"] for t in trades])
    wins, losses = rets[rets > 0], rets[rets <= 0]
    pf = wins.sum() / -losses.sum() if losses.sum() < 0 else float("inf")
    downside = rets[rets < 0].std() if (rets < 0).any() else np.nan
    sortino = rets.mean() / downside if downside and downside > 0 else float("inf")
    return dict(n=len(rets), win=float((rets > 0).mean()), pf=float(pf),
                expectancy=float(rets.mean()), avg_r=float(rs.mean()),
                sortino=float(sortino), avg_days=float(np.mean([t["days"] for t in trades])))


if __name__ == "__main__":
    main()
