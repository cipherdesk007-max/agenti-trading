# Guida rapida ai test · QuantSwarm Alpha Zero

Tre livelli di test, dal più automatico al più manuale. Dettaglio su dispositivo e conto
reale: [docs/VERIFICHE.md](VERIFICHE.md) (11 controlli). Stato e numeri degli studi:
[docs/STATO.md](STATO.md).

## 1. Automatici — CI a ogni push

- Ogni push su `main` che tocca `Sources/**`, `Tests/**`, `UITests/**`, `project.yml` o il
  workflow fa partire **"Unsigned iOS IPA"**: XcodeGen genera il progetto, i test unitari
  girano su simulatore (ora **215 test**), e l'IPA viene compilata solo se tutti passano.
- Run rossa? Leggi il log e cerca `error:` oppure `Test Case '...' failed`.
- **Non pushare mentre una run IPA è in corso**: il workflow ha
  `concurrency: group ios-ipa, cancel-in-progress` — un push la annullerebbe.

## 2. Manuali — dispatch da Actions (non automatici)

- `uitest: true` → i 5 test di interfaccia in `UITests/`. Identificatori stabili:
  `STOP`, `START`, `CONTROLLA ORA`, `HARD KILL SWITCH`, `MERCATI`, `PAPER TRADING`,
  `market-SPY`, `interval-picker`, `chart-price`, `news-badge-XLF`, `Grafico a candele`,
  `buyableETF`.
- `screenshot: true` → nuovi screenshot sul ramo `screenshot`.
- Backtest: workflow **"Backtest filtro"**, input `quale` = `app` · `piccolo` · `overnight` ·
  `segnali` · `studi` · `oggi` · `robustezza` · `portafoglio`. Risultati nel riepilogo del
  run. Il controllo `mensile` parte da solo il 1° di ogni mese. Se uno script va in errore
  il passo fallisce (pipefail): niente tabelle vuote.

## 3. Su telefono e conto paper — i tuoi occhi

Segui [docs/VERIFICHE.md](VERIFICHE.md): 11 controlli con cosa fare nell'app, cosa guardare
nello storico ordini di Alpaca (confronta sempre i `client_order_id` `qsn-` / `qsv-emg-`),
risultato atteso e cosa significa se è diverso. Tra questi: primo MOC/OPG della notte,
stop GTC della giornaliera visibile su Alpaca, flat-by-close con ordini aperti (stop
`qsv-emg-` mai duplicato), cambio conto, pausa batteria, TRADUCI nelle notizie.

## Come segnalare un bug

Screenshot del CRUSCOTTO (catena agenti ed eventi aperti) + storico ordini Alpaca nello
stesso intervallo + report di sessione esportato dall'app.

## Nota sull'"AI"

Kimi non viene "trainato" dall'app: è un modello esterno via API. Quello che l'app fa è
**calibrare e valutare**: registro ombra con pagella (Kimi vs regole), Brier score sulla
confidence, memoria del consiglio (`CouncilRecord`) con esito a 30 minuti e pagella per
specialista. Una modifica ai prompt entra solo dopo prova in ombra con enough esiti
(vedi docs/CONSIGLIO.md). I risultati passati non garantiscono quelli futuri.
