"""Verifica sui dati recenti del "market intraday momentum" (Gao, Han, Li, Zhou,
Journal of Financial Economics 2018): il rendimento dalla chiusura di ieri alla fine
della prima ora predice l'ultima mezz'ora.

Solo acquisti (come l'app): si compra all'apertura dell'ultima mezz'ora (15:30 New York)
se la prima ora (chiusura di ieri → 10:30) è sopra una soglia, si vende alla chiusura.
Riferimenti: sempre comprato nell'ultima mezz'ora; ingressi casuali con la stessa frequenza.
Dati: barre da 1 ora di Yahoo (ultimi ~2 anni). Costi per lato configurabili.
"""
import os

import numpy as np
import pandas as pd
import yfinance as yf

SYMBOLS = ["SPY", "QQQ", "IWM", "DIA", "XLK", "XLF", "XLE", "XLV", "XLY", "XLI", "GLD", "TLT"]
COSTS = [0.0, 0.0002, 0.0005]


def load(sym):
    df = yf.download(sym, period="730d", interval="1h", auto_adjust=True, progress=False, prepost=False)
    if df.empty:
        return None
    if isinstance(df.columns, pd.MultiIndex):
        df.columns = df.columns.get_level_values(0)
    idx = df.index.tz_convert("America/New_York") if df.index.tz is not None else df.index.tz_localize("UTC").tz_convert("America/New_York")
    df.index = idx
    return df


def daily_table(df):
    rows = []
    for day, g in df.groupby(df.index.date):
        g = g.sort_index()
        first = g[(g.index.hour == 9) & (g.index.minute == 30)]
        last = g[(g.index.hour == 15) & (g.index.minute == 30)]
        if first.empty or last.empty:
            continue
        rows.append(dict(day=pd.Timestamp(day), first_close=float(first["Close"].iloc[0]),
                         last_open=float(last["Open"].iloc[0]), close=float(g["Close"].iloc[-1])))
    t = pd.DataFrame(rows).set_index("day").sort_index()
    t["prev_close"] = t["close"].shift()
    t["r_first"] = t["first_close"] / t["prev_close"] - 1
    t["r_last"] = t["close"] / t["last_open"] - 1
    return t.dropna()


def stats(returns, days):
    r = np.asarray(returns)
    if len(r) == 0:
        return "—"
    total = np.prod(1 + r) - 1
    years = days / 252
    ann = (1 + total) ** (1 / years) - 1 if years > 0 else 0
    return f"{len(r)} trade · medio {r.mean() * 100:+.3f}% · vincenti {np.mean(r > 0):.0%} · annuo {ann:+.1%}"


def main():
    print("## Intraday momentum (prima ora → ultima mezz'ora), solo acquisti\n")
    rng = np.random.default_rng(7)
    pooled = {c: [] for c in COSTS}
    pooled_all, pooled_rand = [], []
    print("| ETF | giorni | correlazione | soglia 0 | soglia +0,25% | sempre comprato | casuale (stessa frequenza) |")
    print("|---|---|---|---|---|---|---|")
    for sym in SYMBOLS:
        df = load(sym)
        if df is None:
            continue
        t = daily_table(df)
        if len(t) < 100:
            continue
        rho = t["r_first"].corr(t["r_last"])
        cost = float(os.environ.get("BT_COST", "0.0002"))
        sig0 = t[t["r_first"] > 0]["r_last"] - 2 * cost
        sig25 = t[t["r_first"] > 0.0025]["r_last"] - 2 * cost
        always = t["r_last"] - 2 * cost
        rand = t.sample(n=len(sig0), random_state=int(rng.integers(1e9)))["r_last"] - 2 * cost
        for c in COSTS:
            pooled[c].extend((t[t["r_first"] > 0]["r_last"] - 2 * c).tolist())
        pooled_all.extend(always.tolist())
        pooled_rand.extend(rand.tolist())
        print(f"| {sym} | {len(t)} | {rho:+.3f} | {stats(sig0, len(t))} | {stats(sig25, len(t))} | "
              f"{stats(always, len(t))} | {stats(rand, len(t))} |")
    print("\n### Tutti gli ETF insieme (prima ora > 0), per costo per lato\n")
    for c in COSTS:
        r = np.asarray(pooled[c])
        if len(r):
            se = r.std(ddof=1) / np.sqrt(len(r))
            print(f"- costo {c:.2%}: {len(r)} trade · medio {r.mean() * 100:+.4f}% (t = {r.mean() / se:+.2f}) · vincenti {np.mean(r > 0):.0%}")
    a = np.asarray(pooled_all)
    rr = np.asarray(pooled_rand)
    print(f"- sempre comprato (costo 0,02%): medio {a.mean() * 100:+.4f}% · casuale: medio {rr.mean() * 100:+.4f}%")
    print("\nGiudizio: l'effetto è usabile solo se il medio resta positivo con t > 2 DOPO i costi realistici.")


if __name__ == "__main__":
    main()
