# Proposte · non implementate

Solo idee, da scegliere e poi da sviluppare. Vincoli: le prime 5 usano **solo le 3 API
esistenti** (Alpaca Trading, Alpaca Market Data con notizie Benzinga, Kimi/Moonshot);
dal 12/11/2026 si possono proporre anche **API pubbliche gratuite oltre le 3**, ma solo se
(verificato prima) Alpaca non offre già il dato, la fonte è ufficiale con documentazione e
limiti d'uso dichiarati (link sotto), l'uso è **mai obbligatorio** (se l'API non risponde
l'app si comporta come oggi) e ogni modifica alla strategia passa per un backtest in
`tools/` prima di entrare nell'app (vincolo di `docs/STATO.md`). Nessuna di queste è nel
codice.

## 1 · Trailing stop GTC sulla GIORNALIERA (invece dello stop fisso a 2,5 ATR)

- **API**: Alpaca Trading (ordini `trailing_stop`, restano sul broker come il GTC attuale).
- **Guadagno atteso**: protegge i profitti durante i trend rialzisti lunghi; plausibile miglioramento del rapporto CAGR/perdita massima rispetto allo stop fisso.
- **Rischio**: whipsaw — uscite anticipate per volatilità; con i gap il trailing stop esegue al prezzo di mercato, non al trail. Cambia il carattere della strategia (più trade, più costi).
- **Come provarla prima**: variante di `tools/backtest_app.py` con uscita trailing (stesso 2,5 ATR) contro quella fissa, su 2006–oggi più le 18 varianti di robustezza; se CAGR/|maxDD| migliora in modo robusto entra in app, poi 1 mese in paper con stop reale sul broker.

## 2 · Pesi risk-parity nella NOTTE (1/volatilità a 20 giorni invece di peso uguale)

- **API**: Alpaca Market Data per le barre (lo studio usa yfinance in `tools/`).
- **Guadagno atteso**: la perdita massima della NOTTE (−22% a peso uguale) dovrebbe scendere, dando peso maggiore a oro e volatilità bassa.
- **Rischio**: più turnover e costi d'asta; l'effetto può essersi spento negli ultimi anni; il paniere a peso uguale è più semplice da spiegare e controllare.
- **Come provarla prima**: variante di `tools/backtest_overnight.py` con pesi 1/vol su 2006–oggi **e** sugli ultimi 2 anni; entra solo se migliora CAGR/|maxDD| in entrambi. Poi optionally in `backtest_overnight_fraction.py`.

## 3 · Frazione NOTTE adattiva dopo drawdown (usa i numeri dello studio R1)

- **API**: Alpaca Trading (equity del conto); la logica è in `tools/backtest_overnight_fraction.py`.
- **Guadagno atteso**: dopo notti negative consecutive o un drawdown del conto oltre soglia, la notte investe una frazione minore (es. 97% → 75% → 50%): la perdita massima sul conto scende nelle fasi brutte.
- **Rischio**: sottoperformance nel recupero; se si provano tante soglie il risultato può essere fortunato (Deflated Sharpe) — provarne al massimo 2–3.
- **Come provarla prima**: variante dello studio R1 con f adattiva (soglie su drawdown del conto); confrontare CAGR/|maxDD| su tutto il periodo e sugli ultimi 2 anni prima di toccare `cashBuffer`.

## 4 · Filtro "evento" 48h prima dell'ingresso della GIORNALIERA

**Stato: IN PROVA IN OMBRA dall'app dal 12/11/2026.** `EventFilter48h`
esamina i titoli Benzinga delle 48h di ogni candidato (parole chiave: Fed, FOMC,
CPI, payroll, earnings, halt, downgrade, tariff, ecc.) e scrive solo un flag
`eventFlag` nel registro ombra. Nessun ordine e nessuna decisione cambia. La
pagella confronta l'esito medio dei candidati CON evento contro i SENZA e mostra
il "valore del filtro": positivo = saltarli avrebbe protetto. Si adotta solo se
≥20 esiti lo confermano E un backtest con la stessa regola su dati storici
conferma. Le righe sotto descrivono la proposta originale.

- **API**: Alpaca Market Data News (le notizie delle 48h le prende già l'app per Brain/Reviewer; la regola sarebbe in codice, zero crediti Kimi in più).
- **Guadagno atteso**: blocca ingressi dentro eventi che cambiano il quadro (Fed, CPI, halt), evitando parte dei drawdown post-evento.
- **Rischio**: salta anche trade buoni subito dopo l'evento; la classificazione "hard event" è fuzzy e può degenerare in una regola che non scatta mai (o sempre).
- **Come provarla prima**: backtest in `tools/` con filtro sulle date degli annunci Fed/CPI 2006–oggi contro il filtro attuale (solo RSI2); entra solo se migliora CAGR/|maxDD|. Se non migliora, resta solo nel prompt del Reviewer (comportamento attuale).

## 5 · Badge notizie 48h nel CRUSCOTTO per le posizioni aperte (solo display, nessun ordine)

- **API**: Alpaca Market Data News; nessuna chiamata a Kimi.
- **Guadagno atteso**: visibilità su eventi che possono muovere una posizione durante la notte, dove non c'è stop (la NOTTE non può averne). Puó motivare una chiusura manuale.
- **Rischio**: solo rumore — notifiche a vuoto. **Nessun rischio sugli ordini**: non tocca l'esecuzione, è display puro.
- **Come provarla prima**: 1 mese in paper con log delle notifiche in DETTAGLI: contare quante avvisano un movimento reale della posizione entro 24h contro quante sono rumore. Entra solo se il rapporto è claramente utile.

---

## API pubbliche gratuite aggiuntive · 12/11/2026 (solo proposte, non implementate)

Prima verifica fatta: Alpaca offre **già** calendario di borsa, corporate actions, aste
e screener (proposte 6–9, stesse chiavi, nessun costo né nuova credenziale). Una sola
fonte esterna passa i filtri (proposta 10, FRED). Scartate: Yahoo Finance (non ufficiale,
ToS vietano lo scraping), calendario Nasdaq Trader (pagina HTML, non API documentata),
SEC EDGAR (ufficiale e gratuita ma ridondante con le notizie Benzinga già usate; da
riconsiderare solo per un filtro eventi 8-K, vedi proposta 4).

### 6 · Alpaca Trading API `GET /v2/calendar` (endpoint non usato, stesse chiavi)

- **Dato**: giorni di borsa 1970–2029 con orari di open/close esatti, **incluse le
  chiusure anticipate** (es. 13:00 ET il giorno prima di Natale).
- **A quale modalità serve**: NOTTE (la finestra MOC oggi usa un margine fisso di 10 min;
  con il calendario si conosce la chiusura esatta del giorno, anche anticipata, e si
  evitano OPG/MOC nei festivi); GIORNALIERA e VELOCE (promemoria e controlli solo nei
  giorni di borsa; flat-by-close saprebbe la chiusura anticipata).
- **Guadagno atteso**: niente ordini d'asta nei giorni sbagliati; promemoria precisi.
- **Rischio**: nullo, endpoint di sola lettura. Limite dichiarato: Trading API 200
  richieste/min per conto.
- **Come provarla**: confrontare `calendar` con `clock` per 1 mese in paper; backtest:
  variante di `tools/backtest_overnight.py` che usa le chiusure anticipate reali.
- **Mai obbligatoria**: se non risponde si usa `clock` come oggi.
- **Link**: https://docs.alpaca.markets/us/reference/legacycalendar · limiti:
  https://alpaca.markets/support/usage-limit-api-calls

### 7 · Alpaca Market Data, corporate actions per simbolo (endpoint non usato)

- **Dato**: split, dividendi, merger annunciati per un simbolo in un periodo
  (`data_quality=complete` esclude gli eventi ancora in corso).
- **A quale modalità serve**: NOTTE e GIORNALIERA. I registri locali salvano le
  **quantità**: dopo uno split (es. 2:1) la quantità registrata è stale e la vendita
  OPG / lo stop possono partire a quantità sbagliata (il `min(recorded, held)` di B1/R7
  copre, ma lascia residui orfani post-split).
- **Guadagno atteso**: riconciliazione automatica delle quantità di registro dopo ogni
  corporate action sugli ETF in posizione; niente orfani post-split.
- **Rischio**: dato storico, non real-time; una CA annunciata ma non ancora effettiva va
  ignorata (si confronta con `ex_date`).
- **Come provarla**: unit test con fixture JSON; poi 1 mese in paper confrontando
  quantità di registro vs broker a ogni CA sugli ETF del paniere.
- **Mai obbligatoria**: se non risponde, comportamento odierno.
- **Link**: https://docs.alpaca.markets/us/reference/corporateactions-1 · piano/limiti
  Market Data Basic (IEX real-time, 200 req/min): https://docs.alpaca.markets/us/docs/about-market-data-api

### 8 · Alpaca Market Data, aste storiche `GET /v2/stocks/auctions` (feed `sip`)

- **Dato**: prezzi **reali delle aste di apertura (`o`) e di chiusura (`c`)** per giorno
  e simbolo, con timestamp e size.
- **A quale modalità serve**: NOTTE. Gli studi overnight usano close→open; con i prezzi
  d'asta reali il backtest è fedele a ciò che MOC/OPG esegue davvero. In app: verifica
  post-asta che l'esecuzione sia al prezzo d'asta (scostamento vs close).
- **Guadagno atteso**: backtest overnight più realistico (costi d'asta già stimati a
  0,003%/lato, qui si misura lo scostamento reale); controllo qualità delle esecuzioni.
- **Rischio**: senza feed real-time i dati sono in ritardo di 15 min (va bene dopo la
  chiusura); limite ~100 req/min (header `X-RateLimit-*`).
- **Come provarla**: variante di `tools/backtest_overnight.py` con prezzi d'asta reali
  (da scaricare una tantum da Alpaca in `tools/`); in paper, confronto esecuzione vs
  `auctions` del giorno per un mese.
- **Mai obbligatoria**: se non risponde, si usa l'ultimo prezzo come oggi.
- **Link**: https://docs.alpaca.markets/us/reference/stockauctions-1 (e `stockauctionsingle-1`)

### 9 · Alpaca Market Data, screener most-actives / movers (endpoint non usato)

- **Dato**: top N simboli per volume o numero di trade della giornata (SIP), gainers e
  losers (`/v1beta1/screener/stocks/most-actives`, `/movers`).
- **A quale modalità serve**: VELOCE — scegliere i simboli più liquidi del giorno invece
  di una lista fissa, per ridurre slippage su ingressi/uscite intraday.
- **Guadagno atteso**: liquidità migliore dove si opera intraday.
- **Rischio**: sul piano Basic gratuito il real-time per le azioni è **solo IEX**, quindi
  lo screener SIP può essere limitato o in ritardo — va trattato come opzionale. La
  veloce resta sconsigliata con soldi veri (perde nei backtest).
- **Come provarla**: backtest intraday su top-20 per volume medio a 20 gg (proxy delle
  barre, dato che lo screener storico non esiste) vs lista fissa; in paper, confronto
  slippage 1 mese.
- **Mai obbligatoria**: se non risponde, si usa la lista simboli impostata dall'utente.
- **Link**: https://docs.alpaca.markets/us/reference/mostactives-1 ·
  https://docs.alpaca.markets/us/reference/movers-1 · caveat piano Basic:
  https://docs.alpaca.markets/us/docs/about-market-data-api

### 10 · FRED (Federal Reserve Bank of St. Louis) — serie `VIXCLS` (e `GVZCLS` per l'oro)

- **Dato**: VIX di chiusura CBOE giornaliero dal 1990 (serie `VIXCLS`); `GVZCLS` per la
  volatilità dell'oro. Fonte ufficiale (Federal Reserve Bank of St. Louis), **gratuita**
  con chiave API gratuita (registrazione su fredaccount), limiti dichiarati: **120
  richieste/min per chiave**, Terms of Use pubblici.
- **A quale modalità serve**: GIORNALIERA — filtro di regime in codice: blocca nuovi
  ingressi se VIX sopra soglia (media 20 gg + k·σ oppure livello fisso), da passare anche
  a Brain/Reviewer come contesto. (Alpaca non offre il VIX: è un indice CBOE, non uno
  stock/ETF del paniere.)
- **Guadagno atteso**: evita ingressi dentro drawdown violenti (2008, 2020, 2022…); la
  perdita max della giornaliera (−9%) potrebbe scendere.
- **Rischio**: salta anche i rimbalzi post-crash; aggiunge una quarta credenziale (gratis,
  salvata come le altre nel Keychain); multi-testing se si provano tante soglie
  (Deflated Sharpe).
- **Come provarla**: backtest in `tools/` con `^VIX` da yfinance (stesso dato di VIXCLS)
  — filtro VIX vs senza su 2006–oggi, CAGR/perdita max/Sharpe + 18 varianti di
  robustezza; poi 1 mese in ombra (registro ombra) in paper prima di attivarlo.
- **Mai obbligatoria**: se FRED non risponde (o la chiave manca), nessun filtro e
  l'app si comporta esattamente come oggi.
- **Link**: API https://fred.stlouisfed.org/docs/api/fred/ · limiti (429 oltre 120/min):
  https://fred.stlouisfed.org/docs/api/fred/errors.html · ToU:
  https://fred.stlouisfed.org/docs/api/terms_of_use.html · serie:
  https://fred.stlouisfed.org/series/VIXCLS

---

## Idee esterne · 12/11/2026 (incollate da una fonte esterna, tutte SOLO PROPOSTE)

Verifica preliminare: Alpaca **non offre** un calendario macroeconomico (è un dato di
istituzioni pubbliche, non di un broker) e **non offre** sentiment di mercato come dato
strutturato (le notizie Benzinga sono testo libero, già usate). Le fonti pubbliche
gratuite e ufficiali che restano sono i siti .gov (FOMC/BLS), usate come calendario
statico negli studi, non come API in app. Nessuna di queste proposte è nel codice.

### 11 · Calendario macroeconomico (FOMC, CPI, NFP) come contesto per Kimi e filtro eventi

- **Dato**: date ufficiali di decisioni FOMC (14:00 ET), rilasci CPI/BLS e payroll.
  Fonte ufficiale e gratuita: pagine pubbliche .gov, **senza chiave API**:
  - FOMC: https://www.federalreserve.gov/monetarypolicy/fomccalendars.htm
  - Calendario generale Fed: https://www.federalreserve.gov/newsevents/calendar.htm
  - BLS (CPI, payroll e altri rilasci): https://www.bls.gov/schedule/2026/home.htm e
    https://www.bls.gov/schedule/news_release/cpi.htm
  - Limiti dichiarati: sono pagine HTML, non API (niente rate limit, ma niente guarantee
    di formato); gli studi le traducono in un CSV statico in `tools/`.
- **A quale modalità serve**: GIORNALIERA — bloccare ingressi nelle 48h prima di eventi
  binari (sovrapposizione con la proposta 4, ma qui la lista date è ufficiale invece che
  dedotta dalle notizie); e come contesto testo da passare a Brain/Reviewer (Kimi vede
  "domani FOMC" senza spendere crediti extra: è nel prompt, non in una chiamata nuova).
  In app le stesse informazioni arrivano già come testo dalle notizie Benzinga di Alpaca
  Market Data (proposte 4/12).
- **Guadagno atteso**: evitare parte dei drawdown post-evento; contesto migliore per le
  decisioni di Kimi.
- **Rischio**: date che slittano (shutdown, emergenze); multi-testing se si provano tante
  finestre (Deflated Sharpe).
- **Come provarla**: backtest in `tools/` con CSV delle date ufficiali 2006–oggi vs filtro
  attuale; poi 1 mese in ombra. **Mai obbligatoria**: senza calendario l'app si comporta
  come oggi.

### 12 · Sentiment delle notizie per il Reviewer (solo le 3 API attuali)

- **API**: Alpaca Market Data News (Benzinga) — le headlines 48h le prende già l'app e le
  passa a Brain/Reviewer. Nessuna API nuova, nessun costo Kimi in più.
- **A quale modalità serve**: GIORNALIERA e VELOCE — un passaggio "urgenza" sul testo delle
  notizie (parole chiave di crollo sistemico + simbolo menzionato) che il Reviewer può usare
  per bocciare un ETF in giornata, senza chiamare Kimi.
- **Guadagno atteso**: veto rapido su eventi sistemici in corso, zero crediti spesi.
- **Rischio**: falsi allarmi (veto su notizie irrilevanti); la keyword list è fragile.
- **Come provarla prima**: 1 mese in ombra contando quanti veto scattano e quanti
  hanno anticipato davvero un movimento >1% del simbolo entro 24h. Entra solo se il
  rapporto è chiaramente utile.

### 13 · Modello ML tabellare (XGBoost/LightGBM/CatBoost) come score numerico pre-Kimi

- **Dato**: decine di feature numeriche già disponibili nello studio (VIX da
  FRED/yfinance, correlazioni tra settori, volumi relativi, RSI/ATR del paniere) →
  probabilità di successo del segnale, passata a Kimi come numero invece di fargliela
  calcolare a mente.
- **A quale modalità serve**: GIORNALIERA — score del candidato prima di spendere crediti
  Kimi; i casi con score basso restano HOLD senza chiamata.
- **Guadagno atteso**: Kimi lavora su una probabilità calibrata invece che su testo;
  meno crediti spesi sui segnali deboli.
- **Rischio**: overfitting grave su serie storiche (per questo resta SOLO uno studio in
  `tools/`); Deflated Sharpe se si ottimizza sul test set; dipendenze python pesanti in CI
  (pip install xgboost/lightgbm nel job `studi`).
- **Come provarla**: `tools/backtest_ml_score.py` (da scrivere, runner `quale=studi`):
  train 2006–2019, test 2020–oggi, confronto CAGR/|maxDD| vs filtro RSI2 attuale; entra in
  app solo se robusto out-of-sample. Mai in app prima.

### 14 · Regime detection (HMM a 2 stati sui rendimenti + VIX) per cambiare strategia

- **Dato**: rendimenti giornalieri di SPY (yfinance nello studio) + VIX (FRED VIXCLS,
  proposta 10). HMM gaussiano a 2 stati (trend rialzista a bassa vol / laterale-nervoso),
  implementabile in numpy in `tools/` senza dipendenze pesanti.
- **A quale modalità serve**: GIORNALIERA — in regime "trend" attivare un piccolo braccio
  momentum (il backtest attuale mostra +2,3%/anno del mean-reversion contro +10,9% del
  buy&hold: il bot resta liquido nei grandi trend); in regime "laterale" resta la
  strategia attuale RSI2.
- **Guadagno atteso**: catturare parte dei trend lunghi senza rinnegare il drawdown
  ridotto (−9% max) della strategia attuale.
- **Rischio**: le etichette di regime si conoscono solo a posteriori (look-ahead nel
  backtest se non si sta attenti); il cambio di strategia è il punto dove nasce
  l'overfit (Deflated Sharpe: provare al massimo 2 soglie/varianti).
- **Come provarla**: `tools/backtest_regime.py` (da scrivere, `quale=studi`): HMM online
  (filtro, non smoothing) su 2006–oggi, confronto vs strategia attuale e vs buy&hold,
  + 18 varianti di robustezza. Entra solo se migliora CAGR/|maxDD| out-of-sample.

### 15 · Fractional shares via Alpaca (`notional`) — l'unica con impatto sui conti piccoli

- **API**: Alpaca Trading, stessa chiave. `POST /v2/orders` accetta `notional` (USD) o
  `qty` frazionaria (fino a 9 decimali) per ordini market/limit/stop/stop-limit con
  `time_in_force=day`; minimo $1; oltre 5.000 titoli fractionable **inclusi ETF**
  (verificare il flag `fractionable=true` su `GET /v2/assets/{symbol}`).
  - Link: https://docs.alpaca.markets/us/docs/fractional-trading ·
    https://alpaca.markets/support/fractional-shares · flag sull'asset:
    https://docs.alpaca.markets/us/reference/getasset-1
- **A quale modalità serve**: GIORNALIERA (e VELOCE) sui conti piccoli, dove oggi il 44%
  dei segnali viene saltato perché 1 azione intera costa più del rischio consentito per
  trade.
- **Guadagno atteso**: su conti sotto ~2.000–3.000 $ i segnali saltati diventano
  eseguibili; sizing più preciso (notional esatto invece di qty intera arrotondata).
- **Rischio grave, da valutare prima**: Alpaca supporta le frazioni **solo con ordini
  Day** — niente GTC ("the fractional shares trading is currently supported only for day
  orders", https://docs.alpaca.markets/us/docs/brokerapi-trading). La nostra protezione
  principale è lo stop GTC sul broker: con le frazioni lo stop diventerebbe Day (si
  disarma a fine giornata) oppure assente. Inoltre gli ordini `notional` non possono
  essere sostituiti e gli ordini d'asta MOC/OPG della NOTTE non sono frazionari.
  Quindi: frazioni solo per GIORNALIERA/VELOCE, mai per la NOTTE, e con stop Day da
  riarmare ogni mattina — oppure si decide che il rischio "senza stop overnight" non
  vale il recupero dei segnali.
- **Come provarla**: unit test di conversione sizing→notional (9 decimali) con fallback a
  qty intera se l'asset non è `fractionable` o l'ordine è rifiutato; poi 1 mese in paper
  su un conto da 500 $ confrontando segnali eseguiti vs saltati. **Mai obbligatoria**: se
  l'API rifiuta, si comporta come oggi (qty intera).

### 16 · Filtro di correlazione tra posizioni (matrice del paniere)

- **API**: Alpaca Market Data — le barre giornaliere del paniere le prende già l'app; la
  matrice di correlazione (20–60 gg) si calcola in codice, nessun dato nuovo.
- **A quale modalità serve**: GIORNALIERA — bloccare un nuovo ingresso se il candidato
  correla > soglia (es. 0,85) con un simbolo già in posizione: oggi SPY+QQQ+XLK aperti
  insieme triplicano di fatto lo stesso rischio.
- **Guadagno atteso**: vera diversificazione invece di 3 nomi che si muovono all'unisono;
  drawdown più contenuto nei crolli (dove però tutte le correlazioni tendono a 1).
- **Rischio**: nelle crisi le correlazioni convergono a 1 e il filtro blocca tutto (o, al
  contrario, in trend stabili blocca ingressi validi); soglia da calibrare senza
  multi-testing (Deflated Sharpe: max 2 soglie).
- **Come provarla prima**: variante di `tools/backtest_app.py` con filtro correlazione
  2006–oggi e sugli ultimi 2 anni vs senza filtro; poi 1 mese in ombra. Solo Alpaca,
  nessuna API nuova.

---

## Stato · 12/11/2026 (dopo il giro di lavoro)

- **5 · badge notizie nel CRUSCOTTO**: FATTO (`8606d32`, solo interfaccia, test UI `testNewsBadgeOnOpenPosition`).
- **6 · calendario Alpaca `/v2/calendar`**: FATTO (`9cdaba1`) — finestre NOTTE con chiusura esatta (anche mezze jornadas), niente ordini d'asta nei festivi, promemoria solo nei giorni di borsa. Mai obbligatorio.
- **8 · prezzi reali delle aste**: FATTO come misura (`95790fa`): executed-vs-asta nel report dopo MOC/OPG + `tools/backtest_overnight_auctions.py` nel workflow (`overnight`; senza chiavi in env stampa solo una nota).
- **1 trailing stop, 2 risk-parity NOTTE, 4 filtro evento 48h, 10 filtro VIX**: solo studi pronti in `tools/` (`c540afc`, runner `quale=studi`), con criterio di scarto e nota Deflated Sharpe. L'app non cambia: lancia l'altro revisore, decide l'utente.
- **9 · screener per la VELOCE**: SCARTATA (la veloce resta sconsigliata con soldi veri).
- **7 · riconciliazione corporate actions**: RIMANDATA (gli split sugli ETF del paniere sono rari).
- **3 · frazione adattiva NOTTE**: SCARTATA — il backtest R1 mostra rendimento e perdita in proporzione: resta 97%.
- **11–16 · idee esterne (calendario macro, sentiment Reviewer, ML tabellare, regime HMM, fractional shares, filtro correlazione)**: tutte SOLO PROPOSTE, nessuna implementata. 11/13/14/16 sono studi da scrivere in `tools/` (`quale=studi`) prima di qualsiasi modifica all'app; 12 usa solo le notizie Alpaca già presenti; 15 (fractional `notional`) è l'unica con impatto diretto sull'esecuzione ma ha il vincolo documentato degli ordini solo Day (niente stop GTC frazionario) ed è esclusa dalla NOTTE (MOC/OPG non frazionari) — da valutare con backtest/paper prima di toccare il codice.

---

## Idee del proprietario · 13/11/2026

### 17 · Modalità PORTAFOGLIO: una sola modalità non-veloce (giornaliera + notte sullo stesso conto)

- **Idea del proprietario**: invece di tre modalità da cambiare a mano, una modalità unica
  che fa convivere le due strategie validate sullo stesso conto paper (rigenerabile quando
  si vuole); la VELOCE resta a parte e sperimentale.
- **Studio fatto** (`tools/backtest_portfolio.py`, workflow `quale=portafoglio`, run
  43338377889, dati 2006–2026): due budget sullo stesso conto, riequilibrati a ogni ciclo
  (capitalCap frazionario). Correlazione rendimenti giornaliera/notte +0,04.
  - NOTTE da sola: +7,8%/−21%/Sharpe 0,81 (2006–oggi), +18,1%/−12% (ultimi 3 anni);
  - GIORNALIERA da sola: +0,1%/−23%/0,05 (conferma il +0,1% annuo già noto);
  - split 30/70: +5,6%/−17%/0,79 e Sharpe 1,96 sugli ultimi 3 anni (contro 1,68 della
    notte da sola): perde ~2 punti di CAGR, taglia 4 punti di perdita max e alza lo
    Sharpe recente; regge il controllo a metà campione (+3,6% 2006–2015, +7,4% 2016–oggi);
  - split 50/50: +4,1%/−15%/0,69, Sharpe 2,09 sui 3 anni: ancora meno drawdown;
  - regole DINAMICHE "insegui chi guadagna" (winner-tilt 80/20, risk-parity 1/vol):
    SCARTATE DAI NUMERI: la winner-tilt fa +1,6%/Sharpe 0,25 sulla prima metà e non batte
    mai lo split fisso corrispondente. La notte è un effetto persistente, inseguirla
    rialloca sempre in ritardo.
- **Sensibilità**: con costi notte 0,01%/lato lo split 30/70 scende a +3,1% (2006–oggi):
  il vantaggio della combinazione resta nel drawdown, non nel rendimento.
- **Cosa servirebbe nell'app** (solo se il proprietario conferma): budget frazionario per
  strategia (già quasi tutto c'è: book separati, B1, capitalCap), pannello con P&L separato
  per strategia, ricalibrazione della baseline equity se si rigenera il conto paper
  (il controllo di drawdown altrimenti vede un dirupo). La VELOCE resta fuori.
- **Decisione**: spetta al proprietario scegliere lo split (30/70 consigliato: tiene il
  72% del CAGR della notte con 4 punti di drawdown in meno); poi serve il piano di test.
- **STATO: FATTA il 13/11/2026** — modalità PORTAFOGLIO implementata con split 30/70 (cap sul
  totale prima dello split), P&L separato per strategia e "Ricalibra equity" in SISTEMA.
  Commit `1dfd61c`, `b29be39`, `aec072f`; CI run #185 e #186 verdi (215 test, 0 fallimenti).

### 18 · CRYPTO · 24/7 + Balance Advisor + riscrittura prompt Kimi — richiesta 13/11/2026: ANALISI, **BLOCCATA** (documentata qui invece di implementarla)

- **Cosa chiedeva**: nuova modalità crypto (BTC/USD, ETH/USD, SOL/USD, AVAX/USD, LINK/USD,
  DOGE/USD) con ordini frazionati `notional`, stop GTC/OCO sul broker, loop live 60 s, radar
  Kimi su volume/momentum 24 h; banner "Balance Advisor" in base al saldo; riscrittura dei
  prompt Analyst/Brain/Reviewer; bump di versione e build di release su GitHub.
- **Blocco 1 — nessuna strategia senza numeri**: in `tools/` non esiste alcuno studio crypto e
  `docs/STATO.md` impone "ogni modifica alla strategia va provata con un backtest in `tools/`
  prima di entrare nell'app". I parametri proposti (EMA100 su 1H/4H, RSI2 < 12, stop 3,5 ATR,
  target 2,5 ATR) non hanno alcun backtest alle spalle. Per sbloccare: scrivere
  `tools/backtest_crypto.py` (yfinance, dal 2021, con correzione Deflated Sharpe per le
  varianti provate) + passo `quale=crypto` in `backtest.yml`, lanciato dall'altro revisore
  (a me il dispatch dà 403 e non ho rete); poi decisione del proprietario sui numeri.
- **Blocco 2 — frazioni e stop GTC sul broker sono incompatibili su Alpaca**: le frazioni
  (`notional` / `qty` decimale) sono supportate **solo con ordini Day** — niente GTC/OCO
  (vedi proposta 15 e https://docs.alpaca.markets/us/docs/brokerapi-trading). La richiesta
  chiede entrambe le cose insieme: non è fattibile con questa API. Alternative da studiare:
  stop Day riarmato ogni giorno, oppure protezione lato app (che però non gira ad app chiusa).
- **Blocco 3 — iOS non esegue nulla 24/7 in background**: l'app gira solo quando è aperta
  (docs/GUIDA.md). Un refresh live ogni 60 s è possibile solo in primo piano (come già fa la
  VELOCE); "7 giorni su 7" richiederebbe stop sul broker sempre attivi, che è il blocco 2.
- **Balance Advisor**: la raccomandazione verso CRYPTO è bloccata con la modalità. Per le
  modalità esistenti la copertura c'è già: "ETF comprabili" (`buyableETF`) in SISTEMA e i
  gemelli micro della NOTTE (SPYM/QQQM/VTWO/GLDM). Nessun codice nuovo necessario.
- **Prompt Kimi**: riscriverli cambia il comportamento delle decisioni → stessa regola dei
  numeri: prima validazione in paper/ombra (registro ombra e pagella già pronte in DETTAGLI).
  Non si fa alla cieca.
- **FASE 4 (build di release / `pubblica=true`)**: non è mia — dispatch vietato e token
  read-only sulle mutazioni (403 verificato). La pubblicazione resta manuale dall'utente.
- **Audit di sicurezza rifatto in questa analisi (verificato, nessun cambio di codice)**: 0
  `try!`/`fatalError`/`preconditionFailure` in `Sources/`; 0 pattern di chiavi o segreti in
  Sources/Tests/UITests/.github; retry su 429/5xx (3 tentativi) presente in `AlpacaService` e
  `KimiService`; idempotenza ordini via `client_order_id` + recupero `orderRef(byClientOrderId:)`
  in entrambi i cicli; HARD KILL = `emergencyFlatten` globale (annulla tutti gli ordini e
  chiude tutte le posizioni del conto: coprirebbe anche eventuali posizioni crypto).
