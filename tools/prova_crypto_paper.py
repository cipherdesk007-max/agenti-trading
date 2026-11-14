#!/usr/bin/env python3
"""Prova sul conto PAPER di Alpaca le ipotesi su cui si regge la modalità CRYPTO.

Compra circa 12 dollari (finti) di BTC, mette e toglie uno stop, rivende tutto.
Dura meno di un minuto e lascia il conto com'era, a parte pochi centesimi finti
di commissioni. Serve a controllare sul broker vero quello che i test con il
broker finto non possono dire: come Alpaca scrive i simboli, quanto ci mette a
eseguire, se la commissione si paga in moneta, se accetta lo stop con quei
decimali, se rifiuta i doppioni.

Sicurezze:
- l'indirizzo è fisso su paper-api.alpaca.markets: con chiavi di un conto vero
  Alpaca risponde 401 e lo script si ferma senza fare niente;
- se sul conto c'è già una posizione o un ordine BTC lo script non tocca nulla;
- alla fine, anche in caso d'errore, annulla i propri ordini (prefisso
  "qsprova-") e chiude la posizione BTC che ha aperto lui.

Uso: APCA_API_KEY_ID=... APCA_API_SECRET_KEY=... python3 tools/prova_crypto_paper.py
Non stampa mai le chiavi né il numero di conto.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

TRADING = "https://paper-api.alpaca.markets"
DATA = "https://data.alpaca.markets"
PAIR = "BTC/USD"
KEY = "BTCUSD"
SPESA_USD = 12.0
PREFISSO = "qsprova-"

esiti = []


def chiama(metodo, url, corpo=None):
    """Ritorna (codice HTTP, risposta JSON o testo)."""
    dati = json.dumps(corpo).encode() if corpo is not None else None
    richiesta = urllib.request.Request(url, data=dati, method=metodo)
    richiesta.add_header("APCA-API-KEY-ID", os.environ["APCA_API_KEY_ID"])
    richiesta.add_header("APCA-API-SECRET-KEY", os.environ["APCA_API_SECRET_KEY"])
    richiesta.add_header("Accept", "application/json")
    if dati is not None:
        richiesta.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(richiesta, timeout=20) as risposta:
            testo = risposta.read().decode()
            codice = risposta.status
    except urllib.error.HTTPError as errore:
        testo = errore.read().decode()
        codice = errore.code
    try:
        return codice, json.loads(testo) if testo else None
    except ValueError:
        return codice, testo


def nota(titolo, ok, dettaglio):
    segno = "CONFERMATO" if ok else "DIVERSO"
    esiti.append((titolo, segno, dettaglio))
    print(f"[{segno}] {titolo}: {dettaglio}", flush=True)


def chiave(simbolo):
    return simbolo.upper().replace("/", "")


def posizione_btc():
    codice, elenco = chiama("GET", f"{TRADING}/v2/positions")
    if codice != 200 or not isinstance(elenco, list):
        return None
    for voce in elenco:
        if chiave(voce.get("symbol", "")) == KEY:
            return voce
    return None


def ordini_btc_aperti():
    codice, elenco = chiama("GET", f"{TRADING}/v2/orders?status=open&limit=100")
    if codice != 200 or not isinstance(elenco, list):
        return []
    return [o for o in elenco if chiave(o.get("symbol", "")) == KEY]


def aspetta_stato(order_id, finali, secondi=12.0):
    """Rilegge l'ordine finché lo stato è in `finali`. Ritorna (ordine, secondi passati, stati visti)."""
    inizio = time.time()
    visti = []
    ordine = None
    while time.time() - inizio < secondi:
        _, ordine = chiama("GET", f"{TRADING}/v2/orders/{order_id}")
        stato = (ordine or {}).get("status", "?") if isinstance(ordine, dict) else "?"
        if not visti or visti[-1] != stato:
            visti.append(stato)
        if stato in finali:
            break
        time.sleep(0.25)
    return ordine, time.time() - inizio, visti


def pulizia(aveva_posizione):
    for ordine in ordini_btc_aperti():
        if str(ordine.get("client_order_id", "")).startswith(PREFISSO):
            chiama("DELETE", f"{TRADING}/v2/orders/{ordine['id']}")
    time.sleep(1.0)
    if not aveva_posizione and posizione_btc() is not None:
        chiama("DELETE", f"{TRADING}/v2/positions/{KEY}")
        time.sleep(2.0)


