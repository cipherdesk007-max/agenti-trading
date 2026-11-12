# Il consiglio degli agenti · QuantSwarm Alpha Zero

Aggiornato al 12/11/2026. Questo documento accompagna l'evoluzione della catena
agenti verso il "consiglio": chi decide, chi contesta, cosa si ricorda e come
si verifica. Non sostituisce `docs/STATO.md` (mappa generale del progetto).

## 1. Audit della catena esistente (prima del consiglio)

La catena veloce era già completa e separata per responsabilità:

```
Scout (dati stream Alpaca, 0 crediti)
  → Strategia (filtri a regole: EMA cross, rottura 20 barre, RSI estremo; 0 crediti)
    → Analyst (Kimi: regime, volatilità, bias)
      → Brain (Kimi decide: buy/hold con entry/stop/target e win_probability)
        → Reviewer (Kimi avversario, fail-closed)
          → Risk (RiskRules pure: precheck, sizing, tetto 25%, stop giornaliero,
                   drawdown, idempotenza via client_order_id)
            → Executor (bracket su Alpaca)
```

Cosa c'era già: calibrazione della confidence con Brier score e bucket per
fascia; memoria `DecisionSample` (ogni decisione, anche gli HOLD, valutata a
30 minuti sul movimento del prezzo); registro ombra della giornaliera con
pagella Kimi-vs-regole; pagina DETTAGLI con pipeline e pannelli.

Cosa mancava rispetto al progetto "consiglio": il Brain riceveva solo la
lettura dell'Analyst, non pareri strutturati e confrontabili di più
specialisti; non esisteva una memoria per-agente retrospettiva dei pareri; la
validazione quantitativa non copriva walk-forward out-of-sample e Monte Carlo.

## 2. Il consiglio (cosa esiste ORA)

### Chi sono gli specialisti

Gli specialisti sono LOCALI: funzioni pure deterministiche su dati già in codice
(`Sources/Agents/SpecialistAgents.swift`), **zero crediti Kimi**, zero nuove
API. Ognuno produce un report standardizzato `AgentReport`:

| Campo | Contenuto |
|---|---|
| `agent` | tecnica, quant, notizie, fondamentali, portafoglio |
| `signal` | FAVOREVOLE / NEUTRALE / AVVERSO / SOSPESO |
| `confidence` | completezza dei dati (0–1), NON una probabilità calibrata |
| `analysis` | giudizio in una frase con i numeri |
| `evidence` | fatti verificabili che motivano il parere |
| `risks` | rischi identificati |
| `missingData` | cosa manca e perché il parere non può essere più forte |
| `invalidation` | condizione che smentisce la lettura |

Regole note (tutte testate in `Tests/CouncilAgentsTests.swift`):

- **Tecnica**: multi-timeframe 15m+1m. FAVOREVOLE con almeno 3 condizioni
  allineate su 5 (sopra SMA200, EMA12>EMA26, RSI in zona sana, sui massimi di
  20 barre, conferma 1m) e nessuna rottura; AVVERSO con trend e medie entrambi
  negativi e minimo di 20 barre in rotta; altrimenti NEUTRALE. SOSPESO senza
  storico.
- **Quant**: z-score della chiusura vs media 20 barre, volatilità realizzata,
  trend di fondo. FAVOREVOLE se z ≤ −1,5 dentro un trend positivo (anomalia di
  ribasso), AVVERSO se z ≥ 1,5 (estensione di rialzo).
- **Notizie**: keyword sui titoli Benzinga delle ultime 48 ore (parole chiave
  ad alto impatto, negative, positive). Mai sentiment inventato: senza titoli
  resta SOSPESO.
- **Fondamentali**: SOSPESO SEMPRE, dichiaratamente: le tre API collegate non
  includono dati fondamentali. Non si inventano P/E o utili. Lo specialista
  esiste e dichiara il vincolo.
