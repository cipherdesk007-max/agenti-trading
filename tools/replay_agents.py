"""Banco di prova (FASE 2) degli agenti AI della modalità GIORNALIERA.

Prende i giorni con candidati dal backtest della strategia giornaliera
(stesse regole di backtest_app.py: close > SMA200, RSI(2) < 10 su 15 ETF),
costruisce lo STESSO payload che l'app manda a Kimi in dailyDecide/dailyReview
e chiama davvero l'API Moonshot. Misure dichiarate PRIMA in docs/AGENTI.md:

1. rendimento medio a 5 e 10 sedute: scelti vs scartati vs media candidati
   (scelta casuale) - il Brain vale solo se batte gli scartati oltre i costi;
2. valore del veto del Reviewer: rendimento approvati vs bocciati
   (veto utile = bocciati rendono peggio degli approvati);
3. calibrazione: Brier per fasce di confidence (50-65 / 65-80 / 80-100) su
   rendimento a 5 sedute > 0 (minimo 20 esiti per fascia per giudicare);
4. stabilità: accordo buy/skip per candidato fra due esecuzioni identiche.

LIMITI DICHIARATI PRIMA (docs/AGENTI.md): Kimi conosce il passato, quindi il
payload è ANONIMIZZATO: niente date, ticker -> ETF_A..ETF_O (mappa fissa per
alfabeto), prezzi normalizzati a 100 sulla chiusura del giorno del segnale,
niente notizie (i titoli storici non sono nel dataset). Il replay misura il
meccanismo di scelta sugli indicatori, NON il valore delle notizie. Nel
giornaliero non esiste win_probability: la calibrazione si misura sulla
confidence. Arricchimenti di arrotondamento (max 4 decimali) dichiarati qui.

Varianti FASE 3 (confrontate SOLO su questo banco, mai attivate senza numeri):
- base: prompt attuale del Brain/Reviewer giornaliero (KimiService.swift);
- b: uscita strutturata del Brain (schema daily_decisions_v2: stessi campi
  + reason_code da lista fissa + change_my_mind + comment di 1 frase);
- c: reviewer cieco (stessa chiamata daily_review SENZA rationale e confidence
  della proposta).

Costi: DUE tetti. REPLAY_BUDGET chiamate (default 400) e REPLAY_MAX_USD dollari
stimati (default 1): superato uno dei due il replay si ferma e i risultati
parziali restano nel JSON. Tariffe PER MODELLO dalla pagina prezzi ufficiale
Moonshot/Kimi (https://www.kimi.ai/it/resources/kimi-k3-1-pro-pricing,
consultata il 14/11/2026, USD per milione di token):
- kimi-k3.1-pro-highspeed: input 4,00 / output 20,00 (cache hit 0,20);
- kimi-k3.1-pro: input 2,00 / output 10,00 (cache hit 0,20);
- kimi-k3: input 3,00 / output 15,00 (cache hit 0,30).
Il modello si sceglie con KIMI_MODEL (default kimi-k3.1-pro-highspeed, quello
dell'app). Le tariffe si possono forzare con KIMI_PRICE_IN / KIMI_PRICE_OUT.
STIMA PRUDENTE: non distingue cache hit (0,20): se il prompt condiviso viene
servito dalla cache il costo reale e' PIU' BASSO di quello stimato. Con un
modello non in tabella stampa un avviso e usa le tariffe highspeed (errore
per eccesso, non per difetto: il tetto USD ferma prima).

Selezione dei giorni e finestre (dichiarate PRIMA in docs/AGENTI.md 6-bis):
- REPLAY_SAMPLE=recent (default): gli ultimi REPLAY_MAX_DAYS giorni con
  candidati;
- REPLAY_SAMPLE=uniform: REPLAY_MAX_DAYS giorni scelti con passo uniforme su
  TUTTI i giorni con candidati dal 2006 (indici round(i*(N-1)/(m-1)), primo
  e ultimo giorno inclusi, formula dichiarata prima di eseguire);
- REPLAY_OFFSET / REPLAY_WINDOW: finestra sulla lista selezionata, per
  dividere un campione lungo in piu' run che restano dentro il timeout.

Risultati parziali: a ogni giorno lo script stampa una riga REPLAYDAY o
REPLAYREV per candidato (ricavabile dal log anche se il run viene tagliato a
meta': le chiamate gia' pagate non si perdono) e riscrive
replay_agents_risultati.json.

Bootstrap: differenza media scelti - scartati con intervallo di confidenza al
95% (5000 ricampionamenti con ripetizione, seed fisso, scelti e scartati
ricampionati separatamente). Con --combine file1.json file2.json ... unisce i
JSON di piu' finestre e stampa la tabella dell'unione senza chiamare Kimi.

Senza MOONSHOT_API_KEY stampa un messaggio chiaro ed esce con codice 0 (non è
un errore del run). Con --smoke costruisce i payload su dati sintetici e li
valida SENZA rete (test locale della struttura, senza pandas/yfinance).
"""
import json
import os
import random
import sys
import time
import urllib.error
import urllib.request

ETFS = ["SPY", "QQQ", "IWM", "DIA", "XLK", "XLF", "XLE", "XLV", "XLY", "XLP",
        "XLI", "XLU", "XLB", "GLD", "TLT"]
MARKET_OVERVIEW = ["SPY", "QQQ", "IWM", "TLT", "GLD"]
SLOTS = 3
REASON_CODES = ["trend_intatto", "rsi_estremo", "correlazione_alta",
                "quadro_mercato_debole", "pullback_poco_profondo",
                "diversificazione", "volatilita_alta", "altro"]
CONF_BUCKETS = [(0.50, 0.65), (0.65, 0.80), (0.80, 1.01)]

# Tariffe USD per milione di token (input, output) dalla pagina prezzi
# ufficiale Moonshot/Kimi, consultata il 14/11/2026:
# https://www.kimi.ai/it/resources/kimi-k3-1-pro-pricing
# La cache hit costa meno (0,20 standard/highspeed, 0,30 kimi-k3): la stima
# qui non la distingue, quindi sbaglia per ECCESSO, mai per difetto.
KIMI_PRICES = {
    "kimi-k3.1-pro-highspeed": (4.00, 20.00),
    "kimi-k3.1-pro": (2.00, 10.00),
    "kimi-k3": (3.00, 15.00),
}


