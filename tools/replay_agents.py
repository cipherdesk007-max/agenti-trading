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

Costi: tetto REPLAY_BUDGET chiamate (default 400). Tariffe stimate (env):
KIMI_PRICE_IN / KIMI_PRICE_OUT USD per milione di token (default 0,60 / 2,50:
ASSUNZIONE DICHIARATA, verificare le tariffe correnti di Moonshot).

Senza MOONSHOT_API_KEY stampa un messaggio chiaro ed esce con codice 0 (non è
un errore del run). Con --smoke costruisce i payload su dati sintetici e li
valida SENZA rete (test locale della struttura, senza pandas/yfinance).
"""
import json
import os
import sys
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


class Kimi:
    """Client Moonshot minimale: stessa richiesta di KimiService.chatOnce."""

    def __init__(self, key, model, budget):
        self.key, self.model, self.budget = key, model, budget
        self.calls = 0
        self.tokens_in = self.tokens_out = 0

    def chat(self, prompt, payload, schema, name):
        if self.calls >= self.budget:
            raise RuntimeError(f"budget di {self.budget} chiamate esaurito")
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
        with urllib.request.urlopen(req, timeout=180) as r:
            data = json.load(r)
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
        return json.loads(content[s:e + 1])


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


def find_days(data, max_days):
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
    return days[-int(max_days):]


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
    print(f"\n## {label}: {len(rows)} verdetti su {len(days)} giorni")
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
    variants = [v.strip() for v in os.environ.get("REPLAY_VARIANTS", "base,b,c").split(",")
                if v.strip()]
    stability_on = os.environ.get("REPLAY_STABILITY", "yes").lower() not in ("no", "0", "false")
    budget = int(os.environ.get("REPLAY_BUDGET", "400"))
    kimi = Kimi(key, os.environ.get("KIMI_MODEL", "kimi-k3.1-pro-highspeed"), budget)
    price_in = float(os.environ.get("KIMI_PRICE_IN", "0.60"))
    price_out = float(os.environ.get("KIMI_PRICE_OUT", "2.50"))

    data = load_data()
    days = find_days(data, max_days)
    print(f"# Replay agenti: {len(days)} giorni con candidati, varianti {variants}, "
          f"stabilita' {'si' if stability_on else 'no'}, tetto {budget} chiamate")
    anon = anon_map()
    brain_rows = {"base": [], "b": []}
    review_rows = {"base": [], "c": []}
    first_pass_verdicts = {}   # idx -> {symbol anon: action}
    stability_pairs = []       # (esecuzione 1, esecuzione 2) per candidato
    stop_reason = None
    try:
        for idx, day, cands in days:
            payload, meta = build_payload(data, idx, cands, anon)
            allowed = {anon[t].upper() for t in cands}
            first = kimi.chat(BRAIN_PROMPT, payload, brain_schema(), "daily_decisions")
            verdicts = validate_verdicts(first.get("decisions", []), allowed)
            first_pass_verdicts[idx] = {v["symbol"]: v["action"] for v in verdicts}
            for v in verdicts:
                t = meta[v["symbol"]]["ticker"]
                brain_rows["base"].append({
                    "ticker": t, "chosen": v["action"] == "buy",
                    "ret5": fwd(data, idx, t, 5), "ret10": fwd(data, idx, t, 10),
                    "conf": v["confidence"]})
            buys = sorted([v for v in verdicts if v["action"] == "buy"],
                          key=lambda v: -v["confidence"])[:SLOTS]
            for v in buys:
                rev = kimi.chat(REVIEWER_PROMPT, review_payload(payload, v, meta),
                                REVIEW_SCHEMA, "daily_review")
                t = meta[v["symbol"]]["ticker"]
                review_rows["base"].append({
                    "ticker": t, "approved": rev.get("verdict") == "approve",
                    "ret5": fwd(data, idx, t, 5), "ret10": fwd(data, idx, t, 10)})
            if "b" in variants:
                second = kimi.chat(BRAIN_PROMPT, payload, brain_schema(structured=True),
                                   "daily_decisions_v2")
                for v in validate_verdicts(second.get("decisions", []), allowed):
                    t = meta[v["symbol"]]["ticker"]
                    brain_rows["b"].append({
                        "ticker": t, "chosen": v["action"] == "buy",
                        "ret5": fwd(data, idx, t, 5), "ret10": fwd(data, idx, t, 10),
                        "conf": v["confidence"]})
            if "c" in variants:
                for v in buys:
                    rev = kimi.chat(REVIEWER_PROMPT,
                                    review_payload(payload, v, meta, blind=True),
                                    REVIEW_SCHEMA, "daily_review")
                    t = meta[v["symbol"]]["ticker"]
                    review_rows["c"].append({
                        "ticker": t, "approved": rev.get("verdict") == "approve",
                        "ret5": fwd(data, idx, t, 5), "ret10": fwd(data, idx, t, 10)})
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
    except RuntimeError as e:
        stop_reason = str(e)

    cost = kimi.tokens_in / 1e6 * price_in + kimi.tokens_out / 1e6 * price_out
    print(f"\nChiamate: {kimi.calls} | token in {kimi.tokens_in} out {kimi.tokens_out} | "
          f"costo stimato {cost:.2f} USD "
          f"(tariffe dichiarate {price_in}/{price_out} USD per Mtoken)")
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

    with open("replay_agents_risultati.json", "w") as f:
        json.dump({"calls": kimi.calls, "tokens_in": kimi.tokens_in,
                   "tokens_out": kimi.tokens_out, "cost_usd": round(cost, 2),
                   "days": len(days), "brain": brain_rows, "reviews": review_rows},
                  f, indent=1)
    print("\nDettaglio in replay_agents_risultati.json")
    print("REGOLA DI LETTURA (dichiarata prima in docs/AGENTI.md): nessuna variante b/c")
    print("diventa attiva senza battere il Brain attuale su queste misure e il via dell'utente.")
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
    print("SMOKE OK: payload conforme a dailyDecide/dailyReview, anonimizzato,")
    print("normalizzazione a base 100, review cieco senza rationale, fail-closed attivo")
    return 0


if __name__ == "__main__":
    if "--smoke" in sys.argv:
        sys.exit(smoke())
    try:
        sys.exit(run_replay())
    except urllib.error.HTTPError as e:
        print(f"ERRORE HTTP Moonshot: {e.code} {e.read().decode()[:300]}")
        sys.exit(1)
