"""STUDIO (non cambia l'app): la modalità CRYPTO 24/7 proposta — mean-reversion su crypto.

Regole proposte dal proprietario, da validare QUI prima di qualsiasi codice in app:
- filtro trend: Close > EMA100
- ingresso: RSI(2) < soglia (base 12)
- stop-loss 3,5 ATR(14) sotto l'ingresso; take-profit 2,5 ATR(14) sopra
- rischio max 1% dell'equity per trade; max 3 posizioni; long-only
- costi: Alpaca crypto ~0,15-0,25% per lato; qui BT_COST env (default 0,002 = 0,2% a lato,
  include slippage prudenziale). Ordini frazionati nativi (qty decimale).

Dati: yfinance. Limite noto e dichiarato: yfinance fornisce barre 1h solo per ~730 giorni,
quindi 1D parte dal 2018-01-01 (BTC-USD esiste da settembre 2017) mentre 1H/4H coprono solo
la finestra 1h (~2 anni); 4H si ottiene ricampionando 1H. I due orizzonti vengono
reportati separatamente.

Anti-autoinganno: tutte le varianti sono dichiarate; la scelta si fa su CAGR e maxDD
sull'intero periodo e sul controllo a meta' campione (prima vs seconda meta'), NON sul
picco di Sharpe (Deflated Sharpe, Bailey & Lopez de Prado 2014, https://ssrn.com/abstract=2460551).

Output: markdown per il riepilogo del run (backtest.md / step summary).
"""
import os

import numpy as np
import pandas as pd
import yfinance as yf

import daily_study_lib as lib

COINS = ["BTC-USD", "ETH-USD", "SOL-USD", "AVAX-USD", "LINK-USD", "DOGE-USD"]
START_DAILY = "2018-01-01"
COST = float(os.environ.get("BT_COST", "0.002"))  # per lato, commissioni + slippage
RISK = 0.01          # 1% dell'equity per trade
MAX_POS = 3
START = 1_000.0


def load_ohlc(ticker, start, interval):
    df = lib.flat_by_field(yf.download(ticker, start=start, interval=interval,
                                       auto_adjust=False, progress=False))
    out = df[["Open", "High", "Low", "Close"]].astype(float).dropna()
    # yfinance a ticker singolo restituisce colonne MultiIndex (field, ticker):
    # senza appiattire, df["Close"] resta un DataFrame e .iat[i] con un solo
    # indice esplode ("DataFrame._get_value() missing 'col'", run 43355963065).
    if isinstance(out.columns, pd.MultiIndex):
        out.columns = out.columns.get_level_values(0)
    return out


def resample_4h(df):
    out = df.resample("4h").agg({"Open": "first", "High": "max", "Low": "min", "Close": "last"})
    return out.dropna()


def atr_series(h, l, c, n=14):
    prev = c.shift()
    tr = pd.concat([h - l, (h - prev).abs(), (l - prev).abs()], axis=1).max(axis=1)
    return tr.ewm(alpha=1 / n, adjust=False).mean()


