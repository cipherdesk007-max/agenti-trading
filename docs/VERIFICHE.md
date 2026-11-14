# Verifiche manuali su telefono e conto · checklist

Controlli da fare a mano sull'iPhone (installata via SideStore/LiveContainer) e sullo
storico di **Alpaca paper** (`https://app.alpaca.markets/paper` → Orders / Positions).
Nessuno di questi è automatizzabile in CI: l'app gira solo aperta e le chiavi sono
nel Keychain protetto da Face ID.

## Prerequisiti

- Conto **paper** Alpaca (da 1.000 $) per la GIORNALIERA; secondo conto paper per la NOTTE.
- Chiavi Kimi e Alpaca inserite in **paper** (LOGIN), Face ID attivo.
- Modalità NOTTE sul secondo conto: SISTEMA → CONTI ALPACA. Promemoria alle 14:45 e 21:15 (ora italiana).
- Finestre NOTTE: mattina entro le 15:28 IT (vendita OPG), pomeriggio 15:30–21:50 IT (acquisto MOC).
- `client_order_id` usati dall'app: `qsn-b-` = acquisto MOC, `qsn-s-` = vendita OPG, `qsn-l-` = vendita a mercato di residuo.

## 1 · Primo acquisto MOC della NOTTE

- **Nell'app**: apri nel pomeriggio (15:30–21:50 IT) in modalità NOTTE e avvia. Nel CRUSCOTTO la catena arriva a "in coda per la chiusura: SPYM x az, …".
- **Su Alpaca**: Orders → 4 ordini BUY con `time_in_force = cls` e `client_order_id` `qsn-b-…`, stato accepted.
- **Atteso**: alle 16:00 di New York (22:00 IT) gli ordini si eseguono nell'asta di chiusura; in Positions compaiono le azioni; il registro notte dell'app le elenca con quantità.
- **Se è diverso**: ordine `rejected` → log "ordine CLS rifiutato", nessun acquisto, si ritenta alla finestra successiva. Resta `accepted` senza fill dopo le 16:00 NY → asta non eseguita: al ciclo successivo il residuo (se eseguito in parte) viene chiuso a mercato (R7). Mai due ordini con lo stesso `qsn-b-`.

## 2 · Prima vendita OPG della NOTTE

- **Nell'app**: apri la mattina entro le 15:28 IT. CRUSCOTTO: "vendo all'apertura: …" e notifica VENDITA ALL'APERTURA.
- **Su Alpaca**: Orders → SELL con `time_in_force = opg`, `client_order_id` `qsn-s-…`.
- **Atteso**: alle 9:30 NY (15:30 IT) gli OPG si eseguono; le Positions del conto notte sui 4 simboli vanno a zero; al ciclo successivo il registro notte si svuota.
- **Se è diverso**: OPG annullata/rifiutata all'asta → le azioni restano e **non** scompaiono dal registro (R7, marcate "in coda"); al ciclo pomeridiano il residuo viene chiuso a mercato con ordine `qsn-l-…` (o `closePosition` se la notte ha tutto il detenuto). Verifica che non venda anche azioni della giornaliera sullo stesso simbolo e che non si compri due volte sopra il residuo.

## 3 · Stop GTC della GIORNALIERA visibile su Alpaca

- **Nell'app**: modalità GIORNALIERA, START con un segnale → ordine limite + stop.
- **Su Alpaca**: Orders → coppia BUY limit + SELL stop con `time_in_force = gtc` (stop_price = ingresso − 2,5 ATR); resta `open` anche con l'app chiusa.
- **Atteso**: con l'app chiusa lo stop resta sul broker e scatta da solo se il prezzo lo tocca; in Positions la posizione mostra lo stop.
- **Se è diverso**: stop assente → al ciclo successivo l'app lo rimette (protezione "mai una posizione senza stop"). Stop eseguito → posizione chiusa, è normale. Stop residuo dopo vendita della posizione → bug da segnalare (può aprire uno short).

## 4 · Ripresa dopo app chiusa

