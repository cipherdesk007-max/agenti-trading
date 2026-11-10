"""Backtest di strategie VELOCI (aprono e chiudono in giornata), 5 minuti,
60 giorni Yahoo, 11 titoli liquidi, solo acquisti, uscita forzata 15:55 NY.

  ORB    Rottura del range di apertura: range 9:30-10:00. Dopo le 10:00 e
         entro le 12:00, una candela che chiude sopra il massimo del range →
         compra all'apertura successiva. Stop = minimo del range.
         Variante a: target 2R · variante b: nessun target, esce a fine giornata.
  VWAP   Ritorno al prezzo medio: dopo le 10:00 ed entro le 15:00, chiusura
         sotto VWAP di oltre 1,5 ATR(14) con RSI(14) < 30 → compra
         all'apertura successiva. Esce quando chiude ≥ VWAP; stop a 1,5 ATR.
Il CASO: stesso numero di ingressi per titolo, in orari casuali con le
stesse regole di uscita (per VWAP: solo candele sotto VWAP, come la strategia).
Se una strategia non batte il caso, non entra nell'app.
"""
import os
import random

import numpy as np
import pandas as pd
import yfinance as yf

SYMBOLS = ["SPY", "QQQ", "IWM", "AAPL", "MSFT", "NVDA", "AMD", "TSLA", "META", "AMZN", "GOOGL"]
COST = float(os.environ.get("BT_COST", "0.0002"))
RANDOM_RUNS = 200


def load(symbol):
    df = yf.download(symbol, period="60d", interval="5m", auto_adjust=False, progress=False, prepost=False)
    if df.empty:
        return None
    if isinstance(df.columns, pd.MultiIndex):
        df.columns = df.columns.get_level_values(0)
    df = df.tz_convert("America/New_York")
    df = df[(df.index.time >= pd.Timestamp("09:30").time()) & (df.index.time < pd.Timestamp("16:00").time())]
    df = df.rename(columns=str.lower)[["open", "high", "low", "close", "volume"]].astype(float)
    df["day"] = df.index.date
    df["hm"] = df.index.hour * 100 + df.index.minute
    tp = (df.high + df.low + df.close) / 3
    df["vwap"] = (tp * df.volume).groupby(df.day).cumsum() / df.volume.groupby(df.day).cumsum().replace(0, np.nan)
    tr = pd.concat([df.high - df.low, (df.high - df.close.shift()).abs(), (df.low - df.close.shift()).abs()], axis=1).max(axis=1)
    df["atr"] = tr.ewm(alpha=1 / 14, adjust=False).mean()
    d = df.close.diff()
    up = d.clip(lower=0).ewm(alpha=1 / 14, adjust=False).mean()
    dn = (-d.clip(upper=0)).ewm(alpha=1 / 14, adjust=False).mean()
    df["rsi"] = 100 - 100 / (1 + up / dn.replace(0, np.nan))
    return df.reset_index(drop=True)


def opening_range(df):
    first = df[df.hm < 1000].groupby("day").agg(orh=("high", "max"), orl=("low", "min"))
    return df.join(first, on="day")


def run_trade(df, j, stop, target, exit_on_vwap):
    """Ingresso all'apertura della candela j. Ritorna il risultato in R."""
    day = df.at[j, "day"]
    entry = df.at[j, "open"] * (1 + COST)
    risk = entry - stop
    if risk <= 0:
        return None, j
    m = j
    while m < len(df) and df.at[m, "day"] == day:
        lo, hi, op, cl = df.at[m, "low"], df.at[m, "high"], df.at[m, "open"], df.at[m, "close"]
        if lo <= stop:
            px = min(stop, op)
            return (px * (1 - COST) - entry) / risk, m
        if target and hi >= target:
            px = max(target, op)
            return (px * (1 - COST) - entry) / risk, m
        if exit_on_vwap and cl >= df.at[m, "vwap"]:
            return (cl * (1 - COST) - entry) / risk, m
        if df.at[m, "hm"] >= 1555:
            return (cl * (1 - COST) - entry) / risk, m
        m += 1
    m -= 1
    return (df.at[m, "close"] * (1 - COST) - entry) / risk, m


