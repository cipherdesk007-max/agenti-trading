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
