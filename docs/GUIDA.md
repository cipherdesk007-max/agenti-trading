# Guida all'uso · QuantSwarm Alpha Zero

*Versione 1.6.9 · 14/11/2026 · in italiano semplice, per chi non conosce il trading.*

> **Da leggere prima di tutto**: questa app **non promette e non garantisce alcun
> guadagno**. I risultati passati non garantiscono quelli futuri. Puoi perdere
> parte o tutto il capitale investito. L'app non è un consulente finanziario.

Le immagini sono in `docs/screenshots/` (CRUSCOTTO, MERCATI, GRAFICO, DETTAGLI,
BROKER, SISTEMA). *Nota: gli screenshot sono quelli della build 228 (versione 1.6.9),
presi dal ramo `screenshot`.*

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
| MERCATI e GRAFICO in CRYPTO | Le 5 coppie con prezzo, variazione e stato della regola; toccandone una, candele con media a 200, ingresso e stop | `screenshots/MERCATI-CRYPTO.png`, `screenshots/GRAFICO-CRYPTO.png` |
| DETTAGLI | Curva del capitale contro SPY, ultime decisioni di Kimi, pagella agenti (Kimi contro le regole), consiglio degli specialisti (solo modalità veloce), performance, registro eventi | `screenshots/DETTAGLI.png` |
| BROKER | Conto (a quale conto è collegata l'app, equity, cash, buying power, P&L di oggi e per strategia, se Alpaca accetta nuovi ordini), ordini aperti (Annulla) e posizioni (Chiudi) con controllo manuale, ordini recenti, link rapidi | `screenshots/BROKER.png` |
| SISTEMA | Conti Alpaca (aggiungi/usa/elimina), sezioni Broker (stato del trading, Riattiva trading, Ricalibra equity), Strategia, Kimi (crediti, limite di spesa, modello), App, Stato; versioni e aggiornamenti | `screenshots/SISTEMA.png` |

## 4. Le 3 modalità

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
- Ogni strategia ha il **suo registro** e tocca solo le sue posizioni; il riquadro
  Conto (in BROKER) mostra il **P&L separato per strategia** e il totale del
  conto.
- **Studio 2006–oggi** (`tools/backtest_portfolio.py`, run 43338377889): split 30/70
  → circa **+5,6% annuo**, **perdita massima −17%**, Sharpe 0,79 (Sharpe 1,96 sugli
  ultimi 3 anni); correlazione tra le due strategie +0,04. Le regole dinamiche
  "insegui chi guadagna" sono state scartate dai numeri.
- Serve aprire l'app **due volte al giorno** per la parte notte: mattina entro le
  15:28 e pomeriggio entro le 21:50 (ora italiana). Gli stop della giornaliera
  restano sul broker anche ad app chiusa.
- Con **"Promemoria per aprire l'app"** acceso (SISTEMA) arrivano due notifiche nei
  giorni di borsa: alle 14:45 (vendita della notte) e alle 21:15 (acquisto della
  notte e controllo giornaliero), ora italiana abituale. Nelle sedute corte, quando
  la borsa USA chiude tre ore prima, la seconda arriva tre ore prima. Per qualche
  settimana l'anno (cambio dell'ora in date diverse) gli orari italiani slittano
  di un'ora: fa fede l'ora di New York (8:45 e 45 minuti prima della chiusura).

### Crypto · 24/7 (rischio alto — solo su conto paper)
- Lavora su **5 coppie** di Alpaca: Bitcoin, Ethereum, Solana, Avalanche e Chainlink
  contro dollaro. Ogni coppia riceve **un quinto del conto**.
- **Compra** quando il prezzo supera il massimo degli ultimi 20 giorni e sta sopra la
  media a 200 giorni. **Esce** quando il prezzo scende sotto uno stop che segue il
  prezzo verso l'alto e non scende mai, oppure sotto la media a 200.
- Lo **stop sta sul broker** e resta attivo anche ad app chiusa. Il mercato crypto è
  sempre aperto, ma l'app lavora **solo mentre è aperta** (un controllo ogni 60
  secondi): nuovi acquisti e spostamento dello stop avvengono quando la apri.
- **Non chiama Kimi**: zero crediti. Alpaca trattiene lo 0,25% a ogni acquisto
  (misurato sul conto paper).
- **Numeri dello studio, rifatto il 14/11/2026 con le posizioni dell'app** (`tools/studio_universo.py`,
  run 43572591958): dal luglio 2020 circa +45% l'anno, dall'aprile 2021 circa +21%
  l'anno, in entrambi i casi con **perdita massima −41%** e 30 cali oltre il −10% dal
  massimo. Comprare le stesse monete e tenerle: perdita massima −85%.
- **Attenzione**: l'app blocca i nuovi acquisti quando il conto perde il 10% dal suo
  massimo e si sblocca solo a mano. Con cali così frequenti il blocco scatterebbe
  spesso: questa combinazione **non ha ancora uno studio suo**. I numeri scritti
  nelle versioni precedenti (+8,4% l'anno, perdita massima −9%) valevano per
  posizioni circa 7 volte più piccole.
- **Non ancora visto dal vero**: un ciclo completo con un segnale reale. I singoli
  ordini sono stati provati sul conto paper (12 controlli su 12).

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
  tutte le posizioni a mercato. Da usare solo in emergenza, con conferma. Dopo la
  richiesta l'app rilegge il conto e dice com'è andata davvero: **completato**
  (nessuna posizione, nessun ordine), **chiusure in coda** (a mercato chiuso le
  azioni si vendono alla prossima apertura) oppure **INCOMPLETO** con l'elenco di
  ciò che è rimasto aperto: in quel caso ripremi o chiudi dal sito Alpaca.
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
