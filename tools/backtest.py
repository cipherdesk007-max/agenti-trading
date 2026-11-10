"""Backtest della parte a regole di QuantSwarm (filtro gratuito + uscite bracket).

Domanda a cui risponde: i trigger del filtro (Sources/Core/CandleStore.swift,
FilterTrigger) hanno un vantaggio rispetto a ingressi CASUALI con le stesse
uscite? Se no, Kimi lavora su segnali senza valore e nessuna AI li salva.

Regole replicate:
- candele 15m chiuse, finestra delle ultime 100 (come CandleStore)
- solo acquisti; ingresso all'APERTURA della candela successiva al trigger
- stop = ingresso - K * ATR14(15m), target = ingresso + RR * K * ATR
- niente nuovi ingressi negli ultimi 15 minuti, uscita forzata a fine giornata
- se nella stessa candela tocca sia stop sia target: conta lo stop (prudente)
- costi: 0,03% per lato (spread + slippage)

Uso: python tools/backtest.py  (scarica 60 giorni di 15m da Yahoo Finance)
"""
import math
import os
import random
import sys

import pandas as pd
import yfinance as yf

SYMBOLS = ["SPY", "QQQ", "IWM", "AAPL", "MSFT", "NVDA", "AMD", "TSLA", "META", "AMZN", "GOOGL"]
WINDOW = 100
COST = float(os.environ.get("BT_COST", "0.0003"))
VARIANTS = [(1.0, 2.0), (1.5, 2.0), (2.0, 1.5)]  # (K stop in ATR, R/R)
RANDOM_RUNS = 200


def ema(values, period):
    if len(values) < period:
        return None
    k = 2 / (period + 1)
    cur = sum(values[:period]) / period
    for v in values[period:]:
        cur = v * k + cur * (1 - k)
    return cur


def rsi(closes, period=14):
    if len(closes) <= period:
        return None
    g = l = 0.0
    for i in range(1, period + 1):
        c = closes[i] - closes[i - 1]
        g += max(c, 0)
        l += max(-c, 0)
    ag, al = g / period, l / period
    for i in range(period + 1, len(closes)):
        c = closes[i] - closes[i - 1]
        ag = (ag * (period - 1) + max(c, 0)) / period
        al = (al * (period - 1) + max(-c, 0)) / period
    if al == 0:
        return 50.0 if ag == 0 else 100.0
    return 100 - 100 / (1 + ag / al)


def atr(bars, period=14):
    if len(bars) <= period:
        return None
    trs = [max(b["h"] - b["l"], abs(b["h"] - p["c"]), abs(b["l"] - p["c"]))
           for p, b in zip(bars[:-1], bars[1:])]
    a = sum(trs[:period]) / period
    for t in trs[period:]:
        a = (a * (period - 1) + t) / period
    return a


def trigger(bars):
    """Copia fedele di FilterTrigger.evaluate."""
    if len(bars) < 30:
        return None
    closes = [b["c"] for b in bars]
    prev = closes[:-1]
    last = bars[-1]
    e12, e26 = ema(closes, 12), ema(closes, 26)
    if e12 is None or e26 is None:
        return None
    rn, rp = rsi(closes), rsi(prev)
    e12p, e26p = ema(prev, 12), ema(prev, 26)
    if e12p is not None and e26p is not None and e12p <= e26p and e12 > e26:
        return "incrocio"
    p20 = bars[:-1][-20:]
    if last["c"] > max(b["h"] for b in p20):
        av = sum(b["v"] for b in p20) / len(p20)
        if av <= 0 or last["v"] >= av:
            return "breakout"
    if e12 > e26 and last["c"] > e26 and rn is not None and rp is not None and rp <= 40 and rn > rp:
        return "pullback"
    if rn is not None and rp is not None and rp < 30 and rn >= 30 and last["c"] > last["o"]:
        return "ipervenduto"
    return None


def load(symbol):
    df = yf.download(symbol, period="60d", interval="15m", auto_adjust=False,
                     progress=False, prepost=False)
    if df.empty:
        return []
    if isinstance(df.columns, pd.MultiIndex):
        df.columns = df.columns.get_level_values(0)
    df = df.tz_convert("America/New_York")
    bars = []
    for ts, r in df.iterrows():
        bars.append({"t": ts, "day": ts.date(), "o": float(r["Open"]), "h": float(r["High"]),
                     "l": float(r["Low"]), "c": float(r["Close"]), "v": float(r["Volume"])})
    return bars