def prices_for(model):
    """Tariffe (input, output) del modello; alto e' prudente per il tetto USD."""
    for name, prices in KIMI_PRICES.items():
        if model.strip().lower().startswith(name):
            return prices
    print(f"AVVISO: tariffe di '{model}' non in tabella "
          f"(pagina prezzi ufficiale: https://www.kimi.ai/it/resources/"
          f"kimi-k3-1-pro-pricing): uso le tariffe highspeed 4,00/20,00 per "
          f"prudenza (stima per eccesso).")
    return KIMI_PRICES["kimi-k3.1-pro-highspeed"]

# Prompt IDENTICI a Sources/Services/KimiService.swift dailyDecide (BRAIN_PROMPT)
# e dailyReview (REVIEWER_PROMPT), v1.6.6. Nel replay non ci sono notizie nel
# payload (limite dichiarato), quindi restano validi anche dopo 1.6.7.
BRAIN_PROMPT = """Sei l'agente decisionale (Brain) della modalità giornaliera di un sistema di trading \
su ETF, solo in acquisto. Ricevi ETF che le regole in codice hanno già selezionato: \
chiusura sopra la SMA200 (trend rialzista) e RSI(2) sotto 10 (ribasso di breve). La \
strategia è testata dal 2006: compra il ribasso in trend, esce con chiusura sopra la \
SMA5 o dopo 10 giorni, stop a 2,5 ATR. Per ogni candidato rispondi buy o skip. Scegli \
al massimo slots_available buy, preferendo i pullback più profondi (RSI2 più basso) e \
la diversificazione: evita ETF quasi uguali tra loro o a quelli già in portafoglio \
(per esempio SPY, DIA e QQQ insieme): correlation_60d dà la correlazione dei rendimenti \
giornalieri a 60 sedute con le posizioni aperte e gli altri candidati; sopra 0,85 sono \
quasi lo stesso rischio. news_48h sono i titoli delle notizie delle ultime 48 ore \
(Benzinga) sull'ETF e sul mercato: usale per evitare di comprare dentro un evento \
che può cambiare il quadro (decisione della Fed, dati sull'inflazione, crollo di un \
settore), non per inseguire una notizia. Usa market_overview per il contesto generale e \
recent_closes (ultime 20 chiusure) per giudicare la forma del ribasso. specialist_digest \
contiene i pareri standardizzati degli specialisti locali per candidato (tecnica \
giornaliera, statistica, notizie, fondamentali sospesi): confrontali, segnala nel \
rationale chi è d'accordo e chi no; la loro confidence NON è una probabilità calibrata. \
Se c'è past_outcomes, tienine conto: se gli ETF che scarti vanno meglio di quelli che scegli, \
sii meno selettivo. Se c'è shadow_outcomes, sono gli ultimi esiti MISURATI del registro \
ombra: ogni voce dice se l'hai scelta (chosen true) o scartata (outcome) e quanto ha \
reso davvero (return_pct). Usali per correggere i tuoi bias in modo ripetuto, non \
saltuario: se gli scartati rendono meglio degli scelti più volte, sei troppo selettivo; \
se gli stessi setup che scegli perdono in sequenza, alza l'asticella; se i bocciati dal \
revisore andavano bene, opponiti con più forza. Un singolo esito NON è un pattern: non \
stravolgere il metodo per un caso solo. Non inventare dati. Non usare Markdown."""

REVIEWER_PROMPT = """Sei il revisore avversario della modalità giornaliera. Assumi che l'acquisto proposto \
sia SBAGLIATO e cerca motivi concreti nei dati per respingerlo: trend debole (prezzo \
appena sopra la SMA200), volatilità (ATR) anomala, quadro di mercato in rottura, \
motivazione del Brain non coerente con gli indicatori, correlazione sopra 0,85 con una \
posizione già aperta (correlation_60d), notizie in news_48h che spiegano il calo con \
un cambiamento vero (non un normale ribasso) o un evento imminente ad alto rischio. \
specialist_digest contiene i pareri degli specialisti locali sul candidato: verifica \
tu stesso se i loro motivi reggono sui dati, senza confermarli automaticamente. \
Se c'è shadow_outcomes, sono gli ultimi esiti MISURATI del registro ombra (scelti e \
scartati col rendimento reale): usali per pesare la tua sentenza, non per respingere \
a porte chiuse: se la proposta somiglia a un acquisto recente finito male (stesso \
simbolo ricomprato subito o stesso tipo di setup in sequenza negativa), dillo nel \
reason; se invece gli scartati rendevano meglio degli scelti più volte, questo è un \
rimprovero al Brain da citare, non un motivo automatico di respingimento. \
Approva solo se non trovi nulla di concreto. Non usare Markdown."""


def anon_map():
    """Mappa fissa ticker -> ETF_A.. per alfabeto (nessun ticker nel payload)."""
    return {t: f"ETF_{chr(ord('A') + i)}" for i, t in enumerate(sorted(ETFS))}


def brain_schema(structured=False):
    item = {
        "type": "object",
        "properties": {
            "symbol": {"type": "string"},
            "action": {"type": "string", "enum": ["buy", "skip"]},
            "confidence": {"type": "number", "minimum": 0, "maximum": 1},
            "rationale": {"type": "string"},
        },
        "required": ["symbol", "action", "confidence", "rationale"],
        "additionalProperties": False,
    }
    if structured:
        item["properties"]["reason_code"] = {"type": "string", "enum": REASON_CODES}
        item["required"].append("reason_code")
    schema = {
        "type": "object",
        "properties": {"decisions": {"type": "array", "items": item}},
        "required": ["decisions"],
        "additionalProperties": False,
    }
    if structured:
        schema["properties"]["change_my_mind"] = {"type": "string"}
        schema["required"].append("change_my_mind")
        schema["properties"]["comment"] = {"type": "string"}
        schema["required"].append("comment")
    return schema


REVIEW_SCHEMA = {
    "type": "object",
    "properties": {
        "verdict": {"type": "string", "enum": ["approve", "reject"]},
        "reason": {"type": "string"},
    },
    "required": ["verdict", "reason"],
    "additionalProperties": False,
}


