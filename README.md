# QuantSwarm-Alpha-Zero

App iOS 17+ (Swift 6, SwiftUI, SwiftData) di trading con agenti AI: Kimi via API sceglie e contesta, il codice decide quantità e rischio, Alpaca esegue. Nessuna credenziale nel repository.

## Modalità

| Modalità | Cosa fa | Stato |
|---|---|---|
| **GIORNALIERA · ETF** (default) | 15 ETF (SPY, QQQ, IWM, DIA, 9 settori, GLD, TLT). Ingresso se chiusura > SMA200 e RSI(2) < 10. Stop a 2,5 ATR **sul broker, GTC**: resta attivo ad app chiusa. Uscita a chiusura > SMA5 o dopo 10 giorni. Un controllo subito, poi ogni 15 minuti ad app aperta, e a ogni riapertura. | Validata: batte ingressi casuali nel backtest 2006–oggi |
| **VELOCE · SPERIMENTALE** | Candele 15m, filtro long, bracket in giornata, chiusura totale 10 minuti prima della fine della seduta. Serve l'app sempre aperta. | Nei backtest perde e non batte il caso |

## Catena agenti

Scout (dati, conto, posizioni) → Strategia (segnali a regole, zero crediti) → Analyst (quadro di mercato) → Brain (Kimi sceglie) → Reviewer (Kimi cerca motivi per bocciare) → Rischio (codice: quantità, stop, limiti) → Esecutore (ordine con stop sul broker). Se la Strategia non trova segnali, Kimi non viene chiamato. Ogni errore di Kimi o del broker = nessun ordine. Lo stato di ogni agente è nel CRUSCOTTO.

## Regole di rischio (in codice, testate)

**Capitale del bot** (default 10.000 USD, da 500 a 1.000.000, paper e live; in SISTEMA si vede quanti dei 15 ETF può comprare con almeno 1 azione intera): il bot non impegna mai di più e tutti i limiti si calcolano su questa cifra, non sull'intero conto. Rischio max 1% per trade (impostabile 0,25–2%, mai oltre 5%), posizione max 25% del capitale, max 3 posizioni, stop giornaliero e stop drawdown 10% del capitale con sblocco manuale, solo acquisti (niente short), limite giornaliero di spesa Kimi. In DETTAGLI la **curva del capitale** confronta il bot con SPY compra-e-tieni (un punto per seduta, paper e live separati).

## Verifica indipendente

- **Test automatici**: a ogni push GitHub Actions esegue i test XCTest (regole di rischio, filtro, strategia giornaliera) su simulatore; se un test fallisce l'IPA non viene pubblicata.
- **Backtest**: Actions → "Backtest filtro" → Run workflow (`tutti`, `giornaliero`, `intraday15`, `veloce5m`). Codice in `tools/`. I risultati sono nel riepilogo del run.
- **Broker**: confronta il registro dell'app con l'estratto conto Alpaca.

## Build e IPA

1. Push su `main` con modifiche a `Sources/`, `Tests/`, `project.yml` o al workflow: GitHub Actions genera il progetto con XcodeGen, esegue i test su simulatore e, solo se passano, compila l'IPA non firmata.
2. L'IPA viene pubblicata nella release `ultima` (`QuantSwarm-Alpha-Zero.ipa`).
3. Screenshot dell'interfaccia: Actions → "Unsigned iOS IPA" → Run workflow con "screenshot" attivo; finiscono nella release `screenshot`.

Build locale su macOS:

```sh
brew install xcodegen
xcodegen generate --spec project.yml
xcodebuild -project QuantSwarmAlphaZero.xcodeproj -scheme QuantSwarmAlphaZero -destination 'platform=iOS Simulator,name=iPhone 16' test
```

## Avvio

1. Inserisci la chiave Kimi (`https://api.moonshot.ai/v1`) e le chiavi Alpaca, prima in **paper**. Il passaggio al live richiede di scrivere `LIVE`, e ogni START in live chiede conferma.
2. Modalità GIORNALIERA: premi START. L'app controlla i 15 ETF, chiama Kimi solo se c'è un segnale, mette ordine limite + stop GTC. Poi puoi chiuderla: riaprendola parte subito un controllo (o usa CONTROLLA ORA).
3. `STOP` ferma il motore senza toccare le posizioni. `HARD KILL SWITCH` annulla tutti gli ordini e chiude tutte le posizioni del conto.

## Protezioni (in codice)

- **Mai una posizione senza stop**: a ogni ciclo ogni posizione della giornaliera deve avere uno stop sul broker, altrimenti viene rimesso. Se un'uscita fallisce dopo aver annullato lo stop, lo stop viene ripristinato (solo se la posizione esiste ancora, per non aprire uno short).
- Uscite a regole solo a mercato aperto: a mercato chiuso lo stop resta.
- Ingressi eseguiti in parte: il giorno dopo il residuo viene annullato e lo stop copre solo la quantità comprata.
- La chiusura di fine giornata della modalità veloce tocca solo le sue posizioni, mai quelle della giornaliera.
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
- **Test**: unitari (rischio, strategia, ciclo con broker e Kimi finti) e di interfaccia (conferma live, HARD KILL, START/STOP).

## Sicurezza e privacy

- Chiavi nel Keychain con Face ID (`biometryCurrentSet`, solo questo dispositivo): se cambiano i volti o le impronte registrati vanno reinserite.
- Report e dataset cifrati (`completeFileProtection`) ed esclusi dai backup.
- Il widget non mostra importi, salvo attivazione in SISTEMA.
- Una chiave API dentro un'app resta una credenziale lato client: usa chiavi con privilegi minimi e ruotale.

## Limiti reali

- Nessuna app iOS resta attiva 24/7: la giornaliera è pensata per questo (stop sul broker), la veloce richiede l'app aperta.
- I backtest descrivono il passato; il paper trading non dimostra rendimenti futuri. Il live può perdere più del rischio teorico in caso di gap o rifiuti del broker.

## Riferimenti ufficiali

- Kimi K3.1 Pro: https://platform.moonshot.ai/docs/guide/kimi-k3-1-pro-quickstart
- Kimi JSON Mode: https://platform.moonshot.ai/docs/guide/use-json-mode-feature-of-kimi-api
- Alpaca streaming: https://docs.alpaca.markets/us/docs/streaming-market-data
- Alpaca ordini: https://docs.alpaca.markets/us/docs/orders-at-alpaca
- XcodeGen Project Spec: https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md
- Swift Concurrency: https://docs.swift.org/latest/documentation/the-swift-programming-language/concurrency
