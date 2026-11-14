# Changelog · FMLAB QuantSwarm Alpha Zero

Tutte le modifiche importanti dell'app, dalla più recente.
Formato: [Keep a Changelog](https://keepachangelog.com/it/1.1.0/), versioni [SemVer](https://semver.org/lang/it/).
La versione installata si legge in **SISTEMA → VERSIONE** (con il numero di build della CI).
Le versioni precedenti alla 1.1.0 sono ricostruite dalla storia dei commit.

## [1.6.9] - 14/11/2026

Nessuna funzione nuova: revisione riga per riga dei percorsi che toccano soldi (crypto, HARD KILL, promemoria) e correzione dei difetti trovati, ognuno con il suo test. Nessuna chiamata Kimi.

### Corretto (CRYPTO: la modalità non poteva funzionare su un conto vero)

- **La posizione appena comprata spariva dal registro dopo 60 secondi.** Alpaca scrive la stessa coppia in due modi: `BTC/USD` negli ordini e nei dati, `BTCUSD` (senza barra) nell'elenco delle posizioni. L'app le confrontava così come sono, quindi a ogni controllo la posizione risultava "non più sul broker": veniva tolta dal registro e il suo stop annullato. Risultato: posizione vera sul conto, senza stop e che l'app non seguiva più. Ora il confronto passa da `CryptoSymbol` (stessa chiave per le due scritture). Con i broker finti dei test il difetto non si vedeva: il finto usava la stessa scrittura dappertutto.
- **Lo stop dopo l'acquisto veniva chiesto troppo presto e della misura sbagliata.** L'ordine a mercato su Alpaca nasce "in attesa" e si esegue un attimo dopo, e la commissione crypto si paga nella moneta comprata (sul conto arriva un po' meno dell'eseguito). L'app metteva lo stop subito e per la quantità ordinata: il broker lo rifiutava. Ora aspetta l'esecuzione (fino a 5 letture dello stato), rilegge la quantità che il conto ha davvero e copre quella; se l'ordine non si esegue, il residuo viene annullato e non resta niente in sospeso.
- **Nessun doppio acquisto e nessuna doppia vendita se la rete cade a metà.** Ogni ordine ha già un identificativo fisso (`client_order_id`); ora, quando un invio fallisce, l'app cerca quell'identificativo sul broker prima di concludere che l'ordine non c'è. Se c'è lo adotta (anche dopo che l'app è stata chiusa a metà dell'operazione); se non si riesce a sapere, non scrive niente nel registro e ricontrolla al tick successivo. Un no esplicito del broker (saldo, conto sospeso) non viene ritentato sulla stessa barra.
- **L'uscita fallita non veniva ritentata fino al giorno dopo**, anche se il log diceva "si riprova al prossimo tick": la barra restava segnata come già valutata. Ora torna da valutare e si riprova dopo 60 secondi. Inoltre una vendita accettata dal broker ma con lo stato non leggibile veniva trattata come fallita: ora conta come inviata.
- **Annullo dello stop confermato prima di vendere o di sostituirlo.** Su Alpaca l'annullo è asincrono: finché lo stop è "in annullamento" la quantità resta impegnata e la vendita (o il nuovo stop) viene rifiutata. Ora l'app aspetta la conferma; se non arriva, lascia lo stop dov'è e riprova al tick dopo.
- **Stop "mancante" che in realtà c'era.** Prima di rimettere uno stop l'app guarda gli stop vivi sul broker: se ce n'è uno della misura giusta lo adotta; se è della misura sbagliata lo toglie e ne mette uno giusto. Prima ne chiedeva un secondo, rifiutato a ogni ciclo.
- **Quantità degli ordini crypto con 9 decimali** (il massimo che Alpaca accetta) invece di 8: una posizione al netto della commissione ha 9 decimali, e con 8 l'arrotondamento poteva chiedere di vendere o coprire un soffio più di quanto c'è sul conto (ordine rifiutato).
- **Avviso "senza stop" una volta al giorno per coppia**, non ogni 60 secondi (il tentativo di ripristino continua a ogni ciclo).
- **Acquisto calcolato sul prezzo di adesso**, non sulla chiusura di ieri (l'app può essere aperta ore dopo la barra). Se il prezzo live è già sotto lo stop della barra di rottura l'ingresso salta; se il prezzo live manca non si compra e si riprova. Due ingressi nello stesso controllo non possono più spendere due volte lo stesso contante, e sul contante si tiene un margine del 2% (senza, l'ultima posizione veniva rifiutata per saldo insufficiente).
- **Chandelier salito ma prezzo già sotto il nuovo livello**: lo stop vecchio non viene più annullato per metterne uno che il broker rifiuterebbe.
- **Segnale d'ingresso bloccato da un motivo passeggero** (app in background, blocco drawdown): non viene più perso, si rivaluta quando il blocco cade.
- **ATR uguale a quello dello studio.** L'app usava la media semplice delle ultime 22 barre, lo studio (`tools/backtest_trend_crypto.py`) l'ATR di Wilder. La distanza dello stop era quindi diversa da quella provata nel backtest. Ora la formula è la stessa. Non è un cambio di strategia: è l'app che torna a fare ciò che lo studio ha misurato.

### Corretto (GIORNALIERA: uscita rifiutata e rimandata di un ciclo)

- **L'uscita chiudeva la posizione un istante dopo aver annullato stop e target.** Su Alpaca l'annullo è asincrono e la chiusura non annulla gli ordini aperti: finché lo stop è "in annullamento" le azioni restano impegnate e la vendita viene rifiutata per quantità non disponibile. In quel caso l'app rimetteva lo stop (posizione sempre protetta) ma l'uscita slittava al ciclo successivo, 15 minuti dopo, o al giorno dopo se nel frattempo il mercato chiudeva. Ora, dopo l'annullo, aspetta che gli ordini spariscano dagli aperti (al massimo 2 secondi) e poi chiude. Stessa attesa quando toglie un target rimasto senza il suo stop prima di rimettere lo stop.

### Verificato sul conto PAPER (14/11/2026, run 43557460572) e corretto di conseguenza

- **Prova sul broker vero, con circa 12 dollari finti di BTC comprati e rivenduti: 12 ipotesi su 12 confermate.** La posizione è scritta `BTCUSD` (ordini `BTC/USD`); l'acquisto nasce "pending_new" e si esegue in 0,15 s; la commissione si paga in moneta (0,25%: eseguito 0,000179890, in portafoglio 0,00017944); l'ordine si ritrova per `client_order_id` e un doppione viene rifiutato; lo stop `stop_limit` GTC è accettato con quantità a 9 decimali e prezzi a 2; un secondo stop viene rifiutato; la vendita dopo l'annullo passa; nessun residuo. Con il codice della 1.6.8 le prime tre cose avrebbero fatto perdere la posizione dal registro e rifiutare lo stop.
- **"TRADING SOSPESO" compariva anche per un saldo insufficiente.** La prova ha mostrato che Alpaca usa lo stesso codice 40310000 per ogni rifiuto 403. L'app guardava il codice: un ordine rifiutato per saldo faceva comparire l'avviso "il broker rifiuta TUTTI i nuovi ordini" e il pulsante RIATTIVA TRADING. Ora conta solo il messaggio di Alpaca ("new orders are rejected by user request").

### Corretto (HARD KILL e promemoria)

- **HARD KILL diceva "completato" senza controllare.** Alpaca risponde "ok" alla richiesta di chiudere tutto anche se una singola chiusura non parte, e a mercato chiuso le azioni restano in portafoglio con la vendita in coda. Ora, dopo la richiesta, l'app rilegge posizioni e ordini (fino a 4 volte) e dice che cosa c'è davvero: conto piatto, chiusure in coda fino all'apertura, oppure HARD KILL INCOMPLETO con l'elenco dei simboli ancora aperti (in quel caso i registri non vengono azzerati). La richiesta di chiusura usa `cancel_orders=true`, così gli ordini vengono annullati da Alpaca prima della liquidazione.
- **In PORTAFOGLIO non partiva nessun promemoria.** L'interruttore accendeva i promemoria solo per le vecchie modalità GIORNALIERA e NOTTE, che l'app trasforma in PORTAFOGLIO: di fatto mai. Ora PORTAFOGLIO riceve i due della notte (8:45 di New York per la vendita, 45 minuti prima della chiusura per l'acquisto e il controllo giornaliero).
- **Sedute corte** (chiusura alle 13:00 di New York, per esempio venerdì 27/11/2026): il promemoria d'acquisto segue la chiusura vera di quel giorno. Prima sarebbe arrivato a mercato già chiuso.

### Aggiunto (verifica, nessuna funzione nuova)

- **Test di parità studio ↔ app per la CRYPTO** (proposta 24). Lo studio è in Python, l'app in Swift: due codici che devono applicare la stessa regola. `tools/genera_parita_crypto.py` fa girare il codice dello studio (non una copia) su una serie fissa di 720 barre e scrive che cosa decide barra per barra; `Tests/CryptoParityTests.swift` rifà le stesse barre con il codice dell'app. Devono coincidere stato (dentro o fuori), ATR22, SMA200 e Donchian20 su tutte le 520 barre con decisione (6 ingressi, 6 uscite). Con la formula dell'ATR usata fino alla 1.6.8 il test sarebbe fallito: stato diverso dallo studio in 13 barre su 520 e ATR fino al 20% diverso.
- **Test di parità anche per la GIORNALIERA.** `tools/genera_parita_giornaliera.py` fa girare la funzione `indicators` dello studio (`tools/backtest_app.py`) su 560 barre fisse; `Tests/DailyParityTests.swift` verifica che l'app calcoli le stesse SMA200, SMA5, RSI2 e ATR14 e riconosca gli stessi segnali (chiusura sopra la SMA200 con RSI2 sotto 10; uscita sopra la SMA5) su 356 barre su 356, con 20 segnali d'ingresso. Qui non c'era nessuna differenza da correggere. Per la NOTTE non c'è un segnale da confrontare (compra sempre i 4 indici a peso uguale): la ripartizione in azioni intere è coperta dai suoi test.
- **Pulsante "CONTROLLA ORA" su una riga** (andava a capo accanto a STOP) ed etichette dei pulsanti centrate quando sono su due righe.
- **Test dell'interfaccia**: se il simulatore non fa partire il runner, il flusso aspetta e riprova una volta (nel run 43552818891 nessun test era cominciato).

### Completato (funzioni che c'erano già ma erano a metà)

- **MERCATI in modalità CRYPTO.** La schermata mostrava solo i 15 ETF; in CRYPTO restava ferma sulla scritta "i grafici compaiono dopo il primo controllo", che per le crypto non arrivava mai. Ora mostra le 5 coppie (BTC, ETH, SOL, AVAX, LINK) con prezzo, variazione dalla chiusura di ieri e stato della regola con le stesse parole degli ETF (in posizione, segnale, trend su = sopra la media a 200 in attesa della rottura, trend giù = sotto la media, la regola non compra). Toccando una coppia si apre il grafico a candele su 1G, 1H, 15M e 5M con la media a 200, la spiegazione della regola e, se c'è una posizione, le linee di ingresso e stop. Le candele arrivano dallo stesso servizio dati del ciclo crypto: nessuna API nuova.

### Cambiato (design, fase 1 della direzione "quadro strumenti" · docs/DESIGN.md)

- **Fondo grafite e comandi color avorio.** Il verde resta solo per ciò che significa qualcosa: guadagno, motore acceso, stato a posto. I pulsanti pieni (START, CONTROLLA ORA), la scheda scelta nella barra in basso e le azioni di sezione sono in avorio. Il verde è anche meno acceso.
- **Saldo principale come uno strumento**: più grande, stretto, color avorio.
- **Il consiglio "Saldo piccolo" in CRUSCOTTO è una riga**, non più un riquadro verde pieno che copriva stato e comandi. Toccandola si apre SISTEMA, dove c'è la spiegazione completa.
- **Percentuale del giorno con la virgola** e tra parentesi ("+3,30 $ oggi (+0,33%)"): prima virgola e punto nella stessa riga.
- **Regola unica dei colori su tutte le schermate** (fase 2): riviste una per una le 82 righe che usavano il verde. I comandi sono in avorio (pulsanti, "Usa", "Chiudi", "Traduci", "Passa a…", "Aggiungi sorgente", marchio in alto); il verde resta a stati, interruttori accesi e guadagni; i titoli dei riquadri sono bianchi. Restano da fare: lo stato del motore scritto una volta sola e la virgola nei numeri di MERCATI e DETTAGLI.

### Da sapere (non sono difetti, ma differenze dichiarate)

- CRYPTO: lo stop sul broker scatta durante la giornata; lo studio esce solo alla chiusura giornaliera. L'app è quindi più prudente dello studio e i risultati possono differire.
- CRYPTO: l'app compra quando la apri. Se la apri ore dopo la chiusura della barra, il prezzo d'ingresso non è quello dello studio.
- CRYPTO: gli ordini (acquisto, stop, annullo, vendita) sono provati sul conto paper; il ciclo completo dell'app con un segnale vero no, perché serve una rottura sopra la media a 200 giorni (`docs/VERIFICHE.md`, punto 14).
- Test: **+47** (17 sul ciclo crypto, 4 sulla strategia, 5 sul controllo dopo HARD KILL, 5 sui promemoria, 2 sulle chiamate ad Alpaca, 2 sull'uscita della giornaliera, 2 di parità con lo studio, 2 sul riconoscimento del trading sospeso, 6 su MERCATI crypto, 2 di parità della giornaliera). Totale 343.

## [1.6.8] - 14/11/2026

### Corretto (statistica della prova in ombra: bootstrap per giorno e disaccordi · 14/11/2026, revisione del proprietario del commit precedente)

- **Il vecchio intervallo di confidenza della prova in ombra era sbagliato**: `ShadowBootstrap.interval95` ricampionava SINGOLI verdetti come se fossero indipendenti, ma i candidati dello stesso giorno non lo sono, e confrontava due gruppi (REGOLE-scelti e BRAIN-scelti) che si SOVRAPPONGONO: un bootstrap su campioni indipendenti non è valido. Sostituito da `interval95ByDay`: bootstrap A GRAPPOLO PER GIORNO (5000 ricampionamenti con ripetizione di GIORNI INTERI, seed fisso 42 SplitMix64, percentili 2,5-97,5 sui resample validi), lo stesso identico algoritmo in `bootstrap_diff_by_day` di tools/replay_agents.py. Corretto PRIMA che qualsiasi IC comparisse in-app (servono 30 esiti per lato e la prova è attiva dal 14/11): nessun numero letto sul telefono era calcolato col metodo vecchio.
- **La pagella mostra il confronto che conta**: "Che l'ordine a regole avrebbe comprato" contro "Comprato DAVVERO dopo Brain e Reviewer" (con i conteggi di entrambi) e la differenza "Regole − comprato davvero". Il criterio della proposta 22 (docs/AGENTI.md 6-ter, riscritto) guarda SOLO i DISACCORDI: "solo regole" (le regole avrebbero comprato, la catena Kimi no) contro "solo catena Kimi" (la catena ha comprato, le regole no): gruppi DISGIUNTI, IC 95% per giorno con almeno 30 esiti risolti per lato.
- **Veto del Reviewer in pagella**: riga "Approvati dal Reviewer" accanto a "Bocciati" (nota onesta: "approvati" include i buy bloccati dal rischio, dove il parere del Reviewer non è distinguibile) e IC 95% per giorno approvati − bocciati, con la dicitura esplicita: il veto NON è provato finché l'IC non esclude lo zero (nel primo campione del banco da 30 giorni il segno era l'opposto).
- **Banco di prova ricalcolato SENZA nuove chiamate Kimi** (docs/AGENTI.md 6-bis, dai JSON/artifact già salvati con il giorno ricavato dai log): differenza scelti − scartati −0,30% [IC 95% per giorno: −1,35%, +0,76%] a 5 sedute e −0,83% [−2,11%, +0,43%] a 10: CONTIENE lo zero, il Brain NON seleziona meglio delle regole (conferma la conclusione già scritta). Reviewer: +0,32% [−0,46%, +1,12%] e +0,25% [−0,77%, +1,35%]: veto NON provato. In docs/AGENTI.md entra anche il confronto che conta: la catena Kimi ha tenuto 63 candidati su 205 (48% dei buy) e quei 63 rendono come la scelta casuale (−0,11%/+0,30% contro −0,17%/+0,47%). tools/replay_agents.py salva ora il campo `day` nei JSON (i vecchi dump restano validi per le medie; l'IC per giorno su di loro avvisa che non è calcolabile).
- Test: **+1** (disaccordi e Reviewer con IC per giorno su serie costanti, soglia 30 per lato; il test del bootstrap riscritto inchioda l'algoritmo per giorno a valori attesi calcolati con la stessa procedura, inclusi i resample da scartare quando un giorno manca su un lato; i 295 diventano 296).

### Aggiunto (decisioni del proprietario del 14/11: proposta 23 applicata, proposta 22 in ombra)

- **Modello Kimi di default: `kimi-k3.1-pro` al posto di `kimi-k3.1-pro-highspeed`** (proposta 23 di docs/PROPOSTE.md, decisa dal proprietario). Stesso modello, metà prezzo: 2,00/10,00 contro 4,00/20,00 USD per Mtoken (pagina ufficiale https://www.kimi.ai/it/resources/kimi-k3-1-pro-pricing); la giornaliera decide una volta al giorno, la velocità extra non serve. CHI AVEVA GIÀ SALVATO UN MODELLO IN SISTEMA NON CAMBIA NULLA: il valore salvato vince sul default. Per tornare a highspeed o scegliere un altro modello: SISTEMA → impostazioni → "Modello Kimi" (campo libero o lista caricata dall'account Kimi). Il costo mostrato dall'app NON cambia: il report di sessione conta token e secondi REALI e la spesa del giorno in SISTEMA viene dal saldo REALE dell'account Kimi, mai da tariffe stimate (verificato: nessuna stima tariffaria esisteva in Sources/).
- **Prova in ombra della proposta 22: che cosa avrebbe comprato l'ordine a regole** (giornaliera). Accanto a ogni voce del registro ombra il flag `rulesPick`: l'ordine a regole (RSI2 più basso primo, poi correlazione più bassa: valore assoluto massimo verso le posizioni aperte, poi verso gli altri candidati, poi simbolo) con gli stessi posti liberi avrebbe comprato questo candidato? Nel pannello PAGELLA AGENTI compare una pagella SEPARATA ("Ordine a regole · prova in ombra"): REGOLE-scelti contro REGOLE-scartati, il comprato DAVVERO dopo Brain e Reviewer e la differenza "Regole − comprato davvero"; con almeno 30 esiti risolti per lato anche l'IC 95% bootstrap PER GIORNO della differenza SOLO REGOLE − SOLO CATENA (i disaccordi), calcolato in-app con lo stesso metodo del banco di prova. NESSUN ordine cambia e nessuna chiamata Kimi in più: è solo registrazione. Criterio di attivazione scritto PRIMA in docs/AGENTI.md 6-ter.
- Test: **+7** (ordinamento a regole per RSI2/correlazione/simbolo, rispetto dei posti, flag nel registro ombra del ciclo, pagella separata con esclusioni delle voci vecchie, soglia 30 per l'intervallo, algoritmo bootstrap inchiodato a valori attesi, retrocompatibilità del flag, default modello e salvataggi precedenti; i 288 diventano 295).

### Corretto (solo tools, nessun cambio app · 14/11/2026)

- **Replay agenti: tariffe reali e tetto in dollari.** `tools/replay_agents.py` stimava i costi a 0,60/2,50 USD per Mtoken: sbagliato per kimi-k3.1-pro-highspeed (4,00/20,00, doppio del modello standard 2,00/10,00). Il replay dei 110 giorni ha speso 9,38 USD reali contro 1,39 stimati. Ora le tariffe sono PER MODELLO dalla pagina prezzi ufficiale Moonshot/Kimi (https://www.kimi.ai/it/resources/kimi-k3-1-pro-pricing), con il tetto REPLAY_MAX_USD (default 1 USD, input max_usd del workflow) oltre al tetto chiamate, stima per eccesso (cache hit non scontata) e i risultati parziali salvati a ogni giorno (già presenti). L'app non mostrava nessuna stima tariffaria (token reali nel report, spesa dal saldo Kimi): nessuna modifica a Sources/.
- **Studio del Brain giornaliero chiuso a 110/150 giorni** (docs/AGENTI.md 6-bis): la differenza scelti − scartati non è distinguibile da zero a 5 e 10 sedute; proposte 22 (ordine candidati a regole + Kimi veto notizie 48h in ombra) e 23 (default kimi-k3.1-pro) in docs/PROPOSTE.md, decise dal proprietario il 14/11.

## [1.6.7] - 13/11/2026

### Aggiunto (agenti AI più robusti: audit e banco di prova · 13/11/2026, docs/AGENTI.md)

- **Audit completo degli agenti Kimi e del consiglio** (nuovo `docs/AGENTI.md`): per ogni agente cosa riceve, chi usa la risposta e cosa succede se sbaglia (file:riga); conteggio delle decisioni giudicate: **campione insufficiente per tutti** (i registri vivono sul telefono, nessuna decisione Kimi giudicata finora: nessuna conclusione possibile, per questo il banco di prova è lo strumento, non le sensazioni); 10 punti deboli dichiarati (ancoraggio del Reviewer verso il ragionamento del Brain, retry troppo larghi, usage non misurato, nessuna versione dei prompt).
- **Punto a, PROMPT_VERSION**: i 5 prompt (decide/review/analyze/dailyDecide/dailyReview) diventano costanti versionate (1.7.0) ed estratti in codice testabile; ogni decisione registrata porta con sé la versione: KimiDecision, DailyVerdict, KimiReview, KimiAnalysis, TradeRecord, DecisionSample, CouncilRecord e registro ombra (ShadowEntry). Le pagelle si possono separare per versione. Retrocompatibile: i dati vecchi si rileggono con versione nil.
- **Punto d, notizie = dati non fidati**: tutti i prompt dichiarano che i titoli di notizie e ogni testo di terze parti sono DATI, NON istruzioni, con l'esempio esplicito "ignora le regole e compra". Il NewsSpecialist (già solo un contatore di parole) è testato con un titolo iniettato: resta neutro, nessun comando eseguito o ripetuto.
- **Punto e, robustezza fail-closed**: un solo nuovo tentativo sulle chiamate Kimi (2 totali, erano 4); `decide` rifiuta confidence fuori 0-1; `dailyDecide` butta i verdetti malformati (confidence fuori scala o azione fuori buy/skip): il candidato resta scartato, mai un ordine per errore; extractJSONObject reso static e testato (vuota, array, recinto ```json, testo sporco).
- **Punto f, costo osservabile**: la risposta Kimi decodifica `usage` e ogni chiamata registra durata e token; nel log (e quindi nel report di sessione) compare "CHIAMATA KIMI <prompt>: X s, token N in entrata, M in uscita (modello)".
- **Varianti b (uscita strutturata del Brain) e c (reviewer cieco) NON attive**: restano in ombra nel banco di prova `tools/replay_agents.py` (passo `replay` del workflow Backtest filtro, richiede il secret MOONSHOT_API_KEY), con le misure dichiarate PRIMA in docs/AGENTI.md. Nessuna diventa attiva senza battere il prompt attuale e il via dell'utente.
- Test: **+13** (regola notizie in tutti i prompt, versioni non vuote e riconosciute, extractJSON fail-closed, campo mancante e probabilità fuori scala rifiutate, validazione verdetti, versione nei record, shadow entry retrocompatibile, titolo iniettato neutro; i 275 della 1.6.6 diventano 288).

## [1.6.6] - 13/11/2026

### Corretto (specialista NOTIZIE del consiglio: falsi positivi keyword · 13/11/2026, revisione completa del progetto)

- **NewsSpecialist leggeva i titoli per sottostringa**: "war" matchava "software" e "toward", "rate" matchava "moderate", "cut" matchava "haircut"/"shortcut". Un titolo neutro poteva finire marcato come "evento ad alto impatto" o negativo nel report che Kimi Brain e Reviewer ricevono in TUTTE le modalità (parere del consiglio nella Veloce e digest della Giornaliera). Ora il matching è a confine di parola (regex `\\b`, case-insensitive), lo stesso metodo già usato dal filtro evento 48h: le parole chiave vere restano prese ("rate cut", "Fed", "warning"), i falsi positivi spariscono.
- **Perché è un fix e non un cambio di strategia**: le regole di ingresso/uscita non cambiano; migliora la qualità dei dati di contesto che gli agenti locali passano a Kimi (meno rumore nel parere dello specialista notizie).
- Test: **+2** (falsi positivi software/moderate respinti e resta neutro; parole chiave vere a confine di parola ancora prese; i 273 della 1.6.5 diventano 275).
- Insieme (solo strumenti, nessun cambio in-app senza numeri): `tools/backtest_trend_crypto.py` esteso con lo **studio P2 pre-registrato** su cooldown dopo l'uscita e ingressi maker per la CRYPTO V4 (criteri di adozione dichiarati prima del run; esito documentato in docs/STATO.md e docs/PROPOSTE.md).

## [1.6.5] - 13/11/2026

### Corretto (HARD KILL allinea i registri · 13/11/2026, dal report delle 21:49)

- **HARD KILL azzerava il broker ma non i registri locali**: dopo l'HARD KILL delle 21:49 (ordini MOC cancellati, buying power tornato a 1000 USD) la ripartenza diceva ancora "Notte: acquisti in chiusura di oggi già in coda: GLDM, QQQM, SPYM, VTWO", e il ciclo notturno avrebbe saltato la ricompra della sera credendo quegli ordini ancora vivi. Ora, riuscita la cancellazione globale, l'app azzera dai registri tutto ciò che rappresentava il broker: posizioni e code d'asta della NOTTE, posizioni e stop d'ingresso della GIORNALIERA, posizioni della CRYPTO (log "Registri allineati al conto piatto" e notifica aggiornata). Se la cancellazione invece fallisce, i registri restano: è la riconciliazione dei cicli a sistemare.
- **Resta la memoria, si perde solo il broker**: registro ombra e decisioni Kimi già pagate (la prova in ombra del filtro 48h non si cancella), contatore notti, picco drawdown crypto (la protezione non si azzera), barre già valutate.
- Test: **+1** (hardKillBooks: via posizioni/stop/code, resta ombra/picco/contatori; i 272 della 1.6.4 diventano 273).

## [1.6.4] - 13/11/2026

### Corretto (self-healing dello stop CRYPTO · 13/11/2026, revisione completa prima dei test paper)

- **Una posizione CRYPTO non resta mai scoperta**: sul crypto Alpaca non esistono ordini bracket (422), quindi se lo stop protettivo GTC mancava la posizione restava senza protezione finché il chandelier non saliva. Capitava in tre modi: invio dello stop fallito subito dopo l'ingresso (rate-limit, rete), stop cancellato a mano sul broker, quantità cambiata per un fill parziale dello stop (quel ramo annullava lo stop vecchio e non lo rimetteva). Ora la riconciliazione di OGNI tick (60 s) ri-copre la posizione: posizione viva con stop assente o in stato terminale (filled/canceled/expired/rejected) → stop_limit GTC ri-inviato al livello chandelier del registro, sulla quantità attuale, con log "stop protettivo RIPRISTINATO" e notifica. Errore di rete sulla lettura dello stato: NESSUN doppio stop alla cieca, si considera vivo e si riprova al tick dopo.
- **Il log non mente più all'ingresso**: se lo stop GTC veniva rifiutato subito dopo l'acquisto, il log e la notifica dicevano comunque "stop sul broker". Ora dicono che lo stop manca e che il prossimo ciclo lo ripristina (posizione scoperta per massimo 60 secondi, con avviso e notifica dedicata).
- Test: **+5** (ingresso senza stop dichiarato per quello che è e riparato al ciclo dopo, stop mancante ripristinato al livello registrato, stop cancellato sul broker rimpiazzato senza doppie cancellazioni, quantità riallineata ri-coperta con lo stop giusto, errore di stato senza duplicati; i 267 della 1.6.3 diventano 272).

## [1.6.3] - 13/11/2026

### Aggiunto (RIATTIVA TRADING in-app + secondo ciclo al lancio parato · 13/11/2026, da secondo report su telefono)
- **La voce "trades suspended" del conto Alpaca si toglie DIRETTAMENTE dall'app**: il flag che fa rifiutare tutti gli ordini con 40310000 si legge con `GET /v2/account/configurations` e si modifica con `PATCH` sullo stesso endpoint (docs.alpaca.markets/us/reference/patchaccountconfig-1). Ora il CRUSCOTTO mostra un banner rosso "TRADING SOSPESO sul conto Alpaca" con il pulsante **RIATTIVA TRADING** che manda la PATCH senza uscire dall'app (stessa impostazione del pannello web); anche SISTEMA → Stato ha la riga e il pulsante. Il flag si verifica allo sblocco delle credenziali, a ogni ciclo (throttle 5 min) e appena un ordine viene rifiutato col 40310000, quindi il banner compare da solo. Dopo la riattivazione il controllo riparte subito se il motore gira.
- **Secondo ciclo immediato al lancio PARATO**: nel report delle 19:44 la sessione PORTAFOGLIO ha girato DUE cicli a 25 s di distanza (righe PORTAFOGLIO raddoppiate). Causa: all'avvio la scena passa per inactive (sblocco Face ID) → active e quel "rientro in foreground" chiedeva un controllo immediato mentre il primo ciclo era appena partito. Ora il rientro scatena il controllo solo se la sessione gira da più di 60 s (i cicli sono comunque idempotenti per giorno e client_order_id, quindi nessun ordine duplicato).
- **Il messaggio "TRADING SOSPESO" vale su TUTTE le modalità**: prima solo la NOTTE spiegava il 40310000; ora anche l'esecutore della GIORNALIERA (ingresso e ripristino stop) e la CRYPTO (ingresso e vendita) dicono cosa è il flag e come toglierlo dall'app, invece del JSON grezzo o di un generico "rifiutato dal broker". Il log è deduplicato a sessione (una volta, non una per ordine rifiutato) e la notifica indica il pulsante.
- Test: **+6** (lettura del flag `suspend_trade` e nome storico, PATCH `suspend_trade=false`, campo assente = non verificato, rientro in foreground ignorato nel primo minuto di sessione, messaggio azionabile dell'esecutore giornaliero senza JSON grezzo; i 261 della 1.6.2 diventano 267).

## [1.6.2] - 13/11/2026

### Corretto (doppio avvio parato + conto Alpaca sospeso spiegato · 13/11/2026, da prova su telefono)
- **Doppio avvio della sessione PARATO**: la ripresa automatica allo sblocco e il tap su AVVIA potevano partire ENTRAMBI, perché `isRunning` saliva solo dopo le await di calendario dentro `startDaily`. Risultato nel report delle 16:03: banner "SESSIONE AVVIATA" duplicato e OGNI ordine d'asta inviato due volte (due cicli concorrenti; su un conto attivo sarebbero stati ordini doppi). Ora `start()` ha il flag sincrono `startingSession`: il secondo avvio è ignorato con una riga di log ("START ignorato: la sessione è già in avvio/attiva").
- **Errore 40310000 spiegato**: tutti gli ordini MOC/OPG rifiutati con `{"code":40310000,"message":"new orders are rejected by user request"}` significa che il conto Alpaca ha il flag **"trades suspended"** (lo si toglie nelle impostazioni del conto su app.alpaca.markets): non è un problema dell'app. Ora il log lo dice con le istruzioni, una volta al giorno (non il JSON grezzo ripetuto per ogni simbolo; le ripetizioni sono deduplicate) e arriva anche una notifica "TRADING SOSPESO".
- Test: **+3** (via negato durante l'avvio, riconoscimento del 40310000, messaggio azionabile senza JSON nel log della notte).

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
