"""STUDIO (non cambia l'app): CRYPTO trend-following a regime — regole NUOVE.

Perche' un secondo studio crypto: la proposta 18 (Close>EMA100 + RSI2<12, stop 3,5 ATR,
TP 2,5 ATR) e' stata bocciata dai numeri (run 43357136321: 4H tutte le varianti in
perdita PF 0,75-0,85, 1H -22,8%/-41%, 1D pari dopo i costi). Il difetto strutturale:
mean-reversion long-only con asimmetria NEGATIVA (TP 2,5 ATR < stop 3,5 ATR) che
compra i ribassi in un mercato che scende. La letteratura esterna gia' citata nella
proposta 18 dice la stessa cosa (mean-reversion a default: 0/42 contro buy&hold).

Famiglia NUOVA: trend-following a regime, long-only, senza take-profit fisso:
- V1 SMA200: long quando Close > SMA200, flat quando Close < SMA200 (timing classico).
- V2 SMA200 con isteresi: ingresso Close > SMA200, uscita Close < 0,97*SMA200
  (meno whipsaw a cavallo della media).
- V3 EMA50>EMA200 con chandelier: ingresso EMA50>EMA200, uscita trailing
  max(Close da ingresso) - 3*ATR22 (chandelier) o incrocio ribassista.
- V4 Donchian20: rottura del massimo a 20 barre con regime Close>SMA200, uscita
  chandelier 3*ATR22.
Tutte: sizing a frazione dell'equity (1/n monete), costi BT_COST per lato (default
0,2%: Alpaca crypto ~0,25% primo scaglione, slippage incluso), niente short.

Criteri DECISI PRIMA del run (pre-registrazione, stampati in output):
  A. CAGR full-window dopo i costi >= +3%/anno (batte il contante con margine);
  B. maxDD full-window <= -20% (al massimo un terzo del B&H EW, tipicamente -70%);
  C. finestra recente 2024-11 -> oggi (orso): CAGR >= -2%/anno (capitale salvato);
  D. entrambe le meta' del campione con CAGR > 0 (non un solo regime fortunato).
La variante entra in app SOLO se passa A+B+C+D e il proprietario decide. Nessun
parametro scelto dopo aver visto i numeri: la griglia e' questa e viene dichiarata.

Anti-autoinganno: scelta su CAGR/maxDD e stabilita' a meta' campione, non sul picco
di Sharpe (Deflated Sharpe, Bailey & Lopez de Prado 2014, https://ssrn.com/abstract=2460551).
Dati yfinance; la finestra 1h copre solo ~730 giorni, quindi il 4H e' un controllo
secondario su quella finestra (tutto orso: serve solo a dimostrare che resta flat),
la decisione si prende sul daily dal 2018 (due tori, due orsi).

Output: markdown per il riepilogo del run (backtest.md / step summary).
"""
import os

import numpy as np
import pandas as pd
import yfinance as yf

import daily_study_lib as lib

COINS = ["BTC-USD", "ETH-USD", "SOL-USD", "AVAX-USD", "LINK-USD", "DOGE-USD"]
START_DAILY = "2018-01-01"
RECENT_START = "2024-11-01"   # orso: stesso taglio dello studio della proposta 18
COST = float(os.environ.get("BT_COST", "0.002"))  # per lato, commissioni + slippage
START = 1_000.0


def load_ohlc(ticker, start, interval, period=None):
    """Come backtest_crypto.py: appiattisce le colonne MultiIndex di yfinance
    (run 43355963065) e per le barre 1h usa period="730d" per la finestra reale
    (con start=None yfinance scarica period="1mo", run 43356782169)."""
    if period:
        df = lib.flat_by_field(yf.download(ticker, period=period, interval=interval,
                                           auto_adjust=False, progress=False))
    else:
        df = lib.flat_by_field(yf.download(ticker, start=start, interval=interval,
                                           auto_adjust=False, progress=False))
    out = df[["Open", "High", "Low", "Close"]].astype(float).dropna()
    if isinstance(out.columns, pd.MultiIndex):
        out.columns = out.columns.get_level_values(0)
    return out


