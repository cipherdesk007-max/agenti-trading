# Revisione AI · 12/11/2026

Sessione di continuazione in 4 punti, un commit su `main` per ognuno (niente righe
Co-Authored-By). Dove un commit toccava `Sources/`/`Tests/` si è aspettata la build
verde prima del punto successivo; i commit solo-docs non avviano la workflow IPA
(filtro sui path in `.github/workflows/ios-build.yml`).

| Punto | Commit | Build CI |
|---|---|---|
| 1 · Riconciliazione NOTTE (orfane) | `0f523ab` | run 43132855386 → **success** (test su simulatore: success, 13m16s) |
| 2 · Studio frazione NOTTE (R1, solo analisi) | `0527fda` | nessuna build (docs) — ultima build verde: 43132855386 |
| 3 · Verifiche su telefono/conto | `47a0624` | nessuna build (docs) |
| 4 · Proposte (non implementate) | `f33adfa` | nessuna build (docs) |

## Punto 1 · Riconciliazione NOTTE — fatto, con test

- `Sources/Core/NightCycle.swift`: `NightPosition` guadagna `sellQueuedDay`/`sellQueuedHeld`.
  Dopo l'invio dell'OPG la posizione **resta** nel registro marcata "in coda" e viene
  cancellata solo quando il detenuto sul conto è sceso di almeno la quantità (o è zero).
  Nella fase di acquisto, una posizione di un giorno precedente ancora sul conto e senza
  ordine di vendita aperto è un residuo: si chiude a mercato **solo quella quantità**
  (`ownedQty` ora sottrae anche quanto già venduto dalla coda) e i nuovi acquisti
  escludono i simboli ancora in registro, così non si compra due volte sopra.
  Registro vecchio (pre-B1, simbolo→giorno) e formato B1 (senza coda) sempre leggibili.