def specialist_digest(ind):
    """Replica Council.dailyDigest (SpecialistAgents.swift:508) sui dati del
    replay: prezzi normalizzati, nessuna notizia, fondamentali sospesi.
    ind: close/sma200/sma5/rsi2/atr14 normalizzati + z10 (z-score 10 sedute)."""
    trend_up = ind["close"] > ind["sma200"]
    atr_pct = f"{ind['atr14'] / ind['close'] * 100:.2f}%" if ind["atr14"] > 0 else "n/d"
    technical = {
        "agent": "technical", "signal": "long" if trend_up else "short",
        "confidence": 0.7,
        "analysis": ("Ribasso di breve (RSI2 %.1f) dentro un trend sopra la SMA200: "
                     "setup della strategia." % ind["rsi2"]) if trend_up else
                    "Prezzo sotto la SMA200: il trend di fondo è negativo, niente setup.",
        "evidence": [f"chiusura {ind['close']:.2f} vs SMA200 {ind['sma200']:.2f}",
                     f"RSI2 a {ind['rsi2']:.1f}, soglia segnale < 10",
                     f"SMA5 a {ind['sma5']:.2f} (uscita a regola)"],
        "risks": [],
        "missing_data_count": 0, "abstained": False,
        "invalidation": "Chiusura sotto la SMA200 o RSI2 che risale sopra 10 senza rimbalzo.",
    }
    if ind["z10"] is None:
        quantitative = {"agent": "quantitative", "signal": "abstain", "confidence": 0,
                        "analysis": "Servono le chiusure recenti per la statistica: parere sospeso.",
                        "evidence": [], "risks": [], "missing_data_count": 1,
                        "abstained": True,
                        "invalidation": "Chiusure recenti disponibili."}
    else:
        longq = ind["z10"] <= -1 and trend_up
        quantitative = {"agent": "quantitative", "signal": "long" if longq else "neutral",
                        "confidence": 0.5,
                        "analysis": ("Chiusura estesa sotto la media a 10 sedute (z %+.2f): "
                                     "tipico del pullback profondo." % ind["z10"]) if ind["z10"] <= -1
                                    else ("Chiusura entro un deviation standard dalla media a 10 "
                                          "sedute (z %+.2f)." % ind["z10"]),
                        "evidence": [f"z-score a 10 sedute: {ind['z10']:+.2f}"],
                        "risks": [], "missing_data_count": 0, "abstained": False,
                        "invalidation": "Il rientro dello z-score sopra 0 chiude l'anomalia statistica."}
    news = {"agent": "news", "signal": "abstain", "confidence": 0,
            "analysis": "Nessuna notizia recente disponibile: il parere sulle notizie resta sospeso.",
            "evidence": [], "risks": [], "missing_data_count": 1, "abstained": True,
            "invalidation": "L'arrivo di titoli di notizie riattiva questo parere."}
    fundamental = {"agent": "fundamental", "signal": "abstain", "confidence": 0,
                   "analysis": ("Nessuna fonte di dati fondamentali collegata (bilanci, utili, "
                                "dividendi, macro): parere sempre sospeso, mai inventato."),
                   "evidence": [], "risks": [], "missing_data_count": 2, "abstained": True,
                   "invalidation": "Collegare una API di dati fondamentali sblocca questo parere."}
    return [technical, quantitative, news, fundamental]


def snap_payload(close, sma200, sma5, rsi2, atr14):
    """Snapshot normalizzato (base 100) come snap() di dailyDecide."""
    return {
        "close": round(close, 4),
        "sma200": round(sma200, 4),
        "sma5": round(sma5, 4),
        "rsi2": round(rsi2, 2),
        "atr14": round(atr14, 4),
        "distance_from_sma200_pct": round((close / sma200 - 1) * 100, 4),
    }


def build_payload(data, idx, cands, anon):
    """Payload IDENTICO a dailyDecide, ma anonimizzato (prezzi base 100)."""
    close, s200, s5, rsi2, atr, ret = (data["close"], data["sma200"], data["sma5"],
                                       data["rsi2"], data["atr"], data["ret"])
    cand_payload = []
    meta = {}
    for t in cands:
        a = anon[t]
        base = close[t].iloc[idx]
        closes20 = [round(x / base * 100, 4)
                    for x in close[t].iloc[idx - 19: idx + 1].tolist()]
        z10 = None
        w = closes20[-10:]
        if len(w) == 10:
            m = sum(w) / 10
            sd = (sum((x - m) ** 2 for x in w) / 9) ** 0.5
            if sd > 1e-9:
                z10 = (w[-1] - m) / sd
        ind = {"close": close[t].iloc[idx] / base * 100,
               "sma200": s200[t].iloc[idx] / base * 100,
               "sma5": s5[t].iloc[idx] / base * 100,
               "rsi2": rsi2[t].iloc[idx],
               "atr14": atr[t].iloc[idx] / base * 100,
               "z10": z10}
        corr = {}
        for other in cands:
            if other == t:
                continue
            ra = ret[t].iloc[idx - 60: idx + 1].tolist()
            rb = ret[other].iloc[idx - 60: idx + 1].tolist()
            pair = [(x, y) for x, y in zip(ra, rb) if x == x and y == y][1:]
            if len(pair) >= 20:
                ma = sum(p[0] for p in pair) / len(pair)
                mb = sum(p[1] for p in pair) / len(pair)
                cov = sum((x - ma) * (y - mb) for x, y in pair)
                va = sum((x - ma) ** 2 for x, _ in pair)
                vb = sum((y - mb) ** 2 for _, y in pair)
                if va > 0 and vb > 0:
                    corr[anon[other]] = round(cov / ((va ** 0.5) * (vb ** 0.5)), 2)
        cand_payload.append({
            "symbol": a,
            "indicators": snap_payload(ind["close"], ind["sma200"], ind["sma5"],
                                       ind["rsi2"], ind["atr14"]),
            "recent_closes": closes20,
            "correlation_60d": corr,
            "news_48h": [],
            "specialist_digest": specialist_digest(ind),
        })
        meta[a] = {"ticker": t,
                   "stop_distance": round(2.5 * atr[t].iloc[idx] / base * 100, 4)}
    overview = {}
    for t in MARKET_OVERVIEW:
        c = close[t].iloc[idx]
        s = s200[t].iloc[idx]
        if c == c and s == s and c > 0:
            overview[anon[t]] = snap_payload(
                100.0, s / c * 100, s5[t].iloc[idx] / c * 100,
                rsi2[t].iloc[idx] if rsi2[t].iloc[idx] == rsi2[t].iloc[idx] else 0,
                atr[t].iloc[idx] / c * 100 if atr[t].iloc[idx] == atr[t].iloc[idx] else 0)
    payload = {
        "candidates": cand_payload,
        "market_overview": overview,
        "open_positions": [],
        "slots_available": SLOTS,
        "past_outcomes": None,
        "shadow_outcomes": None,
    }
    return payload, meta


