"""Simulatore giornaliero condiviso dagli studi (tools/backtest_*_studio).

Replica le regole della modalit\u00e0 GIORNALIERA dell'app (come backtest_app.py):
- 15 ETF, segnale alla chiusura: close > SMA200 e RSI(2) < 10 -> compra all'apertura del giorno dopo
- stop = ingresso - K*ATR14 (eseguito al min(stop, open) se c'\u00e8 gap); opzionale trailing sullo stesso K
- uscita a regole: close > SMA5 oppure dopo 10 giorni -> vendita all'apertura successiva
- max 3 posizioni, rischio 1% per trade, tetto 25% per posizione, azioni intere
- costo 0,05% per lato, capitale iniziale 100.000
`block(date)` (se fornita) blocca i nuovi ingressi nelle date in cui torna True
(usata dagli studi filtro-evento e filtro-VIX).
"""

import numpy as np
import pandas as pd
import yfinance as yf

ETFS = ["SPY", "QQQ", "IWM", "DIA", "XLK", "XLF", "XLE", "XLV", "XLY", "XLP",
        "XLI", "XLU", "XLB", "GLD", "TLT"]

WINDOWS = [("2006-01-01", None, "2006\u2013oggi"),
           ("2016-01-01", None, "2016\u2013oggi"),
           (None, "3y", "ultimi 3 anni")]


FIELDS = ("Open", "High", "Low", "Close")
_KNOWN_FIELDS = set(FIELDS) | {"Adj Close", "Volume"}


def flat_by_field(df):
    """yfinance può restituire colonne MultiIndex (field, ticker) oppure
    (ticker, field), a seconda della versione: le porta sempre a (field, ticker)."""
    if not isinstance(df.columns, pd.MultiIndex):
        return df
    if set(df.columns.get_level_values(0)) & _KNOWN_FIELDS:
        return df
    return df.swaplevel(0, 1, axis=1).sort_index(axis=1)


def load(start="2004-06-01"):
    df = flat_by_field(yf.download(ETFS, start=start, auto_adjust=True, progress=False, group_by="column"))
    return tuple(df[k][ETFS].astype(float) for k in FIELDS)


def load_series(ticker, field="Close", start="2004-06-01", auto_adjust=True):
    """Serie di un singolo ticker (es. ^VIX), robusta al MultiIndex di yfinance."""
    df = flat_by_field(yf.download(ticker, start=start, auto_adjust=auto_adjust, progress=False))
    s = df[field]
    if isinstance(s, pd.DataFrame):  # (field, ticker) con un solo ticker → una colonna
        s = s.iloc[:, 0]
    return s.astype(float)


def wilder_rsi(c, n=2):
    delta = c.diff()
    gain = delta.clip(lower=0)
    loss = -delta.clip(upper=0)
    avg_gain = gain.ewm(alpha=1 / n, adjust=False).mean()
    avg_loss = loss.ewm(alpha=1 / n, adjust=False).mean()
    rs = avg_gain / avg_loss.replace(0, np.nan)
    return (100 - 100 / (1 + rs)).fillna(100)


def atr(h, l, c, n=14):
    tr = pd.concat([h - l, (h - c.shift()).abs(), (l - c.shift()).abs()], axis=1).max(axis=1)
    return tr.ewm(alpha=1 / n, adjust=False).mean()


