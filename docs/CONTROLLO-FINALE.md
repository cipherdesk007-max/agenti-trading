# Controllo finale del codice · 12/11/2026

Revisione file per file di `Sources/`, con i rischi trovati e i test che li
coprono. Commit di questo giro: `c4e3876` (niente `try!`/`fatalError`, niente
force-unwrap su subscript, `AlpacaService` testabile, nuovi test HTTP e
parametrici), `3f354ff`/`d490d96` (fix compilazione test mock).

Non è scritto da nessuna parte che l'app sia "senza bug" o "perfetta": sotto c'è
esattamente cosa è stato verificato e cosa no.

## 1. Tabella file per file

| File | Cosa fa | Rischi trovati (e stato) | Test che lo copre |
|---|---|---|---|
| `Sources/App/QuantSwarmAlphaZeroApp.swift` | Entry point, container SwiftData, root view | `try!` nel fallback in-memory → rimosso: `container` è opzionale, fallback a catena con `try?` (`c4e3876`) | Nessuno diretto (UI); build CI + UI test |
| `Sources/Core/QuantSwarmEngine.swift` | Motore: cicli, guard, registro, report, dataset | `modelContext` reso opzionale (`c4e3876`): se nessuno store si apre l'app gira senza persistenza locale | `EngineGuardsTests` (7 test: stop giornaliero, drawdown, auto-resume) |
| `Sources/Core/DailyCycle.swift` | Ciclo GIORNALIERA: segnali, Brain/Reviewer, ordini con stop, uscite | force-unwrap `market[key]!` → sostituito con iterazione dizionario (`c4e3876`) | `DailyCycleTests` (28 test: ordine doppio, timeout, stop mancante, esito, capital cap…) |
| `Sources/Core/DailyStrategy.swift` | Regole pure GIORNALIERA (SMA200/RSI2, stop 2,5 ATR, uscite) | Nessuno nuovo; logica pura | `DailyStrategyTests` (19 test) |
| `Sources/Core/NightCycle.swift` | Ciclo NOTTE: MOC/OPG, registro posizioni, riconciliazione orfane, calendario | force-unwrap `book.positions[$0]!` → `compactMap` (`c4e3876`) | `NightCycleTests` (24 test incl. orfane, OPG annullata, frazioni condivise, calendario festivi/mezze giornate, `testAllocateParametricBudgets`) |
| `Sources/Core/RiskRules.swift` | Sizing e precheck puri: tetto 25%, rischio per trade, lotti, tick | Nessuno nuovo; invarianti ora testati anche su 5 taglie di conto | `RiskRulesTests` (33 test incl. `testSizingParametricAccountSizes`, `testCappedCapitalParametricAccountSizes`) |
| `Sources/Core/QuantSwarmEngine.swift` (guard) | Stop giornaliero, drawdown, pause rete/batteria | — | `EngineGuardsTests` |
| `Sources/Services/AlpacaService.swift` | Tutta la Trading API: ordini, posizioni, calendario, aste, retry | Nessun test HTTP prima: aggiunto `init(credentials:session:)` e `Tests/AlpacaServiceTests.swift` (`c4e3876`) | `AlpacaServiceTests` (12 test: caso normale + 422 rifiutato, 404, risposta parziale, rete assente, decode fallita per ogni funzione che invia/annulla/chiude ordini) |
| `Sources/Services/KimiService.swift` | Chat Kimi, modelli, saldo crediti, parsing decisioni | Parsing con fallback; errori Kimi → nessun ordine (testato a livello ciclo) | `DailyCycleTests`: `testBrainFailureMeansNoOrders`, `testReviewerRejectionMeansNoOrders`, `testAlreadyDecidedTodayIsNotPaidAgain` |
| `Sources/Agents/MarketScoutAgent.swift` | Stream 1m + backfill REST, cache barre | Frame malformato scartato singolarmente (già gestito); force-unwrap su `marketBarsDate` in UI → fixata (`c4e3876`) | `MarketInsightTests` (candele, medie, stati) + `FilterTriggerTests` |
| `Sources/Agents/RiskExecutionAgent.swift` | Esecuzione risk: sizing → ordine → verifica | Doppio ordine evitato via `client_order_id` + recupero per id | `DailyCycleTests`: `testTimeoutRecoversOrderWithoutDuplicate`, `testTimeoutWithRejectedOrderIsNotAnEntry`, `testOrphanTakeProfitCancelledBeforeRestoringStop` |
| `Sources/Core/CandleStore.swift` | Storico candele; solo candele CHIUSE visibili a filtri/Kimi | Candela in formazione nascosta a mercato aperto | `DailyStrategyTests.testFormingBarDroppedWhileMarketOpen`, `MarketInsightTests.testRoundTripKeepsLast300Bars` |
| `Sources/Core/SessionReport.swift` | Report .txt solo a STOP/KILL/chiusura; uno solo | Scrittura solo fuori dal trading | `SessionReport` coperto indirettamente via engine; UI test report |
| `Sources/Core/DatasetExporter.swift`, `TradeExporter.swift` | Export JSONL/CSV | File cifrati, uno solo, eliminabili | — (I/O documentale; build CI) |
| `Sources/Core/EquityHistory.swift` | Curva capitale per conto vs SPY | Per conto separato; history cappata | `EquityHistoryTests` (6 test) |
| `Sources/Core/MarketBarsCache.swift`, `MarketInsight.swift`, `MarketInsight` | Cache barre disco, lettura in parole | Dati pubblici solo, esclusa dal backup | `MarketInsightTests` (7 test) |
| `Sources/Core/DiagnosticsCollector.swift`, `NotificationManager.swift` | MetricKit crash, notifiche locali | Nessun dato conto inviato a terzi | — (solo locale; build CI) |
| `Sources/Core/UpdateChecker.swift` | Sorgente AltStore/LiveContainer | URL da repo pubblico; nessuna scrittura | `UpdateCheckerTests` (4 test) |
| `Sources/Core/WidgetStatusBridge.swift`, `Sources/Widget/` | Snapshot read-only per widget via App Group | Widget non invia ordini | — (read-only; build CI) |
| `Sources/Managers/KeychainManager.swift` | Credenziali in Keychain con Face ID, ThisDeviceOnly | Nessuna chiave nel codice o nei log (verificato con grep: solo stringhe vuote `@State`) | `AccountsTests` (3 test, migrazione profili) |
| `Sources/Models/TradingModels.swift` | Modelli: ordini, posizioni, config, errori | `URL(string:)!` su costanti letterali (non modificabili a runtime) — lasciati, documentati qui | decode test in `RiskRulesTests.testAccountNumberIsDecoded` |
| `Sources/Views/*` | UI (design 1.5.0) | force-unwrap su subscript in `buyableRow` → fixata (`c4e3876`); `URL(string:)!` su link costanti | `UITests/CockpitUITests.swift` |