def review_payload(payload, verdict, meta, blind=False):
    """Payload IDENTICO a dailyReview (indicatori normalizzati).
    blind=True: SENZA rationale e confidence del Brain (variante c)."""
    cand = next(c for c in payload["candidates"] if c["symbol"] == verdict["symbol"])
    ind = cand["indicators"]
    proposal = {"symbol": verdict["symbol"],
                "close": ind["close"], "sma200": ind["sma200"], "sma5": ind["sma5"],
                "rsi2": ind["rsi2"], "atr14": ind["atr14"],
                "stop_distance": meta[verdict["symbol"]]["stop_distance"],
                "correlation_60d": cand["correlation_60d"], "news_48h": []}
    if not blind:
        proposal["confidence"] = verdict["confidence"]
        proposal["rationale"] = verdict["rationale"]
    return {
        "proposal": proposal,
        "specialist_digest": cand["specialist_digest"],
        "shadow_outcomes": None,
        "market_overview": {k: {"close": v["close"], "sma200": v["sma200"],
                                "rsi2": v["rsi2"], "atr14": v["atr14"]}
                           for k, v in payload["market_overview"].items()},
    }


class BudgetExceeded(Exception):
    """Tetto delle chiamate raggiunto: stop pulito con risultati parziali."""


RETRYABLE_HTTP = (429, 500, 502, 503, 504, 529)


class Kimi:
    """Client Moonshot minimale: stessa richiesta di KimiService.chatOnce.
    Due tentativi totali su errori transitori (come sendWithRetry dell'app),
    attesa 5 s fra un tentativo e l'altro."""

    def __init__(self, key, model, budget, price_in, price_out, max_usd):
        self.key, self.model, self.budget = key, model, budget
        self.price_in, self.price_out = price_in, price_out
        self.max_usd = max_usd
        self.calls = 0
        self.retries = 0
        self.tokens_in = self.tokens_out = 0

    def cost(self):
        """Costo stimato dei token gia' consumati (tariffe per modello)."""
        return (self.tokens_in / 1e6 * self.price_in
                + self.tokens_out / 1e6 * self.price_out)

    def _projected(self):
        """Costo stimato dopo la prossima chiamata: media a chiamata finora
        (prudenza x1,5), 0,05 USD di partenza se non c'e' ancora storia."""
        per_call = (self.cost() / self.calls * 1.5) if self.calls else 0.05
        return self.cost() + per_call

    def chat(self, prompt, payload, schema, name):
        if self.calls >= self.budget:
            raise BudgetExceeded(f"budget di {self.budget} chiamate esaurito")
        if self._projected() > self.max_usd:
            raise BudgetExceeded(
                f"tetto REPLAY_MAX_USD raggiunto: {self.max_usd:.2f} USD "
                f"(spesi {self.cost():.2f} stimati, tariffa "
                f"{self.price_in}/{self.price_out} USD/Mtoken, modello {self.model})")
        body = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": prompt},
                {"role": "user", "content": json.dumps(payload, ensure_ascii=False)},
            ],
            "reasoning_effort": "medium",
            "max_completion_tokens": 4096,
            "stream": False,
            "response_format": {"type": "json_schema",
                                 "json_schema": {"name": name, "strict": True,
                                                 "schema": schema}},
        }
        req = urllib.request.Request(
            "https://api.moonshot.ai/v1/chat/completions",
            data=json.dumps(body).encode(),
            headers={"Authorization": f"Bearer {self.key}",
                     "Content-Type": "application/json"},
            method="POST")
        data = None
        for attempt in (1, 2):
            try:
                with urllib.request.urlopen(req, timeout=180) as r:
                    data = json.load(r)
                break
            except urllib.error.HTTPError as e:
                if attempt == 2 or e.code not in RETRYABLE_HTTP:
                    raise
                self.retries += 1
                time.sleep(5)
            except (urllib.error.URLError, TimeoutError):
                if attempt == 2:
                    raise
                self.retries += 1
                time.sleep(5)
        self.calls += 1
        usage = data.get("usage") or {}
        self.tokens_in += usage.get("prompt_tokens", 0) or 0
        self.tokens_out += usage.get("completion_tokens", 0) or 0
        choice = (data.get("choices") or [{}])[0]
        content = ((choice.get("message") or {}).get("content") or "").strip()
        if not content or choice.get("finish_reason") == "length":
            raise RuntimeError("risposta Kimi vuota o troncata")
        s, e = content.find("{"), content.rfind("}")
        if s < 0 or e <= s:
            raise RuntimeError("nessun oggetto JSON nella risposta")
        try:
            return json.loads(content[s:e + 1])
        except ValueError:
            raise RuntimeError("risposta Kimi non decodificabile come JSON")


def load_data():
    import numpy as np
    import pandas as pd
    import yfinance as yf

    df = yf.download(ETFS, start="2004-06-01", auto_adjust=True, progress=False,
                     group_by="column")
    close = df["Close"][ETFS].astype(float)
    high, low = df["High"][ETFS].astype(float), df["Low"][ETFS].astype(float)
    d = close.diff()
    up = d.clip(lower=0).ewm(alpha=0.5, adjust=False).mean()
    dn = (-d.clip(upper=0)).ewm(alpha=0.5, adjust=False).mean()
    rsi2 = 100 - 100 / (1 + up / dn.replace(0, np.nan))
    tr = pd.concat([high - low, (high - close.shift()).abs(),
                    (low - close.shift()).abs()]).groupby(level=0).max()
    atr = tr.ewm(alpha=1 / 14, adjust=False).mean()
    return {"close": close, "sma200": close.rolling(200).mean(),
            "sma5": close.rolling(5).mean(), "rsi2": rsi2, "atr": atr,
            "ret": close.pct_change(), "index": close.index}


