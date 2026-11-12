# Stato del progetto · QuantSwarm Alpha Zero

Aggiornato al 11/11/2026, versione **1.3.0 build 130** (commit su `main`).
Questo file è per chi studia o rivede il progetto (persone o AI): cosa fa l'app, come è collegata, cosa è già stato deciso con i dati e cosa resta aperto.

## Vincoli che non cambiano

- **Solo tre API**: Alpaca Trading API (conto, ordini, posizioni, orologio), Alpaca Market Data API (barre IEX/SIP, ultimo prezzo, notizie Benzinga su `/v1beta1/news`), Kimi/Moonshot (`api.moonshot.ai`, risposte JSON con schema). Nessun servizio a pagamento in più, nessun server.
- **L'app gira solo aperta** su iPhone 15 Pro Max, installata con SideStore e LiveContainer. Tutto ciò che protegge il capitale deve stare sul broker (stop GTC, ordini d'asta).
- **Paper prima del live**: conto paper da 1.000 $ per la giornaliera, secondo conto paper per la notte.
- **Il capitale segue il saldo del conto** (`RiskRules.capped`), con un limite manuale opzionale.
- **Ogni modifica alla strategia va provata** con un backtest in `tools/` prima di entrare nell'app.
- Commit senza righe Co-Authored-By né link di sessione. CI veloce: test di interfaccia e screenshot solo a mano.

## Mappa del codice

| Parte | File | Ruolo |
|---|---|---|
| Motore | `Sources/Core/QuantSwarmEngine.swift` | Stato pubblicato per la UI, avvio/stop, ciclo ogni 15 min (`dailyLoop`), pause (rete, batteria < 20%), heartbeat, background/foreground con riconciliazione, conti multipli, kill switch |
| Giornaliera | `Sources/Core/DailyStrategy.swift`, `Sources/Core/DailyCycle.swift` | Indicatori su barre chiuse, candidati, uscite, registro per conto (`DailyBookStore`), registro ombra e pagella (`ShadowSummary`), ciclo puro testabile con broker e Brain finti |
| Notte | `Sources/Core/NightCycle.swift` | Finestre d'asta (`NightStrategy.phase`), divisione del capitale in azioni intere (`allocate`), registro per conto (`NightBookStore`), ciclo puro testabile |
| Veloce | dentro `QuantSwarmEngine.swift` | Intraday 15m con Kimi, flat prima della chiusura. Sperimentale |
| Rischio | `Sources/Core/RiskRules.swift` | Capitale del bot, quantità, tetto 25%, rischio per trade, 1 azione comprabile |
| Alpaca | `Sources/Services/AlpacaService.swift` | REST trading + dati + notizie; `AlpacaBroker` adatta il servizio a `BrokerClient` e `NightBroker` |
| Kimi | `Sources/Services/KimiService.swift` | Brain e Reviewer della giornaliera (JSON con schema, `reasoning_effort` medium con ripiego low), decide/review/analyze della veloce |
| Promemoria | `Sources/Services/NotificationManager.swift` | Giornaliera 15:30 NY; notte 8:45 e 15:15 NY |
| Interfaccia | `Sources/Views/*.swift` | CRUSCOTTO, MERCATI e grafici, DETTAGLI (curva del capitale, pagella), BROKER, SISTEMA, conti |
| Test | `Tests/*.swift` | Rischio, strategia, ciclo giornaliero, ciclo notte, pagella, conti, aggiornamenti |
| Studi | `tools/*.py`, `.github/workflows/backtest.yml` | Backtest con yfinance; controllo mensile automatico |

Catena della giornaliera: Scout (conto, posizioni, ordini, barre) → Strategia (regole, zero crediti) → Analyst (quadro) → Brain (Kimi) → Reviewer (Kimi avversario) → Rischio (codice) → Esecutore (limite + stop + target sul broker). Kimi viene chiamato solo per candidati che il capitale può comprare. Brain e Reviewer ricevono indicatori, ultime 20 chiusure, correlazione a 60 sedute e notizie delle ultime 48 ore.

## Decisioni prese con i dati