def resample_4h(df):
    out = df.resample("4h").agg({"Open": "first", "High": "max", "Low": "min", "Close": "last"})
    return out.dropna()


def atr_series(h, l, c, n=22):
    prev = c.shift()
    tr = pd.concat([h - l, (h - prev).abs(), (l - prev).abs()], axis=1).max(axis=1)
    return tr.ewm(alpha=1 / n, adjust=False).mean()


def simulate_trend(df, variant, frac, trace=None):
    """Long-only a regime: `frac` = frazione dell'equity allocata quando il regime
    e' rialzista. Nessun take-profit: l'uscita e' il regime (V1/V2), il chandelier
    o l'incrocio ribassista (V3/V4). Ritorna (equity, trades, n_switches).
    `trace` (opzionale, non cambia i risultati): lista che riceve, barra per barra,
    (indice, in posizione a fine barra, ATR22, SMA200, Donchian20). Serve al test
    di parita' con l'app (tools/genera_parita_crypto.py)."""
    c = df["Close"]
    h, l = df["High"], df["Low"]
    sma200 = c.rolling(200).mean()
    ema50 = c.ewm(span=50, adjust=False).mean()
    ema200 = c.ewm(span=200, adjust=False).mean()
    atr = atr_series(h, l, c, 22)
    don_hi = h.rolling(20).max().shift(1)   # massimo delle 20 barre PRECEDENTI
    n = len(df)
    warm = 200 if variant in ("sma200", "sma200h") else max(200, 22)
    cash = START
    qty = 0.0
    entry_px = 0.0
    highest = 0.0
    equity = np.full(n, START)
    trades = []
    for i in range(warm, n):
        px = c.iat[i]
        in_pos = qty > 0
        if in_pos:
            highest = max(highest, px)
            exit_px = None
            if variant == "sma200":
                if px < sma200.iat[i]:
                    exit_px = px
            elif variant == "sma200h":
                if px < 0.97 * sma200.iat[i]:
                    exit_px = px
            elif variant == "ema_cross":
                chandelier = highest - 3.0 * atr.iat[i]
                if px < ema200.iat[i] or px < chandelier:
                    exit_px = max(px, 0.0)
            elif variant == "donchian":
                chandelier = highest - 3.0 * atr.iat[i]
                if px < sma200.iat[i] or px < chandelier:
                    exit_px = max(px, 0.0)
            if exit_px is not None:
                cash += qty * exit_px * (1 - COST)
                trades.append({"ret": (exit_px / entry_px - 1) - 2 * COST})
                qty, entry_px, highest = 0.0, 0.0, 0.0
        if qty == 0:
            want = False
            if variant in ("sma200", "sma200h"):
                want = px > sma200.iat[i]
            elif variant == "ema_cross":
                want = ema50.iat[i] > ema200.iat[i] and px > ema200.iat[i]
            elif variant == "donchian":
                want = px > sma200.iat[i] and px > don_hi.iat[i]
            if want:
                budget = equity[i - 1] * frac
                spend = min(cash, budget)
                if spend > 0:
                    qty = spend * (1 - COST) / px
                    cash -= spend
                    entry_px, highest = px, px
        equity[i] = cash + qty * px
        if trace is not None:
            trace.append((i, qty > 0, float(atr.iat[i]), float(sma200.iat[i]), float(don_hi.iat[i])))
    if qty > 0:  # chiusura forzata a fine dati (contata come trade)
        trades.append({"ret": (c.iat[-1] / entry_px - 1) - 2 * COST})
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


