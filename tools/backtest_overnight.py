"""Altre due idee documentate per la modalità veloce, con costi reali.

1. Effetto "overnight" (Lou, Polk, Skouras, JFE 2019; Boyarchenko, Larsen, Whelan
   2023): negli ETF USA quasi tutto il rendimento arriva da chiusura ad apertura del
   giorno dopo. Strategia: compra in chiusura, vendi all'apertura. Dati giornalieri
   dal 2006 (open/close non rettificati per gli split? si usano rapporti nello stesso
   giorno/notte, quindi i dividendi incidono pochissimo).
2. Rimbalzo di fine giornata: se alle 15:30 l'ETF perde più dell'1% da ieri, compra e
   vendi in chiusura (barre da 1 ora, ultimi 2 anni).
Giudizio: usabile solo se il guadagno medio resta positivo con t > 2 dopo i costi.
"""
import numpy as np
import pandas as pd
import yfinance as yf

SYMBOLS = ["SPY", "QQQ", "IWM", "DIA", "XLK", "XLF", "XLE", "XLV", "XLY", "XLI", "GLD", "TLT"]
COSTS = [0.0, 0.00003, 0.0001, 0.0002, 0.0005]
# Costo realistico per lato con ordini d'asta (MOC in chiusura, OPG in apertura) sugli
# ETF più liquidi: commissioni Alpaca 0, spread di 1 centesimo su 500–700 $ ≈ 0,002%.
LIQUID = ["SPY", "QQQ", "IWM", "GLD"]


def t_stat(r):
    r = np.asarray(r)
    return r.mean() / (r.std(ddof=1) / np.sqrt(len(r))) if len(r) > 2 else float("nan")


def overnight():
    print("## 1. Overnight: compra in chiusura, vendi all'apertura (2006–oggi)\n")
    print("| ETF | notti | medio senza costi | t | medio con 0,02%/lato | t | ultimi 2 anni con 0,02%/lato |")
    print("|---|---|---|---|---|---|---|")
    pooled = {c: [] for c in COSTS}
    recent = []
    for sym in SYMBOLS:
        d = yf.download(sym, start="2006-01-01", auto_adjust=False, progress=False)
        if d.empty:
            continue
        if isinstance(d.columns, pd.MultiIndex):
            d.columns = d.columns.get_level_values(0)
        r = (d["Open"].shift(-1) / d["Close"] - 1).dropna()
        for c in COSTS:
            pooled[c].extend((r - 2 * c).tolist())
        rc = r - 0.0004
        last = rc[rc.index >= rc.index[-1] - pd.Timedelta(days=730)]
        recent.extend(last.tolist())
        print(f"| {sym} | {len(r)} | {r.mean() * 100:+.4f}% | {t_stat(r):+.1f} | {rc.mean() * 100:+.4f}% | "
              f"{t_stat(rc):+.1f} | {last.mean() * 100:+.4f}% (t {t_stat(last):+.1f}) |")
    print()
    for c in COSTS:
        r = np.asarray(pooled[c])
        print(f"- tutti, costo {c:.2%}/lato: medio {r.mean() * 100:+.4f}% a notte (t = {t_stat(r):+.2f}), in guadagno {np.mean(r > 0):.0%}")
    r = np.asarray(recent)
    print(f"- tutti, ultimi 2 anni, 0,02%/lato: medio {r.mean() * 100:+.4f}% (t = {t_stat(r):+.2f})")
    print("\n### Solo i 4 più liquidi (SPY, QQQ, IWM, GLD), per costo per lato e periodo\n")
    print("| costo/lato | 2006–oggi medio (t) | ultimi 2 anni medio (t) | annuo stimato 2 anni |")
    print("|---|---|---|---|")
    raw = {}
    for sym in LIQUID:
        d = yf.download(sym, start="2006-01-01", auto_adjust=False, progress=False)
        if isinstance(d.columns, pd.MultiIndex):
            d.columns = d.columns.get_level_values(0)
        raw[sym] = (d["Open"].shift(-1) / d["Close"] - 1).dropna()
    for c in COSTS:
        allr = np.concatenate([(raw[s_] - 2 * c).values for s_ in raw])
        rec = np.concatenate([(raw[s_][raw[s_].index >= raw[s_].index[-1] - pd.Timedelta(days=730)] - 2 * c).values for s_ in raw])
        # un ETF a notte a rotazione ≈ media per notte × 252
        print(f"| {c:.3%} | {allr.mean() * 100:+.4f}% ({t_stat(allr):+.1f}) | {rec.mean() * 100:+.4f}% ({t_stat(rec):+.1f}) | {((1 + rec.mean()) ** 252 - 1):+.1%} |")


def late_reversal():
    print("\n## 2. Rimbalzo di fine giornata: −1% alle 15:30 → compra, vendi in chiusura (2 anni)\n")
    pooled = {c: [] for c in COSTS}
    for sym in SYMBOLS:
        df = yf.download(sym, period="730d", interval="1h", auto_adjust=True, progress=False)
        if df.empty:
            continue
        if isinstance(df.columns, pd.MultiIndex):
            df.columns = df.columns.get_level_values(0)
        df.index = df.index.tz_convert("America/New_York")
        rows = []
        for day, g in df.groupby(df.index.date):
            last = g[(g.index.hour == 15) & (g.index.minute == 30)]
            if last.empty:
                continue
            rows.append((pd.Timestamp(day), float(last["Open"].iloc[0]), float(g["Close"].iloc[-1])))
        t = pd.DataFrame(rows, columns=["day", "last_open", "close"]).set_index("day")
        t["prev"] = t["close"].shift()
        t = t.dropna()
        sig = t[t["last_open"] / t["prev"] - 1 < -0.01]
        r = sig["close"] / sig["last_open"] - 1
        for c in COSTS:
            pooled[c].extend((r - 2 * c).tolist())
    for c in COSTS:
        r = np.asarray(pooled[c])
        if len(r) > 2:
            print(f"- costo {c:.2%}/lato: {len(r)} trade · medio {r.mean() * 100:+.4f}% (t = {t_stat(r):+.2f}) · in guadagno {np.mean(r > 0):.0%}")
    print("\nGiudizio: usabile solo se il medio resta positivo con t > 2 DOPO i costi realistici (0,02–0,05% per lato).")


if __name__ == "__main__":
    overnight()
    late_reversal()