def simulate_crypto(df, rsi_thr, stop_atr, tp_atr):
    """Long-only: entra alla chiusura della barra con Close>EMA100 e RSI2<soglia;
    stop/tp intraday su Low/High; sizing al 1% di rischio; max 3 posizioni (qui 1 per
    asset, il paniere limita il totale). Ritorna (equity, trades)."""
    c, h, l, o = df["Close"], df["High"], df["Low"], df["Open"]
    ema100 = c.ewm(span=100, adjust=False).mean()
    rsi2 = lib.wilder_rsi(c, 2)
    atr = atr_series(h, l, c, 14)
    n = len(df)
    cash = START
    pos = None  # dict(qty, entry, stop, tp)
    equity = np.full(n, START)
    trades = []
    for i in range(100, n):  # aspetta EMA100/ATR
        px = c.iat[i]
        if pos is not None:
            if l.iat[i] <= pos["stop"]:
                # fill al min(stop, apertura): se la barra apre sotto lo stop
                # (gap, normale sulle crypto) si esce all'apertura, come
                # daily_study_lib.simulate. Prima riempiva sempre a stop.
                fill = min(pos["stop"], o.iat[i])
                cash += pos["qty"] * fill * (1 - COST)
                trades.append({"ret": (fill / pos["entry"] - 1) - 2 * COST})
                pos = None
            elif h.iat[i] >= pos["tp"]:
                cash += pos["qty"] * pos["tp"] * (1 - COST)
                trades.append({"ret": (pos["tp"] / pos["entry"] - 1) - 2 * COST})
                pos = None
        if pos is None and c.iat[i] > ema100.iat[i] and rsi2.iat[i] < rsi_thr:
            entry = px
            stop = entry - stop_atr * atr.iat[i]
            tp = entry + tp_atr * atr.iat[i]
            if stop >= entry or atr.iat[i] <= 0:
                equity[i] = cash
                continue
            risk_usd = cash * RISK  # 1% dell'equity corrente
            qty = risk_usd / (entry - stop)
            cash -= qty * entry * (1 + COST)
            pos = {"qty": qty, "entry": entry, "stop": stop, "tp": tp}
        equity[i] = cash + (pos["qty"] * px if pos else 0.0)
    if pos is not None:  # chiusura forzata a fine dati
        trades.append({"ret": (c.iat[-1] / pos["entry"] - 1) - 2 * COST})
    return pd.Series(equity, index=df.index), trades


def metrics(eq, periods_per_year):
    r = eq.pct_change().dropna()
    if len(r) < 30:
        return None
    years = len(r) / periods_per_year
    cagr = (eq.iloc[-1] / eq.iloc[0]) ** (1 / years) - 1
    vol = r.std() * np.sqrt(periods_per_year)
    dd = (eq / eq.cummax() - 1).min()
    sharpe = (r.mean() * periods_per_year) / vol if vol > 0 else 0.0
    return dict(cagr=cagr, dd=dd, sharpe=sharpe)


def fmt(m):
    return f"{m['cagr']:+.1%} / {m['dd']:.0%} / {m['sharpe']:.2f}" if m else "—"


def row(label, eq, trades, ppy):
    n = len(trades)
    win = np.mean([t["ret"] > 0 for t in trades]) if n else 0
    pf = (sum(t["ret"] for t in trades if t["ret"] > 0) / -sum(t["ret"] for t in trades if t["ret"] < 0)) if any(t["ret"] < 0 for t in trades) else float("inf")
    m = metrics(eq, ppy)
    half = len(eq) // 2
    m1, m2 = metrics(eq.iloc[:half], ppy), metrics(eq.iloc[half:], ppy)
    return (f"| {label} | {fmt(m)} | {fmt(m1)} | {fmt(m2)} | {n} | {win:.0%} | {pf:.2f} |")


HEADER = ("| variante | CAGR / maxDD / Sharpe (tutto) | prima metà | seconda metà | trade | win% | profit factor |\n"
          "|---|---|---|---|---|---|---|")


