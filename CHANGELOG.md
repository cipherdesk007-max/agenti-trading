# Changelog · FMLAB QuantSwarm Alpha Zero

Tutte le modifiche importanti dell'app, dalla più recente.
Formato: [Keep a Changelog](https://keepachangelog.com/it/1.1.0/), versioni [SemVer](https://semver.org/lang/it/).
La versione installata si legge in **SISTEMA → VERSIONE** (con il numero di build della CI).
Le versioni precedenti alla 1.1.0 sono ricostruite dalla storia dei commit.

## [Non rilasciato]

### Corretto
- Grafico: su 1H, 15M e 5M il prezzo non sparisce più; in alto restano ultimo prezzo dell'intervallo e variazione sulla candela precedente.
- Grafico: il prezzo in alto resta visibile anche mentre le candele si stanno caricando o non arrivano: su 1H/15M/5M/LIVE si usa l'ultimo prezzo noto del simbolo (stream o barre giornaliere) come ripiego. Test UI `testChartPriceVisibleOnEveryInterval`.

### Aggiunto
- **Etichetta "NOTIZIE 48H" nel CRUSCOTTO** sulle posizioni aperte: mostra quante notizie delle ultime 48 ore ci sono sul simbolo (stessa API già usata per Brain/Reviewer e il grafico). Solo interfaccia: nessun effetto sugli ordini. Test UI `testNewsBadgeOnOpenPosition`.
- **NOTTE: misura executed-vs-asta nel report.** Dopo ogni acquisto MOC e vendita OPG il ciclo registra nel report la differenza fra prezzo eseguito (`filled_avg_price`) e prezzo reale dell'asta (`GET /v2/stocks/{symbol}/auctions`, feed sip). Solo misura, mai obbligatoria: se l'API non risponde non si registra nulla e nessun ordine cambia. Nuovo studio `tools/backtest_overnight_auctions.py` (runner `overnight`, chiavi Alpaca via env — senza chiavi stampa solo una nota). Test in `Tests/NightCycleTests.swift`.
- **Calendario di borsa Alpaca (`GET /v2/calendar`)** per le finestre della NOTTE e i promemoria: la chiusura esatta del giorno (anche nelle mezze jornadas) decide il cutoff della MOC, e nei festivi non si mettono ordini d'asta. I promemoria si programmano solo sui giorni di borsa del calendario. Mai obbligatorio: se il calendario non risponde l'app si comporta come prima (solo `clock`, promemoria settimanali lun–ven). Test in `Tests/NightCycleTests.swift`.

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
