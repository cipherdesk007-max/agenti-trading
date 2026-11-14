# Verifiche manuali su telefono e conto · checklist

Controlli da fare a mano sull'iPhone (installata via SideStore/LiveContainer) e sullo
storico di **Alpaca paper** (`https://app.alpaca.markets/paper` → Orders / Positions).
Nessuno di questi è automatizzabile in CI: l'app gira solo aperta e le chiavi sono
nel Keychain protetto da Face ID.

## Prerequisiti

- Conto **paper** Alpaca (da 1.000 $) per la GIORNALIERA; secondo conto paper per la NOTTE.
- Chiavi Kimi e Alpaca inserite in **paper** (LOGIN), Face ID attivo.
- Modalità NOTTE sul secondo conto: SISTEMA → CONTI ALPACA. Promemoria alle 14:45 e 21:15 (ora italiana).
- Finestre NOTTE: mattina entro le 15:28 IT (vendita OPG), pomeriggio 15:30–21:50 IT (acquisto MOC).
- `client_order_id` usati dall'app: `qsn-b-` = acquisto MOC, `qsn-s-` = vendita OPG, `qsn-l-` = vendita a mercato di residuo.

## 1 · Primo acquisto MOC della NOTTE

- **Nell'app**: apri nel pomeriggio (15:30–21:50 IT) in modalità NOTTE e avvia. Nel CRUSCOTTO la catena arriva a "in coda per la chiusura: SPYM x az, …".
- **Su Alpaca**: Orders → 4 ordini BUY con `time_in_force = cls` e `client_order_id` `qsn-b-…`, stato accepted.
- **Atteso**: alle 16:00 di New York (22:00 IT) gli ordini si eseguono nell'asta di chiusura; in Positions compaiono le azioni; il registro notte dell'app le elenca con quantità.
- **Se è diverso**: ordine `rejected` → log "ordine CLS rifiutato", nessun acquisto, si ritenta alla finestra successiva. Resta `accepted` senza fill dopo le 16:00 NY → asta non eseguita: al ciclo successivo il residuo (se eseguito in parte) viene chiuso a mercato (R7). Mai due ordini con lo stesso `qsn-b-`.

## 2 · Prima vendita OPG della NOTTE

- **Nell'app**: apri la mattina entro le 15:28 IT. CRUSCOTTO: "vendo all'apertura: …" e notifica VENDITA ALL'APERTURA.
- **Su Alpaca**: Orders → SELL con `time_in_force = opg`, `client_order_id` `qsn-s-…`.
- **Atteso**: alle 9:30 NY (15:30 IT) gli OPG si eseguono; le Positions del conto notte sui 4 simboli vanno a zero; al ciclo successivo il registro notte si svuota.
- **Se è diverso**: OPG annullata/rifiutata all'asta → le azioni restano e **non** scompaiono dal registro (R7, marcate "in coda"); al ciclo pomeridiano il residuo viene chiuso a mercato con ordine `qsn-l-…` (o `closePosition` se la notte ha tutto il detenuto). Verifica che non venda anche azioni della giornaliera sullo stesso simbolo e che non si compri due volte sopra il residuo.

## 3 · Stop GTC della GIORNALIERA visibile su Alpaca

- **Nell'app**: modalità GIORNALIERA, START con un segnale → ordine limite + stop.
- **Su Alpaca**: Orders → coppia BUY limit + SELL stop con `time_in_force = gtc` (stop_price = ingresso − 2,5 ATR); resta `open` anche con l'app chiusa.
- **Atteso**: con l'app chiusa lo stop resta sul broker e scatta da solo se il prezzo lo tocca; in Positions la posizione mostra lo stop.
- **Se è diverso**: stop assente → al ciclo successivo l'app lo rimette (protezione "mai una posizione senza stop"). Stop eseguito → posizione chiusa, è normale. Stop residuo dopo vendita della posizione → bug da segnalare (può aprire uno short).

## 4 · Ripresa dopo app chiusa