def uniform_indices(n, m):
    """Indici uniformemente spaziati su n elementi (primo e ultimo inclusi).
    Formula dichiarata PRIMA in docs/AGENTI.md 6-bis: j(i) = round(i*(n-1)/(m-1))."""
    if m <= 0:
        return []
    if n <= m:
        return list(range(n))
    return sorted({round(i * (n - 1) / (m - 1)) for i in range(m)})


def find_days(data, max_days, sample="recent"):
    """Giorni con candidati (stesse regole del backtest). sample='recent'
    prende gli ultimi max_days (0 = tutti); sample='uniform' sceglie max_days
    giorni con passo uniforme su tutto il periodo dal 2006."""
    close, sma200, rsi2 = data["close"], data["sma200"], data["rsi2"]
    days = []
    for i in range(len(data["index"]) - 12):
        cands = []
        for t in ETFS:
            c, s, r = close[t].iloc[i], sma200[t].iloc[i], rsi2[t].iloc[i]
            if c == c and s == s and r == r and c > s and r < 10:
                cands.append(t)
        if cands:
            days.append((i, data["index"][i], cands))
    if sample == "uniform" and 0 < max_days < len(days):
        return [days[j] for j in uniform_indices(len(days), max_days)]
    if max_days:
        return days[-int(max_days):]
    return days


def fwd(data, idx, ticker, horizon):
    """Rendimento reale a `horizon` sedute dal giorno del segnale."""
    c = data["close"][ticker]
    if idx + horizon >= len(c):
        return None
    a, b = c.iloc[idx], c.iloc[idx + horizon]
    if a == a and b == b and a > 0:
        return b / a - 1
    return None


def mean(xs):
    xs = [x for x in xs if x is not None]
    return sum(xs) / len(xs) if xs else None


def pct(x):
    return "n/d" if x is None else f"{x * 100:+.2f}%"


def brier_rows(samples):
    """samples: [(confidence, win)] con win = rendimento a 5 sedute > 0."""
    rows = []
    for lo, hi in CONF_BUCKETS:
        b = [(p, w) for p, w in samples if lo <= p < hi]
        if not b:
            rows.append((f"{lo:.2f}-{min(hi, 1.00):.2f}", 0, None))
            continue
        score = sum((p - (1.0 if w else 0.0)) ** 2 for p, w in b) / len(b)
        rows.append((f"{lo:.2f}-{min(hi, 1.00):.2f}", len(b), score))
    return rows


def bootstrap_diff(rows, key, n_boot=5000, seed=42, level=0.95):
    """Differenza media scelti - scartati con IC bootstrap (ricampionamento
    con ripetizione, scelti e scartati separati, seed fisso: riproducibile).
    Metodo dichiarato PRIMA in docs/AGENTI.md 6-bis."""
    a = [r[key] for r in rows if r["chosen"] and r[key] is not None]
    b = [r[key] for r in rows if not r["chosen"] and r[key] is not None]
    if len(a) < 2 or len(b) < 2:
        return None
    rng = random.Random(seed)
    ma, mb = sum(a) / len(a), sum(b) / len(b)
    diffs = []
    for _ in range(n_boot):
        sa = sum(a[rng.randrange(len(a))] for _ in a) / len(a)
        sb = sum(b[rng.randrange(len(b))] for _ in b) / len(b)
        diffs.append(sa - sb)
    diffs.sort()
    lo = diffs[max(0, int((1 - level) / 2 * n_boot) - 1)]
    hi = diffs[min(n_boot - 1, int((1 + level) / 2 * n_boot))]
    return {"diff": ma - mb, "lo": lo, "hi": hi,
            "n_chosen": len(a), "n_skipped": len(b)}


def validate_verdicts(decisions, allowed):
    """Fail-closed come l'app: solo simboli candidati, azione buy/skip,
    confidence numero in [0,1]. Il resto si scarta (resta scartato)."""
    out = []
    for d in decisions:
        s = str(d.get("symbol", "")).upper()
        c = d.get("confidence")
        if s in allowed and d.get("action") in ("buy", "skip") \
                and isinstance(c, (int, float)) and 0 <= c <= 1:
            out.append({"symbol": s, "action": d["action"], "confidence": float(c),
                        "rationale": str(d.get("rationale", ""))[:400]})
    return out


def render_verdicts(rows, label, days):
    chosen = [r for r in rows if r["chosen"]]
    skipped = [r for r in rows if not r["chosen"]]
    ndays = days if isinstance(days, int) else len(days)
    print(f"\n## {label}: {len(rows)} verdetti su {ndays} giorni")
    print("| misura | 5 sedute | 10 sedute |")
    print("|---|---|---|")
    print(f"| scelti (media, n={len(chosen)}) | {pct(mean([r['ret5'] for r in chosen]))} | "
          f"{pct(mean([r['ret10'] for r in chosen]))} |")
    print(f"| scartati (media, n={len(skipped)}) | {pct(mean([r['ret5'] for r in skipped]))} | "
          f"{pct(mean([r['ret10'] for r in skipped]))} |")
    print(f"| tutti i candidati = scelta casuale | {pct(mean([r['ret5'] for r in rows]))} | "
          f"{pct(mean([r['ret10'] for r in rows]))} |")
    samples = [(r["conf"], (r["ret5"] or 0) > 0) for r in rows]
    print("Brier per fasce di confidence (win = 5 sedute > 0; minimo 20 esiti per giudicare):")
    for lab, n, score in brier_rows(samples):
        print(f"- {lab}: n={n} brier={'n/d' if score is None else f'{score:.3f}'}")
    print("Differenza scelti - scartati (bootstrap 95%: contiene lo zero = non distinguibile):")
    for key, lab in (("ret5", "5 sedute"), ("ret10", "10 sedute")):
        b = bootstrap_diff(rows, key)
        if b is None:
            print(f"- {lab}: troppo pochi esiti (servono almeno 2 per lato)")
        else:
            print(f"- {lab}: {pct(b['diff'])} [IC 95%: {pct(b['lo'])}, {pct(b['hi'])}] "
                  f"(n scelti {b['n_chosen']}, scartati {b['n_skipped']})")