- **Nell'app**: a mercato aperto chiudi l'app (swipe up) e riaprila: parte subito un controllo automatico (o usa CONTROLLA ORA). Nei log/events compare la riconciliazione col broker.
- **Su Alpaca**: Orders → nessun ordine duplicato: lo stesso `client_order_id` non deve comparire due volte. Se c'era un invio in timeout, l'app cerca l'ordine per id prima di rinviare.
- **Atteso**: un solo ordine per segnale; nessun falso allarme HEARTBEAT (il tempo con l'app chiusa non conta).
- **Se è diverso**: ordine duplicato → bug grave (recupero per client_order_id), confronta gli id `qsn-` in Alpaca e segnala.

## 5 · Cambio conto

- **Nell'app**: SISTEMA → CONTI ALPACA → aggiungi il secondo conto paper (le chiavi vengono provate sul broker prima di salvarle) e passaci a motore fermo. Passare a un conto live chiede conferma con la parola LIVE.
- **Su Alpaca**: confronta Positions e Orders dei due conti.
- **Atteso**: ogni conto ha registro (giornaliera e notte), curva del capitale e protezioni **separati**; il capitale del bot si ricalcola sul saldo del conto attivo.
- **Se è diverso**: registri mescolati (es. il registro notte di un conto che vende sull'altro) → bug, non usare il multi-conto finché non è chiaro.

## 6 · Pausa batteria (e rete)

- **Nell'app**: porta la carica sotto il 20% (o disattiva la rete): il CRUSCOTTO mostra "MOTORE IN PAUSA" con il motivo; il motore non invia ordini.
- **Su Alpaca**: Orders → nessun ordine nuovo nei timestamp della pausa.
- **Atteso**: al rientro (carica > 20% o rete tornata) il ciclo riparte da solo; gli stop GTC sul broker restano attivi per tutto il tempo.
- **Se è diverso**: ordini inviati durante la pausa → bug della pausa, segnala.

## 7 · Traduci nelle notizie

- **Nell'app**: MERCATI → tocca un ETF → grafico → sezione **Notizie · 48 ore** → tocca "Traduci" (richiede iOS 17.4+).
- **Atteso**: si apre il foglio di traduzione di Apple con il testo in italiano, gratis e senza crediti Kimi.
- **Se è diverso**: sul simulatore il foglio non si apre (limite noto, vedi STATO.md). Sul dispositivo reale, se non appare → controlla la versione di iOS.

## 8 · Registro notte della build precedente (solo chi aggiorna da build ≤ 130)

- **Nell'app**: primo ciclo NOTTE dopo l'aggiornamento.
- **Atteso**: il registro vecchio (senza quantità) si rilegge: vende tutto il detenuto del simbolo una sola notte, poi passa al formato nuovo con quantità (R7/B1).
- **Se è diverso**: non vende nulla → registro illeggibile, da indagare. Vende anche azioni della giornaliera sullo stesso simbolo → bug B1: HARD KILL SWITCH e segnala subito.

## 9 · Ragionamento "medium" di Kimi

- **Nell'app**: GIORNALIERA con un segnale di oggi → Brain e Reviewer vengono chiamati.
- **Atteso**: la chiamata usa `reasoning_effort` medium; se il modello lo rifiuta (errore 400) l'app ripiega una volta su low **senza perdere la decisione** (log in CRUSCOTTO/DETTAGLI).
- **Se è diverso**: decisione persa per errore 400 → bug; controlla eventi e crediti Kimi in SISTEMA.

## 10 · Controllo indipendente dei segnali di oggi

- Actions → "Backtest filtro" → `quale` = `oggi` (oppure `python tools/oggi.py` in locale), poi confronta SMA200 e RSI(2) di Wilder con TradingView o Yahoo.
- **Atteso**: gli indicatori dell'app coincidono con la tabella di `oggi`.
- **Se è diverso**: differenza → il feed barre (SIP/IEX) diverge dalla fonte esterna, da indagare prima di fidarsi del segnale.

## 11 · VELOCE: flat-by-close a T-10 con ordini aperti (stop d'emergenza qsv-emg-)

- **Nell'app**: modalità VELOCE, apri una posizione intraday con bracket (gamba stop + target, day) e lascia che il motore arrivi a T-10 dalla chiusura. Il flat-by-close gira anche in pausa: è protezione del capitale.
- **Su Alpaca**: Orders → a T-10 gli ordini aperti del simbolo (gambe del bracket e un eventuale `qsv-emg-…`) passano a `canceled`, poi parte la vendita a mercato (`DELETE /v2/positions/{symbol}`); se fallisce compare un solo SELL stop GTC con `client_order_id` `qsv-emg-SIMBOLO-GIORNO`.
- **Atteso**: a fine tentativo la posizione è chiusa OPPURE ha esattamente uno stop `qsv-emg-…`; mai due stop d'emergenza sullo stesso simbolo, mai ordini residui del simbolo. La doc Alpaca dice che `DELETE /v2/positions/{symbol}` NON annulla gli ordini aperti e che con ordini sell aperti le azioni restano riservate (rifiuto "insufficient qty"): https://docs.alpaca.markets/us/reference/deleteopenposition-1 — da confermare qui sul conto paper.
- **Se è diverso**: più stop `qsv-emg-` sullo stesso simbolo → bug nell'anti-duplicato; ordine residuo del simbolo a posizione chiusa → l'annullo non è stato verificato rileggendo gli ordini; chiusura rifiutata "insufficient qty" → gli ordini sell non erano stati annullati (o restavano riservate: la sequenza cancel→close ha una corsa documentata, https://alpaca.markets/learn/how-to-fix-common-trading-api-errors-at-alpaca); posizione senza stop e senza chiusura → guarda la notifica "POSIZIONE SENZA STOP" e chiudi a mano dal broker panel.

## 12 · Agenti 1.6.7: costo per chiamata nel report e robustezza sulle risposte (13/11 build ≥ 213, non ancora pubblicata)

- **Nell'app**: avvia una modalità che chiama Kimi (GIORNALIERA con candidati, VELOCE, o solo ANALIZZA ORA in MERCATI), poi STOP e apri il report di sessione.
- **Atteso**: nel report compare una riga "CHIAMATA KIMI <prompt>: X s, token N in entrata, M in uscita (modello …)" per OGNI chiamata fatta; il conteggio chiamate del giorno in SISTEMA è coerente. Le decisioni registrate (dettagli/pagelle) portano la versione del prompt 1.7.0.
- **Se è diverso**: manca la riga CHIAMATA KIMI con una chiamata comunque avvenuta (contatore a posto) → il drain del log non è arrivato al report: da segnalare. Token a zero con risposta ricevuta → l'API non ha restituito usage: guardare il modello in uso.
- **Nota costo**: la tariffa stimata non è nell'app (solo token reali); il saldo speso reale resta quello di SISTEMA (baseline saldo Kimi).

## 13 · Decisioni del 14/11: default modello kimi-k3.1-pro e prova in ombra ordine a regole (build ≥ 216, non ancora pubblicata)

- **Modello di default (proposta 23)**: apri SISTEMA → impostazioni → "Modello Kimi".
- **Atteso**: se NON avevi mai salvato un modello, il campo mostra `kimi-k3.1-pro` (stesso modello di highspeed a metà prezzo: 2,00/10,00 contro 4,00/20,00 USD per Mtoken). Se avevi salvato `kimi-k3.1-pro-highspeed`, devi vederlo ANCORA: il valore salvato vince sul default, nessuno te lo cambia. Per cambiare a mano: campo libero o lista "Modelli disponibili" (caricata dall'account Kimi con le tue chiavi).
- **Se è diverso**: il campo vuoto dopo un salvataggio ripristina il default (kimi-k3.1-pro): è il comportamento voluto; un valore salvato che sparisce da solo sarebbe un bug da segnalare.
- **Prova in ombra ordine a regole (proposta 22)**: avvia la GIORNALIERA e lascia correre una sessione con almeno un candidato; poi guarda DETTAGLI → PAGELLA AGENTI.
- **Atteso**: compare la sezione "Ordine a regole · prova in ombra (proposta 22)" con "Che l'ordine a regole avrebbe comprato" e "avrebbe saltato" e la differenza "Regole contro Brain". GLI ORDINI NON CAMBIANO: quello che compra resta deciso dal Brain come sempre. L'IC 95% "REGOLE − BRAIN" compare SOLO quando entrambi i lati hanno almeno 30 esiti risolti (con 1-2 candidati al giorno servono settimane: prima di allora i numeri sono rumore, lo dice anche l'app).
- **Se è diverso**: sezione assente dopo una sessione con candidati → il flag non è stato registrato: da segnalare col report di sessione. IC presente con meno di 30 esiti per lato → bug.
- **Criterio scritto prima** (docs/AGENTI.md 6-ter): si passa all'ordine a regole SOLO se l'IC 95% REGOLE − BRAIN risulta interamente sopra zero, e mai senza il tuo via esplicito.

## Come riportare un problema

Screenshot dell'app (CRUSCOTTO con catena agenti ed eventi) + lo storico ordini di Alpaca
nello stesso intervallo + il report di sessione dell'app. Confrontare sempre i
`client_order_id` `qsn-` fra app e broker: è il modo più rapido per capire se un ordine
è stato inviato, rifiutato o eseguito.
