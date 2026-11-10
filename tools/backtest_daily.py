"""Backtest giornaliero di strategie long documentate, su ETF (niente
survivorship bias), 2006-oggi, con costi e confronto con il caso.

Strategie (segnale sulla chiusura, esecuzione all'APERTURA del giorno dopo):
  A  Trend:      in posizione se chiusura > SMA200, altrimenti cash
  B  Momentum:   a fine mese i 3 ETF con miglior rendimento 12-1 mesi,
                 solo se sopra SMA200 (altrimenti quella quota resta cash)
  C  Pullback:   chiusura > SMA200 e RSI(2) < 10 → compra; esce se
                 chiusura > SMA5 o dopo 10 giorni
  D  Breakout:   chiusura > massimo 55 giorni → compra; esce se
                 chiusura < minimo 20 giorni
Benchmark: buy & hold SPY, buy & hold equipesato di tutti gli ETF.
Caso: per C e D, stessi ingressi in numero ma in giorni casuali (stesse uscite).
Costo: 0,05% per lato su ogni variazione di peso.
"""
import os
import random

import numpy as np
import pandas as pd
import yfinance as yf

ETFS = ["SPY", "QQQ", "IWM", "DIA", "XLK", "XLF", "XLE", "XLV", "XLY", "XLP",
        "XLI", "XLU", "XLB", "GLD", "TLT"]
START = "2005-01-01"
COST = float(os.environ.get("BT_COST", "0.0005"))
RANDOM_RUNS = 100
PERIODS = [("2006-01-01", None, "2006–oggi"), ("2006-01-01", "2015-12-31", "2006–2015"),
           ("2016-01-01", None, "2016–oggi")]


def load():
    df = yf.download(ETFS, start=START, auto_adjust=True, progress=False, group_by="column")
    o, h, l, c = (df[k][ETFS].astype(float) for k in ("Open", "High", "Low", "Close"))
    return o, h, l, c


def rsi(close, n):
    d = close.diff()
    up = d.clip(lower=0).ewm(alpha=1 / n, adjust=False).mean()
    dn = (-d.clip(upper=0)).ewm(alpha=1 / n, adjust=False).mean()
    return 100 - 100 / (1 + up / dn.replace(0, np.nan))


def returns_from_weights(w, o, c):
    """w[t] = peso deciso alla chiusura t, eseguito all'apertura t+1.
    Rendimento giorno t = notte (peso tenuto alla chiusura t-1 = w[t-2])
    + giornata (peso dall'apertura t = w[t-1]); costi sulle variazioni."""
    gap = (o / c.shift(1) - 1).fillna(0)
    intra = (c / o - 1).fillna(0)
    w1, w2 = w.shift(1).fillna(0), w.shift(2).fillna(0)
    r = (1 + w2 * gap) * (1 + w1 * intra) - 1
    turnover = (w1 - w2).abs()
    return (r - turnover * COST).sum(axis=1) if r.ndim == 2 else r - turnover * COST


def state_machine(enter, exit_, max_days=None):
    """Segnali 0/1 per colonna: entra su enter, esce su exit_ o dopo max_days."""
    out = pd.DataFrame(0.0, index=enter.index, columns=enter.columns)
    for col in enter.columns:
        e, x = enter[col].values, exit_[col].values
        pos, days, res = 0, 0, np.zeros(len(e))
        for i in range(len(e)):
            if pos:
                days += 1
                if x[i] or (max_days and days >= max_days):
                    pos = 0
            elif e[i]:
                pos, days = 1, 0
            res[i] = pos
        out[col] = res
    return out


def random_machine(enter, exit_, max_days, rng):
    """Stesso numero di ingressi per ETF, ma in giorni casuali validi."""
    rand_enter = pd.DataFrame(False, index=enter.index, columns=enter.columns)
    for col in enter.columns:
        valid = np.where(exit_[col].notna().values)[0]
        n = int(enter[col].sum())
        if n and len(valid):
            idx = rng.choice(valid, size=min(n, len(valid)), replace=False)
            rand_enter.iloc[idx, rand_enter.columns.get_loc(col)] = True
    return state_machine(rand_enter, exit_.fillna(False), max_days)


def metrics(r):
    r = r.dropna()
    if len(r) < 50:
        return None
    eq = (1 + r).cumprod()
    years = len(r) / 252
    cagr = eq.iloc[-1] ** (1 / years) - 1
    vol = r.std() * np.sqrt(252)
    dd = (eq / eq.cummax() - 1).min()
    return dict(cagr=cagr, vol=vol, sharpe=(r.mean() * 252) / vol if vol > 0 else 0, dd=dd)


def cut(r, start, end):
    return r.loc[start:end] if end else r.loc[start:]


