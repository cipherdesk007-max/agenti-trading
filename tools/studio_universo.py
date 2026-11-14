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

CORREZIONE (14/11/2026, secondo giro della sola parte crypto). Il primo giro
(run 43568807869) usava portfolio_v4 di backtest_trend_crypto.py, che divide
due volte per il numero di monete: ogni moneta entra con 1/N del SUO sottoconto
e poi si fa la MEDIA dei sottoconti, quindi ogni ingresso vale 1/N² del
capitale (1/36 con 6 monete, 1/25 con 5). L'app invece dà a ogni coppia 1/5
del conto (CryptoStrategy.positionBudget). Due conseguenze:
  - i numeri della crypto scritti nei documenti (+8,4% annuo, perdita massima
    -9%) valgono per posizioni circa 7 volte più piccole di quelle dell'app;
  - nel primo giro più monete = posizioni più piccole = rendimento più basso
    per costruzione: il confronto fra panieri non diceva niente.
Qui la crypto è rifatta con UN SOLO CONTO e la stessa regola di dimensione
dell'app: min(valore del conto / N, liquidità x 0,98) a ogni ingresso, nessun
ribilanciamento a posizione aperta. I criteri 1-4 sono rimasti quelli scritti
prima del primo giro. Le regole V4 e gli indicatori sono gli stessi di
simulate_v4 (la riga "come lo studio originale" serve da controllo: deve
ridare i numeri dei documenti).
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


def conto_unico(dfs, n_coppie, costo, inizio, riserva=0.02):
    """V4 su UN SOLO conto, con la dimensione delle posizioni dell'app
    (Sources/Core/CryptoStrategy.swift, positionBudget): a ogni ingresso la
    coppia riceve min(valore del conto / n_coppie, liquidità x (1 - riserva)).
    Indicatori e regole identici a crypto.simulate_v4: regime chiusura > SMA200,
    ingresso sopra il massimo delle 20 barre precedenti, uscita sotto SMA200 o
    sotto il massimo delle chiusure dall'ingresso - 3 x ATR22. Gli indicatori si
    calcolano su tutta la storia della moneta; il conto parte da `inizio`.
    Ritorna (valore del conto giorno per giorno, numero di vendite)."""
    giorni = sorted(set().union(*[set(d.index) for d in dfs.values()]))
    giorni = [g for g in giorni if g >= inizio]
    indice = pd.DatetimeIndex(giorni)
    serie = {}
    for t, df in dfs.items():
        c, h, l = df["Close"], df["High"], df["Low"]
        tabella = pd.DataFrame({"c": c, "sma": c.rolling(200).mean(),
                                "atr": crypto.atr_series(h, l, c, 22),
                                "don": h.rolling(20).max().shift(1)}).reindex(indice)
        serie[t] = {k: tabella[k].to_numpy(dtype=float) for k in tabella.columns}
    cassa = crypto.START
    qty = {t: 0.0 for t in dfs}
    massimo = {t: 0.0 for t in dfs}
    ultimo = {t: 0.0 for t in dfs}
    valori, vendite = [], 0
    for i in range(len(giorni)):
        for t in dfs:
            px = serie[t]["c"][i]
            if px != px:            # NaN: quel giorno la moneta non ha dati
                continue
            ultimo[t] = px
            if qty[t] > 0:
                massimo[t] = max(massimo[t], px)
                if px < serie[t]["sma"][i] or px < massimo[t] - 3.0 * serie[t]["atr"][i]:
                    cassa += qty[t] * px * (1 - costo)
                    qty[t], massimo[t] = 0.0, 0.0
                    vendite += 1
        totale = cassa + sum(qty[t] * ultimo[t] for t in dfs)
        for t in dfs:
            px = serie[t]["c"][i]
            if px != px or qty[t] > 0:
                continue
            if px > serie[t]["sma"][i] and px > serie[t]["don"][i]:   # con NaN il confronto è falso
                spesa = min(totale / n_coppie, max(cassa, 0.0) * (1 - riserva))
                if spesa > 1.0:
                    qty[t] = spesa * (1 - costo) / px
                    cassa -= spesa
                    massimo[t] = px
        valori.append(cassa + sum(qty[t] * ultimo[t] for t in dfs))
    return pd.Series(valori, index=indice), vendite


def sotto_il_blocco(eq, soglia=0.10):
    """Quante volte e per quanto tempo il conto è sceso oltre `soglia` dal suo
    massimo: è la soglia del blocco dell'app (nessun nuovo ingresso, sblocco a mano)."""
    calo = eq / eq.cummax() - 1
    sotto = calo < -soglia
    episodi = int((sotto & ~sotto.shift(1, fill_value=False)).sum())
    return episodi, float(sotto.mean())