## 2. Cosa può andare storto, per modalità

### GIORNALIERA
| Scenario | Copertura |
|---|---|
| Ordine doppio dopo timeout della risposta | `testTimeoutRecoversOrderWithoutDuplicate`, `testTimeoutWithRejectedOrderIsNotAnEntry` |
| Posizione senza stop (stop caduto) | `testMissingStopIsRestored`, `testCoveredPositionGetsNoExtraStop`, `testOrphanTakeProfitCancelledBeforeRestoringStop` |
| Kimi/Reviewer giù o risposta malformata | `testBrainFailureMeansNoOrders`, `testReviewerRejectionMeansNoOrders`, `testBrokerDownAbortsWithoutKimi` |
| App chiusa a metà giornata | stop/target GTC restano sul broker; riapertura = controllo immediato (`testExitDeferredWhenMarketClosed` per la logica) |
| Cambio conto | `AccountsTests`: registro per conto + migrazione (`testDailyBookIsPerAccountAndMigratesLegacy`) |
| Conto piccolo / ETF fuori capitale | `testUnaffordableCandidateNeverReachesKimi`, `testTooSmallAccountIsRejected`, `testCanBuyOneShareUsesFreeCashNotCapital`, parametrici 500–1M |
| Conto grande | `testCapitalCapScalesRiskAndPositionToBotCapital`, `testCappedCapitalParametricAccountSizes` |
| Conto con posizioni non del bot | `testPositionsOutsideTheBotDoNotCountAsBotExposure` |
| Doppia decisione stesso giorno a pagamento | `testAlreadyDecidedTodayIsNotPaidAgain`, `testNoSignalMeansZeroKimiCalls`, `testZeroCreditsOnlyOnKimiStages` |
| Uscita a SMA5 / stop / 10 giorni | `testExitAboveSMA5ClosesWithRealFillPrice`, `testFailedExitRestoresStop`, `testStoppedOutPositionIsRemovedFromBook`, `testExitAfterTenTradingDays` |
| Stop giornaliero / drawdown | `EngineGuardsTests`: `testDailyStopTriggersOnLoss`, `testDailyStopMeasuredOnBotCapital`, `testDailyStopCountsWithdrawalAsLoss`, `testDrawdownLocksBelowFloor`, `testDrawdownFloorMeasuredOnBotCapital` |
| Rete assente | `AlpacaServiceTests.testNetworkAbsentNonHTTPResponseThrowsImmediately`, `testURLErrorIsRetriedThenThrows`; pausa automatica rete/batteria in `EngineGuardsTests`/motore |
| Ordine rifiutato dal broker (422) | `AlpacaServiceTests.testSubmitOrderRejected422ThrowsHTTPStatus`, `testRejectedAuctionOrderIsNotTreatedAsSuccess` (NOTTE) |

