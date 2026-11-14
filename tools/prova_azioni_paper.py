#!/usr/bin/env python3
"""Prova sul conto PAPER di Alpaca gli ordini su azioni che l'app manda.

A MERCATO CHIUSO (anche nel fine settimana) controlla che il broker ACCETTI,
cosi' come l'app li scrive, e poi li annulla tutti:
  1. GIORNALIERA: acquisto limite GTC con stop agganciato (OTO) e con stop +
     target (bracket); le gambe devono essere GTC, cioe' restare sul broker
     anche ad app chiusa nei giorni successivi;
  2. NOTTE: acquisto in asta di chiusura (time_in_force "cls") e ordine in asta
     di apertura ("opg");
  3. ricerca per client_order_id e rifiuto del doppione.
Niente viene eseguito: a mercato chiuso gli ordini restano in coda e lo script
li annulla e controlla che non ne resti nessuno.

A MERCATO APERTO fa in piu' il giro completo con 1 azione di un ETF economico:
compra, guarda lo stop, annulla lo stop, vende (l'uscita della giornaliera).

Sicurezze: indirizzo fisso su paper-api (con chiavi di un conto vero Alpaca
risponde 401); ogni ordine ha il prefisso "qsprova-" e a fine prova, anche in
caso d'errore, tutti gli ordini con quel prefisso vengono annullati e la sola
posizione aperta dallo script viene chiusa. Non stampa chiavi ne' numero di conto.
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
SIMBOLO = "SPYM"     # ETF gemello economico dell'S&P 500, lo stesso che usa l'app
PREFISSO = "qsprova-"
esiti = []


def chiama(metodo, url, corpo=None):
    dati = json.dumps(corpo).encode() if corpo is not None else None
    richiesta = urllib.request.Request(url, data=dati, method=metodo)
    richiesta.add_header("APCA-API-KEY-ID", os.environ["APCA_API_KEY_ID"])
    richiesta.add_header("APCA-API-SECRET-KEY", os.environ["APCA_API_SECRET_KEY"])
    richiesta.add_header("Accept", "application/json")
    if dati is not None:
        richiesta.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(richiesta, timeout=20) as risposta:
            testo, codice = risposta.read().decode(), risposta.status
    except urllib.error.HTTPError as errore:
        testo, codice = errore.read().decode(), errore.code
    try:
        return codice, json.loads(testo) if testo else None
    except ValueError:
        return codice, testo


def nota(titolo, ok, dettaglio):
    segno = "CONFERMATO" if ok else "DIVERSO"
    esiti.append((titolo, segno, dettaglio))
    print(f"[{segno}] {titolo}: {dettaglio}", flush=True)


def miei_ordini_aperti():
    codice, elenco = chiama("GET", f"{TRADING}/v2/orders?status=open&limit=200&nested=true")
    if codice != 200 or not isinstance(elenco, list):
        return []
    return [o for o in elenco if str(o.get("client_order_id", "")).startswith(PREFISSO)]


def annulla_miei():
    for ordine in miei_ordini_aperti():
        chiama("DELETE", f"{TRADING}/v2/orders/{ordine['id']}")
    for _ in range(20):
        if not miei_ordini_aperti():
            return True
        time.sleep(0.5)
    return False


def posizione(simbolo):
    codice, pos = chiama("GET", f"{TRADING}/v2/positions/{simbolo}")
    return pos if codice == 200 and isinstance(pos, dict) else None


def invia(titolo, corpo, attesi=(200, 201)):
    codice, ordine = chiama("POST", f"{TRADING}/v2/orders", corpo)
    ok = codice in attesi and isinstance(ordine, dict)
    return ok, codice, ordine


def main():
    if not os.environ.get("APCA_API_KEY_ID") or not os.environ.get("APCA_API_SECRET_KEY"):
        print("Chiavi Alpaca assenti: niente da fare.")
        return 0
    codice, conto = chiama("GET", f"{TRADING}/v2/account")
    if codice != 200 or not isinstance(conto, dict):
        print(f"Il conto paper non risponde (HTTP {codice}): niente da fare.")
        return 1
    if conto.get("trading_blocked") or conto.get("account_blocked"):
        print("Trading bloccato sul conto: niente da fare.")
        return 1
    _, orologio = chiama("GET", f"{TRADING}/v2/clock")
    aperto = bool((orologio or {}).get("is_open"))
    _, ultimo = chiama("GET", f"{DATA}/v2/stocks/{SIMBOLO}/trades/latest?feed=iex")
    prezzo = float(((ultimo or {}).get("trade") or {}).get("p") or 0)
    if prezzo <= 0:
        print(f"Prezzo di {SIMBOLO} non disponibile: niente da fare.")
        return 1
    aveva = posizione(SIMBOLO) is not None
    print(f"Mercato {'APERTO' if aperto else 'CHIUSO'}; {SIMBOLO} ultimo prezzo {prezzo:.2f}; "
          f"posizione {SIMBOLO} gia' presente: {'si' if aveva else 'no'}")
    marca = str(int(time.time()))
    limite = round(prezzo * 0.90, 2)   # 10% sotto: non si esegue per sbaglio
    stop = round(limite * 0.95, 2)
    target = round(limite * 1.05, 2)
    try:
        # 1. GIORNALIERA: limite GTC + stop agganciato (OTO), come submitEntryWithStop.
        id_oto = f"{PREFISSO}oto-{marca}"
        ok, codice, oto = invia("oto", {
            "symbol": SIMBOLO, "qty": "1", "side": "buy", "type": "limit", "time_in_force": "gtc",
            "limit_price": f"{limite:.2f}", "order_class": "oto", "client_order_id": id_oto,
            "stop_loss": {"stop_price": f"{stop:.2f}"}})
        nota("GIORNALIERA: acquisto limite GTC con stop agganciato (OTO) accettato", ok,
             f"HTTP {codice}: " + (f"stato '{oto.get('status')}'" if ok else str(oto)[:200]))
        if ok:
            gambe = oto.get("legs") or []
            nota("Lo stop agganciato e' GTC (resta sul broker anche nei giorni dopo)",
                 len(gambe) == 1 and gambe[0].get("time_in_force") == "gtc" and gambe[0].get("type") == "stop",
                 "; ".join(f"{g.get('side')} {g.get('type')} {g.get('time_in_force')} stop {g.get('stop_price')} stato {g.get('status')}" for g in gambe) or "nessuna gamba")
            codice, trovato = chiama("GET", f"{TRADING}/v2/orders:by_client_order_id?client_order_id={urllib.parse.quote(id_oto, safe='')}")
            nota("L'ordine si ritrova per client_order_id", codice == 200 and isinstance(trovato, dict) and trovato.get("id") == oto.get("id"), f"HTTP {codice}")
            ok2, codice, doppio = invia("doppio", {
                "symbol": SIMBOLO, "qty": "1", "side": "buy", "type": "limit", "time_in_force": "gtc",
                "limit_price": f"{limite:.2f}", "order_class": "oto", "client_order_id": id_oto,
                "stop_loss": {"stop_price": f"{stop:.2f}"}})
            nota("Un secondo ordine con lo stesso client_order_id viene rifiutato", not ok2, f"HTTP {codice}: {str(doppio)[:140]}")
        # 2. GIORNALIERA con target: bracket GTC.
        ok, codice, br = invia("bracket", {
            "symbol": SIMBOLO, "qty": "1", "side": "buy", "type": "limit", "time_in_force": "gtc",
            "limit_price": f"{limite:.2f}", "order_class": "bracket", "client_order_id": f"{PREFISSO}br-{marca}",
            "stop_loss": {"stop_price": f"{stop:.2f}"}, "take_profit": {"limit_price": f"{target:.2f}"}})
        gambe = (br.get("legs") or []) if ok else []
        nota("GIORNALIERA: bracket GTC (stop + target) accettato, due gambe GTC",
             ok and len(gambe) == 2 and all(g.get("time_in_force") == "gtc" for g in gambe),
             f"HTTP {codice}: " + ("; ".join(f"{g.get('type')} {g.get('time_in_force')}" for g in gambe) if ok else str(br)[:200]))
        # 3. NOTTE: aste di chiusura e di apertura, come submitAuction (market, quote intere).
        for tif, nome in (("cls", "asta di chiusura (MOC)"), ("opg", "asta di apertura (OPG)")):
            ok, codice, asta = invia(tif, {
                "symbol": SIMBOLO, "qty": "1", "side": "buy", "type": "market", "time_in_force": tif,
                "client_order_id": f"{PREFISSO}{tif}-{marca}"})
            nota(f"NOTTE: ordine a mercato in {nome} accettato a quest'ora", ok,
                 f"HTTP {codice}: " + (f"stato '{asta.get('status')}'" if ok else str(asta)[:200]))
        # 4. Annullo di tutto e controllo che non resti niente.
        nota("Tutti gli ordini della prova annullati", annulla_miei(), f"ordini della prova ancora aperti: {len(miei_ordini_aperti())}")

        # 5. Solo a mercato aperto: giro completo con 1 azione (uscita della giornaliera).
        if aperto and not aveva:
            ok, codice, buy = invia("buy", {
                "symbol": SIMBOLO, "qty": "1", "side": "buy", "type": "limit", "time_in_force": "gtc",
                "limit_price": f"{round(prezzo * 1.01, 2):.2f}", "order_class": "oto",
                "client_order_id": f"{PREFISSO}giro-{marca}", "stop_loss": {"stop_price": f"{round(prezzo * 0.9, 2):.2f}"}})
            if ok:
                for _ in range(40):
                    time.sleep(0.5)
                    if posizione(SIMBOLO):
                        break
                pos = posizione(SIMBOLO)
                nota("Giro completo: acquisto eseguito", pos is not None, f"posizione {pos.get('qty') if pos else 'assente'}")
                stopv = [o for o in miei_ordini_aperti() + [g for o in miei_ordini_aperti() for g in (o.get('legs') or [])]
                         if o.get("type") == "stop" and o.get("side") == "sell"]
                _, aperti = chiama("GET", f"{TRADING}/v2/orders?status=open&symbols={SIMBOLO}&limit=50")
                stop_vivi = [o for o in (aperti or []) if o.get("type") == "stop" and o.get("side") == "sell"]
                nota("Giro completo: dopo l'acquisto lo stop e' vivo sul broker, GTC", len(stop_vivi) == 1 and stop_vivi[0].get("time_in_force") == "gtc",
                     "; ".join(f"stop {o.get('stop_price')} {o.get('time_in_force')} {o.get('status')}" for o in stop_vivi) or "nessuno stop")
                for o in stop_vivi:
                    chiama("DELETE", f"{TRADING}/v2/orders/{o['id']}")
                codice, subito = chiama("DELETE", f"{TRADING}/v2/positions/{SIMBOLO}")
                if codice in (200, 201, 204):
                    nota("Giro completo: chiusura subito dopo l'annullo dello stop", True, "accettata al primo colpo")
                else:
                    nota("Giro completo: chiusura subito dopo l'annullo RIFIUTATA (per questo l'app ora aspetta)", True, f"HTTP {codice}: {str(subito)[:140]}")
                    time.sleep(2.0)
                    codice, dopo = chiama("DELETE", f"{TRADING}/v2/positions/{SIMBOLO}")
                    nota("Giro completo: chiusura dopo 2 secondi", codice in (200, 201, 204), f"HTTP {codice}")
                for _ in range(40):
                    time.sleep(0.5)
                    if not posizione(SIMBOLO):
                        break
                nota("Giro completo: posizione chiusa", posizione(SIMBOLO) is None, "nessuna posizione" if posizione(SIMBOLO) is None else "ancora aperta")
        elif not aperto:
            print("Mercato chiuso: il giro completo (compra, stop, annulla, vende) si puo' provare solo a mercato aperto.")
    finally:
        annulla_miei()
        if not aveva and posizione(SIMBOLO) is not None:
            chiama("DELETE", f"{TRADING}/v2/positions/{SIMBOLO}")

    print("\n## Riepilogo prova ordini su azioni, conto PAPER\n")
    print("| Ipotesi | Esito | Dettaglio |\n|---|---|---|")
    for titolo, segno, dettaglio in esiti:
        print(f"| {titolo} | {segno} | {dettaglio.replace('|', '/')} |")
    print(f"\nConto a fine prova: ordini della prova ancora aperti {len(miei_ordini_aperti())}, "
          f"posizione {SIMBOLO} {'presente (c era gia)' if aveva else ('assente' if posizione(SIMBOLO) is None else 'ANCORA APERTA')}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