def main():
    if not os.environ.get("APCA_API_KEY_ID") or not os.environ.get("APCA_API_SECRET_KEY"):
        print("Chiavi Alpaca assenti: niente da fare.")
        return 0
    codice, conto = chiama("GET", f"{TRADING}/v2/account")
    if codice != 200 or not isinstance(conto, dict):
        print(f"Il conto paper non risponde (HTTP {codice}): niente da fare. Con chiavi di un conto vero è il comportamento previsto.")
        return 1
    print(f"Conto paper: stato {conto.get('status')}, crypto {conto.get('crypto_status')}, "
          f"trading bloccato {conto.get('trading_blocked')}")
    if conto.get("trading_blocked") or conto.get("account_blocked"):
        print("Trading bloccato sul conto: niente da fare.")
        return 1
    if posizione_btc() is not None or ordini_btc_aperti():
        print("Sul conto c'è già una posizione o un ordine BTC: lo script non tocca niente. Riprova a conto libero.")
        return 1

    marca = str(int(time.time()))
    aperta_da_me = False
    try:
        # 1. Prezzo e quantità.
        _, quote = chiama("GET", f"{DATA}/v1beta3/crypto/us/latest/quotes?symbols={urllib.parse.quote(PAIR, safe='')}")
        q = ((quote or {}).get("quotes") or {}).get(PAIR) or {}
        medio = (float(q.get("bp", 0)) + float(q.get("ap", 0))) / 2
        if medio <= 0:
            print("Quotazione BTC non disponibile: niente da fare.")
            return 1
        quantita = int(SPESA_USD / medio * 1e8) / 1e8
        print(f"Prezzo medio {medio:.2f} USD, compro {quantita:.8f} BTC (circa {SPESA_USD:.0f} USD finti)")

        # 2. Acquisto a mercato: nasce in attesa? quanto ci mette?
        id_buy = f"{PREFISSO}buy-{marca}"
        codice, buy = chiama("POST", f"{TRADING}/v2/orders", {
            "symbol": PAIR, "qty": f"{quantita:.9f}", "side": "buy", "type": "market",
            "time_in_force": "gtc", "order_class": "simple", "client_order_id": id_buy})
        if codice not in (200, 201) or not isinstance(buy, dict):
            nota("Acquisto a mercato frazionato (qty a 9 decimali, tif gtc)", False, f"HTTP {codice}: {buy}")
            return 1
        aperta_da_me = True
        nota("Acquisto a mercato frazionato (qty a 9 decimali, tif gtc)", True, f"accettato, stato iniziale '{buy.get('status')}'")
        ordine, tempo, visti = aspetta_stato(buy["id"], {"filled", "canceled", "rejected", "expired"})
        eseguito = float((ordine or {}).get("filled_qty") or 0)
        nota("L'acquisto si esegue entro 3 secondi (l'app aspetta fino a 5 letture, circa 3 s)",
             (ordine or {}).get("status") == "filled" and tempo <= 3.0,
             f"stati visti {visti}, stato finale dopo {tempo:.2f} s, filled_qty {eseguito:.9f}")

        # 3. Posizione: come è scritto il simbolo, quantità al netto della commissione.
        time.sleep(0.5)
        pos = posizione_btc()
        if pos is None:
            nota("La posizione compare nell'elenco", False, "nessuna posizione BTC dopo l'eseguito")
            return 1
        nota("L'elenco posizioni scrive la coppia SENZA barra", pos.get("symbol") == KEY,
             f"simbolo '{pos.get('symbol')}' (negli ordini '{buy.get('symbol')}')")
        tenuta = float(pos.get("qty") or 0)
        nota("La commissione si paga in moneta (posizione minore dell'eseguito)", tenuta < eseguito - 1e-12,
             f"eseguito {eseguito:.9f}, in portafoglio {pos.get('qty')} (differenza {(eseguito - tenuta) / max(eseguito, 1e-12) * 100:.3f}%)")
        qty_testo = str(pos.get("qty"))
        decimali = len(qty_testo.split(".")[1]) if "." in qty_testo else 0
        nota("La quantità in portafoglio ha al massimo 9 decimali", decimali <= 9, f"'{qty_testo}' ({decimali} decimali)")

        # 4. Ricerca per client_order_id (l'app la usa per non raddoppiare).
        codice, trovato = chiama("GET", f"{TRADING}/v2/orders:by_client_order_id?client_order_id={urllib.parse.quote(id_buy, safe='')}")
        nota("L'ordine si ritrova per client_order_id", codice == 200 and isinstance(trovato, dict) and trovato.get("id") == buy["id"],
             f"HTTP {codice}")
        codice, doppio = chiama("POST", f"{TRADING}/v2/orders", {
            "symbol": PAIR, "qty": f"{quantita:.9f}", "side": "buy", "type": "market",
            "time_in_force": "gtc", "order_class": "simple", "client_order_id": id_buy})
        nota("Un secondo ordine con lo stesso client_order_id viene rifiutato", codice in (400, 403, 409, 422),
             f"HTTP {codice}: {str(doppio)[:160]}")

        # 5. Stop di vendita stop_limit GTC sulla quantità in portafoglio, prezzi a 2 decimali.
        pos = posizione_btc() or pos
        qty_stop = f"{float(pos.get('qty') or 0):.9f}"
        stop = round(medio * 0.80, 2)
        limite = round(stop * 0.998, 2)
        codice, ordine_stop = chiama("POST", f"{TRADING}/v2/orders", {
            "symbol": PAIR, "qty": qty_stop, "side": "sell", "type": "stop_limit", "time_in_force": "gtc",
            "order_class": "simple", "stop_price": f"{stop:.2f}", "limit_price": f"{limite:.2f}",
            "client_order_id": f"{PREFISSO}stop-{marca}"})
        stop_ok = codice in (200, 201) and isinstance(ordine_stop, dict)
        nota("Lo stop stop_limit GTC sulla quantità intera è accettato (prezzi a 2 decimali)", stop_ok,
             f"HTTP {codice}: " + (f"stato '{ordine_stop.get('status')}'" if stop_ok else str(ordine_stop)[:200]))
        if stop_ok:
            codice, secondo = chiama("POST", f"{TRADING}/v2/orders", {
                "symbol": PAIR, "qty": qty_stop, "side": "sell", "type": "stop_limit", "time_in_force": "gtc",
                "order_class": "simple", "stop_price": f"{stop:.2f}", "limit_price": f"{limite:.2f}",
                "client_order_id": f"{PREFISSO}stop2-{marca}"})
            nota("Un secondo stop per la stessa quantità viene rifiutato (quantità impegnata)", codice not in (200, 201),
                 f"HTTP {codice}: {str(secondo)[:160]}")
            aperti = [o for o in ordini_btc_aperti() if o.get("type") == "stop_limit" and o.get("side") == "sell"]
            nota("Lo stop compare fra gli ordini aperti con simbolo, tipo e quantità", len(aperti) >= 1,
                 "; ".join(f"{o.get('symbol')} qty {o.get('qty')} stop {o.get('stop_price')}" for o in aperti) or "nessuno")

            # 6. Annullo: è asincrono? una vendita subito dopo viene rifiutata?
            chiama("DELETE", f"{TRADING}/v2/orders/{ordine_stop['id']}")
            codice, subito = chiama("POST", f"{TRADING}/v2/orders", {
                "symbol": PAIR, "qty": qty_stop, "side": "sell", "type": "market", "time_in_force": "gtc",
                "order_class": "simple", "client_order_id": f"{PREFISSO}sell-{marca}"})
            _, tempo_annullo, visti_annullo = aspetta_stato(ordine_stop["id"], {"canceled", "filled", "expired", "rejected"})
            if codice in (200, 201):
                nota("Vendita inviata subito dopo l'annullo dello stop", True,
                     f"accettata (questa volta l'annullo era già registrato); annullo confermato dopo {tempo_annullo:.2f} s, stati {visti_annullo}")
            else:
                nota("Vendita subito dopo l'annullo rifiutata: serve l'attesa che l'app ora fa", True,
                     f"HTTP {codice}: {str(subito)[:160]}; annullo confermato dopo {tempo_annullo:.2f} s, stati {visti_annullo}")
                codice, dopo = chiama("POST", f"{TRADING}/v2/orders", {
                    "symbol": PAIR, "qty": qty_stop, "side": "sell", "type": "market", "time_in_force": "gtc",
                    "order_class": "simple", "client_order_id": f"{PREFISSO}sell2-{marca}"})
                nota("Vendita dopo la conferma dell'annullo", codice in (200, 201), f"HTTP {codice}")
        else:
            chiama("POST", f"{TRADING}/v2/orders", {
                "symbol": PAIR, "qty": qty_stop, "side": "sell", "type": "market", "time_in_force": "gtc",
                "order_class": "simple", "client_order_id": f"{PREFISSO}sell-{marca}"})

        # 7. Dopo la vendita dell'intera quantità non resta polvere.
        resto = None
        for _ in range(20):
            time.sleep(0.5)
            resto = posizione_btc()
            if resto is None:
                break
        nota("Vendendo la quantità a 9 decimali la posizione si chiude per intero", resto is None,
             "nessun residuo" if resto is None else f"residuo {resto.get('qty')} BTC")
    finally:
        if aperta_da_me:
            pulizia(aveva_posizione=False)

    print("\n## Riepilogo prova crypto su conto PAPER\n")
    print("| Ipotesi | Esito | Dettaglio |\n|---|---|---|")
    for titolo, segno, dettaglio in esiti:
        print(f"| {titolo} | {segno} | {dettaglio.replace('|', '/')} |")
    finale = posizione_btc()
    print(f"\nConto a fine prova: posizione BTC {'assente' if finale is None else finale.get('qty')}, "
          f"ordini BTC aperti {len(ordini_btc_aperti())}.")
    return 0 if all(segno == "CONFERMATO" for _, segno, _ in esiti) else 2


if __name__ == "__main__":
    sys.exit(main())