def riga_conto(nome, eq, vendite=None):
    m = crypto.metrics(eq, 365)
    meta = len(eq) // 2
    m1, m2 = crypto.metrics(eq.iloc[:meta], 365), crypto.metrics(eq.iloc[meta:], 365)
    recente = eq[eq.index >= pd.Timestamp(crypto.RECENT_START, tz=eq.index.tz)]
    mr = crypto.metrics(recente, 365) if len(recente) > 30 else None
    episodi, quota = sotto_il_blocco(eq)
    anni = len(eq) / 365
    return dict(nome=nome, m=m, m1=m1, m2=m2, mr=mr, episodi=episodi, quota=quota,
                vendite=None if vendite is None else vendite / anni)


def stampa_righe(righe, criterio_contro=None):
    print("| caso | annuo / perdita max / Sharpe | prima metà | seconda metà | ribasso 2024-11 -> oggi | "
          "volte oltre -10% dal massimo (tempo passato sotto) | vendite/anno | esito |")
    print("|---|---|---|---|---|---|---|---|")
    for r in righe:
        esito = ""
        if criterio_contro is not None:
            base = criterio_contro
            if r is base:
                esito = "riferimento"
            else:
                c1 = r["m"]["cagr"] >= base["m"]["cagr"]
                c2 = r["m"]["dd"] >= base["m"]["dd"] - 0.03
                c3 = (r["mr"] is not None and base["mr"] is not None and r["mr"]["cagr"] >= base["mr"]["cagr"] - 0.01)
                c4 = r["m1"]["cagr"] > 0 and r["m2"]["cagr"] > 0
                esito = ("PASSA" if (c1 and c2 and c3 and c4) else "BOCCIATO") + \
                    f" (1 {'sì' if c1 else 'no'}, 2 {'sì' if c2 else 'no'}, 3 {'sì' if c3 else 'no'}, 4 {'sì' if c4 else 'no'})"
        vendite = "—" if r["vendite"] is None else f"{r['vendite']:.0f}"
        print(f"| {r['nome']} | {crypto.fmt(r['m'])} | {pct(r['m1']['cagr'])} | {pct(r['m2']['cagr'])} | "
              f"{pct(r['mr']['cagr']) if r['mr'] else '—'} | {r['episodi']} ({r['quota']:.0%}) | {vendite} | {esito} |")