def simulate(o, h, l, c, *, rsi_thr=10.0, exit_sma=5, stop_atr=2.5, trail=False,
             risk=0.01, max_pos=3, cap=0.25, cost=0.0005, start_equity=100_000.0,
             block=None, start="2006-01-01"):
    sma200 = c.rolling(200).mean()
    sma_exit = c.rolling(exit_sma).mean()
    rsi2 = wilder_rsi(c, 2)
    a = atr(h, l, c, 14)

    dates = c.index
    t0 = int(np.argmax(dates >= pd.Timestamp(start)))
    cash = start_equity
    pos = {}   # col -> dict(qty, entry, stop, day)
    trades = []
    eq = pd.Series(index=dates, dtype=float)

    for t in range(t0, len(dates) - 1):
        d = dates[t]
        # 1) uscite a regole (segnale sulla chiusura precedente -> vendita all'apertura)
        for j in list(pos):
            p = pos[j]
            if c.iloc[t, j] > sma_exit.iloc[t, j] or (t - p["day"]) >= 10:
                px = o.iloc[t + 1, j] * (1 - cost)
                trades.append(dict(ret=px / p["entry"] - 1, reason="rule"))
                cash += p["qty"] * px
                del pos[j]
        # 2) stop intraday (eseguito al min(stop, open) in caso di gap)
        for j in list(pos):
            p = pos[j]
            if l.iloc[t + 1, j] <= p["stop"]:
                px = min(p["stop"], o.iloc[t + 1, j]) * (1 - cost)
                trades.append(dict(ret=px / p["entry"] - 1, reason="stop"))
                cash += p["qty"] * px
                del pos[j]
        # trailing: lo stop sale mai, seguendo close - K*ATR della chiusura precedente
        if trail:
            for j in list(pos):
                p = pos[j]
                new_stop = c.iloc[t, j] - stop_atr * a.iloc[t, j]
                p["stop"] = max(p["stop"], new_stop)
                pos[j] = p
        # 3) nuovi ingressi (segnale sulla chiusura di oggi -> compra all'apertura di domani)
        blocked = bool(block(d)) if block else False
        if not blocked and len(pos) < max_pos:
            sig = [(rsi2.iloc[t, j], j) for j in range(len(c.columns))
                   if c.iloc[t, j] > sma200.iloc[t, j] and rsi2.iloc[t, j] < rsi_thr]
            sig.sort()
            for _, j in sig:
                if len(pos) >= max_pos:
                    break
                entry = o.iloc[t + 1, j] * (1 + cost)
                dist = stop_atr * a.iloc[t, j]
                if not (dist > 0 and entry > dist):
                    continue
                e = cash + sum(p["qty"] * c.iloc[t, k] for k, p in pos.items())
                qty = np.floor(min(risk * e / dist, cash / entry, cap * e / entry))
                if qty < 1:
                    continue
                cash -= qty * entry
                pos[j] = dict(qty=qty, entry=entry, stop=entry - dist, day=t)
        # 4) mark-to-market sulla chiusura
        eq.iloc[t] = cash + sum(p["qty"] * c.iloc[t, k] for k, p in pos.items())
    eq = eq.ffill().loc[start:]
    return eq, trades


def metrics(eq, start, end):
    if end == "3y":
        e = eq.iloc[-3 * 252:]
    elif end:
        e = eq.loc[start:end]
    else:
        e = eq.loc[start:]
    if len(e) < 100:
        return None
    r = e.pct_change().dropna()
    years = len(r) / 252
    cagr = (e.iloc[-1] / e.iloc[0]) ** (1 / years) - 1
    vol = r.std() * np.sqrt(252)
    dd = (e / e.cummax() - 1).min()
    return dict(cagr=cagr, dd=dd, sharpe=(r.mean() * 252) / vol if vol > 0 else 0)


def row(label, eq, trades):
    cells = []
    for start, end, _ in WINDOWS:
        m = metrics(eq, start, end)
        cells.append(f"{m['cagr']:+.1%} / {m['dd']:.0%} / {m['sharpe']:.2f}" if m else "\u2014")
    n = len(trades)
    win = np.mean([t["ret"] > 0 for t in trades]) if n else 0
    return f"| {label} | " + " | ".join(cells) + f" | {n} | {win:.0%} |"


HEADER = ("| variante | 2006\u2013oggi CAGR / maxDD / Sharpe | 2016\u2013oggi | ultimi 3 anni | trade | vincenti |\n"
          "|---|---|---|---|---|---|")
