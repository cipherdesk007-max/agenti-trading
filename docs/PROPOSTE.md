# Proposte · non implementate

Solo idee, da scegliere e poi da sviluppare. Vincoli: usano **solo le 3 API
esistenti** (Alpaca Trading, Alpaca Market Data con notizie Benzinga, Kimi/Moonshot) e
ogni modifica alla strategia deve passare per un backtest in `tools/` prima di entrare
nell'app (vincolo di `docs/STATO.md`). Nessuna di queste è nel codice.

## 1 · Trailing stop GTC sulla GIORNALIERA (invece dello stop fisso a 2,5 ATR)

- **API**: Alpaca Trading (ordini `trailing_stop`, restano sul broker come il GTC attuale).
- **Guadagno atteso**: protegge i profitti durante i trend rialzisti lunghi; plausibile miglioramento del rapporto CAGR/perdita massima rispetto allo stop fisso.
- **Rischio**: whipsaw — uscite anticipate per volatilità; con i gap il trailing stop esegue al prezzo di mercato, non al trail. Cambia il carattere della strategia (più trade, più costi).
- **Come provarla prima**: variante di `tools/backtest_app.py` con uscita trailing (stesso 2,5 ATR) contro quella fissa, su 2006–oggi più le 18 varianti di robustezza; se CAGR/|maxDD| migliora in modo robusto entra in app, poi 1 mese in paper con stop reale sul broker.

## 2 · Pesi risk-parity nella NOTTE (1/volatilità a 20 giorni invece di peso uguale)

- **API**: Alpaca Market Data per le barre (lo studio usa yfinance in `tools/`).
- **Guadagno atteso**: la perdita massima della NOTTE (−22% a peso uguale) dovrebbe scendere, dando peso maggiore a oro e volatilità bassa.
- **Rischio**: più turnover e costi d'asta; l'effetto può essersi spento negli ultimi anni; il paniere a peso uguale è più semplice da spiegare e controllare.
- **Come provarla prima**: variante di `tools/backtest_overnight.py` con pesi 1/vol su 2006–oggi **e** sugli ultimi 2 anni; entra solo se migliora CAGR/|maxDD| in entrambi. Poi optionally in `backtest_overnight_fraction.py`.

## 3 · Frazione NOTTE adattiva dopo drawdown (usa i numeri dello studio R1)

- **API**: Alpaca Trading (equity del conto); la logica è in `tools/backtest_overnight_fraction.py`.
- **Guadagno atteso**: dopo notti negative consecutive o un drawdown del conto oltre soglia, la notte investe una frazione minore (es. 97% → 75% → 50%): la perdita massima sul conto scende nelle fasi brutte.
- **Rischio**: sottoperformance nel recupero; se si provano tante soglie il risultato può essere fortunato (Deflated Sharpe) — provarne al massimo 2–3.
- **Come provarla prima**: variante dello studio R1 con f adattiva (soglie su drawdown del conto); confrontare CAGR/|maxDD| su tutto il periodo e sugli ultimi 2 anni prima di toccare `cashBuffer`.

## 4 · Filtro "evento" 48h prima dell'ingresso della GIORNALIERA

- **API**: Alpaca Market Data News (le notizie delle 48h le prende già l'app per Brain/Reviewer; la regola sarebbe in codice, zero crediti Kimi in più).
- **Guadagno atteso**: blocca ingressi dentro eventi che cambiano il quadro (Fed, CPI, halt), evitando parte dei drawdown post-evento.
- **Rischio**: salta anche trade buoni subito dopo l'evento; la classificazione "hard event" è fuzzy e può degenerare in una regola che non scatta mai (o sempre).
- **Come provarla prima**: backtest in `tools/` con filtro sulle date degli annunci Fed/CPI 2006–oggi contro il filtro attuale (solo RSI2); entra solo se migliora CAGR/|maxDD|. Se non migliora, resta solo nel prompt del Reviewer (comportamento attuale).

## 5 · Badge notizie 48h nel CRUSCOTTO per le posizioni aperte (solo display, nessun ordine)

- **API**: Alpaca Market Data News; nessuna chiamata a Kimi.
- **Guadagno atteso**: visibilità su eventi che possono muovere una posizione durante la notte, dove non c'è stop (la NOTTE non può averne). Puó motivare una chiusura manuale.
- **Rischio**: solo rumore — notifiche a vuoto. **Nessun rischio sugli ordini**: non tocca l'esecuzione, è display puro.
- **Come provarla prima**: 1 mese in paper con log delle notifiche in DETTAGLI: contare quante avvisano un movimento reale della posizione entro 24h contro quante sono rumore. Entra solo se il rapporto è claramente utile.
