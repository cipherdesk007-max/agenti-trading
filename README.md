# FMLAB · QuantSwarm Alpha Zero

Versione corrente: **1.5.0 build 156** (vedi [CHANGELOG.md](CHANGELOG.md) e, nell'app, **SISTEMA → VERSIONE**).
Per chi usa l'app: la guida in italiano è [docs/GUIDA.md](docs/GUIDA.md) (PDF: `docs/GUIDA.pdf`).
Per revisori umani o AI: lo stato del progetto, le decisioni prese e i numeri degli studi sono in [docs/STATO.md](docs/STATO.md).

App iOS 17+ (Swift 6, SwiftUI, SwiftData) di trading con agenti AI: Kimi via API sceglie e contesta, il codice decide quantità e rischio, Alpaca esegue. Nessuna credenziale nel repository.

## Modalità

| Modalità | Cosa fa | Stato |
|---|---|---|
| **PORTAFOGLIO · 30/70** (default) | Giornaliera e notte sullo stesso conto con budget separati, ribilanciati a ogni ciclo sull'equity: **30% giornaliera** (15 ETF, SMA200 + RSI2 < 10, stop 2,5 ATR **sul broker GTC**, attivo ad app chiusa) e **70% notte** (MOC in chiusura / OPG all'apertura su S&P 500, Nasdaq-100, Russell 2000, oro con gemelli economici SPYM/QQQM/VTWO/GLDM). Registri separati, P&L separato per strategia. Due aperture al giorno per la notte: mattina entro le 15:28, pomeriggio entro le 21:50 (ora italiana). | Studio 2006–oggi (run 43338377889): +5,6% annuo, perdita max −17%, Sharpe 0,79 (1,96 ultimi 3 anni), correlazione +0,04 |
| **VELOCE · SPERIMENTALE** | Candele 15m, filtro long, bracket in giornata, chiusura totale 10 minuti prima della fine della seduta. Serve l'app sempre aperta. | Nei backtest perde e non batte il caso |

## Schermate

- **CRUSCOTTO**: stato del motore, numeri di oggi, **MERCATI** (i 15 ETF con stato; tocca per il grafico a candele con medie, ingresso, stop e target reali dal broker), catena agenti, posizioni, eventi.
- **DETTAGLI**: curva del capitale contro SPY, decisioni di Kimi, scelti contro scartati, analisi, metriche.
- **BROKER**: ordini e posizioni con annullo e chiusura manuali.
- **SISTEMA**: versione, modalità, capitale del bot, ETF comprabili, rischio, limiti di Kimi.

Conto piccolo (es. 1.000 $): si comprano azioni intere, quindi entrano solo gli ETF con prezzo entro il 25% del capitale; l'app li indica e non chiama Kimi per gli altri. La regola PDT dei 25.000 $ non esiste più dal 4 giugno 2026.

## Catena agenti

Scout (dati, conto, posizioni) → Strategia (segnali a regole, zero crediti) → Analyst (quadro di mercato) → Brain (Kimi sceglie) → Reviewer (Kimi cerca motivi per bocciare) → Rischio (codice: quantità, stop, limiti) → Esecutore (ordine con stop sul broker). Se la Strategia non trova segnali, Kimi non viene chiamato. Ogni errore di Kimi o del broker = nessun ordine. Lo stato di ogni agente è nel CRUSCOTTO.

## Regole di rischio (in codice, testate)

**Capitale del bot**: di default tutto il saldo del conto (segue da solo guadagni e perdite); un limite manuale opzionale (500–1.000.000 USD) serve solo se sul conto ci sono altri soldi. In SISTEMA si vede quanti dei 15 ETF può comprare con almeno 1 azione intera. Rischio max 1% per trade (impostabile 0,25–2%, mai oltre 5%), posizione max 25% del capitale, max 3 posizioni, stop giornaliero e stop drawdown 10% del capitale con sblocco manuale, solo acquisti (niente short), limite giornaliero di spesa Kimi. In DETTAGLI la **curva del capitale** confronta il bot con SPY compra-e-tieni (un punto per seduta, paper e live separati).

## Verifica indipendente