def verdict(eq, ppy):
    """Criteri A-D pre-registrati (vedi docstring). Stampa PASS/FAIL per criterio."""
    m = metrics(eq, ppy)
    if m is None:
        return "dati insufficienti"
    half = len(eq) // 2
    m1, m2 = metrics(eq.iloc[:half], ppy), metrics(eq.iloc[half:], ppy)
    recent = eq[eq.index >= pd.Timestamp(RECENT_START, tz=eq.index.tz)]
    mr = metrics(recent, ppy) if len(recent) > 30 else None
    a = m["cagr"] >= 0.03
    b = m["dd"] >= -0.20
    c = (mr is not None and mr["cagr"] >= -0.02) if mr is not None else None
    d = (m1 is not None and m2 is not None and m1["cagr"] > 0 and m2["cagr"] > 0)
    parts = [f"A({'PASS' if a else 'FAIL'}) B({'PASS' if b else 'FAIL'}) "
             f"C({'n.d.' if c is None else ('PASS' if c else 'FAIL')}) D({'PASS' if d else 'FAIL'})"]
    ok = a and b and (c is not False) and d
    parts.append("=> ENTRA IN CANDIDATURA" if ok else "=> BOCCIATA")
    return " ".join(parts)


def portfolio(dfs, variant, frac):
    """Ogni moneta riceve 1/len(COINS) dell'equity quando il suo regime e'
    rialzista: equity per moneta normalizzata al suo punto di partenza, poi media
    dei rendimenti (equal weight, ribilanciata implicitamente ogni barra)."""
    eqs = {}
    for t, df in dfs.items():
        eq, _ = simulate_trend(df, variant, frac / len(COINS))
        eqs[t] = eq
    rets = pd.DataFrame({t: e.pct_change() for t, e in eqs.items()}).dropna()
    port = START * (1 + rets.mean(axis=1)).cumprod()
    return port


# --- P2 (13/11/2026): cooldown dopo l'uscita e ingressi maker sul V4 ---
# Le regole IMPLEMENTATE nell'app sono V4 (Donchian20 sopra SMA200, chandelier
# 3*ATR22). Queste due varianti P2 erano in backlog da validare con i numeri
# prima di toccare l'app (regola dei cambi: mai senza backtest).

def simulate_v4(df, frac, cooldown=0, maker=False, maker_cost=0.001):
    """V4 con le due varianti P2. `cooldown=0, maker=False` riproduce ESATTAMENTE
    la V4 di simulate_trend (riga di sanita' nella tabella: se non coincide,
    c'e' un bug qui e lo studio non vale niente).

    - cooldown > 0: dopo UNA USCITA (chandelier o regime: nei dati daily non si
      distingue onestamente quale sia "colpa" dello stop) niente rientro per
      `cooldown` barre, compresa la barra dell'uscita quando cooldown >= 1.
    - maker=True: ingresso con ordine LIMIT al livello di rottura (il massimo a
      20 barre PRECEDENTI della barra del segnale) invece che a mercato alla
      chiusura del segnale. Modello di fill ONESTO: riempito SOLO se la barra
      SUCCESSIVA scambia a quel livello (Low <= livello), al prezzo del livello,
      con costo maker (0,10%: fee maker Alpaca crypto primo scaglione) invece
      del taker COST; se non lo tocca l'ordine SCADE e non c'e' fill (mai un
      fill "guardando avanti" con il vantaggio del senno di poi)."""
    c = df["Close"]
    h, l = df["High"], df["Low"]
    sma200 = c.rolling(200).mean()
    atr = atr_series(h, l, c, 22)
    don_hi = h.rolling(20).max().shift(1)
    n = len(df)
    cash = START
    qty = 0.0
    entry_px = 0.0
    highest = 0.0
    equity = np.full(n, START)
    cooldown_until = -1      # rientri bloccati fino a questa barra (esclusa)
    pending_level = None     # ordine limit piazzato alla barra precedente
    for i in range(200, n):
        px = c.iat[i]
        if qty > 0:
            highest = max(highest, px)
            chandelier = highest - 3.0 * atr.iat[i]
            if px < sma200.iat[i] or px < chandelier:
                cash += qty * px * (1 - COST)
                qty, entry_px, highest = 0.0, 0.0, 0.0
                cooldown_until = i + cooldown - 1   # 0 = rientro subito, come V4
        elif pending_level is not None:
            if l.iat[i] <= pending_level:           # il livello e' stato scambiato
                budget = equity[i - 1] * frac
                spend = min(cash, budget)
                if spend > 0:
                    qty = spend * (1 - maker_cost) / pending_level
                    cash -= spend
                    entry_px, highest = pending_level, pending_level
            pending_level = None
        if qty == 0 and pending_level is None and i > cooldown_until:
            if px > sma200.iat[i] and px > don_hi.iat[i]:
                if maker:
                    pending_level = don_hi.iat[i]  # limit valido UNA barra
                else:
                    budget = equity[i - 1] * frac
                    spend = min(cash, budget)
                    if spend > 0:
                        qty = spend * (1 - COST) / px
                        cash -= spend
                        entry_px, highest = px, px
        equity[i] = cash + qty * px
    return pd.Series(equity, index=df.index)


