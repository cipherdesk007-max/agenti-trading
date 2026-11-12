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