def main():
    o, h, l, c = load()
    n = len(ETFS)
    sma200, sma5 = c.rolling(200).mean(), c.rolling(5).mean()
    valid = sma200.notna()

    strategies = {}
    # A trend
    wA = (c > sma200).astype(float).where(valid, 0) / n
    strategies["A Trend SMA200"] = (wA, None)
    # B momentum dual, mensile
    mom = c.shift(21) / c.shift(252) - 1
    month_end = c.index.to_series().groupby(c.index.to_period("M")).transform("max") == c.index.to_series()
    wB = pd.DataFrame(np.nan, index=c.index, columns=ETFS)
    for t in c.index[month_end.values]:
        m = mom.loc[t].dropna()
        row = pd.Series(0.0, index=ETFS)
        for tk in m.sort_values(ascending=False).index[:3]:
            if c.loc[t, tk] > sma200.loc[t, tk]:
                row[tk] = 1 / 3
        wB.loc[t] = row
    wB = wB.ffill().fillna(0)
    strategies["B Momentum top3"] = (wB, None)
    # C pullback RSI2
    enterC = (c > sma200) & (rsi(c, 2) < 10)
    exitC = (c > sma5).where(valid)
    sC = state_machine(enterC.fillna(False), exitC.fillna(False), max_days=10)
    strategies["C Pullback RSI2"] = (sC / n, (enterC.fillna(False), exitC, 10))
    # D breakout Donchian
    enterD = c > h.rolling(55).max().shift(1)
    exitD = (c < l.rolling(20).min().shift(1)).where(valid)
    sD = state_machine(enterD.fillna(False), exitD.fillna(False))
    strategies["D Breakout 55/20"] = (sD / n, (enterD.fillna(False), exitD, None))

    bench = {
        "Buy & hold SPY": returns_from_weights(pd.DataFrame({"SPY": 1.0}, index=c.index), o[["SPY"]], c[["SPY"]]),
        "Buy & hold tutti gli ETF": returns_from_weights(pd.DataFrame(1.0 / n, index=c.index, columns=ETFS).where(c.notna(), 0), o, c),
    }

    rng = np.random.default_rng(11)
    rows = []
    for name, (w, rand_spec) in strategies.items():
        r = returns_from_weights(w, o, c)
        exposure = w.sum(axis=1).loc["2006":].mean()
        trades_year = ((w.diff().abs() > 1e-9).sum(axis=1).loc["2006":].sum()) / (len(c.loc["2006":]) / 252)
        rand_cagrs = []
        if rand_spec:
            enter, exit_, max_days = rand_spec
            for _ in range(RANDOM_RUNS):
                rw = random_machine(enter, exit_, max_days, rng) / n
                m = metrics(cut(returns_from_weights(rw, o, c), "2006-01-01", None))
                rand_cagrs.append((m["sharpe"], rw.sum(axis=1).loc["2006":].mean()))
        rows.append((name, r, exposure, trades_year, sorted(rand_cagrs)))
    for name, r in bench.items():
        rows.append((name, r, 1.0, 0, []))

    print(f"ETF: {', '.join(ETFS)} · costo {COST:.2%} per lato · esecuzione all'apertura del giorno dopo\n")
    for start, end, label in PERIODS:
        print(f"### {label}\n")
        print("| strategia | CAGR | volatilità | Sharpe | max drawdown |\n|---|---|---|---|---|")
        for name, r, *_ in rows:
            m = metrics(cut(r, start, end))
            if m:
                print(f"| {name} | {m['cagr']:+.1%} | {m['vol']:.1%} | {m['sharpe']:.2f} | {m['dd']:.1%} |")
        print()
    print("### Contro il caso (2006–oggi) e operatività\n")
    print("| strategia | esposizione media | cambi di peso/anno | CAGR | Sharpe | Sharpe casuale p5–p95 (esposizione) | batte il caso? |\n|---|---|---|---|---|---|---|")
    for name, r, exposure, trades_year, rc in rows:
        if not trades_year:
            continue
        m = metrics(cut(r, "2006-01-01", None))
        if rc:
            sh = sorted(x[0] for x in rc)
            p5, p95 = sh[int(0.05 * len(sh))], sh[int(0.95 * len(sh)) - 1]
            verdict = "SÌ" if m["sharpe"] > p95 else ("NO" if m["sharpe"] < p5 else "non distinguibile")
            rand = f"{p5:.2f} – {p95:.2f} ({np.mean([x[1] for x in rc]):.0%})"
        else:
            rand, verdict = "—", "—"
        print(f"| {name} | {exposure:.0%} | {trades_year:.0f} | {m['cagr']:+.1%} | {m['sharpe']:.2f} | {rand} | {verdict} |")


if __name__ == "__main__":
    main()