def simulate(bars, entries, k, rr):
    """entries: indici i della candela-segnale; ingresso a bars[i+1].open."""
    results, busy_until = [], -1
    for i in entries:
        j = i + 1
        if j >= len(bars) or j <= busy_until or bars[j]["day"] != bars[i]["day"]:
            continue
        # niente ingressi nell'ultima candela della giornata
        if j + 1 >= len(bars) or bars[j + 1]["day"] != bars[j]["day"]:
            continue
        a = atr(bars[max(0, i - WINDOW + 1):i + 1])
        if not a:
            continue
        entry = bars[j]["o"] * (1 + COST)
        stop, target = entry - k * a, entry + rr * k * a
        risk = entry - stop
        exit_px, m = None, j
        while m < len(bars) and bars[m]["day"] == bars[j]["day"]:
            b = bars[m]
            if b["l"] <= stop:
                exit_px = min(stop, b["o"])
                break
            if b["h"] >= target:
                exit_px = max(target, b["o"]) if b["o"] > target else target
                break
            m += 1
        if exit_px is None:
            m -= 1
            exit_px = bars[m]["c"]
        exit_px *= (1 - COST)
        results.append((exit_px - entry) / risk)
        busy_until = m
    return results


def stats(rs):
    if not rs:
        return dict(n=0, win=0, avgR=0, pf=0, totR=0)
    wins = [r for r in rs if r > 0]
    loss = -sum(r for r in rs if r <= 0)
    return dict(n=len(rs), win=len(wins) / len(rs), avgR=sum(rs) / len(rs),
                pf=(sum(wins) / loss) if loss > 0 else math.inf, totR=sum(rs))


def main():
    random.seed(7)
    data = {}
    for s in SYMBOLS:
        bars = load(s)
        if len(bars) > WINDOW + 10:
            data[s] = bars
    print(f"Dati: {', '.join(f'{s} {len(b)}' for s, b in data.items())} candele 15m · costo {COST:.4%} per lato\n")
    lines = ["| K stop | R/R | trade filtro | win | R medio | profit factor | R totali | R medio CASUALE (p5–p95) | il filtro batte il caso? |",
             "|---|---|---|---|---|---|---|---|---|"]
    by_trigger = {}
    for k, rr in VARIANTS:
        all_rs, rand_avgs = [], []
        per_symbol_entries = {}
        for s, bars in data.items():
            entries = []
            for i in range(WINDOW, len(bars) - 1):
                t = trigger(bars[i - WINDOW + 1:i + 1])
                if t:
                    entries.append(i)
                    by_trigger.setdefault((k, rr, t), []).append((s, i))
            per_symbol_entries[s] = entries
            all_rs += simulate(bars, entries, k, rr)
        for _ in range(RANDOM_RUNS):
            rs = []
            for s, bars in data.items():
                n = len(per_symbol_entries[s])
                if n == 0:
                    continue
                idx = sorted(random.sample(range(WINDOW, len(bars) - 1), min(n, len(bars) - WINDOW - 1)))
                rs += simulate(bars, idx, k, rr)
            if rs:
                rand_avgs.append(sum(rs) / len(rs))
        st = stats(all_rs)
        rand_avgs.sort()
        p5 = rand_avgs[int(0.05 * len(rand_avgs))]
        p95 = rand_avgs[int(0.95 * len(rand_avgs)) - 1]
        pct = sum(1 for r in rand_avgs if r < st["avgR"]) / len(rand_avgs)
        verdict = "SÌ (oltre il 95° percentile)" if st["avgR"] > p95 else (
            "NO (sotto il caso)" if st["avgR"] < p5 else f"non distinguibile ({pct:.0%} dei casuali sotto)")
        lines.append(f"| {k} | {rr} | {st['n']} | {st['win']:.0%} | {st['avgR']:+.3f} | {st['pf']:.2f} | "
                     f"{st['totR']:+.1f} | {sum(rand_avgs)/len(rand_avgs):+.3f} ({p5:+.3f} – {p95:+.3f}) | {verdict} |")
    print("\n".join(lines))
    print("\nPer tipo di trigger (K=1.5, R/R=2):")
    print("| trigger | trade | win | R medio | profit factor |\n|---|---|---|---|---|")
    for (k, rr, t), items in sorted(by_trigger.items()):
        if (k, rr) != (1.5, 2.0):
            continue
        rs = []
        for s in data:
            idx = [i for sym, i in items if sym == s]
            rs += simulate(data[s], idx, k, rr)
        st = stats(rs)
        print(f"| {t} | {st['n']} | {st['win']:.0%} | {st['avgR']:+.3f} | {st['pf']:.2f} |")
    print("\nR = multipli del rischio: con rischio 1% per trade, +0,10 R medi ≈ +0,1% del capitale a trade.")


if __name__ == "__main__":
    sys.exit(main())
