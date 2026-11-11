"""Controllo indipendente dei segnali di oggi (dati Yahoo, non quelli dell'app).

Per ognuno dei 15 ETF: ultima chiusura, SMA200, RSI(2) di Wilder e cosa manca
al segnale (sopra SMA200 e RSI2 < 10). Poi conta, negli ultimi 120 giorni di
borsa, in quanti giorni almeno un ETF dava segnale: sono i giorni in cui
l'app avrebbe chiamato Kimi.
"""
import numpy as np
import pandas as pd
import yfinance as yf

ETFS = ["SPY", "QQQ", "IWM", "DIA", "XLK", "XLF", "XLE", "XLV", "XLY", "XLP",
        "XLI", "XLU", "XLB", "GLD", "TLT"]


def wilder_rsi(c, n):
    d = c.diff()
    up = d.clip(lower=0).ewm(alpha=1 / n, adjust=False).mean()
    dn = (-d.clip(upper=0)).ewm(alpha=1 / n, adjust=False).mean()
    return 100 - 100 / (1 + up / dn.replace(0, np.nan))


c = yf.download(ETFS, period="2y", auto_adjust=True, progress=False)["Close"][ETFS].astype(float)
sma = c.rolling(200).mean()
rsi = wilder_rsi(c, 2)
sig = (c > sma) & (rsi < 10)

last = c.index[-1].date()
print(f"## Segnali oggi (ultima chiusura {last})\n")
print("| ETF | Chiusura | SMA200 | RSI2 | Stato |")
print("|---|---:|---:|---:|---|")
for s in ETFS:
    cl, sm, r = c[s].iloc[-1], sma[s].iloc[-1], rsi[s].iloc[-1]
    if cl <= sm:
        state = "sotto SMA200: escluso"
    elif r < 10:
        state = "**SEGNALE → Kimi**"
    else:
        state = f"manca un calo: RSI2 {r:.0f} > 10"
    print(f"| {s} | {cl:.2f} | {sm:.2f} | {r:.1f} | {state} |")

w = sig.iloc[-120:]
days = int(w.any(axis=1).sum())
print(f"\nUltimi 120 giorni di borsa: {days} giorni con almeno un segnale "
      f"({int(w.values.sum())} segnali in tutto).")
recent = w[w.any(axis=1)].tail(8)
for d, row in recent.iterrows():
    print(f"- {d.date()}: {', '.join(row[row].index)}")
