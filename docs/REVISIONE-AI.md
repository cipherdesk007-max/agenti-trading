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

---

# Sessione 12/11/2026 (seconda parte) · design 1.5.0 completo + controllo finale + versione

Un commit su `main` per blocco, build verde prima del successivo (run CI indicato),
nessuna riga Co-Authored-By. I commit solo-docs non avviano la workflow IPA.

| Lavoro | Commit | Build CI |
|---|---|---|
| PROPOSTE.md: triage idee esterne (11–16, con link ufficiali e limiti) | `77a6ee5` | nessuna (docs) |
| Design DETTAGLI (+ helper condivisi nello stile nuovo) | `2ff870f` | run#148 **success** |
| Design BROKER | `1516b1c` | run#149 **success** |
| Design SISTEMA (sezioni Conto/Strategia/Kimi/App/Stato) | `a186539` | run#150 **success** |
| Design LOGIN (+ residui GRAFICO, helper morti rimossi da Theme) | `c9a0d69` | run#151 **success** |
| Controllo finale A: niente try!/fatalError, via force-unwrap, AlpacaService testabile, test HTTP + parametrici 500–1M | `c4e3876` | run#152 **failure** (Swift 6 concurrency su `static var handler` del mock) |
| fix concurrency mock | `3f354ff` | run#153 **failure** (`didReceive` vs `didLoad`) |
| fix callback `urlProtocol(_:didLoad:)` + body da httpBodyStream + CONTROLLO-FINALE.md + GUIDA.md + screenshots | `a448de7` | run#155 **success** (153 unitari + 5 UI verdi) |
| MARKETING_VERSION 1.5.0 (app e widget) | `9f6c534` | run#156 **success** → **build 156** |
| CHANGELOG/README/STATO/REVISIONE-AI/RELEASE-NOTE per 1.5.0 | questo commit | nessuna (docs) |

## Cosa è stato fatto

- **Design 9c completo** (solo `Sources/Views` + `Theme.swift`): tutte le schermate nel
  sistema nuovo (un accento, SF Pro + cifre tabellari, griglia 8 pt, AppCard piene senza
  bordi, SectionHeader/ValueRow/StatusChip, SISTEMA a sezioni). Identificatori UI dei
  test invariati (`STOP`, `START`, `CONTROLLA ORA`, `HARD KILL SWITCH`, tab `MERCATI`,
  switch `PAPER TRADING`, `market-SPY`, `interval-picker`, `chart-price`,
  `news-badge-XLF`, `Grafico a candele`, `buyableETF`).
