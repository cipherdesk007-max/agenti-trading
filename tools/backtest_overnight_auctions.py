"""Variante di backtest_overnight.py con i PREZZI REALI DELLE ASTE Alpaca.

La NOTTE compra in asta di chiusura (MOC) e vende in asta di apertura (OPG):
lo studio base usa close->open come approssimazione. Qui si usano i prezzi
d'asta reali di GET /v2/stocks/{symbol}/auctions (feed sip), per misurare
quanto cambia il risultato (e quanto costa davvero l'asta).

Le chiavi Alpaca si leggono dalle variabili d'ambiente APCA_API_KEY_ID /
APCA_API_SECRET_KEY (mai committate; in CI non ci sono e lo script stampa solo
una nota ed esce 0 — mai obbligatoria). Lo lancia l'altro revisore in locale.

Criterio di scarto: se con i prezzi d'asta reali il CAGR a 0,003%/lato non
resta positivo (t > 2 dopo i costi) sullo stesso periodo, la stima close->open
era ottimistica e va documentato in docs/STATO.md.
"""

import json
import os
import urllib.parse
import urllib.request

import numpy as np
import pandas as pd
import yfinance as yf

LIQUID = ["SPY", "QQQ", "IWM", "GLD"]
COST = 0.00003  # 0,003% per lato, come nello studio base
START = "2019-01-01"  # la storia aste Alpaca copre gli ultimi anni


def auctions(symbol, start, end, key_id, secret):
    """Prezzo d'asta di apertura e chiusura per giorno, dall'endpoint Alpaca."""
    base = os.environ.get("APCA_API_BASE_URL", "https://data.alpaca.markets")
    out = {}
    token = None
    while True:
        q = f"symbols={symbol}&start={start}&end={end}&feed=sip&limit=10000&sort=asc"
        if token:
            q += f"&page_token={urllib.parse.quote(token)}"
        req = urllib.request.Request(f"{base}/v2/stocks/auctions?{q}")
        req.add_header("APCA-API-KEY-ID", key_id)
        req.add_header("APCA-API-SECRET-KEY", secret)
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.load(resp)
        for entry in data.get("auctions", {}).get(symbol, []):
            day = entry["d"]
            o = entry.get("o") or []
            c = entry.get("c") or []
            if o and c:
                out[day] = (o[-1]["p"], c[-1]["p"])  # (asta apertura, asta chiusura)
        token = data.get("next_page_token")
        if not token:
            break
    return out


def main():
    key_id = os.environ.get("APCA_API_KEY_ID", "")
    secret = os.environ.get("APCA_API_SECRET_KEY", "")
    if not key_id or not secret:
        print("## Overnight con prezzi d'asta reali (Alpaca /v2/stocks/auctions)")
        print()
        print("Chiavi Alpaca non presenti in APCA_API_KEY_ID/APCA_API_SECRET_KEY: "
              "studio saltato (mai obbligatorio). Lancialo in locale con le chiavi paper.")
        return

    end = pd.Timestamp.now(tz="America/New_York").strftime("%Y-%m-%d")
    auct = {s: auctions(s, START, end, key_id, secret) for s in LIQUID}

    days = sorted(set.intersection(*[set(a) for a in auct.values()]))
    if len(days) < 100:
        print("Pochi giorni d'asta in comune: dati insufficienti.")
        return

    print(f"## Overnight con PREZZI D'ASTA REALI (MOC->OPG), {days[0]} .. {days[-1]} ({len(days)} notti)\n")
    print("Paniere SPY/QQQ/IWM/GLD a peso uguale, costo 0,003% per lato. Confronto con close->open (yfinance) sugli stessi giorni.\n")
    print("| ETF | notti | medio asta reale (t) | medio close->open (t) | diff |")
    print("|---|---|---|---|---|")

    port_asta, port_co = [], []
    for sym in LIQUID:
        d = yf.download(sym, start=START, auto_adjust=False, progress=False)
        if isinstance(d.columns, pd.MultiIndex):
            d.columns = d.columns.get_level_values(0)
        r_co = (d["Open"].shift(-1) / d["Close"] - 1).dropna()
        r_co.index = r_co.index.strftime("%Y-%m-%d")
        r_co = r_co[r_co.index.isin(days[:-1])]
        ra = []
        for i in range(len(days) - 1):
            t, t1 = days[i], days[i + 1]
            ac = auct[sym][t][1]         # asta di chiusura del giorno t (MOC)
            nxt_open = auct[sym][t1][0]  # asta di apertura del giorno t+1 (OPG)
            if ac > 0 and nxt_open > 0:
                ra.append(nxt_open / ac - 1)
        ra = pd.Series(ra, index=days[:-1])
        rc = r_co.reindex(ra.index)
        t_asta = ra.mean() / (ra.std(ddof=1) / np.sqrt(len(ra))) if len(ra) > 2 else float("nan")
        print(f"| {sym} | {len(ra)} | {ra.mean() * 100:+.4f}% ({t_asta:+.1f}) "
              f"| {rc.mean() * 100:+.4f}% | {(ra.mean() - rc.mean()) * 10000:+.1f} bp |")
        port_asta.append(ra)
        port_co.append(rc)

    pa = pd.concat(port_asta, axis=1).mean(axis=1) - 2 * COST
    pc = pd.concat(port_co, axis=1).mean(axis=1) - 2 * COST

    def stats(r):
        eq = np.cumprod(1 + r.values)
        years = len(r) / 252
        cagr = eq[-1] ** (1 / years) - 1
        dd = (eq / np.maximum.accumulate(eq) - 1).min()
        sharpe = r.mean() / r.std(ddof=1) * np.sqrt(252)
        return cagr, dd, sharpe

    ca, da, sa = stats(pa)
    cc, dc, sc = stats(pc)
    print()
    print(f"- portafoglio ASTA REALE: CAGR {ca:+.1%} · perdita max {da:.0%} · Sharpe {sa:.2f}")
    print(f"- portafoglio close->open: CAGR {cc:+.1%} · perdita max {dc:.0%} · Sharpe {sc:.2f}")
    print()
    print("Se l'asta reale resta positiva con t>2 dopo i costi, lo studio close->open era realistico; "
          "altrimenti documentare lo scostamento in docs/STATO.md.")


if __name__ == "__main__":
    main()