- **Nell'app**: a mercato aperto chiudi l'app (swipe up) e riaprila: parte subito un controllo automatico (o usa CONTROLLA ORA). Nei log/events compare la riconciliazione col broker.
- **Su Alpaca**: Orders → nessun ordine duplicato: lo stesso `client_order_id` non deve comparire due volte. Se c'era un invio in timeout, l'app cerca l'ordine per id prima di rinviare.
- **Atteso**: un solo ordine per segnale; nessun falso allarme HEARTBEAT (il tempo con l'app chiusa non conta).
- **Se è diverso**: ordine duplicato → bug grave (recupero per client_order_id), confronta gli id `qsn-` in Alpaca e segnala.

## 5 · Cambio conto

- **Nell'app**: SISTEMA → CONTI ALPACA → aggiungi il secondo conto paper (le chiavi vengono provate sul broker prima di salvarle) e passaci a motore fermo. Passare a un conto live chiede conferma con la parola LIVE.
- **Su Alpaca**: confronta Positions e Orders dei due conti.
- **Atteso**: ogni conto ha registro (giornaliera e notte), curva del capitale e protezioni **separati**; il capitale del bot si ricalcola sul saldo del conto attivo.
- **Se è diverso**: registri mescolati (es. il registro notte di un conto che vende sull'altro) → bug, non usare il multi-conto finché non è chiaro.

## 6 · Pausa batteria (e rete)

- **Nell'app**: porta la carica sotto il 20% (o disattiva la rete): il CRUSCOTTO mostra "MOTORE IN PAUSA" con il motivo; il motore non invia ordini.
- **Su Alpaca**: Orders → nessun ordine nuovo nei timestamp della pausa.
- **Atteso**: al rientro (carica > 20% o rete tornata) il ciclo riparte da solo; gli stop GTC sul broker restano attivi per tutto il tempo.
- **Se è diverso**: ordini inviati durante la pausa → bug della pausa, segnala.

## 7 · Traduci nelle notizie

- **Nell'app**: MERCATI → tocca un ETF → grafico → sezione **Notizie · 48 ore** → tocca "Traduci" (richiede iOS 17.4+).
- **Atteso**: si apre il foglio di traduzione di Apple con il testo in italiano, gratis e senza crediti Kimi.
- **Se è diverso**: sul simulatore il foglio non si apre (limite noto, vedi STATO.md). Sul dispositivo reale, se non appare → controlla la versione di iOS.

## 8 · Registro notte della build precedente (solo chi aggiorna da build ≤ 130)

- **Nell'app**: primo ciclo NOTTE dopo l'aggiornamento.
- **Atteso**: il registro vecchio (senza quantità) si rilegge: vende tutto il detenuto del simbolo una sola notte, poi passa al formato nuovo con quantità (R7/B1).
- **Se è diverso**: non vende nulla → registro illeggibile, da indagare. Vende anche azioni della giornaliera sullo stesso simbolo → bug B1: HARD KILL SWITCH e segnala subito.

## 9 · Ragionamento "medium" di Kimi

- **Nell'app**: GIORNALIERA con un segnale di oggi → Brain e Reviewer vengono chiamati.
- **Atteso**: la chiamata usa `reasoning_effort` medium; se il modello lo rifiuta (errore 400) l'app ripiega una volta su low **senza perdere la decisione** (log in CRUSCOTTO/DETTAGLI).
- **Se è diverso**: decisione persa per errore 400 → bug; controlla eventi e crediti Kimi in SISTEMA.

## 10 · Controllo indipendente dei segnali di oggi

- Actions → "Backtest filtro" → `quale` = `oggi` (oppure `python tools/oggi.py` in locale), poi confronta SMA200 e RSI(2) di Wilder con TradingView o Yahoo.
- **Atteso**: gli indicatori dell'app coincidono con la tabella di `oggi`.
- **Se è diverso**: differenza → il feed barre (SIP/IEX) diverge dalla fonte esterna, da indagare prima di fidarsi del segnale.

## 11 · VELOCE: flat-by-close a T-10 con ordini aperti (stop d'emergenza qsv-emg-)

- **Nell'app**: modalità VELOCE, apri una posizione intraday con bracket (gamba stop + target, day) e lascia che il motore arrivi a T-10 dalla chiusura. Il flat-by-close gira anche in pausa: è protezione del capitale.
- **Su Alpaca**: Orders → a T-10 gli ordini aperti del simbolo (gambe del bracket e un eventuale `qsv-emg-…`) passano a `canceled`, poi parte la vendita a mercato (`DELETE /v2/positions/{symbol}`); se fallisce compare un solo SELL stop GTC con `client_order_id` `qsv-emg-SIMBOLO-GIORNO`.
- **Atteso**: a fine tentativo la posizione è chiusa OPPURE ha esattamente uno stop `qsv-emg-…`; mai due stop d'emergenza sullo stesso simbolo, mai ordini residui del simbolo. La doc Alpaca dice che `DELETE /v2/positions/{symbol}` NON annulla gli ordini aperti e che con ordini sell aperti le azioni restano riservate (rifiuto "insufficient qty"): https://docs.alpaca.markets/us/reference/deleteopenposition-1 — da confermare qui sul conto paper.
- **Se è diverso**: più stop `qsv-emg-` sullo stesso simbolo → bug nell'anti-duplicato; ordine residuo del simbolo a posizione chiusa → l'annullo non è stato verificato rileggendo gli ordini; chiusura rifiutata "insufficient qty" → gli ordini sell non erano stati annullati (o restavano riservate: la sequenza cancel→close ha una corsa documentata, https://alpaca.markets/learn/how-to-fix-common-trading-api-errors-at-alpaca); posizione senza stop e senza chiusura → guarda la notifica "POSIZIONE SENZA STOP" e chiudi a mano dal broker panel.

## 12 · Agenti 1.6.7: costo per chiamata nel report e robustezza sulle risposte (13/11 build ≥ 213, non ancora pubblicata)

- **Nell'app**: avvia una modalità che chiama Kimi (GIORNALIERA con candidati, VELOCE, o solo ANALIZZA ORA in MERCATI), poi STOP e apri il report di sessione.
- **Atteso**: nel report compare una riga "CHIAMATA KIMI <prompt>: X s, token N in entrata, M in uscita (modello …)" per OGNI chiamata fatta; il conteggio chiamate del giorno in SISTEMA è coerente. Le decisioni registrate (dettagli/pagelle) portano la versione del prompt 1.7.0.
- **Se è diverso**: manca la riga CHIAMATA KIMI con una chiamata comunque avvenuta (contatore a posto) → il drain del log non è arrivato al report: da segnalare. Token a zero con risposta ricevuta → l'API non ha restituito usage: guardare il modello in uso.
- **Nota costo**: la tariffa stimata non è nell'app (solo token reali); il saldo speso reale resta quello di SISTEMA (baseline saldo Kimi).

## 13 · Decisioni del 14/11: default modello kimi-k3.1-pro e prova in ombra ordine a regole (build ≥ 217, versione 1.6.8, non ancora pubblicata)

- **Modello di default (proposta 23)**: apri SISTEMA → impostazioni → "Modello Kimi".
- **Atteso**: se NON avevi mai salvato un modello, il campo mostra `kimi-k3.1-pro` (stesso modello di highspeed a metà prezzo: 2,00/10,00 contro 4,00/20,00 USD per Mtoken). Se avevi salvato `kimi-k3.1-pro-highspeed`, devi vederlo ANCORA: il valore salvato vince sul default, nessuno te lo cambia. Per cambiare a mano: campo libero o lista "Modelli disponibili" (caricata dall'account Kimi con le tue chiavi).
- **Se è diverso**: il campo vuoto dopo un salvataggio ripristina il default (kimi-k3.1-pro): è il comportamento voluto; un valore salvato che sparisce da solo sarebbe un bug da segnalare.
- **Versione**: SISTEMA → VERSIONE deve leggere 1.6.8 (con numero di build della CI).
- **Prova in ombra ordine a regole (proposta 22)**: avvia la GIORNALIERA e lascia correre una sessione con almeno un candidato; poi guarda DETTAGLI → PAGELLA AGENTI.
- **Atteso**: compare la sezione "Ordine a regole · prova in ombra (proposta 22)" con "Che l'ordine a regole avrebbe comprato" e "avrebbe saltato", la riga "Comprato DAVVERO dopo Brain e Reviewer" (stessi conteggi in stile "quanti · rendimento medio · quota in guadagno") e la differenza "Regole − comprato davvero"; più sotto le due righe dei DISACCORDI ("solo regole" e "solo catena Kimi"). Nella pagella principale compare anche "Approvati dal Reviewer" accanto a "Bocciati dal Reviewer". GLI ORDINI NON CAMBIANO: quello che compra resta deciso dal Brain come sempre.
- **IC in-app**: gli intervalli compaiono SOLO quando entrambi i lati hanno almeno 30 esiti risolti (l'IC dei disaccordi e quello del Reviewer sono PER GIORNO: con 1-2 candidati al giorno servono settimane; prima di allora l'app scrive che i numeri sono rumore). Nota onesta dichiarata in-app: "approvati" del Reviewer include i buy bloccati dal rischio, dove il parere del revisore non è distinguibile.
- **Se è diverso**: sezione assente dopo una sessione con candidati → il flag non è stato registrato: da segnalare col report di sessione. IC presente con meno di 30 esiti per lato → bug.
- **Criterio scritto prima** (docs/AGENTI.md 6-ter, corretto il 14/11): si passa all'ordine a regole SOLO se l'IC 95% per giorno della differenza SOLO REGOLE − SOLO CATENA (i disaccordi) risulta interamente sopra zero, e mai senza il tuo via esplicito. Il veto del Reviewer NON è provato: si attiva qualcosa solo se il suo IC esclude lo zero.

## 14 · CRYPTO: primo ingresso, stop sul broker, ripresa, uscita (versione 1.6.9)

**Da sapere prima.** La modalità CRYPTO non è mai stata provata su un conto vero. Fino alla 1.6.8 non poteva funzionare: Alpaca scrive la coppia `BTC/USD` negli ordini e `BTCUSD` nell'elenco posizioni, l'app le confrontava così com'erano e dopo 60 secondi credeva la posizione sparita (la toglieva dal registro e annullava lo stop). Nei test non si vedeva perché il broker finto usava una sola scrittura. La 1.6.9 corregge questo e altri nove punti (CHANGELOG), ma la conferma può darla solo il broker vero.

**Prova rapida senza aspettare un segnale** (circa 12 dollari FINTI di BTC comprati e rivenduti sul conto paper, meno di un minuto): flusso GitHub **"Prova crypto su conto PAPER"** (Actions → Run workflow → scrivere `PAPER`), oppure chiedere a chi lavora sul repository di lanciarlo. Stampa una tabella con ogni ipotesi e l'esito CONFERMATO o DIVERSO: simbolo nell'elenco posizioni, tempo d'esecuzione dell'acquisto, commissione pagata in moneta, stop `stop_limit` accettato con quantità a 9 decimali e prezzi a 2, secondo stop rifiutato, stesso `client_order_id` rifiutato, vendita subito dopo l'annullo dello stop, nessun residuo dopo la vendita. Lo script (`tools/prova_crypto_paper.py`) usa solo l'indirizzo paper, non tocca il conto se c'è già una posizione o un ordine BTC e a fine prova rimette tutto com'era. **Lanciato il 14/11/2026 (run 43557460572): 12 ipotesi su 12 CONFERMATE**, conto lasciato senza posizioni né ordini BTC. In più ha mostrato che Alpaca usa il codice 40310000 anche per il saldo insufficiente: l'app lo scambiava per "trading sospeso", corretto. Resta da vedere il ciclo completo dell'app con un segnale vero (qui sotto).

**Prova con l'app** (serve un segnale vero: una coppia che chiude sopra il massimo dei 20 giorni e sopra la media a 200 giorni; con il mercato sotto la media può volerci molto):
- **Nell'app**: modalità CRYPTO, START, app aperta.
- **Su Alpaca dopo l'ingresso**: Positions → la coppia SENZA barra (es. `BTCUSD`), quantità un po' sotto l'ordinato se la commissione è in moneta. Orders → un BUY market `qsc-buy-BTCUSD-GIORNO` eseguito e UN SOLO SELL `stop_limit` GTC `qsc-stop-BTCUSD-GIORNO` per la stessa quantità della posizione.
- **Atteso nell'app**: log "ingresso … stop stop_limit GTC a … sul broker". Dopo 1 e dopo 5 minuti la posizione è ANCORA nel pannello e nel log NON compare "la posizione non è più sul broker".
- **Ripresa**: con la posizione aperta chiudi l'app, riaprila, START. Atteso: nessun nuovo acquisto, nessun secondo stop, niente "RIPRISTINATO" se lo stop era al suo posto.
- **Uscita**: quando la chiusura giornaliera scende sotto il chandelier o la media a 200, l'app annulla lo stop, aspetta la conferma e vende (`qsc-sell-BTCUSD-GIORNO`). Su Alpaca: stop `canceled`, poi un SELL market eseguito, posizione assente.
- **Se è diverso**: "lo stop GTC NON è stato accettato" seguito entro 60 s da "RIPRISTINATO" → funziona ma va segnalato; "senza stop" che resta → mandare il report (probabile rifiuto di Alpaca su prezzo o quantità dello stop); due BUY della stessa coppia nello stesso giorno → l'anti-doppione non ha funzionato; posizione sparita dal pannello ma presente su Alpaca → il difetto dei simboli non è risolto.
- **Differenze dichiarate rispetto allo studio**: lo stop sul broker scatta durante la giornata (lo studio esce solo alla chiusura giornaliera) e l'app compra quando viene aperta, non alla chiusura della barra.

## 15 · HARD KILL: l'esito è quello vero (versione 1.6.9)

- **A mercato aperto, con almeno una posizione**: premi HARD KILL. Atteso: stato "HARD KILL completato" e nel log "HARD KILL verificato: sul conto non restano né posizioni né ordini". Su Alpaca: Positions e Orders vuoti.
- **A mercato chiuso, con una posizione in azioni**: atteso "HARD KILL: chiusure in coda" con l'elenco dei simboli. Su Alpaca la posizione c'è ancora, con un SELL market in attesa che si esegue alla prossima apertura (fino ad allora è senza stop: è il comportamento di Alpaca, ora l'app lo dice).
- **Se è diverso**: "completato" con posizioni ancora presenti su Alpaca → bug, mandare il report. "HARD KILL INCOMPLETO" con un elenco → ripremere; se resta, chiudere dal sito Alpaca e mandare il report.

## 16 · Promemoria in PORTAFOGLIO (versione 1.6.9)

- **Nell'app**: SISTEMA → "Promemoria per aprire l'app" acceso, modalità PORTAFOGLIO, notifiche consentite per l'app in Impostazioni iOS. Apri l'app almeno una volta dopo l'aggiornamento (i promemoria si programmano all'avvio del motore o al salvataggio delle impostazioni, per i 21 giorni successivi).
- **Atteso**: nei giorni di borsa due notifiche. "NOTTE: VENDITA" alle 8:45 di New York (14:45 in Italia quando la differenza è di 6 ore) e "NOTTE: ACQUISTO" 45 minuti prima della chiusura (21:15 in Italia). Venerdì 27/11/2026 la borsa chiude alle 13:00 di New York: la seconda deve arrivare alle 12:15 di New York (18:15 in Italia), non alle 21:15.
- **Se è diverso**: nessuna notifica con i permessi a posto → segnalare con il report. Fino alla 1.6.8 in PORTAFOGLIO non ne partiva nessuna: se le notifiche non arrivavano non era un problema del telefono.

## 17 · GIORNALIERA: uscita al primo tentativo (versione 1.6.9)

- **Quando capita**: alla prima uscita a regole della giornaliera (chiusura sopra la media a 5 giorni, o scadenza dei giorni) con l'app aperta a mercato aperto.
- **Atteso**: log "USCITA — …" al primo ciclo. Su Alpaca: stop (e target) `canceled`, poi la vendita eseguita.
- **Se è diverso**: "uscita non riuscita … stop rimesso sul broker, riprovo al prossimo ciclo" → la posizione è protetta ma l'attesa di 2 secondi non è bastata: mandare il report, serve allungarla.

## Come riportare un problema

Screenshot dell'app (CRUSCOTTO con catena agenti ed eventi) + lo storico ordini di Alpaca
nello stesso intervallo + il report di sessione dell'app. Confrontare sempre i
`client_order_id` `qsn-` fra app e broker: è il modo più rapido per capire se un ordine
è stato inviato, rifiutato o eseguito.
