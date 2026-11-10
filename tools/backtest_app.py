"""Backtest con le regole ESATTE dell'app (modalità giornaliera).

Replica Sources/Core/DailyStrategy.swift + RiskRules.sizeStopOnly + DailyCycle:
- 15 ETF, segnale sulla chiusura: close > SMA200 e RSI(2) < soglia
- al massimo 3 posizioni; fra più candidati si prendono gli RSI2 più bassi
- quantità = min(rischio% equity / distanza stop, cash / prezzo, 25% equity / prezzo), intera
- stop = ingresso - K × ATR14 (sul broker: eseguito al prezzo di stop o all'apertura se c'è gap)
- uscita a regole: chiusura > SMA(n) oppure 10 giorni → all'apertura successiva
- costi 0,05% per lato
Varianti: griglia di robustezza, take-profit sul broker, esecuzione alla chiusura,
confronto con ingressi casuali (stesse regole di sizing e uscita) e buy & hold.
"""
import os

import numpy as np
import pandas as pd
import yfinance as yf

ETFS = ["SPY", "QQQ", "IWM", "DIA", "XLK", "XLF", "XLE", "XLV", "XLY", "XLP",
        "XLI", "XLU", "XLB", "GLD", "TLT"]
COST = float(os.environ.get("BT_COST", "0.0005"))
START_EQUITY = 100_000.0
PERIODS = [("2006-01-01", None, "2006–oggi"), ("2006-01-01", "2015-12-31", "2006–2015"),
           ("2016-01-01", None, "2016–oggi")]


def load():
    df = yf.download(ETFS, start="2004-06-01", auto_adjust=True, progress=False, group_by="column")
    return tuple(df[k][ETFS].astype(float) for k in ("Open", "High", "Low", "Close"))


def wilder_rsi(c, n):
    d = c.diff()
    up = d.clip(lower=0).ewm(alpha=1 / n, adjust=False).mean()
    dn = (-d.clip(upper=0)).ewm(alpha=1 / n, adjust=False).mean()
    return 100 - 100 / (1 + up / dn.replace(0, np.nan))


def indicators(o, h, l, c, exit_sma):
    tr = pd.concat([h - l, (h - c.shift()).abs(), (l - c.shift()).abs()]).groupby(level=0).max()
    return dict(
        sma200=c.rolling(200).mean().values,
        smax=c.rolling(exit_sma).mean().values,
        rsi2=wilder_rsi(c, 2).values,
        atr=tr.ewm(alpha=1 / 14, adjust=False).mean().values,
    )