- **Guida rapida ai test** (CI automatica, test manuali, controlli su telefono): [docs/TESTI.md](docs/TESTI.md).
- **Test automatici**: a ogni push GitHub Actions esegue **218 test unitari** (regole di rischio, filtro, strategia giornaliera, ciclo notte, HTTP Alpaca con mock, parametrici su conti 500–1.000.000 $) su simulatore; se un test fallisce l'IPA non viene pubblicata. I 5 test di interfaccia girano solo a mano.
- **Backtest**: Actions → "Backtest filtro" → Run workflow con `quale` = `tutti`, `app`, `piccolo`, `overnight`, `segnali`, `momentum`, `giornaliero`, `intraday15`, `veloce5m`, `studi` (studi solo-da-studiare: trailing stop, risk-parity NOTTE, filtro evento 48h, filtro VIX) oppure `oggi` (segnali di oggi con dati Yahoo, indipendenti dall'app). Il 1° di ogni mese parte da solo il controllo `mensile` (app, piccolo, overnight). Codice in `tools/`, risultati nel riepilogo del run.
- **Broker**: confronta il registro dell'app con l'estratto conto Alpaca.

## Build e IPA

1. Push su `main` con modifiche a `Sources/`, `Tests/`, `project.yml` o al workflow: GitHub Actions genera il progetto con XcodeGen, esegue i test unitari su simulatore e, solo se passano, compila l'IPA non firmata. I test di interfaccia e gli screenshot girano solo a mano (Run workflow con `uitest` / `screenshot`), per tenere veloce la CI.
2. L'IPA finisce nel ramo `bozza-ipa` (`QuantSwarm-Alpha-Zero.ipa`, con il numero di build nel messaggio del commit); gli screenshot nel ramo `screenshot`. Le release si creano a mano dalla pagina Releases: il token di Actions non ha il permesso di crearle. La pubblicazione per l'aggiornamento dall'app parte solo con l'opzione `pubblica`.
3. Per una nuova versione: aggiorna `MARKETING_VERSION` in `project.yml` (app e widget) e aggiungi la sezione in `CHANGELOG.md`.

Build locale su macOS:

```sh
brew install xcodegen
xcodegen generate --spec project.yml
xcodebuild -project QuantSwarmAlphaZero.xcodeproj -scheme QuantSwarmAlphaZero -destination 'platform=iOS Simulator,name=iPhone 16' test
```

## Avvio

1. Inserisci la chiave Kimi (`https://api.moonshot.ai/v1`) e le chiavi Alpaca, prima in **paper**. Il passaggio al live richiede di scrivere `LIVE`, e ogni START in live chiede conferma.
2. Modalità PORTAFOGLIO: premi START. L'app controlla i 15 ETF della parte giornaliera (Kimi solo se c'è un segnale, ordine limite + stop GTC sul broker) e gestisce la parte notte alle aste (MOC in chiusura, OPG all'apertura). Poi puoi chiuderla: riaprendola parte subito un controllo (o usa CONTROLLA ORA). Per la notte bastano due aperture al giorno: mattina entro le 15:28 (ora italiana) e pomeriggio entro le 21:50; i promemoria arrivano alle 14:45 e alle 21:15. Se rigeneri il conto paper, usa "Ricalibra equity" in SISTEMA.
3. `STOP` ferma il motore senza toccare le posizioni. `HARD KILL SWITCH` annulla tutti gli ordini e chiude tutte le posizioni del conto.

## Protezioni (in codice)

- **Mai una posizione senza stop**: a ogni ciclo ogni posizione della giornaliera deve avere uno stop sul broker, altrimenti viene rimesso. Se un'uscita fallisce dopo aver annullato lo stop, lo stop viene ripristinato (solo se la posizione esiste ancora, per non aprire uno short).
- Uscite a regole solo a mercato aperto: a mercato chiuso lo stop resta.
- Ingressi eseguiti in parte: il giorno dopo il residuo viene annullato e lo stop copre solo la quantità comprata.
- La chiusura di fine giornata della modalità veloce tocca solo le sue posizioni, mai quelle della giornaliera.
- La notte usa un registro proprio per conto (`NightBookStore`): vende solo quello che ha comprato. Ordini d'asta con `client_order_id` deterministico e ricerca prima di ogni nuovo invio, quindi mai due ordini uguali. Se la vendita del mattino è saltata, il pomeriggio chiude a mercato la posizione rimasta prima di ricomprare.
- Rischio reale calcolato sul prezzo d'ingresso effettivo; posizione max 25% del capitale; max 3 posizioni; stop giornaliero e drawdown 10% (sblocco manuale); niente short.
- Errore di Kimi o del broker = nessun ordine; timeout sull'invio = verifica sul broker, mai un secondo invio.
- Barre giornaliere dal feed consolidato SIP (gratuito oltre i 15 minuti), con ripiego su IEX.
- Esito delle uscite dal prezzo di esecuzione reale.

## Misura e verifica

- **Backtest con le regole esatte dell'app** (`tools/backtest_app.py`, Actions → "Backtest filtro" → `app`): 2006–oggi +2,3% annuo, perdita massima −9%, Sharpe 0,43; batte ingressi casuali con le stesse regole; tutte le 18 varianti di parametri vicine guadagnano (strategia robusta, parametri lasciati invariati). Guadagna meno del buy & hold (+10,9%, ma −55% di perdita massima).
- **Registro ombra** (DETTAGLI → "Kimi · scelti vs scartati"): esito ipotetico, con le stesse regole, dei candidati comprati e di quelli scartati da Brain/Reviewer. Dopo almeno 10 esiti dice se Kimi aggiunge valore; l'esito passato viene anche dato al Brain.
- **Ordini eseguiti**: inviati, mai eseguiti, eseguiti in parte.
- **Take-profit +2 ATR sul broker** (bracket con lo stop): nel backtest non cambia il risultato ma fa uscire anche ad app chiusa.
- **Promemoria** lun–ven 15:30 New York (21:30 in Italia) per aprire l'app. Un controllo automatico in background non è possibile senza togliere la protezione Face ID alle chiavi.
- **Crash e blocchi** raccolti con MetricKit e riportati nel report di sessione.
- **CSV dei trade chiusi** (DETTAGLI), per il commercialista e il confronto con l'estratto conto.
- **Test**: 153 unitari (rischio, strategia, cicli con broker/Kimi finti, HTTP Alpaca con mock, parametrici per taglie di conto) e 5 di interfaccia (conferma live, HARD KILL, START/STOP, prezzo su ogni intervallo, badge notizie). Vedi [docs/CONTROLLO-FINALE.md](docs/CONTROLLO-FINALE.md).

## Sicurezza e privacy

- Chiavi nel Keychain con Face ID (`biometryCurrentSet`, solo questo dispositivo): se cambiano i volti o le impronte registrati vanno reinserite.
- Report e dataset cifrati (`completeFileProtection`) ed esclusi dai backup.
- Il widget non mostra importi, salvo attivazione in SISTEMA.
- Una chiave API dentro un'app resta una credenziale lato client: usa chiavi con privilegi minimi e ruotale.

## Limiti reali

- Nessuna app iOS resta attiva 24/7: la giornaliera è pensata per questo (stop sul broker), la notte usa ordini d'asta che restano sul broker, la veloce richiede l'app aperta.
- Con un conto piccolo (1.000 $) circa il 44% dei segnali della giornaliera viene saltato perché 1 azione costa troppo; il rendimento percentuale cambia poco (studio `piccolo`).
- I backtest descrivono il passato; il paper trading non dimostra rendimenti futuri. Il live può perdere più del rischio teorico in caso di gap o rifiuti del broker.

## Riferimenti ufficiali

- Kimi K3.1 Pro: https://platform.moonshot.ai/docs/guide/kimi-k3-1-pro-quickstart
- Kimi JSON Mode: https://platform.moonshot.ai/docs/guide/use-json-mode-feature-of-kimi-api
- Alpaca streaming: https://docs.alpaca.markets/us/docs/streaming-market-data
- Alpaca ordini: https://docs.alpaca.markets/us/docs/orders-at-alpaca
- XcodeGen Project Spec: https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md
- Swift Concurrency: https://docs.swift.org/latest/documentation/the-swift-programming-language/concurrency
