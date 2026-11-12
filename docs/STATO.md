# Stato del progetto · QuantSwarm Alpha Zero

Aggiornato al 12/11/2026, versione **1.5.0 build 156** (commit `9f6c534` su `main`).
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

## Correzioni di sicurezza (12/11/2026, revisione esterna su 1.5.0 build 157 — tutte con test in `Tests/`)

- **NOTTE: conferma della vendita dallo stato dell'ordine OPG.** Il registro salva il `client_order_id` (`sellQueuedOrderId`): `filled` toglie la voce, `canceled`/`rejected`/`expired` resta come residuo. Prima la conferma veniva dal calo del detenuto, inaffidabile con la giornaliera sullo stesso simbolo.
- **NOTTE: MOC parziali e blocco famiglia.** Le MOC rifiutate vengono ritentate solo per le famiglie mancanti (col gemello); con un residuo su un simbolo della famiglia non si compra l'altro (niente SPY se resta SPYM).
- **VELOCE: flat-by-close** non annulla più gli stop protettivi (stop GTC d'emergenza) e non tocca i simboli del registro NOTTE.
- **NOTTE: finestre.** Weekend: OPG in coda a mercato chiuso fuori da 9:28–19:00 ET (anche sabato/domenica, per lunedì). Festivo infrasettimanale: nessuna asta. A mercato chiuso il wait copre tutta 9:28–19:00 ET (niente OPG dopo chiusure anticipate alle 13:00).
- **Studi `quale=studi`:** fix colonne MultiIndex di yfinance (`daily_study_lib.flat_by_field`/`load_series`) e `pipefail` nel workflow, così uno script in errore fa fallire il passo invece di pubblicare tabelle vuote. Da rilanciare a mano (403): le tabelle si riempiono al prossimo run.
- **Design dagli screenshot (build 157):** tile MERCATI uniformi e sentence case, STOP arancione vs CONTROLLA ORA primario, BROKER con stati in italiano e tipo/prezzo, "Traduci", SISTEMA con una sola riga sotto il selettore.

## Correzioni di sicurezza (11/11/2026, tutte con test in `Tests/`)

- **B1 · la notte vende solo le sue azioni.** Il registro notte ora salva anche la quantità (`NightPosition`, retrocompatibile con il vecchio formato). Prima l'OPG vendeva TUTTE le azioni del simbolo: con SPY/QQQ/IWM/GLD in entrambi i panieri svuotava le posizioni della giornaliera e il suo stop GTC residuo poteva aprire uno short. La chiusura "leftover" del mattino fa lo stesso: vende solo la quantità della notte.
- **B2 · mai ripresa automatica su conto LIVE.** Il motore riparte da solo solo su paper; in live la sessione parte dal bottone con la conferma.
- **B3 · flat-by-close fallito = stop GTC di emergenza.** Se la chiusura della veloce fallisce a T-10 minuti e non si ripara entro la seduta, la posizione resterebbe overnight nuda (le gambe del bracket `day` scadono alla chiusura). Ora si rimette subito uno stop GTC (chiusura − 2,5 ATR, come la giornaliera); se anche quello fallisce: notifica "POSIZIONE SENZA STOP".
- **B4 · un ordine rifiutato non è un invio riuscito.** Il recupero per `client_order_id` ora controlla lo stato: `rejected`/`canceled`/`expired` non bloccano il retry né producono ricevute (notte, giornaliera e veloce).
- **B5 · circuit breaker estratti e testati.** Stop giornaliero e drawdown sono formule pure in `RiskRules` con test. Limite noto e documentato: un prelievo dal conto appare come perdita (con le API disponibili non è distinguibile).
- **B6 · prefilter della veloce sul contante libero vero** (capitale meno esposizione aperta): meno chiamate Kimi a vuoto.
- **R5 · l'esito dell'uscita si registra fino a 200 posizioni indietro** (prima 50, con filtro in memoria).
- **R6 · rimosso `riskRewardRatio`** (codice morto).
- **R7 · OPG annullata all'asta = residuo chiuso, non azioni orfane.** Dopo l'invio dell'OPG la posizione resta nel registro con `sellQueuedDay`/`sellQueuedHeld` e viene cancellata solo quando il detenuto scende di almeno la quantità; se l'ordine sparisce senza eseguirsi, la fase di acquisto la chiude a mercato (solo la quantità della notte) e i nuovi acquisti non si sommano al residuo. La voce legacy (senza quantità) resta a una sola vendita: esce subito dopo l'invio dell'OPG. Test in `Tests/NightCycleTests.swift`.
- Studio `tools/backtest_overnight_fraction.py` (runner `overnight`, incluso nel controllo mensile): quanto CAGR e perdita massima **sul conto** cambiano se la NOTTE investisse solo una frazione f del capitale ogni notte (f = 97% è il comportamento attuale, cashBuffer 3%). Tabella attesa: f, CAGR, perdita max, Sharpe, CAGR/|perdita| per f in {97%, 75%, 50%, 25%, 10%}, più la variante sugli ultimi 2 anni. **Criterio di decisione** (dal docstring dello script): tenere la frazione più piccola che mantiene il CAGR sul conto almeno metà di quello a frazione piena dopo i costi; scartare le frazioni con CAGR ≈ 0 dopo i costi; la perdita massima sul conto deve scendere almeno in proporzione a f. **Attenzione al multi-testing**: con 5 frazioni provate lo Sharpe massimo è gonfiato (Deflated Sharpe, Bailey & López de Prado 2014, https://ssrn.com/abstract=2460551), quindi la scelta si fa sul rapporto CAGR/perdita massima sull'intero periodo e sul sotto-periodo recente, non sul picco di Sharpe. **Stato**: lo script non ha ancora girato in CI (il controllo mensile parte il 1° dicembre; il dispatch manuale con il token in uso dà 403 — va lanciato a mano da Actions → "Backtest filtro" → `quale` = `overnight`). Fino ad allora la frazione resta 97%: la protezione resta il tetto del capitale.

## Da verificare sul telefono o sul conto vero

- Checklist pronta in [VERIFICHE.md](VERIFICHE.md): 10 controlli con passo nell'app, cosa guardare su Alpaca, atteso e "se è diverso" (MOC/OPG, stop GTC, riapertura, cambio conto, pausa batteria, TRADUCI, registro vecchio, `reasoning_effort`, segnali di oggi).
- La NOTTE è testata con broker finto: va confermato che Alpaca paper accetti gli ordini `cls` e `opg` e li esegua alle aste.
- Con R7, se una OPG in coda viene annullata senza eseguirsi le azioni restano nel registro marcate "in coda" e il giorno dopo vengono chiuse a mercato (solo la quantità della notte) prima di ricomprare. Da confermare su paper che non produca doppie vendite.
- Che il registro notte scritto dalla versione precedente (senza quantità) si rilegga: vende tutto il detenuto del simbolo **una sola volta**, poi il registro passa al formato nuovo con quantità.
- Tabella dello studio R1 (frazione NOTTE): primo run in CI il **1° dicembre** (cron mensile) o dispatch manuale di `overnight` da Actions. Fino ad allora la frazione resta 97%; criterio di decisione e Deflated Sharpe documentati sopra.
- `reasoning_effort` medium accettato dal modello Kimi in uso (altrimenti l'app passa da sola a low).
- Il foglio TRADUCI di Apple (non si apre sul simulatore).
- Durata reale della prova: con 1.000 $ circa un segnale a settimana nella giornaliera; servono 20–30 trade chiusi prima di giudicare.
- Documenti di sessione, proposte e design: [REVISIONE-AI.md](REVISIONE-AI.md), [PROPOSTE.md](PROPOSTE.md), [DESIGN.md](DESIGN.md), [CONTROLLO-FINALE.md](CONTROLLO-FINALE.md), [GUIDA.md](GUIDA.md), [RELEASE-NOTE.md](RELEASE-NOTE.md).
- Design 1.5.0 **completo** (solo viste, un commit per schermata): Theme, CRUSCOTTO, MERCATI+GRAFICO, DETTAGLI, BROKER, SISTEMA, LOGIN. Da rifare dopo il rilascio: gli screenshot del ramo `screenshot` (ora sono pre-1.5.0, copiati in `docs/screenshots/` per la guida).

## Come verificare in modo indipendente

- Test: 166 unitari (CI a ogni push, "Unsigned iOS IPA": +12 HTTP AlpacaServiceTests con mock, +3 parametrici conti 500–1M, +8 revisione esterna 1.5.0: OPG per stato ordine, MOC parziali, blocco famiglia, finestre weekend/festivo/mezza giornata, +5 FlatByCloseTests revisione build 161: flat-by-close VELOCE che annulla tutti gli ordini del simbolo e verifica l'annullo, chiude a mercato, rimette lo stop d'emergenza `qsv-emg-` mai duplicato) + 5 di interfaccia in `UITests/` (solo a mano, opzione `uitest`). Tabella file/rischi/test in [CONTROLLO-FINALE.md](CONTROLLO-FINALE.md).
- Strategie: Actions → "Backtest filtro" → `quale` = `app`, `piccolo`, `overnight`, `segnali`, `studi`, `oggi`.
- Ordini: confronta il report di sessione dell'app con lo storico ordini di Alpaca.
- Indicatori: SMA200 e RSI(2) di Wilder su TradingView o Yahoo devono coincidere con la tabella di `oggi`.