def main():
    print("## Studio CRYPTO 24/7 (solo analisi, non cambia l'app)")
    print(f"\nRegole proposte: Close>EMA100 + RSI2<soglia, stop ATR, TP ATR, rischio 1%, max 3 pos, "
          f"costi {COST:.3%}/lato. Dati yfinance; 1H/4H coprono solo ~730 giorni.")
    print(f"Deflated Sharpe: https://ssrn.com/abstract=2460551 — la scelta si fa su CAGR/maxDD, non sul picco di Sharpe.\n")

    # --- 1D, dal 2018: base + benchmark buy&hold equal-weight ---
    print("### Daily (dal 2018, 365 gg/anno)")
    print(HEADER)
    dfs_d = {t: load_ohlc(t, START_DAILY, "1d") for t in COINS}
    eq_strat, all_trades = {}, {}
    for t in COINS:
        eq, tr = simulate_crypto(dfs_d[t], rsi_thr=12, stop_atr=3.5, tp_atr=2.5)
        eq_strat[t], all_trades[t] = eq, tr
    # strategia equal-weight (media dei rendimenti giornalieri delle equity normalizzate).
    # ATTENZIONE dichiarata: l'allineamento (dropna) porta il paniere EW alla nascita
    # della moneta piu' giovane (SOL, 2020): la data va nel nome della riga, le
    # righe per singola moneta usano la loro storia completa.
    rets = pd.DataFrame({t: eq_strat[t].pct_change() for t in COINS}).dropna()
    port_strat = START * (1 + rets.mean(axis=1)).cumprod()
    all_tr = [t for ts in all_trades.values() for t in ts]
    print(row(f"CRYPTO RSI2<12 EMA100 stop3.5AT TP2.5 (EW, dal {rets.index[0].date()})", port_strat, all_tr, 365))
    bhr = pd.DataFrame({t: dfs_d[t]["Close"].pct_change() for t in COINS}).dropna()
    bh = START * (1 + bhr.mean(axis=1)).cumprod()
    print(row(f"Benchmark buy&hold EW (dal {bhr.index[0].date()})", bh, [{"ret": 0.0}], 365))
    for t in COINS:
        print(row(f"  {t} da solo", eq_strat[t], all_trades[t], 365))

    # --- 1H e 4H sulla finestra disponibile (~2 anni) ---
    print("\n### 4H (ricampionata da 1h, ~730 giorni, 365*6 barre/anno) — griglia dichiarata")
    print(HEADER)
    dfs_h = {t: load_ohlc(t, None, "1h") for t in COINS}  # start=None → finestra massima 1h
    dfs_4h = {t: resample_4h(dfs_h[t]) for t in COINS}
    for rsi_thr in (10.0, 12.0, 14.0):
        for stop_atr in (3.0, 3.5):
            eqs, trs = {}, []
            for t in COINS:
                eq, tr = simulate_crypto(dfs_4h[t], rsi_thr=rsi_thr, stop_atr=stop_atr, tp_atr=2.5)
                eqs[t] = eq
                trs += tr
            rets = pd.DataFrame({t: eqs[t].pct_change() for t in COINS}).dropna()
            port = START * (1 + rets.mean(axis=1)).cumprod()
            print(row(f"4H RSI2<{rsi_thr:.0f} stop{stop_atr}AT TP2.5AT (EW)", port, trs, 365 * 6))
    bh4 = START * (1 + pd.DataFrame({t: dfs_4h[t]["Close"].pct_change() for t in COINS}).dropna().mean(axis=1)).cumprod()
    print(row("Benchmark buy&hold EW 4H", bh4, [{"ret": 0.0}], 365 * 6))

    print("\n### 1H (base) — stessa finestra")
    print(HEADER)
    eqs, trs = {}, []
    for t in COINS:
        eq, tr = simulate_crypto(dfs_h[t], rsi_thr=12, stop_atr=3.5, tp_atr=2.5)
        eqs[t] = eq
        trs += tr
    rets = pd.DataFrame({t: eqs[t].pct_change() for t in COINS}).dropna()
    port = START * (1 + rets.mean(axis=1)).cumprod()
    print(row("1H RSI2<12 EMA100 stop3.5AT TP2.5AT (EW)", port, trs, 365 * 24))
    bh1 = START * (1 + pd.DataFrame({t: dfs_h[t]["Close"].pct_change() for t in COINS}).dropna().mean(axis=1)).cumprod()
    print(row("Benchmark buy&hold EW 1H", bh1, [{"ret": 0.0}], 365 * 24))

    print("\nNota: 1D vs 1H/4H non sono confrontabili direttamente (orizzonte diverso). "
          "La decisione entra in app solo se una variante regge a meta' campione con maxDD "
          "compatibile col drawdown 10% dell'app.")


if __name__ == "__main__":
    main()