def render_reviews(rows, label):
    appr = [r for r in rows if r["approved"]]
    rej = [r for r in rows if not r["approved"]]
    print(f"\n## {label} (veto: approvati vs bocciati)")
    print("| misura | 5 sedute | 10 sedute |")
    print("|---|---|---|")
    print(f"| approvati (n={len(appr)}) | {pct(mean([r['ret5'] for r in appr]))} | "
          f"{pct(mean([r['ret10'] for r in appr]))} |")
    print(f"| bocciati (n={len(rej)}) | {pct(mean([r['ret5'] for r in rej]))} | "
          f"{pct(mean([r['ret10'] for r in rej]))} |")
    print("Veto utile se i bocciati rendono peggio degli approvati.")


def run_replay():
    key = os.environ.get("MOONSHOT_API_KEY", "").strip()
    if not key:
        print("MOONSHOT_API_KEY assente: replay non eseguito.")
        print("Aggiungere il secret su GitHub (Settings > Secrets and variables >")
        print("Actions > MOONSHOT_API_KEY) e rilanciare il passo 'replay' del workflow")
        print("Backtest filtro. Uscita senza errore: non è una falla del run.")
        return 0
    max_days = int(os.environ.get("REPLAY_MAX_DAYS", "30"))
    sample = os.environ.get("REPLAY_SAMPLE", "recent").strip().lower()
    offset = int(os.environ.get("REPLAY_OFFSET", "0"))
    window = int(os.environ.get("REPLAY_WINDOW", "0"))
    variants = [v.strip() for v in os.environ.get("REPLAY_VARIANTS", "base,b,c").split(",")
                if v.strip()]
    stability_on = os.environ.get("REPLAY_STABILITY", "yes").lower() not in ("no", "0", "false")
    budget = int(os.environ.get("REPLAY_BUDGET", "400"))
    max_usd = float(os.environ.get("REPLAY_MAX_USD", "1"))
    model = os.environ.get("KIMI_MODEL", "kimi-k3.1-pro-highspeed")
    price_in, price_out = prices_for(model)
    if os.environ.get("KIMI_PRICE_IN"):
        price_in = float(os.environ["KIMI_PRICE_IN"])
    if os.environ.get("KIMI_PRICE_OUT"):
        price_out = float(os.environ["KIMI_PRICE_OUT"])
    kimi = Kimi(key, model, budget, price_in, price_out, max_usd)

    data = load_data()
    all_days = find_days(data, 0)
    selected = find_days(data, max_days, sample)
    days = selected[offset:offset + window] if window > 0 else selected[offset:]
    print(f"# Replay agenti: campionamento {sample} ({max_days} giorni richiesti su "
          f"{len(all_days)} giorni con candidati dal 2006), finestra offset {offset} "
          f"+ {window if window else 'tutti'} -> {len(days)} giorni di questa run, "
          f"varianti {variants}, stabilita' {'si' if stability_on else 'no'}, "
          f"tetto {budget} chiamate, tetto {max_usd:.2f} USD stimati, modello "
          f"{model} (tariffe {price_in}/{price_out} USD/Mtoken)")
    anon = anon_map()
    brain_rows = {"base": [], "b": []}
    review_rows = {"base": [], "c": []}
    first_pass_verdicts = {}   # idx -> {symbol anon: action}
    stability_pairs = []       # (esecuzione 1, esecuzione 2) per candidato
    skipped_days = 0
    stop_reason = None

    def dump(stop=None):
        c = kimi.cost()
        with open("replay_agents_risultati.json", "w") as f:
            json.dump({"sample": sample, "selected": len(selected), "offset": offset,
                       "window": window, "days": len(days), "calls": kimi.calls,
                       "retries": kimi.retries, "tokens_in": kimi.tokens_in,
                       "tokens_out": kimi.tokens_out, "cost_usd": round(c, 2),
                       "skipped_days": skipped_days, "stop": stop,
                       "brain": brain_rows, "reviews": review_rows}, f, indent=1)

    def fmt(x):
        return "nan" if x is None else f"{x:.6f}"

    try:
        for dnum, (idx, day, cands) in enumerate(days, 1):
            dstr = str(day)[:10]
            day_base, day_b, day_rev = [], [], []
            try:
                payload, meta = build_payload(data, idx, cands, anon)
                allowed = {anon[t].upper() for t in cands}
                first = kimi.chat(BRAIN_PROMPT, payload, brain_schema(), "daily_decisions")
                verdicts = validate_verdicts(first.get("decisions", []), allowed)
                first_pass_verdicts[idx] = {v["symbol"]: v["action"] for v in verdicts}
                for v in verdicts:
                    t = meta[v["symbol"]]["ticker"]
                    row = {"ticker": t, "chosen": v["action"] == "buy",
                           "ret5": fwd(data, idx, t, 5), "ret10": fwd(data, idx, t, 10),
                           "conf": v["confidence"]}
                    brain_rows["base"].append(row)
                    day_base.append(row)
                buys = sorted([v for v in verdicts if v["action"] == "buy"],
                              key=lambda v: -v["confidence"])[:SLOTS]
                for v in buys:
                    rev = kimi.chat(REVIEWER_PROMPT, review_payload(payload, v, meta),
                                    REVIEW_SCHEMA, "daily_review")
                    t = meta[v["symbol"]]["ticker"]
                    row = {"ticker": t, "approved": rev.get("verdict") == "approve",
                           "ret5": fwd(data, idx, t, 5), "ret10": fwd(data, idx, t, 10)}
                    review_rows["base"].append(row)
                    day_rev.append(row)
                if "b" in variants:
                    second = kimi.chat(BRAIN_PROMPT, payload, brain_schema(structured=True),
                                       "daily_decisions_v2")
                    for v in validate_verdicts(second.get("decisions", []), allowed):
                        t = meta[v["symbol"]]["ticker"]
                        row = {"ticker": t, "chosen": v["action"] == "buy",
                               "ret5": fwd(data, idx, t, 5), "ret10": fwd(data, idx, t, 10),
                               "conf": v["confidence"]}
                        brain_rows["b"].append(row)
                        day_b.append(row)
                if "c" in variants:
                    for v in buys:
                        rev = kimi.chat(REVIEWER_PROMPT,
                                       review_payload(payload, v, meta, blind=True),
                                       REVIEW_SCHEMA, "daily_review")
                        t = meta[v["symbol"]]["ticker"]
                        row = {"ticker": t, "approved": rev.get("verdict") == "approve",
                               "ret5": fwd(data, idx, t, 5), "ret10": fwd(data, idx, t, 10)}
                        review_rows["c"].append(row)
                        day_rev.append(row)
            except BudgetExceeded:
                raise
            except RuntimeError as e:
                skipped_days += 1
                print(f"REPLAYSKIP {dstr} giorno {dnum}/{len(days)} saltato: {e}")
                dump()
                continue
            for r in day_base:
                print(f"REPLAYDAY {dstr} base {r['ticker']} "
                      f"{'buy' if r['chosen'] else 'skip'} "
                      f"{fmt(r['ret5'])} {fmt(r['ret10'])} {r['conf']:.3f}")
            for r in day_b:
                print(f"REPLAYDAY {dstr} b {r['ticker']} "
                      f"{'buy' if r['chosen'] else 'skip'} "
                      f"{fmt(r['ret5'])} {fmt(r['ret10'])} {r['conf']:.3f}")
            for r in day_rev:
                print(f"REPLAYREV {dstr} {r['ticker']} "
                      f"{'approve' if r['approved'] else 'reject'} "
                      f"{fmt(r['ret5'])} {fmt(r['ret10'])}")
            if dnum % 10 == 0 or dnum == len(days):
                print(f"# progresso: {dnum}/{len(days)} giorni, {kimi.calls} chiamate, "
                      f"{kimi.tokens_in} token in, {kimi.tokens_out} token out")
            dump()
        if stability_on and "base" in variants:
            for idx, day, cands in days:
                payload, meta = build_payload(data, idx, cands, anon)
                allowed = {anon[t].upper() for t in cands}
                second = kimi.chat(BRAIN_PROMPT, payload, brain_schema(),
                                   "daily_decisions")
                second_actions = {v["symbol"]: v["action"]
                                  for v in validate_verdicts(second.get("decisions", []), allowed)}
                for sym, action in second_actions.items():
                    if sym in first_pass_verdicts.get(idx, {}):
                        stability_pairs.append((first_pass_verdicts[idx][sym], action))
    except BudgetExceeded as e:
        stop_reason = str(e)
    except RuntimeError as e:
        stop_reason = str(e)

    cost = kimi.cost()
    print(f"\nChiamate: {kimi.calls} | token in {kimi.tokens_in} out {kimi.tokens_out} | "
          f"costo stimato {cost:.2f} USD (modello {model}, tariffe "
          f"{price_in}/{price_out} USD per Mtoken, cache hit non scontata: "
          f"stima per eccesso)")
    if stop_reason:
        print(f"STOP anticipato: {stop_reason} (risultati parziali)")

    if brain_rows["base"]:
        render_verdicts(brain_rows["base"], "Brain attuale", days)
    else:
        print("\n## Brain attuale: nessun risultato (manca budget o API key?)")
    if brain_rows["b"]:
        render_verdicts(brain_rows["b"], "Variante b (uscita strutturata)", days)
    else:
        print("\n## Variante b: non eseguita")
    if review_rows["base"]:
        render_reviews(review_rows["base"], "Reviewer attuale")
    else:
        print("\n## Reviewer attuale: non eseguito")
    if review_rows["c"]:
        render_reviews(review_rows["c"], "Variante c (reviewer cieco)")
    else:
        print("\n## Variante c: non eseguita")
    if stability_pairs:
        agree = sum(1 for a, b in stability_pairs if a == b)
        n = len(stability_pairs)
        kappa = "n/d (meno di 30 confronti)" if n < 30 else "vedi note"
        print(f"\n## Stabilità: accordo buy/skip su {n} verdetti ripetuti: "
              f"{agree / n * 100:.1f}% ({kappa})")
    else:
        print("\n## Stabilità: non eseguita")

    dump(stop_reason)
    if skipped_days:
        print(f"\nGiorni saltati per risposta Kimi non valida: {skipped_days}")
    print("\nDettaglio in replay_agents_risultati.json")
    print("REGOLA DI LETTURA (dichiarata prima in docs/AGENTI.md): nessuna variante b/c")
    print("diventa attiva senza battere il Brain attuale su queste misure e il via dell'utente.")
    return 0


