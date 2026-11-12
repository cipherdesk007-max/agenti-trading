# Release note · v1.5.0-b156

- **Tag**: `v1.5.0-b156`
- **Titolo**: QuantSwarm Alpha Zero 1.5.0 (build 156) — nuovo design e controllo finale
- **Data**: 2026-11-12

## Testo pronto da incollare nella release

Nuova versione candidata al rilascio.

- **Design rifatto da prototipo a prodotto**: un solo colore d'accento, caratteri di
  sistema (SF Pro) con cifre tabellari per i numeri, griglia 8 pt, card piene senza
  bordi, niente titoli in maiuscolo, SISTEMA diviso in sezioni (Conto, Strategia,
  Kimi, App, Stato), LOGIN più pulito. Tutte le funzioni restano raggiungibili;
  gli identificatori dei test UI non cambiano.
- **Controllo finale del codice** (`docs/CONTROLLO-FINALE.md`): niente `try!` o
  `fatalError` in `Sources/`, via le force-unwrap su subscript, nuovi test HTTP con
  mock per ogni funzione che invia/annulla/chiude ordini (caso normale + errore),
  test parametrici su conti da 500 a 1.000.000 USD. Totale 153 unitari + 5 UI.
- **Già in 1.4.x e ora in 1.5.0**: calendario di borsa Alpaca per le finestre
  NOTTE, misura executed-vs-asta nel report, etichetta notizie 48h, riconciliazione
  delle OPG annullate (niente più azioni orfane).
- **Guida d'uso** in italiano: `docs/GUIDA.md` → `docs/GUIDA.pdf`.
- Nessun guadagno è promesso o garantito; i risultati passati non garantiscono
  quelli futuri.

## File da allegare

- `QuantSwarm-Alpha-Zero.ipa` dal ramo `bozza-ipa` (build 156)
- `docs/GUIDA.pdf` (generato da `docs/GUIDA.md` + `docs/screenshots/`)

## Procedura di pubblicazione (a mano, il token Actions non può creare release)

1. GitHub → Releases → Draft a new release.
2. Tag `v1.5.0-b156` sul commit `9f6c534`, titolo sopra, testo sopra.
3. Allega l'IPA e la guida PDF.
4. NON marcarla come "pubblica" nell'app (opzione `pubblica` del workflow) finché
   l'altro revisore non ha finito screenshot, UI test e backtest `quale=studi`.