def studio_crypto():
    su_alpaca = coppie_alpaca()
    dfs = {}
    note = []
    for t in CRYPTO_BASE + CRYPTO_PIU6:
        try:
            d = crypto.load_ohlc(YAHOO.get(t, t), crypto.START_DAILY, "1d")
        except Exception:  # noqa: BLE001 - una moneta senza dati si esclude e si dichiara
            d = None
        if d is None or len(d) < 900:
            note.append(f"- {t}: storico insufficiente o non scaricabile, esclusa dallo studio")
            continue
        dfs[t] = d
        if su_alpaca is not None and t.replace("-", "/") not in su_alpaca:
            note.append(f"- {t}: NON risulta scambiabile su Alpaca in USD (lo studio la calcola lo stesso, ma non si potrebbe aggiungere)")
    costo_studio = crypto.COST

    # ---- 1. La dimensione delle posizioni: lo studio originale contro l'app
    print("## CRYPTO 1 · Dimensione delle posizioni: lo studio originale contro l'app\n")
    sei = [t for t in CRYPTO_BASE + ["DOGE-USD"] if t in dfs]
    cinque = [t for t in CRYPTO_BASE if t in dfs]
    crypto.COINS = sei
    originale = crypto.portfolio_v4({t: dfs[t] for t in sei}, 1.0, 0, False)
    inizio = originale.index[0]
    print(f"Finestra: dal {inizio.date()} a oggi (da quando esistono tutte e 6 le monete dello studio originale). "
          f"Costo {costo_studio:.2%} per lato, come nello studio originale.\n")
    eq6, v6 = conto_unico({t: dfs[t] for t in sei}, len(sei), costo_studio, inizio)
    eq5, v5 = conto_unico({t: dfs[t] for t in cinque}, len(cinque), costo_studio, inizio)
    compra_e_tieni = pd.DataFrame({t: dfs[t]["Close"].pct_change() for t in cinque}).dropna()
    compra_e_tieni = compra_e_tieni[compra_e_tieni.index >= inizio]
    bh = crypto.START * (1 + compra_e_tieni.mean(axis=1)).cumprod()
    stampa_righe([
        riga_conto(f"Come lo studio originale: {len(sei)} monete, ogni ingresso 1/{len(sei) ** 2} del capitale "
                   "(controllo: deve ridare i numeri dei documenti)", originale),
        riga_conto(f"Stesse {len(sei)} monete, un conto solo, ogni ingresso 1/{len(sei)} del conto", eq6, v6),
        riga_conto(f"COME L'APP: le {len(cinque)} coppie, un conto solo, ogni ingresso 1/{len(cinque)} del conto", eq5, v5),
        riga_conto(f"Comprare le {len(cinque)} coppie e tenerle (parti uguali, senza regole)", bh),
    ])
    print("\nLa riga COME L'APP è il profilo vero della modalità CRYPTO con le regole di oggi. "
          "L'app blocca i nuovi ingressi quando il conto perde il 10% dal massimo e si sblocca solo a mano: "
          "la colonna dice quante volte sarebbe successo.\n")

    # ---- 2. Il costo vero
    print("## CRYPTO 2 · Quanto pesa la commissione vera (le 5 coppie, come l'app)\n")
    print("Lo studio usa 0,20% per lato. Sul conto paper Alpaca ha trattenuto lo 0,25% all'acquisto "
          "(run 43557460572); con lo scarto fra prezzo d'acquisto e di vendita il costo reale è più alto.\n")
    righe = []
    for costo in (0.0020, 0.0025, 0.0035, 0.0050):
        eq, v = conto_unico({t: dfs[t] for t in cinque}, len(cinque), costo, inizio)
        righe.append(riga_conto(f"costo {costo:.2%} per lato", eq, v))
    stampa_righe(righe)

    # ---- 2 bis. Quanto mettere su ogni coppia: il rischio che si sceglie
    # Non è una ricerca del numero migliore: il rendimento sale e scende insieme
    # al rischio. Serve al proprietario per scegliere la perdita che accetta.
    print("\n## CRYPTO 2 bis · Quanto mettere su ogni coppia (le 5 coppie, un conto solo, costo 0,25% per lato)\n")
    print("L'app oggi usa 1/5 del conto per coppia. Lo studio originale aveva provato, senza volerlo, 1/36 del capitale. "
          "Il blocco dell'app scatta al -10% dal massimo; il criterio B dello studio chiedeva una perdita massima entro -20%.\n")
    righe = []
    for divisore in (5, 8, 10, 15, 25):
        eq, v = conto_unico({t: dfs[t] for t in cinque}, divisore, 0.0025, inizio)
        investito = min(1.0, len(cinque) / divisore)
        righe.append(riga_conto(f"1/{divisore} del conto per coppia (al massimo {investito:.0%} del conto investito)", eq, v))
    stampa_righe(righe)

    # ---- 3. Panieri più larghi, a parità di regola di dimensione
    print("\n## CRYPTO 3 · Coppie attuali contro panieri più larghi (un conto solo, ogni coppia 1/N del conto)\n")
    if su_alpaca is not None:
        print(f"Coppie in USD scambiabili su Alpaca oggi ({len(su_alpaca)}): {', '.join(su_alpaca)}\n")
    for n in note:
        print(n)
    # Tutti i panieri sulla stessa finestra: da quando OGNI moneta ha le 200
    # barre che servono alla media (prima non potrebbe essere comprata).
    pronta = max(d.index[200] for d in dfs.values())
    print(f"\nFinestra uguale per tutti: dal {pronta.date()} (da quel giorno ogni moneta ha le 200 barre "
          f"che servono alla regola). Costo {costo_studio:.2%} per lato.\n")
    panieri = [("ATTUALI (5 coppie)", CRYPTO_BASE),
               ("+3: DOGE LTC BCH (8)", CRYPTO_BASE + CRYPTO_PIU3),
               ("+6: anche DOT UNI AAVE (11)", CRYPTO_BASE + CRYPTO_PIU6)]
    righe = []
    for nome, lista in panieri:
        presenti = [t for t in lista if t in dfs]
        eq, v = conto_unico({t: dfs[t] for t in presenti}, len(presenti), costo_studio, pronta)
        righe.append(riga_conto(nome if len(presenti) == len(lista) else f"{nome} [solo {len(presenti)} con dati]", eq, v))
    stampa_righe(righe, criterio_contro=righe[0])
    print("\nCriterio (scritto prima del primo giro): 1 rendimento annuo >= attuale; 2 perdita massima non peggiore "
          "di oltre 3 punti; 3 finestra ribassista non peggiore di oltre 1 punto; 4 entrambe le metà sopra zero.\n")


if __name__ == "__main__":
    print("# Studio: panieri allargati (ETF e crypto) · criteri scritti prima, vedi intestazione dello script\n")
    studio_etf()
    studio_crypto()