def combine(paths):
    """Unisce i JSON di piu' finestre di replay e stampa la tabella dell'unione
    (nessuna chiamata Kimi): i verdetti di un giorno appartengono a una sola
    finestra, quindi l'unione non duplica niente."""
    merged_brain = {"base": [], "b": []}
    merged_rev = {"base": [], "c": []}
    calls = tokens_in = tokens_out = days = skipped = 0
    cost = 0.0
    windows = []
    for path in paths:
        with open(path) as f:
            d = json.load(f)
        for k in ("base", "b"):
            merged_brain[k].extend(d.get("brain", {}).get(k, []))
        for k in ("base", "c"):
            merged_rev[k].extend(d.get("reviews", {}).get(k, []))
        calls += d.get("calls", 0) or 0
        tokens_in += d.get("tokens_in", 0) or 0
        tokens_out += d.get("tokens_out", 0) or 0
        cost += d.get("cost_usd", 0) or 0
        days += d.get("days", 0) or 0
        skipped += d.get("skipped_days", 0) or 0
        windows.append(f"{path} (offset {d.get('offset')}, giorni {d.get('days')})")
    print("# Replay agenti COMBINATO (unione delle finestre, nessuna nuova chiamata):")
    for w in windows:
        print(f"- {w}")
    print(f"Giorni: {days} (saltati {skipped}) | chiamate {calls} | token in {tokens_in} "
          f"out {tokens_out} | costo stimato {cost:.2f} USD")
    if merged_brain["base"]:
        render_verdicts(merged_brain["base"], "Brain attuale (unione)", days)
    else:
        print("\n## Brain attuale: nessun risultato")
    if merged_brain["b"]:
        render_verdicts(merged_brain["b"], "Variante b (unione)", days)
    if merged_rev["base"]:
        render_reviews(merged_rev["base"], "Reviewer attuale (unione)")
    else:
        print("\n## Reviewer attuale: nessun risultato")
    if merged_rev["c"]:
        render_reviews(merged_rev["c"], "Variante c (unione)")
    with open("replay_agents_risultati_combinati.json", "w") as f:
        json.dump({"calls": calls, "tokens_in": tokens_in, "tokens_out": tokens_out,
                   "cost_usd": round(cost, 2), "days": days,
                   "brain": merged_brain, "reviews": merged_rev}, f, indent=1)
    print("\nDettaglio in replay_agents_risultati_combinati.json")
    return 0


