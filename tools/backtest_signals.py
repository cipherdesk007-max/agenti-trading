"""Batteria di regole d'ingresso giornaliere documentate sugli stessi 15 ETF, con le
STESSE uscite e gli stessi costi dell'app (stop 2,5 ATR, target 2 ATR, uscita sopra la
media a 5 o dopo 10 sedute, max 3 posizioni, rischio 1%, tetto 25%, esecuzione
all'apertura successiva). Tutte richiedono il trend: chiusura sopra la media a 200.

Regole (tutte "compra il ribasso in un trend che sale"):
  RSI2   RSI a 2 giorni < 10 (quella dell'app; Connors)
  IBS    Internal Bar Strength (chiusura−minimo)/(massimo−minimo) < 0,15
  7MIN   chiusura al minimo delle ultime 7 sedute ("Double 7s", Connors)
  3GIU   tre chiusure in calo di fila
  UNIONE una qualsiasi delle precedenti (più segnali)
  DOPPIA almeno due delle precedenti insieme (segnali più forti)
Periodi: 2006–oggi, 2016–oggi, ultimi 3 anni. Riferimento: ingressi casuali con la
stessa frequenza (percentile 95 di 200 simulazioni).
"""
import numpy as np
import pandas as pd

import backtest_app as app


def masks(o, h, l, c, ind):
    C, H, L = c.values, h.values, l.values
    trend = C > ind["sma200"]
    rsi = ind["rsi2"] < 10
    rng = np.where(H - L > 0, H - L, np.nan)
    ibs = ((C - L) / rng) < 0.15
    low7 = c.rolling(7).min().values
    min7 = C <= low7
    down = c.diff()
    d3 = ((down < 0) & (down.shift(1) < 0) & (down.shift(2) < 0)).values
    rules = {"RSI2": rsi, "IBS": ibs, "7MIN": min7, "3GIU": d3}
    total = sum(r.astype(int) for r in rules.values())
    rules["UNIONE"] = total >= 1
    rules["DOPPIA"] = total >= 2
    return {k: (v & trend) for k, v in rules.items()}


def simulate(o, h, l, c, ind, entry, score, start="2006-01-01", risk=0.01, max_pos=3, cap=0.25,
             stop_atr=2.5, max_days=10, tp_atr=2.0, seed=None):
    O, H, L, C = o.values, h.values, l.values, c.values
    SX, A = ind["smax"], ind["atr"]
    T, N = C.shape
    t0 = int(np.argmax(c.index >= pd.Timestamp(start)))
    cash, pos = 100_000.0, {}
    pend_in, pend_out = [], set()
    eq = np.full(T, np.nan)
    trades = 0
    rng = np.random.default_rng(seed) if seed is not None else None
    cost = app.COST

    def mark(t, arr):
        return cash + sum(p["q"] * (arr[t, j] if np.isfinite(arr[t, j]) else p["e"]) for j, p in pos.items())

    for t in range(t0, T):
        for j in list(pend_out):
            if j in pos and np.isfinite(O[t, j]):
                p = pos.pop(j); cash += p["q"] * O[t, j] * (1 - cost); trades += 1
        pend_out.clear()
        for j, atr in pend_in:
            if j in pos or len(pos) >= max_pos or not np.isfinite(O[t, j]):
                continue
            e = O[t, j] * (1 + cost); dist = stop_atr * atr
            if not (dist > 0 and e > dist):
                continue
            equity = mark(t, O)
            q = min(risk * equity / dist, cash / e, cap * equity / e)
            if q <= 0:
                continue
            cash -= q * e
            pos[j] = dict(q=q, e=e, s=e - dist, tp=e + tp_atr * atr, d=t)
        pend_in = []
        for j in list(pos):
            p = pos[j]
            if not np.isfinite(L[t, j]):
                continue
            if L[t, j] <= p["s"]:
                cash += p["q"] * min(p["s"], O[t, j]) * (1 - cost); pos.pop(j); trades += 1; continue
            if H[t, j] >= p["tp"]:
                cash += p["q"] * max(p["tp"], O[t, j]) * (1 - cost); pos.pop(j); trades += 1; continue
            if C[t, j] > SX[t, j] or t - p["d"] + 1 >= max_days:
                pend_out.add(j)
        free = max_pos - len(pos) + len(pend_out)
        if free > 0:
            cands = [j for j in range(N) if j not in pos and np.isfinite(C[t, j]) and entry[t, j]]
            if rng is not None:
                rng.shuffle(cands)
            else:
                cands.sort(key=lambda j: score[t, j])
            pend_in = [(j, A[t, j]) for j in cands[:free]]
        eq[t] = mark(t, C)
    return pd.Series(eq, index=c.index).dropna(), trades


def row(eq, trades, start):
    e = eq[eq.index >= pd.Timestamp(start)]
    m = app.metrics(e, start, None)
    years = len(e) / 252
    return f"{m['cagr']:+.1%} / {m['dd']:.0%} / {m['sharpe']:.2f}", trades / max(years, 1e-9)


def main():
    o, h, l, c = app.load()
    ind = app.indicators(o, h, l, c, 5)
    ms = masks(o, h, l, c, ind)
    three = (c.index[-1] - pd.Timedelta(days=3 * 365)).strftime("%Y-%m-%d")
    print("## Batteria di regole giornaliere (stesse uscite dell'app)\n")
    print("| regola | segnali/anno | 2006–oggi CAGR / maxDD / Sharpe | 2016–oggi | ultimi 3 anni | caso p95 Sharpe 2006– |")
    print("|---|---|---|---|---|---|")
    score = ind["rsi2"]
    for name, mask in ms.items():
        sig_year = mask[np.asarray(c.index >= pd.Timestamp("2006-01-01"))].sum() / (len(c[c.index >= "2006-01-01"]) / 252)
        eq, tr = simulate(o, h, l, c, ind, mask, score)
        a, _ = row(eq, tr, "2006-01-01")
        eq16, tr16 = simulate(o, h, l, c, ind, mask, score, start="2016-01-01")
        b, _ = row(eq16, tr16, "2016-01-01")
        eq3, tr3 = simulate(o, h, l, c, ind, mask, score, start=three)
        d, _ = row(eq3, tr3, three)
        # caso: stessi giorni/numero di candidati ma scelti a caso tra gli ETF in trend
        trend = (c.values > ind["sma200"])
        rand = []
        for s in range(40):
            rmask = np.zeros_like(mask)
            rs = np.random.default_rng(s)
            for t in range(mask.shape[0]):
                k = int(mask[t].sum())
                if k:
                    idx = np.flatnonzero(trend[t])
                    if len(idx):
                        rmask[t, rs.choice(idx, size=min(k, len(idx)), replace=False)] = True
            req, _ = simulate(o, h, l, c, ind, rmask, score, seed=s)
            rand.append(app.metrics(req, "2006-01-01", None)["sharpe"])
        p95 = np.percentile(rand, 95)
        print(f"| {name} | {sig_year:.0f} | {a} | {b} | {d} | {p95:.2f} |")
    print("\nGiudizio: una regola vale se lo Sharpe 2006– supera il caso p95 E resta positivo negli ultimi 3 anni.")


if __name__ == "__main__":
    main()
