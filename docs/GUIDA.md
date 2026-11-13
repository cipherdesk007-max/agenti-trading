# Guida all'uso · QuantSwarm Alpha Zero

*Versione 1.5.0 · 12/11/2026 · in italiano semplice, per chi non conosce il trading.*

> **Da leggere prima di tutto**: questa app **non promette e non garantisce alcun
> guadagno**. I risultati passati non garantiscono quelli futuri. Puoi perdere
> parte o tutto il capitale investito. L'app non è un consulente finanziario.

Le immagini sono in `docs/screenshots/` (CRUSCOTTO, MERCATI, GRAFICO, DETTAGLI,
BROKER, SISTEMA). *Nota: gli screenshot sono stati rifatti dopo il nuovo design
della 1.5.0 dal ramo `screenshot`.*

---

## 1. Cos'è l'app e cosa NON è

QuantSwarm Alpha Zero è un'app iPhone che segue regole di trading automatiche su
ETF americani (S&P 500, Nasdaq-100, Russell 2000, oro) usando un conto Alpaca.

- **Gira solo quando è aperta.** Non esistono app iOS attive 24/7: per questo le
  protezioni (stop) vengono messe **sul broker**, dove restano attive anche con
  l'app chiusa.
- **Non è un consulente**: non ti dice "compra ora". Decide con regole fisse e,
  nella modalità giornaliera, con un modello di linguaggio (Kimi) che valuta i
  segnali.
- **Nessun guadagno garantito**: i numeri degli studi sono il passato; il futuro
  può essere diverso.

## 2. Installazione e primo avvio

1. Installa con **SideStore** (o **LiveContainer**) l'IPA dal ramo `bozza-ipa`.
2. Apri l'app: appare la schermata di **login**.
3. Inserisci:
   - la **chiave API Kimi** (Moonshot, da platform.kimi.ai);
   - **Key ID e Secret Key di Alpaca** (da app.alpaca.markets, conto **paper** per
     le prove);
   - lascia **PAPER TRADING** acceso.
4. Tocca **VALIDA · FACE ID · SBLOCCA**: le chiavi finiscono nel Keychain protetto
   da Face ID; ogni riapertura chiede il volto.

## 3. Le schermate, una per una

| Schermata | Cosa mostra | Screenshot |
|---|---|---|
| CRUSCOTTO | Saldo e P&L di oggi in grande, stato del motore, START/STOP/CONTROLLA ORA, posizioni aperte, catena agenti e registro a richiesta, HARD KILL in basso | `screenshots/CRUSCOTTO.png` |
| MERCATI | Griglia dei 15 ETF con stato (in posizione, segnale, trend, non comprabile) e ultimo prezzo | `screenshots/MERCATI.png` |
| GRAFICO | Toccando un ETF: grafico a candele (1G/1H/15M/5M), prezzo sempre visibile, medie, livelli di ingresso/stop/target, notizie 48h con TRADUCI | `screenshots/GRAFICO.png` |
| DETTAGLI | Curva del capitale contro SPY, pagella agenti (Kimi contro le regole), consiglio degli specialisti (solo modalità veloce), portafoglio, crediti Kimi, performance, registro eventi | `screenshots/DETTAGLI.png` |
| BROKER | Ordini aperti (Annulla) e posizioni (Chiudi) con controllo manuale, ordini recenti, link rapidi | `screenshots/BROKER.png` |
| SISTEMA | Conti Alpaca (aggiungi/usa/elimina), sezioni Strategia, Kimi, App, Stato; versioni e aggiornamenti | `screenshots/SISTEMA.png` |

## 4. Le 2 modalità

Tutti i numeri sono degli studi in `tools/` (backtest 2006–oggi con yfinance) e
sono descritti in `docs/STATO.md`. **I risultati passati non garantiscono quelli
futuri.**

### Portafoglio (consigliata per iniziare, su conto paper)
- Fa convivere **giornaliera e notte sullo stesso conto**, con due budget separati:
  **30% alla giornaliera** e **70% alla notte**. Il capitale si **ribilancia a ogni
  ciclo** sull'equity corrente; se imposti un tetto in SISTEMA, il tetto vale sul
  totale prima dello split.
- **Giornaliera (la sua parte)**: compra un ETF quando è in trend rialzista (sopra
  SMA200) e ha appena fatto un ribasso forte (RSI2 < 10); stop a 2,5 ATR **sul
  broker (GTC)**, attivo anche ad app chiusa; esce a chiusura sopra SMA5, dopo 10
  giorni, allo stop o al target. Kimi viene chiamato solo se c'è un segnale.
- **Notte (la sua parte)**: compra in chiusura (asta MOC) S&P 500, Nasdaq-100,
  Russell 2000 e oro a peso uguale e vende all'apertura del giorno dopo (asta OPG).
  Zero crediti Kimi.
- Ogni strategia ha il **suo registro** e tocca solo le sue posizioni; il pannello
  Portafoglio (in DETTAGLI) mostra il **P&L separato per strategia** e il totale del
  conto.
- **Studio 2006–oggi** (`tools/backtest_portfolio.py`, run 43338377889): split 30/70
  → circa **+5,6% annuo**, **perdita massima −17%**, Sharpe 0,79 (Sharpe 1,96 sugli
  ultimi 3 anni); correlazione tra le due strategie +0,04. Le regole dinamiche
  "insegui chi guadagna" sono state scartate dai numeri.
