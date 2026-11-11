"""Studio: la strategia dell'app con un conto PICCOLO (azioni intere ai prezzi di oggi).

Il backtest normale usa prezzi rettificati: nel 2006 SPY "costava" ~100 $, quindi con
1.000 $ si comprava. Oggi costa ~750 $ e con il tetto del 25% non entra. Qui ogni ETF
si compra a "lotti" del suo prezzo di OGGI (una azione intera vera), mentre i
rendimenti restano quelli storici. Così si misura cosa succede davvero con 1.000 $.

Scenari:
  A. paniere attuale (15 ETF)
  B. paniere "gemelli economici": stessi indici, quote più piccole
     SPY→SPYM/SPLG, QQQ→QQQM, IWM→VTWO, GLD→GLDM; DIA senza gemello resta.
     La storia dei segnali resta quella dell'originale (indice identico).
Capitali: 1.000, 2.000, 5.000 e 100.000 USD (riferimento).
"""
import numpy as np
import pandas as pd
import yfinance as yf

import backtest_app as app

TWINS = {"SPY": ["SPYM", "SPLG"], "QQQ": ["QQQM"], "IWM": ["VTWO"], "GLD": ["GLDM"]}


def last_price(tickers):
    for t in tickers:
        try:
            s = yf.download(t, period="10d", auto_adjust=False, progress=False)["Close"].dropna()
            if len(s):
                return t, float(np.asarray(s).ravel()[-1])
        except Exception:
            pass
    return None, None


def simulate_lots(o, h, l, c, lots, equity0, ind, risk=0.01, max_pos=3, cap=0.25, stop_atr=2.5,
                  rsi_thr=10, max_days=10, tp_atr=2.0):
    """Come app.simulate (esecuzione all'apertura, TP +2 ATR) ma con quantità in azioni
    intere al prezzo di oggi `lots[j]`; segnali scartati per capitale contati."""
    O, H, L, C = o.values, h.values, l.values, c.values
    S200, SX, R2, A = ind["sma200"], ind["smax"], ind["rsi2"], ind["atr"]
    T, N = C.shape
    start = int(np.argmax(c.index >= pd.Timestamp("2006-01-01")))
    cash = equity0
    pos, pending_entries, pending_exits = {}, [], set()
    equity = np.full(T, np.nan)
    trades, skipped, taken = [], 0, 0
    cost = app.COST

    def mark(t, arr):
        return cash + sum(p["qty"] * (arr[t, j] if np.isfinite(arr[t, j]) else p["entry"]) for j, p in pos.items())

    def buy(t, j, price, atr):
        nonlocal cash, skipped, taken
        eq = mark(t, O)
        entry = price * (1 + cost)
        dist = stop_atr * atr
        if not (dist > 0 and entry > dist):
            return
        notional = min(risk * eq * entry / dist, cash, cap * eq)
        lot = lots[j] * (1 + cost)
        n = np.floor(notional / lot)
        if n < 1:
            skipped += 1
            return
        taken += 1
        value = n * lot
        qty = value / entry          # quote rettificate equivalenti
        cash -= value
        pos[j] = dict(qty=qty, entry=entry, stop=entry - dist, tp=entry + tp_atr * atr if tp_atr else None, day=t)

    def sell(t, j, price, reason):
        nonlocal cash
        p = pos.pop(j)
        px = price * (1 - cost)
        cash += p["qty"] * px
        trades.append(dict(ret=px / p["entry"] - 1, reason=reason))

    for t in range(start, T):
        for j in list(pending_exits):
            if j in pos and np.isfinite(O[t, j]):
                sell(t, j, O[t, j], "regola")
        pending_exits.clear()
        for j, atr in pending_entries:
            if j not in pos and len(pos) < max_pos and np.isfinite(O[t, j]):
                buy(t, j, O[t, j], atr)
        pending_entries = []
        for j in list(pos):
            p = pos[j]
            if not np.isfinite(L[t, j]) or t < p["day"]:
                continue
            if L[t, j] <= p["stop"]:
                sell(t, j, min(p["stop"], O[t, j]), "stop"); continue
            if p["tp"] and H[t, j] >= p["tp"]:
                sell(t, j, max(p["tp"], O[t, j]), "target"); continue
        for j in list(pos):
            p = pos[j]
            if C[t, j] > SX[t, j] or t - p["day"] + 1 >= max_days:
                pending_exits.add(j)
        free = max_pos - len(pos) + len(pending_exits)
        if free > 0:
            cands = sorted((R2[t, j], j) for j in range(N)
                           if j not in pos and np.isfinite(C[t, j]) and np.isfinite(S200[t, j])
                           and C[t, j] > S200[t, j] and R2[t, j] < rsi_thr)
            # come nell'app: prima i comprabili (Kimi non vede gli altri)
            def affordable(j):
                eq = mark(t, C)
                dist = stop_atr * A[t, j]
                notional = min(risk * eq * C[t, j] / dist if dist > 0 else 0, cash, cap * eq)
                return notional >= lots[j] * (1 + cost)
            ok = [j for _, j in cands if affordable(j)]
            skipped += len(cands) - len(ok)
            pending_entries = [(j, A[t, j]) for j in ok[:free]]
        equity[t] = mark(t, C)
    return pd.Series(equity, index=c.index).dropna(), trades, skipped, taken


def main():
    o, h, l, c = app.load()
    ind = app.indicators(o, h, l, c, 5)
    print("## Studio conto piccolo: azioni intere ai prezzi di oggi\n")
    lots_now, twin_lots, twin_names = {}, {}, {}
    for j, sym in enumerate(app.ETFS):
        _, p = last_price([sym])
        lots_now[j] = p
        name, tp = last_price(TWINS[sym]) if sym in TWINS else (sym, p)
        twin_lots[j] = tp if tp else p
        twin_names[sym] = name or sym
    print("| ETF | prezzo oggi | gemello | prezzo gemello |\n|---|---|---|---|")
    for j, sym in enumerate(app.ETFS):
        print(f"| {sym} | {lots_now[j]:.2f} | {twin_names[sym]} | {twin_lots[j]:.2f} |")
    print()
    print("| scenario | capitale | 2006–oggi CAGR / maxDD / Sharpe | 2016–oggi | trade/anno | segnali saltati per capitale |")
    print("|---|---|---|---|---|---|")
    spy = app.ETFS.index("SPY")
    no_spy_twin = dict(twin_lots)
    no_spy_twin[spy] = lots_now[spy]
    for label, lots in [("A. paniere attuale", lots_now), ("B. gemelli economici", twin_lots),
                        ("C. gemelli tranne SPY", no_spy_twin)]:
        for cap0 in (1_000, 2_000, 5_000, 100_000):
            eq, tr, skipped, taken = simulate_lots(o, h, l, c, lots, cap0, ind)
            m1 = app.metrics(eq, "2006-01-01", None)
            m2 = app.metrics(eq, "2016-01-01", None)
            years = len(eq) / 252
            share = skipped / max(skipped + taken, 1)
            print(f"| {label} | {cap0:,} | {m1['cagr']:+.1%} / {m1['dd']:.0%} / {m1['sharpe']:.2f} | "
                  f"{m2['cagr']:+.1%} / {m2['dd']:.0%} / {m2['sharpe']:.2f} | {len(tr) / years:.0f} | {share:.0%} |")
    print("\nNota: con i gemelli i rendimenti sono quelli dell'ETF originale (stesso indice); "
          "differenze reali di commissione annua (es. QQQM 0,15% vs QQQ 0,20%) trascurate.")


if __name__ == "__main__":
    main()