class _Slice:
    def __init__(self, values):
        self.values = values

    def tolist(self):
        return self.values


class _Iloc:
    """Indicizzatore come pandas: iloc[intero] e iloc[fetta].tolist()."""

    def __init__(self, values):
        self.values = values

    def __getitem__(self, i):
        if isinstance(i, slice):
            return _Slice(self.values[i])
        return self.values[i]


class Ser:
    """Shim di una Series pandas per lo smoke test (iloc e' un indicizzatore)."""

    def __init__(self, values):
        self.values = values

    @property
    def iloc(self):
        return _Iloc(self.values)




def smoke():
    """Test locale senza rete: payload sintetico, struttura e anonimizzazione."""
    import math
    n = 80
    raw = {}
    for t in ETFS:
        wave = [100 * (1 + 0.01 * math.sin(i / 7 + (ord(t[0]) % 5))) for i in range(n)]
        raw[t] = {"close": wave, "sma200": [x * 0.98 for x in wave],
                  "sma5": [x * 0.99 for x in wave], "rsi2": [5.0] * n,
                  "atr": [2.0] * n, "ret": [0.01] * n}
    cols = ("close", "sma200", "sma5", "rsi2", "atr", "ret")
    data = {c: {t: Ser(raw[t][c]) for t in ETFS} for c in cols}
    data["index"] = list(range(n))
    idx = n - 1
    cands = ["SPY", "QQQ", "IWM"]
    payload, meta = build_payload(data, idx, cands, anon_map())
    txt = json.dumps(payload)
    assert "SPY" not in txt and "QQQ" not in txt and "TLT" not in txt, "ticker nel payload!"
    anon = anon_map()
    symbols_in_payload = {c["symbol"] for c in payload["candidates"]} | \
        set(payload["market_overview"])
    assert symbols_in_payload and symbols_in_payload <= set(anon.values()), \
        "simboli payload fuori dalla mappa anonima"
    assert "ETF_E" in txt and "ETF_F" in txt, "mappa anonima incompleta"
    assert payload["slots_available"] == SLOTS and payload["open_positions"] == []
    assert payload["past_outcomes"] is None and payload["shadow_outcomes"] is None
    c0 = payload["candidates"][0]
    assert abs(c0["indicators"]["close"] - 100.0) < 1e-6, "normalizzazione sbagliata"
    assert set(c0["indicators"]) == {"close", "sma200", "sma5", "rsi2",
                                     "atr14", "distance_from_sma200_pct"}
    assert [d["agent"] for d in c0["specialist_digest"]] == \
        ["technical", "quantitative", "news", "fundamental"]
    assert all(d["signal"] == "abstain" for d in c0["specialist_digest"][2:])
    assert len(c0["recent_closes"]) == 20
    verdict = {"symbol": c0["symbol"], "action": "buy", "confidence": 0.7,
               "rationale": "test"}
    rp = review_payload(payload, verdict, meta)
    assert "confidence" in rp["proposal"] and "rationale" in rp["proposal"]
    rpb = review_payload(payload, verdict, meta, blind=True)
    assert "confidence" not in rpb["proposal"] and "rationale" not in rpb["proposal"]
    allowed = {c["symbol"].upper() for c in payload["candidates"]}
    assert validate_verdicts([{"symbol": c0["symbol"], "action": "buy", "confidence": 1.5}],
                             allowed) == [], "confidence fuori range accettata!"
    assert validate_verdicts([{"symbol": "ETF_Z", "action": "buy", "confidence": 0.6}],
                             allowed) == [], "simbolo inventato accettato!"
    assert validate_verdicts([{"symbol": c0["symbol"], "action": "buy", "confidence": 0.6}],
                             allowed) != [], "verdetto valido rifiutato!"
    assert len(REASON_CODES) == len(set(REASON_CODES)), "reason codes duplicati"
    assert uniform_indices(10, 4) == [0, 3, 6, 9], "selezione uniforme sbagliata"
    assert uniform_indices(5, 10) == [0, 1, 2, 3, 4], "piu' richiesti che disponibili"
    assert len(uniform_indices(2000, 150)) == 150, "150 su 2000 devono essere 150"
    assert uniform_indices(2000, 150)[0] == 0 and uniform_indices(2000, 150)[-1] == 1999, \
        "primo e ultimo giorno esclusi"
    rows = ([{"chosen": True, "ret5": 0.01, "ret10": 0.02},
             {"chosen": False, "ret5": -0.01, "ret10": -0.02}] * 5)
    b1, b2 = bootstrap_diff(rows, "ret5"), bootstrap_diff(rows, "ret5")
    assert b1["lo"] == b2["lo"] and b1["hi"] == b2["hi"], "bootstrap non riproducibile"
    assert b1["lo"] > 0 and b1["hi"] > 0, "IC di una differenza nettamente positiva"
    assert bootstrap_diff([{"chosen": False, "ret5": 0.0}] * 3, "ret5") is None, \
        "bootstrap senza scelti deve dare None"
    print("SMOKE OK: payload conforme a dailyDecide/dailyReview, anonimizzato,")
    print("normalizzazione a base 100, review cieco senza rationale, fail-closed attivo,")
    print("selezione uniforme e bootstrap riproducibili")
    return 0


if __name__ == "__main__":
    if "--combine" in sys.argv:
        sys.exit(combine(sys.argv[sys.argv.index("--combine") + 1:]))
    if "--smoke" in sys.argv:
        sys.exit(smoke())
    try:
        sys.exit(run_replay())
    except urllib.error.HTTPError as e:
        print(f"ERRORE HTTP Moonshot: {e.code} {e.read().decode()[:300]}")
        sys.exit(1)