| Tema | Risultato | Decisione |
|---|---|---|
| Regola d'ingresso giornaliera | Batteria di 6 regole (`segnali`): RSI2 Sharpe 0,43; IBS 0,31; 7MIN 0,35; 3GIU 0,36; UNIONE 0,26; DOPPIA 0,38 | Resta RSI2 |
| Giornaliera, regole esatte dell'app (`app`) | 2006–oggi +2,3% annuo, perdita massima −9%, Sharpe 0,43; batte ingressi casuali; 18 varianti vicine tutte positive | Parametri invariati |
| Conto piccolo (`piccolo`) | 1.000 $: +1,7% annuo, Sharpe 0,45, 44% dei segnali saltati; 5.000 $: nessun salto | Va bene così per la prova |
| Gemelli economici nella giornaliera | 1.000 $: Sharpe 0,37 contro 0,45 senza gemelli | Provati e tolti |
| Intraday da 20 minuti a 1 ora | Filtro 15m, ORB, VWAP, momentum della prima ora, rimbalzo di fine giornata: tutti negativi dopo i costi | Veloce resta sperimentale, sconsigliata con soldi veri |
| Overnight (`overnight`) | SPY/QQQ/IWM/GLD a peso uguale, costi 0,003% per lato: +8,0% annuo, perdita massima −22%, Sharpe 0,81; ultimi 2 anni +13,9%; gemelli positivi | Costruita la modalità NOTTE |
| Secondo modello locale (Qwen3.5 su iPhone con MLX) | Possibile tecnicamente; pochi segnali da giudicare, rischio di memoria sotto LiveContainer | Rimandato: si riconsidera se la pagella mostra che il Brain sbaglia |

## Correzioni di sicurezza (11/11/2026, tutte con test in `Tests/`)

- **B1 · la notte vende solo le sue azioni.** Il registro notte ora salva anche la quantità (`NightPosition`, retrocompatibile con il vecchio formato). Prima l'OPG vendeva TUTTE le azioni del simbolo: con SPY/QQQ/IWM/GLD in entrambi i panieri svuotava le posizioni della giornaliera e il suo stop GTC residuo poteva aprire uno short. La chiusura "leftover" del mattino fa lo stesso: vende solo la quantità della notte.
- **B2 · mai ripresa automatica su conto LIVE.** Il motore riparte da solo solo su paper; in live la sessione parte dal bottone con la conferma.
- **B3 · flat-by-close fallito = stop GTC di emergenza.** Se la chiusura della veloce fallisce a T-10 minuti e non si ripara entro la seduta, la posizione resterebbe overnight nuda (le gambe del bracket `day` scadono alla chiusura). Ora si rimette subito uno stop GTC (chiusura − 2,5 ATR, come la giornaliera); se anche quello fallisce: notifica "POSIZIONE SENZA STOP".
- **B4 · un ordine rifiutato non è un invio riuscito.** Il recupero per `client_order_id` ora controlla lo stato: `rejected`/`canceled`/`expired` non bloccano il retry né producono ricevute (notte, giornaliera e veloce).
- **B5 · circuit breaker estratti e testati.** Stop giornaliero e drawdown sono formule pure in `RiskRules` con test. Limite noto e documentato: un prelievo dal conto appare come perdita (con le API disponibili non è distinguibile).
- **B6 · prefilter della veloce sul contante libero vero** (capitale meno esposizione aperta): meno chiamate Kimi a vuoto.
- **R5 · l'esito dell'uscita si registra fino a 200 posizioni indietro** (prima 50, con filtro in memoria).
- **R6 · rimosso `riskRewardRatio`** (codice morto).
- Studio nuovo in `tools/backtest_overnight_fraction.py` (runner `overnight`): quanto CAGR e perdita massima cambiano se la NOTTE investisse solo una frazione del conto. La frazione resta 97% finché i numeri non dicano altro: la protezione resta il tetto del capitale.

## Da verificare sul telefono o sul conto vero

- La NOTTE è testata con broker finto: va confermato che Alpaca paper accetti gli ordini `cls` e `opg` e li esegua alle aste.
- Con B1, se una OPG in coda venisse annullata senza eseguirsi (asta saltata), le azioni resterebbero sul conto ma fuori dal registro notte: il ciclo non le rivende più. Capire se capita davvero su paper (le OPG a mercato eseguono in asta, è raro) e in caso decidere una riconciliazione.
- Che il registro notte scritto dalla versione precedente (senza quantità) si rilegga: vende tutto il detenuto del simbolo finché non passa una notte.
- `reasoning_effort` medium accettato dal modello Kimi in uso (altrimenti l'app passa da sola a low).
- Il foglio TRADUCI di Apple (non si apre sul simulatore).
- Durata reale della prova: con 1.000 $ circa un segnale a settimana nella giornaliera; servono 20–30 trade chiusi prima di giudicare.

## Come verificare in modo indipendente

- Test: GitHub Actions → "Unsigned iOS IPA" (a ogni push).
- Strategie: Actions → "Backtest filtro" → `quale` = `app`, `piccolo`, `overnight`, `segnali`, `oggi`.
- Ordini: confronta il report di sessione dell'app con lo storico ordini di Alpaca.
- Indicatori: SMA200 e RSI(2) di Wilder su TradingView o Yahoo devono coincidere con la tabella di `oggi`.