def simulate(o, h, l, c, rsi_thr=10, exit_sma=5, stop_atr=2.5, risk=0.01, max_pos=3, cap=0.25,
             max_days=10, tp_atr=None, exec_mode="open", random_rate=None, rng=None, ind=None):
    O, H, L, C = o.values, h.values, l.values, c.values
    ind = ind or indicators(o, h, l, c, exit_sma)
    S200, SX, R2, A = ind["sma200"], ind["smax"], ind["rsi2"], ind["atr"]
    T, N = C.shape
    start = int(np.argmax(c.index >= pd.Timestamp("2006-01-01")))
    cash = START_EQUITY
    pos = {}            # col -> dict(qty, entry, stop, tp, day)
    pending_entries = []  # (col, atr) da eseguire all'apertura
    pending_exits = set()
    equity = np.full(T, np.nan)
    trades = []
    signals = 0

    def mark(t, price_arr):
        return cash + sum(p["qty"] * (price_arr[t, j] if np.isfinite(price_arr[t, j]) else p["entry"])
                          for j, p in pos.items())

    def buy(t, j, price, atr):
        nonlocal cash
        eq = mark(t, O if exec_mode == "open" else C)
        entry = price * (1 + COST)
        dist = stop_atr * atr
        if not (dist > 0 and entry > dist):
            return
        qty = np.floor(min(risk * eq / dist, cash / entry, cap * eq / entry))
        if qty < 1:
            return
        cash -= qty * entry
        pos[j] = dict(qty=qty, entry=entry, stop=entry - dist,
                      tp=(entry + tp_atr * atr) if tp_atr else None, day=t)

    def sell(t, j, price, reason):
        nonlocal cash
        p = pos.pop(j)
        px = price * (1 - COST)
        cash += p["qty"] * px
        trades.append(dict(ret=px / p["entry"] - 1, pnl=p["qty"] * (px - p["entry"]), days=t - p["day"], reason=reason))

    for t in range(start, T):
        # 1. apertura: uscite a regole e ingressi del giorno prima
        for j in list(pending_exits):
            if j in pos and np.isfinite(O[t, j]):
                sell(t, j, O[t, j], "regola")
        pending_exits.clear()
        if exec_mode == "open":
            for j, atr in pending_entries:
                if j not in pos and len(pos) < max_pos and np.isfinite(O[t, j]):
                    buy(t, j, O[t, j], atr)
            pending_entries = []
        # 2. in giornata: stop e take-profit sul broker
        for j in list(pos):
            p = pos[j]
            if not np.isfinite(L[t, j]):
                continue
            # lo stop è attivo appena l'ingresso è eseguito: in "open" già dal
            # giorno d'ingresso, in "close" dal giorno dopo.
            active = t >= p["day"] if exec_mode == "open" else t > p["day"]
            if not active:
                continue
            if L[t, j] <= p["stop"]:
                sell(t, j, min(p["stop"], O[t, j]), "stop")
                continue
            if p["tp"] and H[t, j] >= p["tp"]:
                sell(t, j, max(p["tp"], O[t, j]), "target")
                continue
        # 3. chiusura: regole d'uscita e nuovi segnali
        for j in list(pos):
            p = pos[j]
            held = t - p["day"] + 1
            if C[t, j] > SX[t, j] or held >= max_days:
                if exec_mode == "close":
                    sell(t, j, C[t, j], "regola")
                else:
                    pending_exits.add(j)
        free = max_pos - len(pos) + len(pending_exits)
        if free > 0:
            cands = []
            for j in range(N):
                if j in pos or not np.isfinite(C[t, j]) or not np.isfinite(S200[t, j]):
                    continue
                if random_rate is not None:
                    if rng.random() < random_rate:
                        cands.append((rng.random(), j))
                elif C[t, j] > S200[t, j] and R2[t, j] < rsi_thr:
                    cands.append((R2[t, j], j))
            signals += len(cands)
            cands.sort()
            chosen = [j for _, j in cands[:free]]
            if exec_mode == "open":
                pending_entries = [(j, A[t, j]) for j in chosen]
            else:
                for j in chosen:
                    if len(pos) - len(pending_exits) < max_pos:
                        buy(t, j, C[t, j], A[t, j])
        equity[t] = mark(t, C)
    eq = pd.Series(equity, index=c.index).dropna()
    return eq, trades, signals


def metrics(eq, start, end, trades=None):
    e = eq.loc[start:end] if end else eq.loc[start:]
    if len(e) < 100:
        return None
    r = e.pct_change().dropna()
    years = len(r) / 252
    cagr = (e.iloc[-1] / e.iloc[0]) ** (1 / years) - 1
    vol = r.std() * np.sqrt(252)
    dd = (e / e.cummax() - 1).min()
    return dict(cagr=cagr, vol=vol, sharpe=(r.mean() * 252) / vol if vol > 0 else 0, dd=dd)


def row(label, eq, trades):
    parts = [f"| {label}"]
    for start, end, _ in PERIODS:
        m = metrics(eq, start, end)
        parts.append(f"{m['cagr']:+.1%} / {m['dd']:.0%} / {m['sharpe']:.2f}" if m else "—")
    n = len(trades)
    win = np.mean([t["ret"] > 0 for t in trades]) if n else 0
    avg = np.mean([t["ret"] for t in trades]) if n else 0
    years = len(eq) / 252
    return " | ".join(parts) + f" | {n / years:.0f} | {win:.0%} | {avg:+.2%} |"


HEADER = ("| variante | 2006–oggi CAGR / maxDD / Sharpe | 2006–2015 | 2016–oggi | trade/anno | vincenti | medio/trade |\n"
          "|---|---|---|---|---|---|---|")