def portfolio_v4(dfs, frac, cooldown, maker):
    eqs = {t: simulate_v4(df, frac / len(COINS), cooldown, maker) for t, df in dfs.items()}
    rets = pd.DataFrame({t: e.pct_change() for t, e in eqs.items()}).dropna()
    return START * (1 + rets.mean(axis=1)).cumprod()


def main():
    print("## Studio CRYPTO trend-following a regime (solo analisi, non cambia l'app)")
    print(f"\nRegole NUOVE dopo il bando della proposta 18 (mean-reversion bocciata): "
          f"SMA200 / SMA200+isteresi / EMA50>EMA200+chandelier / Donchian20+chandelier. "
          f"Long-only, senza TP fisso, costi {COST:.3%}/lato, frazione dell'equity per posizione.")
    print("Criteri pre-registrati: A CAGR>=+3% | B maxDD<=-20% | C finestra 2024-11→oggi "
          "CAGR>=-2% | D entrambe le meta' > 0. Deflated Sharpe: https://ssrn.com/abstract=2460551.\n")

    dfs_d = {t: load_ohlc(t, START_DAILY, "1d") for t in COINS}
    _win = portfolio(dfs_d, "sma200", 1.0)
    print(f"### Daily (dal 2018, 365 gg/anno) — la decisione si prende QUI")
    print(f"Finestra comune delle righe EW del paniere: dal {_win.index[0].date()} "
          f"(nascita della moneta più giovane); le righe per singola moneta usano "
          f"la loro storia completa.")
    hdr = ("| variante | CAGR / maxDD / Sharpe (tutto) | prima metà | seconda metà | verdetto |\n"
           "|---|---|---|---|---|")
    print(hdr)
    for label, variant in (("V1 SMA200", "sma200"),
                           ("V2 SMA200 isteresi 0,97", "sma200h"),
                           ("V3 EMA50>EMA200 + chandelier 3ATR", "ema_cross"),
                           ("V4 Donchian20 + chandelier 3ATR", "donchian")):
        port = portfolio(dfs_d, variant, 1.0)
        half = len(port) // 2
        m = metrics(port, 365)
        m1, m2 = metrics(port.iloc[:half], 365), metrics(port.iloc[half:], 365)
        print(f"| {label} | {fmt(m)} | {fmt(m1)} | {fmt(m2)} | {verdict(port, 365)} |")
    # benchmark B&H EW sulla finestra comune + contante
    bhr = pd.DataFrame({t: dfs_d[t]["Close"].pct_change() for t in COINS}).dropna()
    bh = START * (1 + bhr.mean(axis=1)).cumprod()
    half = len(bh) // 2
    print(f"| Benchmark buy&hold EW (dal {bh.index[0].date()}) | {fmt(metrics(bh, 365))} "
          f"| {fmt(metrics(bh.iloc[:half], 365))} | {fmt(metrics(bh.iloc[half:], 365))} | — |")
    print("| Contante (zero) | +0,0% / 0% / — | — | — | — |")
    # per-coin della migliore famiglia (SMA200, dichiarata in anticipo come baseline)
    print("\nDettaglio per moneta (V1 SMA200):")
    print("| moneta | CAGR / maxDD / Sharpe | verdetto |")
    print("|---|---|---|")
    for t in COINS:
        eq, _ = simulate_trend(dfs_d[t], "sma200", 1.0)
        print(f"| {t} | {fmt(metrics(eq, 365))} | {verdict(eq, 365)} |")

    # --- P2: cooldown dopo l'uscita e ingressi maker sul V4 (regole dell'app) ---
    # Criteri di adozione PRE-REGISTRATI prima del run: una variante P2 entra
    # nell'app SOLO se (1) CAGR full-window > baseline V4, (2) maxDD non peggio
    # di 3 punti percentuali rispetto alla baseline, (3) finestra orso non
    # peggio di 1 punto, (4) entrambe le meta' > 0. Altrimenti si respinge con
    # i numeri stampati qui (regola del repo: cambi solo con backtest).
    print("\n### P2 (studio, non cambia l'app): cooldown dopo l'uscita e ingressi maker sul V4 (le regole implementate)")
    print(f"Criteri pre-registrati: si adotta SOLO se CAGR > baseline E maxDD >= baseline - 3pp "
          f"E finestra orso non peggio di 1pp E meta' > 0. Maker: limit al livello Donchian20 valido "
          f"1 barra, fill solo se scambiato (Low <= livello), fee maker 0,10% contro taker {COST:.2%}.")
    base = portfolio_v4(dfs_d, 1.0, 0, False)
    rows = [("V4 baseline (mercato alla chiusura, nessuna pausa)", 0, False),
            ("V4 + pausa 3 barre dopo l'uscita", 3, False),
            ("V4 + pausa 5 barre dopo l'uscita", 5, False),
            ("V4 + pausa 10 barre dopo l'uscita", 10, False),
            ("V4 ingresso maker (limit al livello Donchian20)", 0, True),
            ("V4 maker + pausa 5 barre", 5, True)]
    print("| variante P2 | CAGR / maxDD / Sharpe (tutto) | prima metà | seconda metà | orso 2024-11→oggi |")
    print("|---|---|---|---|---|")
    for label, cd, mk in rows:
        port = portfolio_v4(dfs_d, 1.0, cd, mk)
        half = len(port) // 2
        m = metrics(port, 365)
        m1, m2 = metrics(port.iloc[:half], 365), metrics(port.iloc[half:], 365)
        recent = port[port.index >= pd.Timestamp(RECENT_START, tz=port.index.tz)]
        mr = metrics(recent, 365) if len(recent) > 30 else None
        print(f"| {label} | {fmt(m)} | {fmt(m1)} | {fmt(m2)} | {fmt(mr)} |")
    print("Sanita': la riga baseline deve coincidere con la V4 della prima tabella, altrimenti questo studio non vale.")

    # --- 4H: controllo secondario sulla finestra 1h (~730 giorni, tutto orso) ---
    dfs_h = {t: load_ohlc(t, None, "1h", period="730d") for t in COINS}
    w = dfs_h[COINS[0]]
    print(f"\n### 4H (ricampionata da 1h, finestra reale {w.index[0].date()} → {w.index[-1].date()}) "
          f"— controllo secondario: in un orso long-only deve restare ~piatta")
    dfs_4h = {t: resample_4h(dfs_h[t]) for t in COINS}
    print(hdr)
    for label, variant in (("V1 SMA200 4H", "sma200"),
                           ("V2 SMA200 isteresi 4H", "sma200h"),
                           ("V4 Donchian20 4H", "donchian")):
        port = portfolio(dfs_4h, variant, 1.0)
        half = len(port) // 2
        m = metrics(port, 365 * 6)
        m1, m2 = metrics(port.iloc[:half], 365 * 6), metrics(port.iloc[half:], 365 * 6)
        print(f"| {label} | {fmt(m)} | {fmt(m1)} | {fmt(m2)} | C qui non si applica (finestra=orso) |")
    bh4 = START * (1 + pd.DataFrame({t: dfs_4h[t]["Close"].pct_change() for t in COINS}).dropna().mean(axis=1)).cumprod()
    print(f"| Benchmark buy&hold EW 4H | {fmt(metrics(bh4, 365 * 6))} | — | — | — |")

    print("\nNota: sul 4H i criteri A/D non si applicano (la finestra 1h copre solo l'orso "
          "2024-2026). La decisione spetta al proprietario, solo sulle righe del daily.")


if __name__ == "__main__":
    main()