### NOTTE
| Scenario | Copertura |
|---|---|
| OPG annullata/rifiutata: azioni restano senza vendita | `testCanceledOPGIsClosedNextDayAndNotStacked`, `testRejectedAuctionOrderIsNotTreatedAsSuccess` |
| OPG eseguita: sparisce dal registro | `testExecutedOPGWithSharedSymbolClearsTheBook` |
| Giornaliera e notte sullo stesso simbolo | `testSellWindowSellsOnlyNightSharesWhenDailyOwnsSameSymbol`, `testLeftoverClosesOnlyNightSharesNotDailyOnes`, `testRequeuedOPGWithSharedSymbolSellsOnlyNightShares`, `testDailyPositionsAreNeverTouched` |
| Residuo da notte precedente (app non aperta la mattina) | `testLeftoverFromLastNightClosedBeforeNewBuy`, `testLeftoverClosesOnlyNightSharesNotDailyOnes` |
| Festivi / mezze jornadas / ordini d'asta nel giorno sbagliato | `testPhaseHolidayBlocksAuctionOrders`, `testPhaseEarlyCloseUsesCalendarClose`, `testHolidayCyclePlacesNoOrders` (calendario `/v2/calendar`, mai obbligatorio) |
| Conto piccolo usa i gemelli, mai oltre il budget | `testSmallAccountUsesTwinsAndStaysInBudget`, `testTinyBudgetBuysNothing`, `testAllocateParametricBudgets` (500–1M) |
| Conto grande | `testLargeAccountBuysOriginals`, `testAllocateParametricBudgets` |
| Misura executed-vs-asta | `testAuctionDiffIsMeasuredOnceAndReported`, `testAuctionMeasurementIsOptional` |
| Registro vecchio leggibile | `testNightBookDecodesLegacyFormatAndRoundTrips`, `testSellWindowLegacyEntryWithoutQuantitySellsAllHeld` |

### VELOCE (sperimentale)
| Scenario | Copertura |
|---|---|
| Trigger solo su candele chiuse | `testFormingBarDroppedWhileMarketOpen`, `FilterTriggerTests` (6 test: breakout con/senza volume, EMA cross, flat, downtrend) |
| Chiusura prima della chiusura mercato / guard | regole in `SystemSettingsView` + `NightCycleTests.testPhases`-style; flat-by-close in codice motore |
| Crediti: zero se nessun trigger | `FilterTriggerTests.testTooFewCandlesNeverTrigger` + `testZeroCreditsOnlyOnKimiStages` |

## 3. Verifiche automatiche fatte in questo giro

- **Zero `try!`, `fatalError`, `preconditionFailure` in `Sources/`**: verificato con
  grep dopo `c4e3876` (prima c'era un `try!` nel fallback SwiftData).
- **Nessuna chiave o segreto nel codice o nei log**: grep su pattern
  `api_key = "…"`, `secret = "…"`, chiavi private — solo `@State` vuoti in UI.
- **Force-unwrap su subscript/valori dinamici rimosse** (4 siti). Restano solo
  `URL(string:)!` su stringhe costanti letterali (non possono fallire).
- **Warning del compilatore**: la build CI compila in Swift 6 con errori di
  concorrenza come errori (vedi `nonisolated(unsafe)` nei test); build verde =
  nessun errore. I warning non bloccanti non sono conteggiati in CI: da controllare a mano nei log della build.
- **Test parametrici conti 500 / 1.000 / 10.000 / 100.000 / 1.000.000 USD**:
  `RiskRulesTests.testSizingParametricAccountSizes` (mai oltre budget, mai tetto
  25% o rischio superati, mai quantità zero/negative), `testCappedCapitalParametricAccountSizes`,
  `NightCycleTests.testAllocateParametricBudgets` (divisione NOTTE mai oltre il
  budget del 97%, mai quantità zero/negative, 4 famiglie già da $1.000).
- **Ogni funzione che invia/annulla/chiude ordini ha caso normale + errore**:
  `AlpacaServiceTests` copre `submitEntryWithStop` (GTC+stop), `submitBracket`
  (legs), `submitAuction` (MOC/OPG), `submitMarket`, `submitStop`, `cancelOrder`,
  `closePosition(ReturningOrder)`, `cancelAllAndFlatten` (via test HTTP), più
  rete assente, 422, 404, risposta parziale, decode fallita.

## 4. Cosa NON è stato verificato (da fare a mano, vedi docs/VERIFICHE.md)

- Comportamento su telefono reale (Face ID, notifiche, widget, SideStore/LiveContainer).
- Primo MOC/OPG reale su conto paper e storico ordini su Alpaca.
- Ripresa dopo app chiusa a metà ciclo, cambio conto live, pausa batteria < 20%.
- UI test su simulatore girano in CI, ma gli screenshot reali sono dell'altro revisore.
- I backtest (`tools/`, workflow `backtest`) girano separati: l'altro revisore lancia `quale=studi`.
- Nessuna verifica automatica che gli ordini GTC restino davvero attivi sul broker ad app chiusa: è una proprietà di Alpaca, verificabile solo su Alpaca (docs/VERIFICHE.md).