- **Portafoglio**: esposizione reale (posizioni + ordini d'ingresso pendenti),
  tetto simboli, concentrazione sul capitale bot, sovrapposizione per famiglia
  di ETF (SPY/VOO/IVV/DIA, QQQ/QQQM, …). AVVERSO se il simbolo è già in
  portafoglio o non c'è posto.

### Chi decide e chi contesta

- **Chief Decision Agent = Kimi Brain esistente**, arricchito: riceve nel
  payload `specialist_reports` (report compatti) e `divergence_note`. Il system
  prompt gli impone di segnalare nel rationale chi è d'accordo e chi no, e di
  motivare esplicitamente un buy che va contro pareri avversi. La confidence
  degli specialisti NON è una probabilità: non può diventare win_probability.
- **Contrarian Agent = Kimi Reviewer esistente**: riceve gli stessi report e
  la divergenza; il prompt gli impone di NON confermare automaticamente né la
  proposta né gli altri agenti, e di cercare l'angolo morto anche quando tutti
  sono favorevoli.
- **Risk resta in codice** (`RiskRules`): precheck, sizing, tetti, circuit
  breaker, idempotenza. Nessun agente AI può aggirarlo; l'ordine parte solo se
  tutto il resto ha detto sì.

Le chiamate Kimi non aumentano: decide + review come prima, con payload più
ricchi. La modalità giornaliera riceve lo stesso tramite `specialist_digest`
per candidato in `dailyDecide`/`dailyReview` (tecnica del pullback, statistica,
notizie, fondamentali sospesi).

### Divergenze

`CouncilDivergence.assess` confronta i pareri: la divergenza è "forte" quando
convivono pareri FAVOREVOLI e AVVERSI. La nota testuale va nel prompt di Brain
e Reviewer e nel pannello CONSIGLIO (in ambra). Un acquisto contro l'intero
consiglio è possibile solo se il Chief lo motiva e il Contrarian non lo boccia.

### Memoria e pagella per agente

- `CouncilRecord` (SwiftData, stesso container di `TradeRecord` e
  `DecisionSample`): report + divergenza + decisione + prezzo di riferimento;
  a 30 minuti (`SystemLimits.holdEvaluationSeconds`) `evaluateCouncilRecords`
  registra il movimento % del prezzo (stesso criterio degli HOLD sample).
- `AgentScorecard`: per ogni specialista, hit sui pareri giudicati
  (FAVOREVOLE vinto se il prezzo sale, AVVERSO se scende; NEUTRALE e SOSPESO
  mai giudicati). Hit rate mostrato solo con almeno 5 giudizi. È un'euristica
  documentata di primo ordine, NON una probabilità calibrata.
- I record non modificano mai prompt né limiti di rischio da soli: le modifiche
  alla strategia restano versionate e provate con backtest (vincolo fisso).

### Dashboard

Pannello **CONSIGLIO** in DETTAGLI (solo modalità veloce): ultima seduta
(simbolo, decisione, esito Contrarian), divergenze in ambra, una scheda per
specialista (parere, completezza, analisi, evidenze, dati mancanti,
invalidazione), rationale del Chief e pagella per specialista. Ogni decisione
resta ricostruibile dalle evidenze registrate.

## 3. Validazione quantitativa (FASE 5)

`tools/backtest_robustness.py` (workflow `backtest.yml`, input
`quale=robustezza`, incluso in `tutti` e nel controllo mensile) misura le
REGOLE attuali dell'app riutilizzando `simulate` di `backtest_app.py`:

1. **Walk-forward**: 8 anni in-sample, 2 anni out-of-sample, passo 2 anni
   (dal 2006). I parametri si scelgono SOLO sull'IS (griglia RSI2 5/10/15 ×
   uscita SMA5/10 × stop 2/2,5/3 ATR) e si testano UNA volta sull'OOS mai
   visto. Confronto per fold con SPY nello stesso periodo.
2. **Monte Carlo**: 1000 percorsi bootstrap iid dei rendimenti giornalieri
   della strategia; distribuzione di CAGR, max drawdown ed equity finale,
   probabilità di finire sotto il capitale iniziale.
3. **Metriche per trade**: win rate, profit factor, expectancy, R-multiplo
   medio (P&L in unità della distanza stop, aggiunto a `backtest_app.sell`),
   Sortino, durata media.

Bias dichiarati e gestiti: niente look-ahead (l'ingresso avviene all'apertura
successiva al segnale, gli indicatori sono già calcolati in codice), costi
0,05% per lato, stop eseguiti anche sul gap, warmup degli indicatori fuori dai
fold. Limitazione dichiarata: il bootstrap iid ignora l'autocorrelazione dei
rendimenti. Il calibration error della confidence (Brier) resta misurato
dall'app sui trade reali (pannello CALIBRAZIONE).

## 4. Cosa NON è stato fatto (e perché)

- **Fundamental Agent operativo**: servirebbe una quarta API (dati di bilancio
  / macro). Lo specialista esiste e dichiara "dati mancanti": è il
  comportamento corretto senza la fonte.
- **Market Intelligence Agent separato**: la sua funzione (regime, volatilità,
  bias macro) è l'Analyst Kimi esistente; duplicarlo creerebbe due agenti per
  lo stesso lavoro, vietato dal progetto.
- **Self-modifica dei prompt dai risultati**: vietata da vincolo fisso e dal
  buon senso: la pagella è euristica con pochi campioni; i cambi di strategia
  passano da backtest e commit versionati.