def main():
    o, h, l, c = load()
    print(f"ETF: {', '.join(ETFS)} · costo {COST:.2%} per lato · capitale iniziale {START_EQUITY:,.0f}\n")

    base_eq, base_tr, base_sig = simulate(o, h, l, c)
    spy = c["SPY"].loc["2006-01-01":]
    spy_eq = START_EQUITY * spy / spy.iloc[0]
    ew = (c.pct_change().loc["2006-01-01":].mean(axis=1).fillna(0) + 1).cumprod() * START_EQUITY

    print("### Regole attuali dell'app vs riferimenti\n")
    print(HEADER)
    print(row("APP: RSI2<10, SMA5, stop 2,5 ATR, rischio 1%", base_eq, base_tr))
    for label, eq in [("Buy & hold SPY", spy_eq), ("Buy & hold 15 ETF", ew)]:
        print(row(label, eq, []))

    # ingressi casuali con le stesse regole di sizing e uscita
    valid = np.isfinite(c.values) & np.isfinite(c.rolling(200).mean().values)
    start = int(np.argmax(c.index >= pd.Timestamp("2006-01-01")))
    rate = base_sig / max(valid[start:].sum(), 1)
    rng = np.random.default_rng(3)
    ind = indicators(o, h, l, c, 5)
    rand_sh = []
    for _ in range(60):
        eq, _, _ = simulate(o, h, l, c, random_rate=rate, rng=rng, ind=ind)
        rand_sh.append(metrics(eq, "2006-01-01", None)["sharpe"])
    rand_sh.sort()
    base_m = metrics(base_eq, "2006-01-01", None)
    p5, p95 = rand_sh[int(0.05 * len(rand_sh))], rand_sh[int(0.95 * len(rand_sh)) - 1]
    verdict = "SÌ" if base_m["sharpe"] > p95 else ("NO" if base_m["sharpe"] < p5 else "non distinguibile")
    print(f"\nIngressi CASUALI con stesso sizing e uscite (60 serie): Sharpe p5–p95 {p5:.2f} – {p95:.2f} · "
          f"app {base_m['sharpe']:.2f} → batte il caso: **{verdict}**")
    reasons = pd.Series([t["reason"] for t in base_tr]).value_counts()
    print("Uscite app: " + ", ".join(f"{k} {v}" for k, v in reasons.items()) + "\n")

    print("### Robustezza (2006–oggi: CAGR / maxDD / Sharpe)\n")
    print("| RSI2 < | uscita | stop 2 ATR | stop 2,5 ATR | stop 3 ATR |\n|---|---|---|---|---|")
    for thr in (5, 10, 15):
        for sma in (5, 10):
            ind_s = indicators(o, h, l, c, sma)
            cells = []
            for k in (2.0, 2.5, 3.0):
                eq, _, _ = simulate(o, h, l, c, rsi_thr=thr, exit_sma=sma, stop_atr=k, ind=ind_s)
                m = metrics(eq, "2006-01-01", None)
                cells.append(f"{m['cagr']:+.1%} / {m['dd']:.0%} / {m['sharpe']:.2f}")
            print(f"| {thr} | SMA{sma} | " + " | ".join(cells) + " |")

    print("\n### Varianti di esecuzione e uscita\n")
    print(HEADER)
    for label, kwargs in [
        ("Esecuzione alla CHIUSURA del segnale (MOC)", dict(exec_mode="close")),
        ("Take-profit sul broker +1 ATR", dict(tp_atr=1.0)),
        ("Take-profit sul broker +1,5 ATR", dict(tp_atr=1.5)),
        ("Take-profit sul broker +2 ATR", dict(tp_atr=2.0)),
        ("Rischio 0,5% per trade", dict(risk=0.005)),
        ("Max 5 posizioni", dict(max_pos=5)),
    ]:
        eq, tr, _ = simulate(o, h, l, c, ind=ind, **kwargs)
        print(row(label, eq, tr))


if __name__ == "__main__":
    main()