def orb_signals(df):
    out = []
    taken = set()
    for i in range(len(df) - 1):
        r = df.iloc[i]
        if r.day in taken or not (1000 <= r.hm < 1200) or np.isnan(r.orh):
            continue
        if r.close > r.orh and df.at[i + 1, "day"] == r.day:
            out.append(i)
            taken.add(r.day)
    return out


def vwap_signals(df):
    ok = (df.hm >= 1000) & (df.hm < 1500) & (df.close < df.vwap - 1.5 * df.atr) & (df.rsi < 30)
    return [i for i in np.where(ok.values)[0] if i + 1 < len(df) and df.at[i + 1, "day"] == df.at[i, "day"]]


def simulate(df, entries, kind, variant=None):
    res, busy = [], -1
    for i in entries:
        j = i + 1
        if j <= busy:
            continue
        if kind == "orb":
            stop = df.at[i, "orl"]
            entry = df.at[j, "open"] * (1 + COST)
            target = entry + 2 * (entry - stop) if variant == "a" else None
            r, m = run_trade(df, j, stop, target, False)
        else:
            stop = df.at[j, "open"] - 1.5 * df.at[i, "atr"]
            r, m = run_trade(df, j, stop, None, True)
        if r is not None:
            res.append(r)
            busy = m
    return res


def random_entries(df, n, kind, rng):
    if kind == "orb":
        pool = np.where((df.hm >= 1000) & (df.hm < 1200) & (df.close > df.orl))[0]
    else:
        pool = np.where((df.hm >= 1000) & (df.hm < 1500) & (df.close < df.vwap))[0]
    pool = [i for i in pool if i + 1 < len(df) and df.at[i + 1, "day"] == df.at[i, "day"]]
    if not pool or n == 0:
        return []
    return sorted(rng.sample(pool, min(n, len(pool))))


def summary(rs):
    if not rs:
        return 0, 0.0, 0.0, 0.0
    wins = [r for r in rs if r > 0]
    loss = -sum(r for r in rs if r <= 0)
    return len(rs), len(wins) / len(rs), float(np.mean(rs)), (sum(wins) / loss if loss > 0 else float("inf"))


def main():
    rng = random.Random(5)
    data = {}
    for s in SYMBOLS:
        df = load(s)
        if df is not None and len(df) > 500:
            data[s] = opening_range(df)
    print(f"Dati 5m: {', '.join(f'{s} {len(d)}' for s, d in data.items())} · costo {COST:.3%} per lato\n")
    print("| strategia | trade | vincenti | R medio | profit factor | R medio CASUALE p5–p95 | batte il caso? |")
    print("|---|---|---|---|---|---|---|")
    for label, kind, variant, finder in [
        ("ORB a · stop minimo range, target 2R", "orb", "a", orb_signals),
        ("ORB b · stop minimo range, fine giornata", "orb", "b", orb_signals),
        ("VWAP · ritorno al prezzo medio", "vwap", None, vwap_signals),
    ]:
        entries = {s: finder(d) for s, d in data.items()}
        rs = [r for s, d in data.items() for r in simulate(d, entries[s], kind, variant)]
        n, win, avg, pf = summary(rs)
        rand = []
        for _ in range(RANDOM_RUNS):
            rr = [r for s, d in data.items()
                  for r in simulate(d, random_entries(d, len(entries[s]), kind, rng), kind, variant)]
            if rr:
                rand.append(float(np.mean(rr)))
        rand.sort()
        p5, p95 = rand[int(0.05 * len(rand))], rand[int(0.95 * len(rand)) - 1]
        verdict = "SÌ" if avg > p95 else ("NO" if avg < p5 else "non distinguibile")
        print(f"| {label} | {n} | {win:.0%} | {avg:+.3f} | {pf:.2f} | {p5:+.3f} – {p95:+.3f} | {verdict} |")


if __name__ == "__main__":
    main()