- **Proposte 11–16** (idee incollate dall'esterno): tutte solo in `docs/PROPOSTE.md` con
  verifica preliminare (Alpaca non dà calendario macro né sentiment strutturato), link
  ufficiali (.gov FOMC/BLS, docs Alpaca fractional) e limiti dichiarati. La 15
  (fractional `notional`) documenta il vincolo grave: ordini solo Day → niente stop
  GTC frazionario, e MOC/OPG della NOTTE non frazionari.
- **Controllo finale A** (`docs/CONTROLLO-FINALE.md`): tabella file-per-file con
  rischi e test; scenari "cosa può andare storto" per GIORNALIERA/VELOCE/NOTTE mappati
  ai test; nessun `try!`/`fatalError` (grep verificato), via 4 force-unwrap su subscript;
  nessun segreto nel codice/log (grep verificato); test parametrici 500/1.000/10.000/
  100.000/1.000.000 $ per sizing, tetto 25%, rischio, divisione NOTTE; 12 test HTTP
  mock su AlpacaService (normale + 422/404/parziale/rete assente/decode).
- **Guida** `docs/GUIDA.md` (9 capitoli, numeri veri da STATO, "i risultati passati non
  garantiscono quelli futuri", nessun guadagno promesso) + screenshot copiati in
  `docs/screenshots/`. **GUIDA.pdf non generabile in questa sandbox** (no pandoc/
  wkhtmltopdf/reportlab): lo genera l'altro revisore.
- **Versione 1.5.0 build 156** (`9f6c534`, run#156 verde). `docs/RELEASE-NOTE.md` pronto
  con tag `v1.5.0-b156`, testo e allegati. Pubblicazione (release GitHub, `pubblica`)
  vietata a me: la fa l'altro revisore/a mano.

## Cosa resta aperto

- Screenshot post-design-1.5.0 da rifare sul ramo `screenshot` (l'altro revisore).
- UI test (`uitest`) e backtest `quale=studi` + `overnight` (R1) da lanciare (403 per me).
- `docs/VERIFICHE.md` da eseguire su telefono/conto vero (10 controlli).
- `docs/GUIDA.pdf` da generare.
- Pubblicazione release v1.5.0-b156 a mano (token Actions senza permesso release).
- Proposte 11–16: da scegliere dall'utente; 13/14/16 richiedono prima uno script in
  `tools/` (`quale=studi`); 15 richiede il backtest/paper e la valutazione del
  rischio "stop solo Day".

## Cosa non ho podido verificare

- Compilazione locale (solo CI: tutte le build indicate sono verdi tranne le due
  fallite e subito fixate, 152/153).
- UI reale su telefono, Face ID, notifiche, widget, TRADUCI (solo simulatore).
- Ordini reali su Alpaca paper/live (MOC/OPG accettati, stop GTC visibili).
- Backtest con rete esterna (solo CI/locale dell'altro revisore).

---

# Sessione 12/11/2026 (terza parte) · revisione esterna su 1.5.0 build 157 — 3 blocchi

Un push per blocco, build verde prima del blocco successivo, niente Co-Authored-By
(nota: il trailer `Co-authored-by` appare su TUTTI i commit di questa sessione e delle
 precedenti: è iniettato dall'ambiente, non scritto da me).

| Blocco | Commit | Build CI |
|---|---|---|
| 1 · SICUREZZA (OPG per stato ordine, MOC parziali/blocco famiglia, flat-by-close, finestre weekend/festivo/mezza giornata) + test | `6e98b2a` | run#158 **failure** (`let-else` non valido) |
| fix sintassi | `17e3789` | run#159 **failure** (2 test: id ordine salvato era quello server, non il client_order_id; conteggio MOC contava i retry) |
| fix: `sellQueuedOrderId = client_order_id` + test corretti | `2da9ac6` | run#160 **success** (161 unitari + 5 UI) |
| 2 · STUDI ROTTI: `daily_study_lib.flat_by_field`/`load_series` (MultiIndex yfinance), fix riskparity, `pipefail` nel workflow backtest | `a1f2787` | nessuna build IPA (tools/ e backtest.yml non triggerano; py_compile + yaml validati in locale) |
| 3 · DESIGN dagli screenshot: tile MERCATI uniformi + sentence case, STOP warning vs CONTROLLA ORA primario, BROKER stati IT + tipo/prezzo, "Traduci", SISTEMA riga singola + info | `aaae321` | run#161 **success** |
| docs: CHANGELOG/STATO/REVISIONE-AI | questo commit | nessuna (docs) |

## Cosa NON ho fatto / non ho potuto verificare

- **BLOCCO 2 non rilanciato**: non posso lanciare workflow (403) e nel sandbox non c'è
  rete/yfinance — gli script sono fixati e compilano (`py_compile` OK), ma le tabelle
  si riempiono solo al prossimo `quale=studi` dell'altro revisore. Da verificare lì che
  ogni variante stampi almeno una riga e che il passo fallisca se uno script erra.
- **Screenshot post-fix** (BLOCCO 3) da rifare e rivedere: altro revisore.
- **Verifiche su telefono/conto** (docs/VERIFICHE.md): le faccio io a mano, non la sandbox.
- **UI test (`uitest`)**: solo a mano/dispatch, non da qui.
- Le nuove protezioni NOTTE/VELOCE sono coperte da test con broker finto; la conferma su
  Alpaca paper (OPG che passa da `new` a `filled`, MOC parziali reali) resta in
  VERIFICHE.md.