- `Tests/NightCycleTests.swift`: test (a) `testCanceledOPGIsClosedNextDayAndNotStacked`
  (OPG annullata → il giorno dopo chiusura a mercato del residuo, poi ricompra, mai doppia
  esposizione — verificato anche l'ordine cronologico degli invii), (b)
  `testExecutedOPGWithSharedSymbolClearsTheBook` (OPG eseguita → sparisce dal registro),
  (c) coperti dagli esistenti `testSellWindowSellsOnlyNightSharesWhenDailyOwnsSameSymbol`
  e `testLeftoverClosesOnlyNightSharesNotDailyOnes`, aggiornati alla nuova marcatura
  "in coda"; B4 e round-trip del registro estesi al nuovo campo.
- `CHANGELOG.md` [Non rilasciato] e `docs/STATO.md` (nuovo punto R7, voce "da verificare"
  aggiornata).

## Punto 2 · Studio frazione NOTTE (R1) — analisi, app invariata

- Commit `0527fda`: `docs/STATO.md` ora riporta il criterio di decisione (frazione più
  piccola con CAGR sul conto ≥ metà di quello a frazione piena dopo i costi; scartare
  CAGR ≈ 0; perdita max che scenda almeno in proporzione a f), la tabella attesa
  (f = 97/75/50/25/10% → CAGR, perdita max, Sharpe, CAGR/|perdita|, più ultimi 2 anni)
  e l'avvertenza Deflated Sharpe (Bailey & López de Prado 2014, https://ssrn.com/abstract=2460551):
  con 5 frazioni provate non si sceglie sul picco di Sharpe.
- **Blocco documentato**: il dispatch di "Backtest filtro" con il token in uso dà
  HTTP 403 sull'endpoint `/actions/workflows/.../dispatches`; la sandbox non ha rete,
  quindi `tools/backtest_overnight_fraction.py` non può girare in locale. Lo script non
  ha ancora girato in CI (i run "Overnight" dell'11/11 precedono l'aggiunta dello step,
  commit `c36f6dd`). Prossimo run automatico: cron mensile del 1° dicembre (`mensile`
  include overnight + fraction). In alternativa, a mano: Actions → "Backtest filtro" →
  Run workflow → `quale` = `overnight`, risultati nel riepilogo del run.
- **Tabella**: non ancora disponibile. Nessuna frazione proposta ora: senza numeri
  resta 97% (comportamento attuale). La decisione resta all'utente.

## Punto 3 · Verifiche su telefono e conto — pronte, da eseguire a mano

- Commit `47a0624`: `docs/VERIFICHE.md`, 10 controlli, ognuno con passo nell'app, cosa
  guardare su Alpaca (Orders/Positions, id `qsn-b-`/`qsn-s-`/`qsn-l-`), risultato atteso
  e cosa significa se è diverso: primo MOC, prima OPG (compreso il caso annullata, R7),
  stop GTC della giornaliera, ripresa dopo app chiusa (no duplicati), cambio conto,
  pausa batteria/rete, TRADUCI, registro notte della build precedente, `reasoning_effort`
  medium, segnali di oggi (`oggi`) contro TradingView/Yahoo.

## Punto 4 · Proposte — solo elenco, niente codice

- Commit `f33adfa`: `docs/PROPOSTE.md`, 5 idee che usano solo le 3 API esistenti, ognuna
  con guadagno atteso, rischio e prova in backtest/ombra prima di entrare in app:
  trailing stop GTC; pesi risk-parity nella NOTTE; frazione NOTTE adattiva (da R1);
  filtro "evento" 48h sulle notizie prima dell'ingresso; badge notizie 48h nel CRUSCOTTO
  per posizioni aperte (display puro, nessun ordine).

## Resta aperto

- Tabella R1 e decisione sulla frazione (punto 2): in attesa del run CI del 1° dicembre
  o del dispatch manuale.
- Le 10 verifiche di `docs/VERIFICHE.md` sul dispositivo e sul conto paper.
- Prova paper in corso: servono ~20–30 trade chiusi prima di giudicare la pagella
  (ShadowSummary) di Kimi.
- R7 da confermare su paper: che la chiusura del residuo non produca doppie vendite.
- Limite noto di R7: se la giornaliera vende azioni dello stesso simbolo, il calo del
  detenuto può far cancellare la voce di registro della notte prima che l'OPG esegua
  (le azioni resterebbero orfane). Con i dati disponibili non è distinguibile, perché il
  registro giornaliera non registra le quantità: da valutare solo se capita davvero su paper.

## Non ho potuto verificare in questa sessione

- Compilazione e test in locale: la sandbox non ha Xcode/Swift — i test sono stati
  verificati solo dalla CI (run 43132855386, success, "Run risk tests" passato).
- Backtest in locale: la sandbox non ha accesso di rete (yfinance non scarica i dati).
- Dispatch manuale dei workflow: 403 con il token `GH_TOKEN` in uso.
- UI reale, TRADUCI, Face ID, notifiche, aste Alpaca: richiedono il dispositivo e il conto.

---

# Giro finale 1.4.0 · 12/11/2026

## Punto 1 · Revisione diff c86d1b1..HEAD e percorsi trade

Riletti `Sources/` e `Tests/` dalla build 130 a oggi e percorsi end-to-end:
- **GIORNALIERA** (`DailyCycle.swift` + `runDailyCycle`): scout → manutenzione registro → cancello residui ingressi → protezione stop (mai posizione senza stop) → uscite a regole solo a mercato aperto (annulla stop, chiude a mercato, se fallisce ripristina lo stop solo se la posizione esiste ancora) → segnali → prefilter capitale → Kimi → reviewer → sizing → ordine limite+stop+target GTC con recupero per `client_order_id` solo se vivo (B4).
- **VELOCE** (`analysisLoop` in `QuantSwarmEngine.swift`): filtro gratuito su candela chiusa → prefilter contante libero (B6) → Kimi → race guard (stop/background/pausa) → precheck regole → reviewer → bracket `day` → flat-by-close a T-10 solo sulle sue posizioni, con ripristino stop GTC se la chiusura fallisce (B3).
- **NOTTE** (`NightCycle.swift`): finestre asta, registro per conto, R7.

**Bug dimostrato trovato e corretto** (commit `ff3db12`): regressione introdotta da R7 sulle voci legacy del registro notte (senza quantità) — restavano in coda e, con la giornaliera sullo stesso simbolo, venivano ri-messe in coda ogni sera vendendo TUTTO il detenuto. Fix: la voce legacy esce subito dopo l'invio dell'OPG (una sola vendita, come prima di R7); il re-invio con quantità note vende solo le azioni della notte. Test: `testSellWindowLegacyEntryWithoutQuantitySellsAllHeld` esteso e `testRequeuedOPGWithSharedSymbolSellsOnlyNightShares` nuovo. Fix di compilazione test `c3d6a17` (`await` fuori dall'autoclosure di XCTAssert).

Build: run 43136621316 **failure** (compilazione test) → fix → run 43137804159 su `c3d6a17` **success** (test su simulatore passati).

## Punto 2+3 · Versione 1.4.0

- `311f9c6`: `MARKETING_VERSION` 1.4.0 in `project.yml` (app e widget); CHANGELOG `[Non rilasciato]` → `[1.4.0 · build N] - 2026-11-12`. Build run 43139568790 **success** → run_number **137**.
- `6f26d33`: CHANGELOG con `build 137`.

## Punto 4 · Documentazione dello stato reale

- `972bc96`: README e `docs/STATO.md` a **1.4.0 build 137** (12/11/2026); test: **132 unitari** (CI a ogni push) + **3 UI** (solo a mano); "da verificare" aggiornato con puntatore a `VERIFICHE.md`, stato R1 (primo run 1° dicembre o dispatch manuale), nota legacy una-sola-vendita, puntatori a `REVISIONE-AI.md` e `PROPOSTE.md`.

## Non fatto (divieto): release su GitHub, `pubblica = true`, dispatch di workflow

UI test, screenshot e backtest della frazione R1 (`overnight`) li lancia l'altro revisore dopo il commit di versione.

## Resta aperto

- Tabella R1 frazione NOTTE (CAGR/perdita max/Sharpe per f) — primo run CI il 1° dicembre o dispatch manuale; decisione all'utente.
- Le 10 verifiche di `docs/VERIFICHE.md` su dispositivo e conto paper.
- Pagella Kimi: servono ~20–30 trade chiusi in paper.
- R7 da confermare su paper (no doppie vendite); limite noto: se la giornaliera vende lo stesso simbolo, il calo del detenuto può far uscire la voce di registro prima dell'esecuzione dell'OPG.
- Non verificabili dalla sandbox: compilazione/test locali (no Xcode — solo CI), backtest (no rete), dispatch workflow (403), UI reale/Face ID/notifiche/aste (servono il telefono e il conto).

---

# Sessione 12/11/2026 · punti 5–7 + design (9a–9c parziale)

Ordine seguito: punto 5 (bug grafico), poi 6a/6b/6c, poi 7, poi 9. Un commit su `main`
per punto, build verde prima del successivo (dove il commit toccava Sources/Tests).
Nessun Co-Authored-By. Nessuna release, nessun `pubblica`, nessun dispatch di workflow.

| Punto | Commit | Build CI |
|---|---|---|
| 5 · bug grafico (prezzo su 1H/15M/5M) | `384a8d3` (fallback ultimo prezzo noto + test UI `testChartPriceVisibleOnEveryInterval`) | 43148613953 success (build di 05c3542: 43146688980 success, verificata verde prima) |
| 6a · calendario Alpaca | `9cdaba1` (finestre NOTTE: chiusura esatta/festivi; promemoria per data; mai obbligatorio) | 43150103222 success |
| 6b · badge NOTIZIE 48H | `8606d32` (solo UI + test `testNewsBadgeOnOpenPosition`) | 43151647878 success |
| 6c · misura executed-vs-asta | `95790fa` (report NOTTE + `backtest_overnight_auctions.py` nel workflow) | 43153907464 success |
| 7 · 4 studi (quale=studi) | `c540afc` (tools/ + workflow; app invariata) | nessuna build (solo tools/workflow) |
| 9a · studio design | `d8e901d` (docs/DESIGN.md: schermata per schermata + sistema nuovo) | nessuna build (docs) |
| 9c · Theme e componenti | `6d81fc3` | 43156429606 success |
| 9c · CRUSCOTTO | `cecf367` | 43157416051 success |
| 9c · MERCATI e GRAFICO | `0ac0e50` + fix `dafcf67` (tabularNumber posizionale) | 43158777488 failure (compilazione) → 43159120191 in corso |

## Resta aperto

- **SCREENSHOT**: dopo CRUSCOTTO + MERCATI/GRAFICO l'altro revisore lancia gli screenshot
  (`screenshot` branch) e rivede; poi si procede con DETTAGLI, BROKER, SISTEMA, LOGIN
  (un commit per schermata, SCREENSHOT ogni 2 schermate).
- Studi `quale=studi` e `overnight` (con/senza chiavi aste): li lancia l'altro revisore;
  le decisioni (trailing, risk-parity, evento, VIX, frazione) sono dell'utente.
- R1 frazione NOTTE resta 97% (scartata la variante adattiva: rendimento e perdita in proporzione).
- Verifiche su telefono/conto: docs/VERIFICHE.md (10 controlli) + pagella Kimi (20–30 trade).
- Non verificabili dalla sandbox: compilazione locale (solo CI), backtest con rete esterna
  (solo CI/locale), dispatch workflow (403), UI reale, screenshot.
