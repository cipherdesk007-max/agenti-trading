# Changelog · FMLAB QuantSwarm Alpha Zero

Tutte le modifiche importanti dell'app, dalla più recente.
Formato: [Keep a Changelog](https://keepachangelog.com/it/1.1.0/), versioni [SemVer](https://semver.org/lang/it/).
La versione installata si legge in **SISTEMA → VERSIONE** (con il numero di build della CI).
Le versioni precedenti alla 1.1.0 sono ricostruite dalla storia dei commit.

## [Non rilasciato]

### Perfezionato (chiarezza CRYPTO + log agenti · 13/11/2026, da prova su telefono)
- **Il pannello CRYPTO non mostra più "FUORI" secco**: il chip di ogni coppia dice il perché — **"FUORI · sotto SMA200"** (regime ribassista: le regole V4 non operano sotto la media di 200 giorni) oppure **"FUORI · attende rottura 99.500"** (regime ok, manca la rottura Donchian20, livello indicato). Sotto il prezzo, una riga con i livelli concreti: SMA200 e massimo Donchian20 da superare (o chandelier/stop se in posizione). Nella prova su telefono tutte e 5 le coppie erano sotto la SMA200 (mercato ribassista reale): corretto, ma prima non si capiva.
- **Riepilogo SCOUT del ciclo crypto nel log**: ogni tick di 60 s lasciava il log muto quando non c'era nulla da fare. Ora ogni ciclo chiude con una riga che fotografa TUTTE le coppie e il motivo del loro stato, es. `CRYPTO ciclo: BTC fuori sotto SMA200 · ETH fuori sotto SMA200 · … · posizioni 0/5 · budget 200 USD/coppia · drawdown ok`. La riga si ripete solo se qualcosa cambia (deduplica nel motore), non ogni minuto.
- **STOP del motore non è più un errore del broker**: fermare la sessione mentre un ciclo girava loggava falsi "broker non raggiungibile (CancellationError)" (visibili nel report di sessione dell'utente alle 06:20:38). Ora la CancellationError esce in silenzio in CRYPTO, GIORNALIERA e NOTTE; un vero errore di rete resta loggato con il motivo.
- Test: **+8** (chip esplicativi e livelli, riepilogo del ciclo nel log, STOP silenzioso su tre modalità).

### Aggiunto (modalità CRYPTO · 24/7 + Balance Advisor · 13/11/2026)
- **Nuova modalità CRYPTO · 24/7** (proposta 20, CONSEGNATA): 5 coppie Alpaca (BTC, ETH, SOL, AVAX, LINK in USD), equal-weight con budget 1/5 per coppia. Regole V4 dello studio `tools/backtest_trend_crypto.py` (run 43358878933, costi 0,2%/lato): **ingresso** sopra la SMA200 alla rottura del massimo Donchian20, **uscita** sotto il chandelier (massimo delle chiusure da ingresso − 3×ATR22) o sotto la SMA200, **blocco drawdown ferreo al 10%** dal picco. Nel selettore: PORTAFOGLIO · CRYPTO · VELOCE.
- **Ordini crypto SENZA bracket** (Alpaca li rifiuta con 422): ordine `market` frazionato (qty a 8 decimali), poi, appena risulta `filled`, un ordine `sell stop_limit` GTC **separato** sul broker che copre la quantità realmente riempita (fill parziale gestito). Il chandelier sale e mai scende: lo stop viene cancellato e ripiazzato solo verso l'alto (tolleranza 0,2%). Uscita a mercato solo dopo aver annullato lo stop (mai la doppia vendita). Riconciliazione a ogni ciclo: una posizione chiusa dallo stop ad app chiusa esce dal registro e lo stop residuo viene pulito.
- **Client dati**: `GET /v1beta3/crypto/us/bars` (barre 1D chiuse, paginate, la barra in formazione esclusa) e `/v1beta3/crypto/us/latest/quotes` (mid bid/ask). Fallback silenzioso: una coppia senza dati (rate-limit, disservizio) non blocca le altre; il ciclo riprova al tick successivo.
- **Live loop**: in modalità crypto ad app aperta il motore gira ogni **60 secondi** (prezzi, indicatori, segnali, riconciliazione) con badge **LIVE · 60s** nel cruscotto; ad app chiusa gli stop GTC restano sul broker, 24/7.
- **Balance Advisor**: banner nel CRUSCOTTO e card in SISTEMA che consiglia la modalità in base al saldo (< 1.500 USD → CRYPTO, frazionata su ogni segnale; 1.500–5.000 → PORTAFOGLIO micro o CRYPTO; > 5.000 → PORTAFOGLIO completo). Pulsante "Passa a…" che prepara il selettore; la scelta resta dell'utente. Rispetta NASCONDI SALDO (il numero del conto non appare nel banner).
- **Kimi auto-correzione (task 4)**: i prompt di Brain e Reviewer ricevono `shadow_outcomes`, il digest degli **ultimi 10 esiti risolti** del registro ombra (scelti vs scartati con rendimento % reale e medie complessive). I prompt dicono a Kimi come usarlo: pesare le proposte simili ad acquisti finiti male, citare il rimprovero se gli scartati rendevano meglio, mai respingere a porte chiuse. Record leggeri: `ShadowDigest` è una struct costruita al volo dal registro esistente, nessun record SwiftData nuovo (la potatura a 90 giorni resta). I 5 specialisti locali restano invariati: deterministici e validati, cambiarli violerebbe la regola del backtest.
- **Deviazioni dichiarate** (docs/STATO.md): paniere in-app a 5 coppie come richiesto dal proprietario (lo studio EW includeva DOGE); "max 3 posizioni" della vecchia spec non c'è: ogni coppia ha il suo 1/5, fedeltà allo studio; stop `stop_limit` (Alpaca crypto non supporta l'ordine `stop` semplice né i bracket); lo stop intraday del broker può uscire PRIMA della chiusura della barra (conservativo, dichiarato).
- Test: **+32** (regole V4, sizing frazionato, drawdown, ordini senza bracket, stop prima della vendita, chandelier solo in alto, fill parziale, riconciliazione, fallback coppia senza dati, barra non firmata due volte, Balance Advisor su tutte le fasce, ShadowDigest e payload Kimi).

### Studio crypto trend a regime: V4 approvata dai numeri (13/11/2026)
- **Esiti (run 43358878933, verde):** V4 Donchian20 + chandelier 3ATR **passa tutti i criteri** (+8,4%/anno, maxDD −9%, Sharpe 1,08; finestra orso 2024-11→oggi +7,4% contro −31,8% del buy &amp; hold; entrambe le metà positive) → implementata sopra come modalità CRYPTO · 24/7. V3 (+12,2%/−15%) passa A/C/D ma la perdita max supera il blocco drawdown al 10%: scartata. V1/V2 bocciate (maxDD −38%). Solo il paniere equal-weight funziona: le regole per singola moneta perdono quasi tutte. 4H controllo secondario: nell'orso −0,9% contro −32,3% (capitale salvato).

### Studio crypto trend a regime (strumenti, 13/11/2026)
- **`tools/backtest_trend_crypto.py` + passo `quale=cryptotrend` in `backtest.yml`.** Regole NUOVE dopo il bando della proposta 18 (mean-reversion bocciata): trend-following a regime long-only senza take-profit fisso — V1 SMA200, V2 SMA200 con isteresi 0,97, V3 EMA50>EMA200 + chandelier 3ATR, V4 Donchian20 + chandelier 3ATR. Daily dal 2018 (dove si decide) + 4H su finestra 730gg come controllo secondario. Criteri **pre-registrati** e stampati dallo script: CAGR ≥ +3%, maxDD ≤ −20%, finestra orso 2024-11→oggi ≥ −2%, entrambe le metà del campione positive. Sensibilità costi 0,2% e 0,1% per lato. La modalità CRYPTO 24/7 entra in app **solo se** una variante passa tutti i criteri e il proprietario lo decide.

### Aggiunto (modalità PORTAFOGLIO · 13/11/2026)
- **Nuova modalità PORTAFOGLIO (default)**: GIORNALIERA e NOTTE convivono sullo stesso conto con budget separati, **split fisso 30% / 70%** ribilanciato a ogni ciclo sull'equity corrente (`PortfolioSplit.budgets`); il tetto capitale manuale si applica al **totale prima dello split** (E_eff = min(equity, cap), poi 0,30·E_eff e 0,70·E_eff: la somma non supera mai il cap). Studio `tools/backtest_portfolio.py` (run 43338377889): CAGR +5,6%, perdita max −17%, Sharpe 0,79 (1,96 sugli ultimi 3 anni), correlazione +0,04; regole dinamiche "insegui chi guadagna" scartate dai numeri. **Nessuna regola di ingresso/uscita cambia.**
- Le config legacy GIORNALIERA/NOTTE migrano a PORTAFOGLIO (`TradingMode.migrated`); le posizioni già aperte restano nei rispettivi registri e corrono fino alla loro uscita normale: il nuovo budget dimensiona **solo i nuovi ingressi** (mai forzate né ridimensionate).
- Il selettore ha ora **due modalità**: PORTAFOGLIO e VELOCE (invariata, sperimentale).
- Pannello Portafoglio con **P&L separato per strategia** (non realizzato dal broker + realizzato cumulativo; un simbolo in entrambi i registri è contato una sola volta) e P&L totale del conto.
- SISTEMA: divisione 30/70 e budget attuali per strategia; nuovo pulsante **"Ricalibra equity"** che riallinea picco del drawdown e baseline all'equity corrente (conto paper rigenerato o prelievo: niente stop drawdown per un calo fittizio).
- Test: +14 in `Tests/PortfolioModeTests.swift` (split 30/70, cap applicato al totale, migrazione legacy, P&L separato, ricalibrazione drawdown, notte entro il suo budget, posizione esistente mai forzata, budget piccolo blocca solo i nuovi ingressi). Totale: **215 test unitari** + 5 di interfaccia (run #186 verde).

### Corretto (debug memoria agenti · 13/11/2026)
- **Potatura della memoria SwiftData**: `CouncilRecord` e `DecisionSample` crescevano senza
  limite (mai eliminati). Ora `MemoryPruner.prune` elimina i record oltre 90 giorni, chiamato
  a ogni rollover giornaliero; `TradeRecord` resta perché è lo storico operazioni esportabile.
  Test: `MemoryPrunerTests` (container SwiftData in-memory). Nuova guida rapida
  [docs/TESTI.md](docs/TESTI.md) (CI automatica, `uitest`/`screenshot`, backtest `quale=…`,
  controlli su telefono in VERIFICHE.md).

### Studio pronto (analisi, non entra in app)
- `tools/backtest_crypto.py` + `quale=crypto` in `backtest.yml`: testa la proposta crypto
  (EMA100 + RSI2<12, stop 3,5 ATR, TP 2,5 ATR, rischio 1%) su 1D/4H/1H con controllo a metà
  campione e Deflated Sharpe. Da lanciare con dispatch manuale; la modalità crypto entra in app
  solo se i numeri reggono e solo dopo decisione del proprietario.

### Corretto (strumenti e CI, 13/11/2026)
- **`tools/backtest_crypto.py`: due bug trovati nelle prime esecuzioni (run 43355963065 e 43356782169).** (1) yfinance a ticker singolo restituisce colonne MultiIndex: `df["Close"]` restava un DataFrame e `.iat[i]` con un solo indice esplodeva ("DataFrame._get_value() missing 'col'"). Ora `load_ohlc` appiattisce le colonne in Serie vere. (2) Per le barre 1h con `start=None` yfinance usa il suo default `period="1mo"`: la "finestra 730 giorni" era un mese (benchmark 1H a −94,5% annuo e zero trade su 4H). Ora la 1h si scarica con `period="730d"` e l'output stampa la finestra reale. Inoltre due fix di onestà: il fill dello stop usa `min(stop, apertura)` in caso di gap (come `daily_study_lib.simulate`; prima riempiva sempre a stop, ottimista sulle crypto che gappano spesso) e le righe equal-weight dichiarano la finestra comune nel nome (l'allineamento parte dalla nascita della moneta più giovane, prima era implicito).

### Bloccato e documentato (richiesta "CRYPTO 24/7 + Balance Advisor + prompt Kimi" del 13/11/2026)
- Non implementata: vedi proposta 18 in [docs/PROPOSTE.md](docs/PROPOSTE.md). Motivi: nessuno
  studio crypto in `tools/` (regola di progetto: ogni strategia entra solo con backtest
  documentato), frazioni e stop GTC sul broker incompatibili su Alpaca (solo ordini Day),
  iOS non esegue l'app 24/7 in background, e la build di release/`pubblica=true` non è mia
  (dispatch vietato, token read-only). Audit di sicurezza rifatto: 0 `try!`/`fatalError` in
  `Sources/`, 0 segreti, retry 429/5xx presente in entrambe le servizi, HARD KILL globale
  verificato (copre tutte le posizioni del conto).

### Aggiunto (studio conto unico GIORNALIERA+NOTTE, 13/11/2026)
- **`tools/backtest_portfolio.py` + passo `quale=portafoglio` nel workflow backtest.** Studio (non cambia l'app) per l'idea del proprietario di una modalità PORTAFOGLIO unica al posto di giornaliera e notte separate: due budget sullo stesso conto riequilibrati a ogni ciclo (capitalCap frazionario), 8 split fissi + 2 regole dinamiche decise solo sul semestre precedente (winner-tilt e risk-parity 1/vol), controllo a metà campione 2006–2015 vs 2016–oggi, sensibilità sui costi notte e sul niente riequilibro. Risultati in `docs/STATO.md` e proposta 17 in `docs/PROPOSTE.md`: la combinazione riduce la perdita massima molto più che in proporzione (correlazione +0,04), le regole "insegui chi guadagna" sono scartate dai numeri; split consigliato 30/70 in attesa di decisione del proprietario.

### Aggiunto (prova in ombra del filtro evento 48h, 12/11/2026)
- **Il filtro evento 48h è in prova in ombra nella GIORNALIERA.** Lo studio del 12/11 mostrava che saltare gli ingressi con un evento ad alto impatto nelle notizie migliorava CAGR/perdita massima su entrambi i periodi lunghi, ma usava un proxy prezzo/volume, non la notizia vera. Ora l'app registra il flag sulle voci del registro ombra usando i titoli Benzinga reali che scarica già per il Brain (`EventFilter48h`: keyword Fed/FOMC/CPI/payroll/earnings/halt/downgrade/tariff/ecc. nei titoli delle 48h). **Non cambia nemmeno un ordine né una decisione**: aggiunge solo `eventFlag` a `ShadowEntry` (opzionale: le voci storiche restano nil ed escono solo dal confronto del filtro). Nella pagella (DETTAGLI → Pagella agenti) una nuova sezione mostra l'esito medio dei candidati CON evento contro quelli SENZA e il "valore del filtro" in punti: positivo = saltarli avrebbe protetto, negativo = avrebbe saltato occasioni buone. La decisione di renderlo reale spetta all'utente, solo dopo almeno 20 esiti e con backtest di conferma. Il filtro VIX resta invece solo un candidato: nessuna delle 3 API autorizzate fornisce il VIX, quindi è provabile solo su dati storici in `tools/`, mai in-app.

### Aggiunto (consiglio degli agenti, 12/11/2026)
- **Consiglio di specialisti locali attorno al Brain.** Nuovo `Sources/Agents/SpecialistAgents.swift`: cinque specialisti deterministici a zero crediti (Tecnica multi-timeframe 15m+1m, Quant con z-score e volatilità realizzata, Notizie Benzinga per keyword con astensione se non ci sono titoli, Fondamentali sempre sospesi perché nessuna API li fornisce, Portafoglio con esposizione, tetto e famiglie ETF sovrapposte). Ognuno produce lo stesso report standard (`AgentReport`: parere, completezza, analisi, evidenze, rischi, dati mancanti, invalidazione) e `CouncilDivergence` segnala quando convivono pareri favorevoli e avversi. Il Chief è il Kimi Brain esistente: riceve `specialist_reports` e `divergence_note` nel payload e deve motivare nel rationale un buy che va contro altri pareri; il Contrarian è il Kimi Reviewer esistente, che ora verifica i pareri invece di confermarli. Stesse due chiamate Kimi di prima, payload più ricchi. Anche `dailyDecide`/`dailyReview` ricevono il digest per candidato.
- **Memoria e pagella per agente.** Nuovo modello SwiftData `CouncilRecord` (report + divergenza + decisione, valutato dopo 30 minuti sul movimento del prezzo come gli HOLD sample) e `AgentScorecard`: hit rate per specialista sui pareri giudicati (favorvole vinto se il prezzo sale, avverso se scende; neutri e sospesi mai giudicati; hit rate visibile solo con almeno 5 giudizi). È un'euristica dichiarata, non una probabilità calibrata, e non tocca mai prompt o limiti da sola.
- **Pannello CONSIGLIO in DETTAGLI** (solo modalità veloce): ultima seduta con esito del Contrarian, divergenze in ambra, scheda per specialista con evidenze, dati mancanti e invalidazione, rationale del Chief e pagella per specialista.
- **Validazione quantitativa: `tools/backtest_robustness.py`** (workflow `backtest.yml`, `quale=robustezza`, anche in `tutti` e mensile): walk-forward 8+2 anni con parametri scelti solo in-sample e testati una volta fuori campione, Monte Carlo con 1000 percorsi bootstrap dei rendimenti (CAGR/maxDD/equity finale, probabilità di finire sotto il capitale), metriche per trade (win rate, profit factor, expectancy, R-multiplo medio aggiunto a `backtest_app.sell`, Sortino, durata). Riutilizza la `simulate` esatta dell'app, con warmup degli indicatori fuori dai fold e limitazioni dichiarate. Documento di riferimento: `docs/CONSIGLIO.md`.
- **Test del consiglio: `Tests/CouncilAgentsTests.swift`** (25 test): regole di tecnica (long/short/neutro/astensione), z-score del quant, keyword notizie con astensione, fondamentali sempre sospesi, portafoglio (già in portafoglio, tetto raggiunto, posto libero, sovrapposizione famiglia), divergenze, digest giornaliero, pagella (matematica, soglia 5 giudizi, neutrali esclusi), payload compatto per Kimi e round-trip JSON di `CouncilRecord`.

### Corretto (app, 12/11/2026)
- **Aggiornamenti in-app: Aggiorna apre il gestore GIUSTO.** L'app ora rileva com'è installata: dentro LiveContainer (classi host `LCAppInfo`/`LCSharedUtils` nel processo) apre `livecontainer://install?url=…`; installata da SideStore apre gli schemi ufficiali `sidestore://install?url=…` e `sidestore://source?url=…` (così l'aggiornamento finisce sulla copia SideStore, non "sopra" LiveContainer); senza gestori riconosciuti scarica l'IPA con Safari. Prima il pulsante apriva sempre LiveContainer anche per le copie installate con SideStore. Aggiunti `LSApplicationQueriesSchemes` (livecontainer, sidestore) all'Info.plist per `canOpenURL`. Test: 4 nuovi in `UpdateCheckerTests` (link SideStore codificato, URL di install per gestore, sorgente per gestore, rilevamento SideStore altrimenti download).


### Aggiunto (strumenti e CI, 12/11/2026)
- **Workflow `Docs PDF`** (`.github/workflows/docs.yml`): genera `docs/GUIDA.pdf` da `docs/GUIDA.md` con pandoc + weasyprint a ogni modifica della guida e su dispatch manuale; il PDF viene caricato come artifact e committato in `docs/` dal bot di GitHub.

### Corretto (strumenti e CI, 12/11/2026)
- **`daily_study_lib.atr`: ATR per simbolo.** Il true range veniva calcolato con `pd.concat(..., axis=1).max(axis=1)`, che schiacciava i 15 ETF su una sola colonna (Series): `a.iloc[t, j]` esplodeva con `IndexingError: Too many indexers` e tutti gli studi `quale=studi` fallivano. Ora stack + `groupby(level=0).max()`, come `backtest_app.py`.
- **`daily_study_lib.simulate`: mai sovrascrivere una posizione esistente.** Il segnale RSI2<10 dura spesso più giorni mentre la posizione è detenuta: senza il controllo `j in pos` l'ingresso nuovo rimpiazzava quello vecchio nel registro e le azioni già comprate sparivano dai libri (cash scalato all'ingresso, mai riaccreditato). Effetto: conto polverizzato (maxDD −100%), 93 trade totali e zero operazioni dopo il 2016, riprodotto identico a ogni run. Con il controllo i numeri tornano coerenti con `backtest_app.py` (1586 trade, BASE +0,1% annuo 2006–oggi).

### Corretto (revisione esterna sulla 1.5.0 build 157)
- **NOTTE: la vendita OPG si conferma dallo STATO dell'ordine, non dal calo del detenuto.** Il registro salva ora il `client_order_id` dell'OPG (`sellQueuedOrderId`): a ogni ciclo si rilegge lo stato sul broker — `filled` toglie la voce, `canceled`/`rejected`/`expired` resta come residuo (poi chiusa come leftover), vivo resta in coda. Prima con la giornaliera sullo stesso simbolo il detenuto poteva risalire e la conferma sul calo era inaffidabile: il pomeriggio poteva vendere le azioni sbagliate. Test: `testOPGFilledByOrderStatusClearsBookEvenWhenHeldDidNotDrop`, `testOPGCanceledByOrderStatusStaysAsResidual`, `testExecutedOPGWithSharedSymbolClearsTheBook` (aggiornato allo stato).
- **NOTTE: acquisti MOC parziali.** Se alcune MOC vengono rifiutate si ritenta SOLO le famiglie mancanti, con il gemello economico (es. QQQ rifiutato → QQQM). E a livello di famiglia: con un residuo su SPYM non si compra SPY (stesso indice, stesso rischio raddoppiato). Test: `testPartialMOCRetriesOnlyMissingFamiliesWithTwin`, `testResidualOnTwinBlocksOriginalOfSameFamily`.
- **VELOCE: i simboli del registro NOTTE sono esclusi dal flat-by-close** (come quelli della giornaliera: restano intatte con la loro vendita OPG in coda).
- **NOTTE, finestre (regressione del calendario):** nel fine settimana a mercato chiuso la vendita OPG va messa in coda se l'ora è fuori da 9:28–19:00 ET, anche sabato e domenica (per lunedì); i festivi infrasettimanali restano "nessuna asta"; a mercato chiuso l'attesa copre ora TUTTA 9:28–19:00 ET, quindi dopo una chiusura anticipata (13:00 ET) non si invia più un'OPG che Alpaca rifiuterebbe. Test: `testPhaseWeekendQueuesOPGOutsideAuctionWindow`, `testWeekendEveningQueuesOPGForMonday`, `testPhaseWeekdayHolidayStillWaits`, `testPhaseEarlyCloseAfternoonWaits`.
- **Studi rotti (`quale=studi`):** `backtest_trailing_stop.py`, `backtest_event_filter.py`, `backtest_vix_filter.py` e `backtest_overnight_riskparity.py` leggono ora i dati con un helper robusto alle colonne MultiIndex di yfinance (`daily_study_lib.flat_by_field`/`load_series`, stesso criterio di `backtest_app.py`); il workflow `backtest.yml` ora usa `bash -e -o pipefail`, quindi se uno script va in errore il passo FALLISCE invece di pubblicare tabelle vuote.

### Corretto (revisione esterna sulla build 161 · flat-by-close della VELOCE)
- **VELOCE: il flat-by-close a T-10 annulla TUTTI gli ordini aperti del simbolo** (gambe del bracket stop/take-profit e l'eventuale stop d'emergenza), **verifica l'annullo rileggendo gli ordini aperti**, poi **chiude a mercato**; se la chiusura fallisce **rimette subito lo stop d'emergenza GTC** con `client_order_id` `qsv-emg-SIMBOLO-GIORNO` (riconosciuto dal prefisso, non dal tipo d'ordine) e **mai due stop d'emergenza insieme**: a fine tentativo la posizione o è chiusa o ha un solo stop. Motivazione, doc Alpaca verificata 12/11/2026: `DELETE /v2/positions/{symbol}` crea solo l'ordine di chiusura e non annulla gli ordini aperti, e con ordini di vendita aperti le azioni restano riservate (chiusura rifiutata "insufficient qty") — https://docs.alpaca.markets/us/reference/deleteopenposition-1 e https://alpaca.markets/learn/how-to-fix-common-trading-api-errors-at-alpaca. Test: `FlatByCloseTests` (5 test: bracket a T-10 → chiusa; chiusura fallita → stop `qsv-emg-…` presente; secondo tentativo riuscito → nessun ordine residuo; mai due stop d'emergenza; annullo fallito → log di residuo e chiusura tentata comunque).

### Cambiato (dagli screenshot della build 157)
- MERCATI: tile tutte della stessa altezza e etichette di stato sempre su una riga, in sentence case ("In posizione", "Trend su", "Fuori capitale" — niente più maiuscole a ogni parola né testo a capo).
- CRUSCOTTO: CONTROLLA ORA è il pulsante primario, STOP è arancione (colore d'avviso) e ben distinto.
- BROKER: gli ordini aperti mostrano lo stato in italiano ("in attesa", "in parte eseguito"…) e tipo+prezzo ("stop 47,85", "limite 51,40") al posto di "held · n/d".
- GRAFICO: il pulsante è "Traduci" (non più tutto maiuscolo).
- SISTEMA: sotto il selettore di modalità resta una sola riga; la descrizione della modalità va dietro il pulsante info.

## [1.5.0 · build 156] - 2026-11-12

### Corretto
- Grafico: su 1H, 15M e 5M il prezzo non sparisce più; in alto restano ultimo prezzo dell'intervallo e variazione sulla candela precedente.
- Grafico: il prezzo in alto resta visibile anche mentre le candele si stanno caricando o non arrivano: su 1H/15M/5M/LIVE si usa l'ultimo prezzo noto del simbolo (stream o barre giornaliere) come ripiego. Test UI `testChartPriceVisibleOnEveryInterval`.
- **Controllo finale del codice** (`c4e3876`, tabella completa in [docs/CONTROLLO-FINALE.md](docs/CONTROLLO-FINALE.md)): nessun `try!`/`fatalError`/`preconditionFailure` in `Sources/` (il fallback SwiftData usa ora `try?` a catena con container opzionale e store in memoria), rimosse le force-unwrap su subscript (`DailyCycle`, `NightCycle`, `MarketsView`, `buyableRow`). Restano solo `URL(string:)!` su costanti letterali. Nessuna chiave o segreto nel codice o nei log (verificato con grep).

### Aggiunto
- **Etichetta "NOTIZIE 48H" nel CRUSCOTTO** sulle posizioni aperte: mostra quante notizie delle ultime 48 ore ci sono sul simbolo (stessa API già usata per Brain/Reviewer e il grafico). Solo interfaccia: nessun effetto sugli ordini. Test UI `testNewsBadgeOnOpenPosition`.
- **NOTTE: misura executed-vs-asta nel report.** Dopo ogni acquisto MOC e vendita OPG il ciclo registra nel report la differenza fra prezzo eseguito (`filled_avg_price`) e prezzo reale dell'asta (`GET /v2/stocks/{symbol}/auctions`, feed sip). Solo misura, mai obbligatoria: se l'API non risponde non si registra nulla e nessun ordine cambia. Nuovo studio `tools/backtest_overnight_auctions.py` (runner `overnight`, chiavi Alpaca via env — senza chiavi stampa solo una nota). Test in `Tests/NightCycleTests.swift`.
- **Calendario di borsa Alpaca (`GET /v2/calendar`)** per le finestre della NOTTE e i promemoria: la chiusura esatta del giorno (anche nelle mezze giornate) decide il cutoff della MOC, e nei festivi non si mettono ordini d'asta. I promemoria si programmano solo sui giorni di borsa del calendario. Mai obbligatorio: se il calendario non risponde l'app si comporta come prima (solo `clock`, promemoria settimanali lun–ven). Test in `Tests/NightCycleTests.swift`.
- **Test HTTP di AlpacaService** (`Tests/AlpacaServiceTests.swift`, 12 test con URLProtocol mock e sessione iniettabile): per ogni funzione che invia/annulla/chiude ordini (`submitEntryWithStop`, `submitBracket`, `submitAuction`, `submitMarket`, `submitStop`, `cancelOrder`, `closePosition`) caso normale più caso di errore: ordine rifiutato (422), ordine non trovato (404), risposta parziale (DELETE posizione con corpo non decodabile non sembra fallita), rete assente (risposta non HTTP e URLError con retry), decode JSON fallita.
- **Test parametrici sui conti da 500 a 1.000.000 USD**: sizing e tetto del capitale del bot (`RiskRulesTests.testSizingParametricAccountSizes`, `testCappedCapitalParametricAccountSizes`) e divisione della NOTTE (`NightCycleTests.testAllocateParametricBudgets`): mai oltre il budget, mai tetto 25% o rischio per trade superati, mai quantità zero o negative. Totale: **153 test unitari + 5 di interfaccia**.
- **Guida d'uso** [docs/GUIDA.md](docs/GUIDA.md): 9 capitoli in italiano semplice (cosa è e cosa non è, installazione, schermate, le 3 modalità con i numeri veri degli studi e "i risultati passati non garantiscono quelli futuri", capitale, protezioni, conti multipli e checklist prima del live, problemi frequenti, rischi e limiti). Nessun guadagno promesso. Immagini in `docs/screenshots/`; `docs/GUIDA.pdf` da generare da GUIDA.md (nel sandbox di revisione manca il generatore PDF: lo genera l'altro revisore).
- **Proposte 11–16** in [docs/PROPOSTE.md](docs/PROPOSTE.md) (idee esterne valutate 12/11/2026): calendario macro da fonti .gov ufficiali, sentiment notizie per il Reviewer, ML tabellare pre-Kimi, regime detection HMM, fractional shares Alpaca (`notional`, con il vincolo documentato: solo ordini Day, niente stop GTC frazionario, esclusa la NOTTE), filtro di correlazione. Tutte SOLO proposte con link e limiti dichiarati: nessuna è nel codice.

### Cambiato
- **Design 1.5.0 completo** (una schermata per commit, vedi [docs/DESIGN.md](docs/DESIGN.md)): nuovo sistema visivo — un solo accento (verde; rosso solo P&L/stati, arancione solo avvisi, cyan rimosso), SF Pro con cifre tabellari per i numeri (monospaziato solo nel registro eventi), griglia 8 pt, card a superficie piena senza bordi colorati e senza riquadri dentro i riquadri, niente titoli in maiuscolo, componenti unici in `Theme.swift` (`AppCard`, `ValueRow`, `StatusChip`, `SectionHeader`, `InfoButton`, pulsanti primario/secondario). Schermate rifatte: Theme e componenti, CRUSCOTTO (compatto: stato, azione principale, numeri di oggi, posizioni; catena agenti e registro a richiesta), MERCATI e GRAFICO, DETTAGLI, BROKER, SISTEMA (ora a sezioni: Conto, Strategia, Kimi, App, Stato), LOGIN. Un numero protagonista per schermata, testi d'aiuto dietro info e nascosti in MODALITÀ PRO, aree toccabili ≥ 44 pt. Identificatori usati dai test UI invariati. Commit: `6d81fc3`, `cecf367`, `0ac0e50`, `2ff870f`, `1516b1c`, `a186539`, `c9a0d69`.

## [1.4.0 · build 137] - 2026-11-12

### Corretto
- **NOTTE: registro vecchio (senza quantità) resta a una sola vendita.** Nella riconciliazione R7 la voce legacy restava in coda: se la giornaliera aveva lo stesso simbolo il detenuto non tornava a zero e ogni sera veniva ri-messa in coda la vendita di TUTTO il detenuto. Ora la voce senza quantità esce subito dopo l'invio dell'OPG, come prima di R7. Test.
- **NOTTE: una vendita all'apertura (OPG) non eseguita non lascia più azioni orfane.** Dopo l'invio dell'OPG la posizione resta nel registro marcata "in coda" (quantità e detenuto al momento dell'invio) e viene cancellata solo quando il detenuto sul conto è sceso di almeno quella quantità. Se l'OPG viene annullata all'asta, il giorno dopo il ciclo la chiude a mercato (solo la quantità della notte) prima di ricomprare, e non compra sopra il residuo. Prima la posizione veniva cancellata subito dopo l'invio: in caso di OPG annullata le azioni restavano sul conto senza stop e la notte poteva comprarne altre sopra. Il registro delle versioni precedenti resta leggibile.
- **NOTTE: vende solo le sue azioni, mai quelle della giornaliera.** Il registro notte salva anche la quantità acquistata; l'OPG all'apertura e la chiusura "leftover" vendono esattamente quella. Prima, se la giornaliera aveva lo stesso simbolo (SPY, QQQ, IWM, GLD sono in entrambi i panieri), l'ordine d'asta vendeva TUTTE le azioni del conto e lo stop GTC residuo della giornaliera poteva aprire uno short. Il vecchio registro (senza quantità) si rilegge: vende tutto il detenuto finché non passa una notte.
- **Mai ripresa automatica su conto LIVE**: il motore riparte da solo solo su paper. Con soldi veri la sessione parte dal bottone, con la conferma.
- **VELOCE: flat-by-close fallito = stop GTC di emergenza.** Se la chiusura a T-10 minuti fallisce e non si ripara entro la seduta, la posizione restava overnight senza protezione (le gambe del bracket "day" scadono alla chiusura). Ora si rimette subito uno stop GTC sul broker (chiusura − 2,5 ATR) e, se anche quello fallisce, arriva la notifica POSIZIONE SENZA STOP.
- **Un ordine rifiutato non è più un invio riuscito.** Il recupero per client_order_id controlla lo stato dell'ordine (notte, giornaliera e veloce): rejected/canceled/expired non producono vendite o ingressi finti e non bloccano il retry.
- Il prefilter della modalità veloce usa il contante libero vero (capitale meno esposizione già aperta): meno chiamate Kimi spese per candidati che il sizing avrebbe bocciato.
- L'esito di un'uscita si registra anche con più di 50 posizioni aperte (prima solo gli ultimi 50 record non risolti).
- Le formule dello stop giornaliero e dello stop drawdown sono estratte in `RiskRules` e testate; il limite noto (un prelievo appare come perdita) è documentato in `docs/STATO.md`.
- Rimosso `riskRewardRatio`, calcolato ma mai usato.

### Aggiunto
- Studio `tools/backtest_overnight_fraction.py` (runner `overnight`): CAGR e perdita massima sul conto se la NOTTE investisse solo una frazione del capitale. La frazione resta 97% finché i numeri non dicano altro.

## [1.3.0 · build 130] - 2026-11-11

### Aggiunto
- **MODALITÀ NOTTE**: compra in chiusura (asta MOC) S&P 500, Nasdaq-100, Russell 2000 e oro a peso uguale e vende all'apertura del giorno dopo (asta OPG). Per ogni indice l'ETF originale o il gemello economico (SPYM, QQQM, VTWO, GLDM) secondo il saldo. Zero crediti Kimi. Due promemoria: 14:45 per la vendita, 21:15 per l'acquisto (ora italiana). Le posizioni della giornaliera non vengono mai toccate. Studio 2006–oggi: circa +8% l'anno, cali fino al −22%.
- **TRADUCI** nelle notizie del grafico: usa la traduzione di Apple direttamente sul telefono, gratis e senza crediti Kimi, con iOS 17.4 o successivo.
- **NASCONDI SALDO**: con l'occhio accanto al patrimonio, oppure in Sistema, saldo, P&L, capitale e importi delle posizioni diventano •••••. Le percentuali e i prezzi degli ETF restano visibili. L'impostazione resta salvata.
- **Notizie agli agenti**: quando c'è un segnale, Brain e Reviewer ricevono i titoli delle notizie Benzinga delle ultime 48 ore sull'ETF e sul mercato (SPY e QQQ), presi dalla News API di Alpaca con le stesse chiavi, senza costi. Servono a non comprare dentro un evento che cambia il quadro (Fed, inflazione, crollo di un settore), non a inseguire le notizie. Il Reviewer boccia se una notizia spiega il calo con un cambiamento vero.
- Nel grafico di ogni ETF c'è la sezione **NOTIZIE · 48 ORE**, con le stesse notizie che riceve Kimi.

### Corretto
- Niente più falso allarme HEARTBEAT al rientro dal background: il tempo con l'app chiusa non conta.
- Una sola riconciliazione col broker anche se iOS segnala il rientro due volte.
- "Strategia: nessun segnale oggi" scritto una volta al giorno, non a ogni riapertura.
- Catena agenti: "0 crediti" compariva anche su Rischio ed Esecutore, che sono codice e non usano mai Kimi. Ora compare solo su Analyst, Brain e Reviewer.

### Aggiunto
- Controllo mensile automatico delle strategie (GitHub Actions, il 1° del mese): giornaliera con le regole dell'app, conto piccolo e overnight rifatti sui dati aggiornati, per accorgersi se un effetto si sta spegnendo.

## [1.3.0] - 2026-11-11

### Aggiunto
- **Barra delle sezioni in basso** con icone (Cruscotto, Mercati, Dettagli, Broker, Sistema), alla portata del pollice. MERCATI diventa una sezione sua, con la legenda degli stati.
- **Intestazione nuova**: patrimonio in grande, risultato del giorno in dollari e in percentuale, PAPER/LIVE e mercato aperto/chiuso come etichette, stato del motore in una riga.
- **Conto alla rovescia** del prossimo controllo, con barra di avanzamento.
- **Più conti Alpaca** (SISTEMA → CONTI ALPACA): con la stessa chiave Kimi salvi più conti paper o live e passi dall'uno all'altro a motore fermo. Le chiavi vengono provate sul broker prima di salvarle. Ogni conto ha registro del bot, curva del capitale e protezioni separati; passare a un conto live chiede conferma.
- **Capitale scritto in chiaro**: in SISTEMA c'è il numero "CAPITALE USATO DAL BOT" e la scritta "tutto il conto" oppure "solo una parte". L'interruttore si chiama ora "Usa solo una parte del conto".
- **MODALITÀ PRO** (SISTEMA, spenta di base): per chi conosce già l'app toglie spiegazioni, legende e testi d'aiuto. Restano numeri, stati, avvisi e pulsanti.
- Vibrazione leggera al cambio di sezione e all'avvio o arresto del motore.
- **Agenti**: Brain e Reviewer ricevono la **correlazione a 60 sedute** di ogni candidato con le posizioni aperte e con gli altri candidati. Prima il prompt chiedeva di evitare ETF quasi uguali senza dare i numeri. Il Reviewer boccia sopra 0,85 con una posizione già aperta.
- **Agenti**: ragionamento "medio" per Brain e Reviewer della giornaliera, che fanno poche chiamate al giorno ma importanti; resta "basso" per la modalità veloce.

### Studiato (tools/)
- **Conto piccolo** (`backtest_small.py`): azioni intere ai prezzi di oggi. Con 1.000 $ la giornaliera rende circa +1,8% l'anno, contro +2,2% con 100.000 $, con perdita massima −6%/−7%. Gli ETF "gemelli" economici (QQQM, VTWO, GLDM, SPYM) fanno saltare meno segnali, ma in due esecuzioni il rendimento è cambiato di segno rispetto al paniere attuale: differenza dentro il rumore, quindi il paniere resta com'è.
- **Regole giornaliere a confronto** (`backtest_signals.py`), con le stesse uscite dell'app: RSI2 sotto 10 (quella in uso), IBS, minimo a 7 giorni, 3 cali di fila, la loro unione e "almeno due insieme". RSI2 resta la migliore: Sharpe 0,43 dal 2006 e +7,4% l'anno negli ultimi 3 anni. Aggiungere regole dà più segnali ma peggiora il risultato (l'unione scende a Sharpe 0,26), quindi la regola non cambia.
- **Intraday momentum** (`backtest_momentum.py`): verifica sui dati recenti dello studio Gao, Han, Li e Zhou (JFE 2018) per la modalità veloce.

### Corretto
- Se il modello Kimi rifiuta il ragionamento "medio" (errore 400), la chiamata viene ripetuta una volta al livello base invece di perdere la decisione.

### Cambiato
- Testi descrittivi in carattere di sistema, più leggibile; numeri ed etichette restano in stile terminale.

## [1.2.0] - 2026-11-11

### Aggiunto
- **Aggiornamenti dall'app**: all'avvio l'app controlla se c'è una versione nuova. Se c'è, nel CRUSCOTTO compare un avviso e in SISTEMA il pulsante **AGGIORNA**, che apre LiveContainer e installa la nuova IPA sopra l'app; dati, chiavi e impostazioni restano. Con **AGGIUNGI SORGENTE A LIVECONTAINER** le versioni nuove compaiono anche nella scheda Sources di LiveContainer.
- Su richiesta (Run workflow con "pubblica"), la CI pubblica la build sul repository pubblico `quantswarm-releases`: solo IPA, icona e sorgente `apps.json`, il codice resta privato. Serve il segreto `RELEASES_TOKEN`.

### Cambiato
- IPA e screenshot della CI vanno sui branch `bozza-ipa` e `screenshot` (un commit sovrascritto ogni volta): da novembre il token delle Actions non può più creare release nel repository.
- Le release non partono più da sole: di default l'IPA va in una bozza privata e viene consegnata a mano. `ultima`, `vX.Y.Z` e gli aggiornamenti dall'app partono solo con "pubblica".
- CI più veloce: a ogni modifica girano solo i test sulla logica, che bloccano l'IPA se falliscono. I test dell'interfaccia e gli screenshot partono su richiesta, prima delle release.

- **Grafici a più intervalli** (1G, 1H, 15M, 5M, e LIVE in modalità veloce), anche a mercato chiuso: le candele arrivano dallo storico del broker (feed SIP, con IEX come riserva), senza crediti Kimi.
- **Pagella agenti** in DETTAGLI: confronta le regole da sole (tutti i segnali) con gli scelti e gli scartati da Kimi e con i bocciati dal Reviewer. Per ognuno mostra numero, rendimento medio e quota in guadagno, più il **valore di Kimi** in punti, la **tendenza** tra esiti vecchi e recenti e un giudizio che arriva solo dopo 30 esiti.
- MERCATI compare subito all'apertura con le ultime barre salvate, con l'ora dei dati; il primo controllo le aggiorna.
- DETTAGLI mostra solo ciò che serve alla modalità attiva: analisi a richiesta, dataset di training, edge e calibrazione restano nella modalità veloce. L'esportazione CSV dei trade ha un pannello suo.

### Corretto
- "ANALIZZA ORA" a mercato chiuso lasciava in alto il messaggio "Dati fermi: analisi impossibile". Ora resta solo nel registro.
- Gli ingressi mai eseguiti (limite annullato, scaduto o rifiutato) venivano richiesti al broker a ogni ciclo, per sempre. Ora vengono chiusi una volta ed esclusi da statistiche e CSV.
- Il grafico negli screenshot automatici si apre dopo il caricamento dei dati d'esempio.

## [1.1.0] - 2026-11-11

### Aggiunto
- **Icona dell'app** (candele verdi su nero).
- **MERCATI** nel CRUSCOTTO: i 15 ETF dove opera il bot, con prezzo, variazione e stato (in posizione, segnale, trend su/giù, fuori capitale). Toccando un ETF si apre il **grafico a candele** con la media a 200 e a 5 giorni e, sul grafico, ingresso, stop e target reali presi dal broker, più la spiegazione del perché compra o non compra.
- In modalità veloce, MERCATI mostra i simboli scelti con le candele del timeframe decisionale, aggiornate ogni 5 secondi.
- **Capitale del bot automatico**: di default usa tutto il saldo del conto, che segue da solo guadagni e perdite. Il limite manuale (da 500 USD) è facoltativo e serve solo se sullo stesso conto ci sono altri soldi.
- **ETF COMPRABILI** in SISTEMA: quanti dei 15 ETF il capitale può comprare con almeno 1 azione intera, sui prezzi reali.
- **Curva del capitale** in DETTAGLI: il bot confrontato con SPY compra-e-tieni, con capitale impegnato e perdita massima dal picco. È separata per ogni conto.
- **Cambio di conto riconosciuto** (per esempio un nuovo conto paper da 1.000 $): picco, stop giornaliero, drawdown e curva ripartono dal nuovo saldo.
- **Versione e build** visibili in SISTEMA; release numerata su GitHub con queste note, oltre a "ultima".
- Screenshot automatici anche di MERCATI e del grafico.

### Cambiato
- Grafica: un unico sistema visivo (colori dell'icona, schede arrotondate con bordo sottile, intestazioni più leggibili, numeri a cifre fisse).
- Rischio per trade, tetto del 25% per posizione, stop giornaliero e drawdown si calcolano sul capitale del bot.
- Kimi non viene chiamato per candidati che il capitale non può comprare (giornaliera e veloce): nessun credito sprecato su un conto piccolo.
- Modalità veloce: suggerimento sul prezzo massimo per azione in base al capitale. La regola PDT da 25.000 $ è stata abolita il 4 giugno 2026 ed è stata rimossa anche da Alpaca.
- CI: i test unitari bloccano l'IPA; i test dell'interfaccia riprovano una volta e, se falliscono, danno solo un avviso.

### Corretto
- Un nuovo conto paper con meno soldi faceva scattare subito lo stop drawdown, perché lo confrontava col picco del conto vecchio.
- Il registro scriveva tutte le impostazioni a ogni modifica: ora scrive solo quelle cambiate.

## [1.0.0] - 2026-11-11

### Aggiunto
- **Registro ombra di Kimi**: esiti ipotetici dei candidati scelti contro quelli scartati, per misurare se Kimi aggiunge valore.
- Take-profit sul broker a +2 ATR (bracket GTC); fino a 5 posizioni; statistiche degli ordini eseguiti, parziali e mai eseguiti.
- Promemoria giornaliero (lun–ven 15:30 New York), diagnostica MetricKit, esportazione CSV dei trade.
- A Kimi arrivano le chiusure recenti e gli esiti passati come feedback.
- Backtest con le regole esatte dell'app (2006–oggi): +2,3% l'anno, perdita massima −9%, meglio del caso; tutte le varianti vicine dei parametri sono in guadagno.

## [0.3.0] - 2026-11-10

### Aggiunto
- **Modalità giornaliera Trend+Pullback** sui 15 ETF: compra sopra la media a 200 giorni con RSI2 < 10, stop 2,5 ATR GTC sul broker, uscita sopra la media a 5 giorni o dopo 10 sedute.
- Catena agenti con stato (Scout → Strategia → Analyst → Brain → Reviewer → Rischio → Esecutore).
- Cruscotto unico con CONTROLLA ORA e controllo a ogni riapertura.

### Corretto
- Mai posizioni senza stop: lo stop viene ripristinato dopo un'uscita fallita, controllato a ogni ciclo e gestito anche sui parziali.
- Lettura degli ordini con `nested=true`: prima gli esiti di stop e target non venivano registrati.

## [0.2.0] - 2026-11-10

### Aggiunto
- Regole di rischio pure e testate: niente short, stop e target al tick, rischio sul prezzo reale, tetto del 25%.
- Timeframe decisionale (1/5/15 min), filtro gratuito prima di Kimi, Kimi Reviewer avversario, limite crediti sul saldo reale.
- Stop giornaliero e drawdown persistenti, app solo in primo piano con pausa per rete o batteria.
- Strumenti di backtest (filtro 15 min, giornaliera ETF, strategie 5 min).

### Corretto
- Decodifica dei trade dallo stream Alpaca; build CI su runner Intel con Xcode 26.

## [0.1.0] - 2026-11-09

### Aggiunto
- Prima versione: motore con agenti (Scout, Kimi, Rischio), Alpaca paper/live, credenziali nel Keychain con Face ID, cruscotto, report di sessione, HARD KILL, widget.
