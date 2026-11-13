# Piano VPS · motore 24/7 dopo i paper

> Stato: **PIANO, non consegnato** (13/11/2026). Il proprietario ha deciso: il motore su VPS si
> monta SOLO quando l'app è "perfetta e fa risultati", cioè dopo settimane di test paper
> verificati (regola già scritta in STATO.md: paper verificati PRIMA dei saldi reali, VPS dopo).
> Questo documento serve a non reinventare nulla quando si decide: requisiti, opzioni,
> vincoli e costo. Nessuna riga di codice server esiste ancora.

## Perché una VPS

Il limite iOS è strutturale e dichiarato: l'app esegue i cicli solo quando è aperta in primo
piano (CRYPTO ogni 60 s, PORTAFOGLIO ogni 15 minuti, NOTTE alle finestre d'asta). Oggi è mitigato
dagli stop GTC sul broker (le USCITE di protezione girano 24/7 anche ad app chiusa); a mancare
sono i NUOVI INGRESSI e le uscite a regola con l'app chiusa. Una VPS elimina il problema alla
radice: i cicli girano sempre, l'app diventa il pannello di controllo.

## Vincoli che NON cambiano

- **Le stesse 3 API**: Alpaca Trading, Alpaca Market Data/Benzinga, Kimi/Moonshot. La VPS non
  aggiunge servizi dati.
- **Mai chiavi nel repo**: le credenziali vivono nell'ambiente della VPS (env/systemd secrets),
  come oggi vivono nel Keychain del telefono.
- **Le regole sono quelle backtestate**: nessuna regola nuova per il solo fatto di spostarsi su
  server. Il motore della VPS replica i Runner esistenti, non li reinventa.
- **UN solo esecutore per conto**: mai due motori che inviano ordini sullo stesso conto. O la
  VPS o l'app: il pannello SISTEMA avrà un interruttore "motore su server" che mette i cicli
  dell'app in modalità SOLO OSSERVAZIONE (riconciliazione e log, zero ordini).
- HARD KILL dell'app deve restare effetivo: cancella ordini/posizioni sul broker e la VPS lo
  rispetta per via della riconciliazione (a ogni ciclo rilegge il broker prima di agire).

## Due opzioni tecniche

### Opzione A · motore server in Python (raccomandata al momento)

- I tool di backtest in `tools/` già contengono le regole esatte (V4 crypto, trend+pullback,
  overnight) scritte in Python: il motore server le riusa con la Trading API Alpaca REST
  (stessi endpoint di `AlpacaService.swift`, documentati in docs/STATO.md).
- NOTTE e CRYPTO sono "solo regole": 1:1 traducibili senza perdite. La GIORNALIERA chiama Kimi
  (Brain + Reviewer) con lo stesso payload JSON di `KimiService.dailyDecide/dailyReview`.
- Pro: ecosistema server consolidato (systemd, log, monitor), costo di manutenzione minimo,
  test con pytest affiancabili ai 275 dell'app.
- Contro: le regole esistono in due lingue (Swift in app, Python su server): serve disciplina
  di parità, con un test di parità che gira in CI su segnali condivisi (fixture JSON).

### Opzione B · cicli Swift su Linux (Swift runtimes + Vapor)

- `DailyCycleRunner`, `NightCycleRunner`, `CryptoCycleRunner` sono logica pura già isolata dai
  protocolli broker: girano su Linux con un wrapper REST/actors. Fedeltà massima (stesso codice
  dell'app), zero doppioni di regole.
- Contro: toolchain server Swift, runtime iOS-specific da sostituire (UserDefaults → file JSON),
  CI di build per Linux da aggiungere: più costo di manutenimento di quanto il guadagno di
  fedeltà giustifichi, finché l'app è l'unico pannello.

**Raccomandazione**: Opzione A con test di parità segnali/regole tra `tools/` e `Sources/`
(fixture condivise nel repo). Se un giorno la parità diventa fragile, si valuta la B.

## Cosa serve concretamente (checklist di attivazione)

1. VPS minimale (1 vCPU, 1 GB RAM bastano: sono chiamate REST ogni 60 s) ~ 5 USD/mese.
2. Utente non privilegiato, systemd unit con `Restart=always`, credenziali in env file 0600.
3. Un solo esecutore: interruttore in-app "motore su server" (Modalità OSSERVAZIONE).
4. Health-check: heartbeat su file locale + alert via notifica dell'app al prossimo sync
   (nessun quarto servizio di notifica: resta nei vincoli).
5. Log in chiaro con la stessa sintassi dell'app (riconciliabili a occhio).
6. Registro locale del server che replica NightBook/DailyBook/CryptoBook (stesso formato JSON),
   così un eventuale ritorno all'app come esecutore non perde lo stato.
7. Paper prima anche qui: 2 settimane di VPS in paper, confronto ordine-per-ordine con
   l'app in OSSERVAZIONE, poi eventually il conto reale.

## Cosa NON serve

- Niente database esterno, niente brokeraggio aggiuntivo, niente Telegram/notifiche di terzi,
  niente API dati nuove. Il conto Alpaca è già "il database" del broker state.
