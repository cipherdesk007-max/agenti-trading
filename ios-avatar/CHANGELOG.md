# CHANGELOG · AvatarFit

## 1.1.3 (build 5)

- **Rig 3D riscritto da zero** (eccezione voluta dal proprietario alla regola
  "niente riscritture"): il manichino ora è costruito con mesh loftate
  (busto svasato vita/petto, arti con gonfiaggio muscolare, bacino, deltoidi,
  pettorali, trapezio, testa con cranio/mascella/naso/orecchie/capelli,
  scarpe visibili) invece di box e capsule generiche.
- **Pose degli esercizi riprogettate frame per frame** su un renderer di
  riferimento: ogni keyframe ha contatti verificati (mani a terra, punte dei
  piedi a terra, sbarra in mano, schiena appoggiata alla panca) e verso del
  corpo corretto (flessioni e plank proni, panca supina) - nell versione
  precedente i piedi galleggiavano e in alcuni casi il volto guardava
  dalla parte sbagliata.
- Movimenti coperti: push-up, trazioni (3 fasi con sbarra fissata
  all'altezza giusta), squat, curl, rematore, panca (panca sotto la schiena
  + bilanciere che segue le mani), alzate laterali, affondi, plank, lento
  con manubri (movimento libero). Appoggio automatico dei piedi per le pose
  in piedi; cicli chiusi (l'animazione non ripassa più da pose neutre).
- Test nuovi: coerenza della mesh loftata, ciclo dei keyframe chiuso,
  appoggio dei piedi a terra; nessun test esistente modificato.

## 1.1.2 (build 4)
## 1.1.2 (build 4)

- **Volto dell'avatar da galleria (Memoji o selfie)**: iOS non espone le Memoji
  alle app di terze parti, quindi la via è salvarle in Foto; l'app ora può
  prendere il volto dalla galleria in due modi: scelta manuale (selettore
  di sistema, nessun permesso richiesto) e **lettura automatica**
  (accesso alla libreria Foto, chiesto una volta, uso in sola lettura): prende l'ultimo selfie
  e, se non esiste, l'ultima immagine del rullino. La foto viene ritagliata in
  cerchio e applicata come volto dell'avatar, in 3D (disco davanti alla testa)
  e in 2D; se la mesh TrueDepth esiste, resta lei la precedenza.
- La scelta manuale o lo selfie scattato spegnono la lettura automatica
  (l'ultima azione dell'utente vince); la card mostra il volto attivo e come
  rimuoverlo.
- Warning preesistente in CrashLog sistemato (risultato try? non usato) e
  permesso nuovo in Info.plist per l'accesso alla libreria Foto, uso locale
  (nessun invio, nessun upload).
- Messaggi della scansione viso aggiornati: se la scansione TrueDepth non
  parte (può succedere dentro LiveContainer) ora dicono esplicitamente di usare
  il volto da galleria.
- Test: selezione della foto (l'ultimo selfie vince sull'ultima foto del
  rullino, la più recente vince tra selfie, lista vuota = nessuna scelta) e
  ritaglio circolare (lato minore, immagine vuota = niente ritaglio).

## 1.1.1 (build 3)

- Demo e screenshot della UI in CI: l'app accetta l'argomento di lancio
  `--tab=<home|giornata|nosmoke|workout|tracker|sistema>` (valore sconosciuto
  o assente → Home); il workflow scatta le schermate delle 6 schede sul
  simulatore con l'avatar di prova (dati versionati in `Demo/avatar-demo.json`,
  decodifica protetta da test bloccante) e le pubblica sul branch
  `bozza-screenshot-avatarfit`, insieme a una copia b64 di dati.json prima e
  dopo il lancio (diagnostica). Nessun cambiamento per chi usa l'app.

## 1.1.0 (build 2)

- **1RM a corpo libero non più zero**: per gli esercizi a corpo libero il carico
  totale ora include la frazione del peso corporeo (trazioni 100%, piegamenti
  ~64%, squat/affondi ~65%, plank ~50%, più eventuale zavorra). "1RM stimato
  ora" e "Record 1RM" mostrano il valore con corpo incluso, con etichetta
  esplicita; lo stepper mostra "Carico extra" e il peso del corpo stimato.
  Il defaultWeight del prossimo workout resta il solo carico extra.
- **Recupero auto-avviato anche tra un esercizio e il prossimo** e vibrazione
  quando il timer di recupero arriva a zero.
- Test: frazioni del peso corporeo per tipo di movimento, carico effettivo,
  1RM a corpo libero non più zero.

## 1.0.0 (build 1)

- Prima versione: avatar parametrico 3D/2D, scansione viso TrueDepth, demo 3D
  degli esercizi, workout attivo con serie/recupero/1RM, libreria esercizi
  espandibile, tracker personalizzabili, contatore no-smoke con traguardi di
  salute, timeline 24h, backup export/import JSON, crash log in Sistema.
