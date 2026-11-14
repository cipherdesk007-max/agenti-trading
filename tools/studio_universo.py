#!/usr/bin/env python3
"""STUDIO (non cambia l'app): conviene allargare il paniere ETF e le coppie crypto?

Richiesta del proprietario (14/11/2026): "estendere il mercato ETF e quello
cripto perché sono poche". Cambiare il paniere è cambiare la strategia: i
numeri in docs/STATO.md valgono per i 15 ETF e le 5 coppie di oggi. Qui si
misura, con LE STESSE REGOLE dell'app (tools/backtest_app.py per la giornaliera,
simulate_v4 di tools/backtest_trend_crypto.py per la crypto), che cosa succede
con panieri più larghi.

LISTE DECISE PRIMA di vedere un numero (niente scelta a posteriori dei
"migliori"): si aggiunge per liquidità e per tipo di mercato non ancora coperto.
  ETF  +8 macro   : EFA EEM (azioni estere), IEF LQD HYG (obbligazioni),
                    VNQ (immobiliare), SLV DBC (materie prime)
       +7 settori : XBI SMH XME KRE XOP GDX XRT (industrie USA, più volatili)
  CRYPTO +3       : DOGE LTC BCH (le più vecchie e scambiate su Alpaca)
         +6       : le 3 sopra + DOT UNI AAVE

CRITERIO scritto prima (un paniere largo si propone SOLO se li passa tutti):
  ETF     1. Sharpe 2006-oggi >= quello dei 15 ETF attuali
          2. perdita massima 2006-oggi non peggiore di oltre 2 punti
          3. rendimento annuo degli ultimi 3 anni >= quello attuale
          4. rendimento annuo > 0 in entrambe le metà (2006-2015, 2016-oggi)
  CRYPTO  sulla STESSA finestra per tutti i panieri (da quando esistono tutte
          le monete), contro le 5 coppie attuali:
          1. rendimento annuo >= quello attuale
          2. perdita massima non peggiore di oltre 3 punti
          3. finestra ribassista (2024-11 -> oggi) non peggiore di oltre 1 punto
          4. rendimento annuo > 0 in entrambe le metà
Varianti provate: 2 per gli ETF e 2 per la crypto, tutte riportate qui sotto,
anche quelle bocciate. Un "passa" NON cambia l'app: resta una proposta, con
prova in ombra e ok del proprietario (AGENTS.md, regola 2).
"""
import datetime as dt
import json
import os
import urllib.request

import pandas as pd
import yfinance as yf

import backtest_app as giornaliera
import backtest_trend_crypto as crypto

ETF_BASE = list(giornaliera.ETFS)
ETF_MACRO = ["EFA", "EEM", "IEF", "LQD", "HYG", "VNQ", "SLV", "DBC"]
ETF_SETTORI = ["XBI", "SMH", "XME", "KRE", "XOP", "GDX", "XRT"]
CRYPTO_BASE = ["BTC-USD", "ETH-USD", "SOL-USD", "AVAX-USD", "LINK-USD"]
CRYPTO_PIU3 = ["DOGE-USD", "LTC-USD", "BCH-USD"]
CRYPTO_PIU6 = CRYPTO_PIU3 + ["DOT-USD", "UNI-USD", "AAVE-USD"]
YAHOO = {"UNI-USD": "UNI7083-USD"}  # su Yahoo "UNI-USD" è un'altra moneta


def pct(x):
    return "—" if x is None else f"{x:+.1%}"


def studio_etf():
    print("## Paniere ETF della GIORNALIERA: attuale contro allargato\n")
    tutti = ETF_BASE + ETF_MACRO + ETF_SETTORI
    df = yf.download(tutti, start="2004-06-01", auto_adjust=True, progress=False, group_by="column")
    tre_anni = (dt.date.today() - dt.timedelta(days=3 * 365)).isoformat()
    panieri = [("ATTUALE (15 ETF)", ETF_BASE),
               ("+8 macro (23 ETF)", ETF_BASE + ETF_MACRO),
               ("+8 macro +7 settori (30 ETF)", tutti)]
    righe = []
    for nome, lista in panieri:
        o, h, l, c = (df[k][lista].astype(float) for k in ("Open", "High", "Low", "Close"))
        eq, trades, segnali = giornaliera.simulate(o, h, l, c)
        pieno = giornaliera.metrics(eq, "2006-01-01", None)
        m1 = giornaliera.metrics(eq, "2006-01-01", "2015-12-31")
        m2 = giornaliera.metrics(eq, "2016-01-01", None)
        m3 = giornaliera.metrics(eq, tre_anni, None)
        anni = len(eq) / 252
        righe.append(dict(nome=nome, pieno=pieno, m1=m1, m2=m2, m3=m3,
                          trade=len(trades) / anni, segnali=segnali / anni))
    base = righe[0]
    print("| paniere | 2006-oggi: annuo / perdita max / Sharpe | 2006-2015 | 2016-oggi | ultimi 3 anni | operazioni/anno | segnali/anno | esito |")
    print("|---|---|---|---|---|---|---|---|")
    for r in righe:
        p = r["pieno"]
        if r is base:
            esito = "riferimento"
        else:
            c1 = p["sharpe"] >= base["pieno"]["sharpe"]
            c2 = p["dd"] >= base["pieno"]["dd"] - 0.02
            c3 = r["m3"]["cagr"] >= base["m3"]["cagr"]
            c4 = r["m1"]["cagr"] > 0 and r["m2"]["cagr"] > 0
            esito = ("PASSA" if (c1 and c2 and c3 and c4) else "BOCCIATO") + \
                f" (1 {'sì' if c1 else 'no'}, 2 {'sì' if c2 else 'no'}, 3 {'sì' if c3 else 'no'}, 4 {'sì' if c4 else 'no'})"
        print(f"| {r['nome']} | {p['cagr']:+.1%} / {p['dd']:.0%} / {p['sharpe']:.2f} | {pct(r['m1']['cagr'])} | "
              f"{pct(r['m2']['cagr'])} | {pct(r['m3']['cagr'])} | {r['trade']:.0f} | {r['segnali']:.0f} | {esito} |")
    print("\nNota: nello studio fra più segnali si compra l'RSI2 più basso; nell'app sceglie Kimi. "
          "Più ETF = più segnali = più chiamate a Kimi (colonna segnali/anno).\n")


