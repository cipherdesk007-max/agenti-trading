# Changelog · FMLAB QuantSwarm Alpha Zero

Tutte le modifiche importanti dell'app, dalla più recente.
Formato: [Keep a Changelog](https://keepachangelog.com/it/1.1.0/), versioni [SemVer](https://semver.org/lang/it/).
La versione installata si legge in **SISTEMA → VERSIONE** (con il numero di build della CI).
Le versioni precedenti alla 1.1.0 sono ricostruite dalla storia dei commit.

## [Non rilasciato]

## [1.2.0] - 2026-11-11

### Aggiunto
- **Aggiornamenti dall'app**: all'avvio l'app controlla se c'è una versione nuova. Se c'è, nel CRUSCOTTO compare un avviso e in SISTEMA il pulsante **AGGIORNA**, che apre LiveContainer e installa la nuova IPA sopra l'app; dati, chiavi e impostazioni restano. Con **AGGIUNGI SORGENTE A LIVECONTAINER** le versioni nuove compaiono anche nella scheda Sources di LiveContainer.
- Su richiesta (Run workflow con "pubblica"), la CI pubblica la build sul repository pubblico `quantswarm-releases`: solo IPA, icona e sorgente `apps.json`, il codice resta privato. Serve il segreto `RELEASES_TOKEN`.

### Cambiato
- Le release non partono più da sole: di default l'IPA va in una bozza privata e viene consegnata a mano. `ultima`, `vX.Y.Z` e gli aggiornamenti dall'app partono solo con "pubblica".
- CI più veloce: a ogni modifica girano solo i test sulla logica, che bloccano l'IPA se falliscono. I test dell'interfaccia e gli screenshot partono su richiesta, prima delle release.

### Corretto
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