- Serve aprire l'app **due volte al giorno** per la parte notte: mattina entro le
  15:28 e pomeriggio entro le 21:50 (ora italiana). Gli stop della giornaliera
  restano sul broker anche ad app chiusa.

### Veloce (sperimentale — sconsigliata con soldi veri)
- Decide ogni pochi minuti con Kimi su candele da 1–15 minuti; chiude tutto prima
  della chiusura del mercato. **Nei backtest perde e non batte il caso.** Richiede
  l'app sempre aperta.
- Prima di ogni decisione un **consiglio di specialisti locali** (analisi tecnica,
  statistica quantitativa, notizie, portafoglio; i fondamentali restano sospesi
  perché l'app non ha quella fonte) produce pareri motivati con evidenze. Kimi
  (il "Chief") li confronta, deve motivare quando va contro qualcuno, e un secondo
  Kimi avversario contesta tutto. In DETTAGLI, il pannello CONSIGLIO mostra i
  pareri, le divergenze, la decisione e una pagella per specialista costruita
  sui risultati a 30 minuti. Il costo in crediti non cambia.

## 5. Il capitale

- Il bot usa **tutto il saldo del conto** del conto attivo, oppure solo una parte
  se imposti "Usa solo una parte del conto" in SISTEMA (utile se sullo stesso conto
  tieni altri soldi).
- Ogni posizione è al massimo il **25% del capitale del bot** e il rischio per
  trade è impostabile (default 1%).
- Su conti piccoli alcuni ETF "escono dal capitale" (non si compra nemmeno 1
  azione entro i limiti): la riga "ETF comprabili" in SISTEMA lo mostra.

## 6. Protezioni

- **Stop sul broker (GTC)**: resta attivo anche con l'app chiusa.
- **Stop giornaliero**: se la perdita del giorno supera la soglia impostata, niente
  nuovi ordini fino a mezzanotte UTC.
- **Drawdown**: se perdi oltre il 10% dal picco del capitale bot, il motore si
  blocca finché non sblocchi manualmente (con avvertenza).
- **HARD KILL** (pulsante rosso in CRUSCOTTO): cancella tutti gli ordini e chiude
  tutte le posizioni a mercato. Da usare solo in emergenza, con conferma.
- **Pause automatiche**: niente ordini se la rete manca o la batteria è sotto il 20%.

## 7. Conti multipli e passaggio a LIVE

- In SISTEMA → Conti Alpaca puoi salvare più conti (es. un paper da 1.000 $ per la
  giornaliera e uno per la notte) e passare da uno all'altro (motore fermo).
- **Prima dei soldi veri**, lista di controllo:
  1. Almeno **20–30 operazioni chiuse in paper** (con 1.000 $ circa un segnale a
     settimana: qualche mese).
  2. Checklist di [VERIFICHE.md](VERIFICHE.md) completata sul conto vero.
  3. Stop GTC visibili su Alpaca (storico ordini).
  4. HARD KILL provato in paper.
  5. Solo dopo: togli PAPER TRADING (serve scrivere LIVE per confermare).

## 8. Problemi frequenti

| Sintomo | Cosa fare |
|---|---|
| "Nessun segnale" per giorni | Normale: la giornaliera compra solo ribassi forti in trend. Vedi la pagella in DETTAGLI. |
| App chiusa la mattina, la NOTTE non ha venduto | Il residuo viene chiuso a mercato alla prossima apertura della finestra di acquisto (solo le azioni della notte). Controlla su Alpaca. |
| Notifica "POSIZIONE SENZA STOP" | Apri l'app e premi CONTROLLA ORA: il motore rimette lo stop. Se non riesce, chiudi manualmente da BROKER. |
| Limite crediti Kimi raggiunto | Kimi si ferma fino a mezzanotte UTC; le posizioni restano protette dagli stop sul broker. |
| Cambio di versione | In SISTEMA → Stato → Aggiorna (apre LiveContainer). Dati e chiavi restano. |
| Report di sessione | Appare in CRUSCOTTO a STOP/HARD KILL: ESPORTA/INVIA lo manda via share sheet. |

## 9. Rischi e limiti, in chiaro

- Puoi perdere parte o tutto il capitale. Gli ETF possono scendere del 20–50% o più
  (la modalità notte ha misurato −22% di perdita massima nello studio).
- L'app gira solo aperta: se il telefono si spegne o perde rete durante un ordine,
  la protezione resta quella sul broker (stop GTC), non l'app.
- I backtest usano dati storici: il futuro può essere diverso. Più varianti si
  provano, più il risultato migliore può essere fortuna (effetto Deflated Sharpe).
- Le API esterne (Alpaca, Kimi) possono cambiare o non rispondere: l'app in quel
  caso si ferma in sicurezza e non invia ordini.
- L'app non è un consulente finanziario e non garantisce alcun risultato.

---

*PDF: `docs/GUIDA.pdf` si genera da questo file con le immagini di
`docs/screenshots/` (es. `pandoc GUIDA.md -o GUIDA.pdf --resource-path=docs`).
Nel sandbox di revisione non c'è un generatore PDF: lo genera l'altro revisore.*