def coppie_alpaca():
    """Coppie crypto in USD che Alpaca fa scambiare davvero (dato grezzo, se ci sono le chiavi)."""
    chiave, segreto = os.environ.get("APCA_API_KEY_ID"), os.environ.get("APCA_API_SECRET_KEY")
    if not chiave or not segreto:
        return None
    richiesta = urllib.request.Request("https://paper-api.alpaca.markets/v2/assets?asset_class=crypto&status=active")
    richiesta.add_header("APCA-API-KEY-ID", chiave)
    richiesta.add_header("APCA-API-SECRET-KEY", segreto)
    try:
        with urllib.request.urlopen(richiesta, timeout=20) as risposta:
            elenco = json.loads(risposta.read().decode())
    except Exception:  # noqa: BLE001 - dato facoltativo: senza, lo studio prosegue
        return None
    return sorted(a["symbol"] for a in elenco if a.get("tradable") and str(a.get("symbol", "")).endswith("/USD"))


def studio_crypto():
    print("## Coppie CRYPTO (regola V4 dell'app): attuali contro allargate\n")
    su_alpaca = coppie_alpaca()
    if su_alpaca is not None:
        print(f"Coppie in USD scambiabili su Alpaca oggi ({len(su_alpaca)}): {', '.join(su_alpaca)}\n")
    dfs = {}
    for t in CRYPTO_BASE + CRYPTO_PIU6:
        try:
            d = crypto.load_ohlc(YAHOO.get(t, t), crypto.START_DAILY, "1d")
        except Exception:  # noqa: BLE001 - una moneta senza dati si esclude e si dichiara
            d = None
        if d is None or len(d) < 900:
            print(f"- {t}: storico insufficiente o non scaricabile, esclusa dallo studio")
            continue
        dfs[t] = d
        if su_alpaca is not None and t.replace("-", "/") not in su_alpaca:
            print(f"- {t}: NON risulta scambiabile su Alpaca in USD (lo studio la calcola lo stesso, ma non si potrebbe aggiungere)")
    inizio = max(d.index[0] for d in dfs.values())
    comuni = {t: d[d.index >= inizio] for t, d in dfs.items()}
    print(f"\nFinestra comune a tutte le monete: dal {inizio.date()} (prima alcune non esistevano).\n")
    panieri = [("ATTUALI (5 coppie)", CRYPTO_BASE),
               ("+3: DOGE LTC BCH (8)", CRYPTO_BASE + CRYPTO_PIU3),
               ("+6: anche DOT UNI AAVE (11)", CRYPTO_BASE + CRYPTO_PIU6)]
    righe = []
    for nome, lista in panieri:
        lista = [t for t in lista if t in comuni]
        crypto.COINS = lista  # ogni coppia riceve 1/N del capitale, come nell'app
        port = crypto.portfolio_v4({t: comuni[t] for t in lista}, 1.0, 0, False)
        m = crypto.metrics(port, 365)
        meta = len(port) // 2
        m1, m2 = crypto.metrics(port.iloc[:meta], 365), crypto.metrics(port.iloc[meta:], 365)
        recente = port[port.index >= pd.Timestamp(crypto.RECENT_START, tz=port.index.tz)]
        mr = crypto.metrics(recente, 365) if len(recente) > 30 else None
        righe.append(dict(nome=f"{nome}" if len(lista) == len(panieri[len(righe)][1]) else f"{nome} [solo {len(lista)} con dati]",
                          m=m, m1=m1, m2=m2, mr=mr))
    base = righe[0]
    print("| paniere | annuo / perdita max / Sharpe | prima metà | seconda metà | ribasso 2024-11 -> oggi | esito |")
    print("|---|---|---|---|---|---|")
    for r in righe:
        if r is base:
            esito = "riferimento"
        else:
            c1 = r["m"]["cagr"] >= base["m"]["cagr"]
            c2 = r["m"]["dd"] >= base["m"]["dd"] - 0.03
            c3 = (r["mr"] is not None and base["mr"] is not None and r["mr"]["cagr"] >= base["mr"]["cagr"] - 0.01)
            c4 = r["m1"]["cagr"] > 0 and r["m2"]["cagr"] > 0
            esito = ("PASSA" if (c1 and c2 and c3 and c4) else "BOCCIATO") + \
                f" (1 {'sì' if c1 else 'no'}, 2 {'sì' if c2 else 'no'}, 3 {'sì' if c3 else 'no'}, 4 {'sì' if c4 else 'no'})"
        print(f"| {r['nome']} | {crypto.fmt(r['m'])} | {pct(r['m1']['cagr'])} | {pct(r['m2']['cagr'])} | "
              f"{pct(r['mr']['cagr']) if r['mr'] else '—'} | {esito} |")
    print(f"\nCosti: {crypto.COST:.2%} per lato. Con N coppie ognuna riceve 1/N del capitale: più coppie = posizioni più piccole.\n")


if __name__ == "__main__":
    print("# Studio: panieri allargati (ETF e crypto) · criteri scritti prima, vedi intestazione dello script\n")
    studio_etf()
    studio_crypto()
