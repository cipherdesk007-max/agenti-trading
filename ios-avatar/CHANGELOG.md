# CHANGELOG · AvatarFit

## 1.1.9 (build della CI)

- **Personaggio 3D (fase 2)**: nell'Home gli esercizi animano un personaggio
  rigged vero, CC0 1.0 (Quaternius Universal Base Characters, Superhero
  Male), al posto del manichino: scheletro glTF guidato con lo stesso
  driver verificato nella simulazione numerica (distanza mano-bersaglio
  dichiarata max ~8 cm su tutti gli esercizi, riprodotta nei test unitari
  che confrontano le posizioni con la simulazione). Caricamento con
  GLTFSceneKit (MIT) da pacchetto SPM. Priorità nell'Home: avatar
  personale > personaggio > manichino; in SISTEMA c'è il selettore e senza
  i file del personaggio si ricade sul manichino senza crash. La CI scarica
  i file CC0 nel bundle prima di compilare (il vecchio esperimento Blender
  è stato tolto: la conversione falliva sugli URI immagine spezzati del
  glTF, ora si usa il glTF originale).
- Onestà dichiarata: su questo personaggio NON sono ancora implementati
  viso-foto, effetto delle misure sulle ossa, auto-camera e bagliore
  muscolare selettivo (il bagliore sul corpo intero c'è); il manichino
  resta disponibile disattivando il selettore.

## 1.1.8 (build 11)

- **Avatar personale (beta)**: in SISTEMA si importa un proprio modello 3D
  (.usdz, .usda, .dae o .obj, con SceneKit nativo) e lo si usa al posto del
  manichino nell'Home: ruota col dito, si inquadra da solo qualunque siano
  le unità di misura del file e mostra le animazioni contenute nel file.
  Onestà dichiarata: gli esercizi NON animano ancora il modello importato
  (è la fase 2 del piano in docs/STUDIO-AVATAR3D.md) e il file non entra
  nei backup: dopo un ripristino va reimportato.
- **Copia link IPA per LiveContainer**: il banner aggiornamenti su Home e
  la scheda AGGIORNAMENTI in SISTEMA ora hanno il bottone che copia il
  link diretto dell'IPA, da incollare in LiveContainer › Installa da URL
  (il link è anche visibile come testo selezionabile).
- **Esperimento in CI (nessun effetto in app)**: la CI converte con Blender
  il personaggio CC0 rigged di Quaternius (Universal Base Characters,
  licenza CC0 verificata dentro il pacchetto) in .dae e .usd e li pubblica
  sul branch bozza-modello-3d: è la preparazione della fase 2, guidare lo
  scheletro di un personaggio vero con le pose già calibrate. Il passo non
  blocca la build.

## 1.1.7 (build 10)

- **Scarpe piatte a terra (caviglia V4)**: nelle pose di contatto le scarpe
  rigidamente figlie dello stinco si inclinavano col corpo e le punte
  affondavano fino a 14 cm DENTRO la pedana (push-up e plank erano i peggiori;
  era parte del "molto buggato" visto sul telefono). Aggiunto il giunto
  caviglia con `footPitch` nella posa: push-up, plank e panca lo impostano
  per tenere la suola piatta sul pavimento per TUTTO il ciclo (anche durante
  l'interpolazione). In panca anche il ginocchio piu' piegato cosi' i piedi
  arrivano a terra. Verificato fotogramma per fotogramma nello studio di
  rendering locale ricostruito: minimo del corpo sotto lo zero da -14 cm
  a -0.6 cm.

## 1.1.6 (build 9)

- **Build 9**: corretto il test dell'IK: i bersagli fuori portata non
  possono pretendere la mano a un centimetro dal bersaglio (e' la run #24
  rossa: asserzioni sbagliate nel test, non nel codice dell'IK). Ora il
  test verifica che il braccio resti di un pezzo (omero e avambraccio
  mai allungati), che si tenda tutto verso un bersaglio lontano e che la
  mano si tenga alla distanza legale quando il bersaglio e' troppo vicino.
- **Mani inchiodate con cinematica inversa**: nelle trazioni, flessioni e
  plank le mani restano esattamente su sbarra o pavimento per TUTTO il
  ciclo, non solo nei fotogramma chiave (prima l'interpolazione le faceva
  scivolare via dall'attrezzo). IK analitica a due link (spalla+gomito)
  con saturazione morbida fuori portata e ramo del gomito scelto dal
  keyframe. Test: la mano torna sul bersaglio punto per punto, e il ciclo
  intero resta alla portata dell'ancora.
- **Una testa sola**: la mesh TrueDepth copre solo la faccia e senza
  retro: sul 3D sembrava una seconda testa sotto i capelli. La scansione
  resta salvata ma non si mostra più sul rig; il volto visibile è quello
  scolpito, con la foto selfie applicata via maschera sfumata quando c'è
  (ora la foto va sul 3D anche se esiste una scansione).
- Riferimento estetico (Sketchfab dell'utente) e studi su progetti open
  source per il futuro: il passo dopo sarà un personaggio rigged vero
  (scheletro + animazioni), la direzione type MakeHuman/BVH/glTF.

## 1.1.5 (build 7)

- **Niente più 2D dietro il 3D**: il disegno 2D era sempre disegnato sotto la
  vista 3D e si vedeva intorno al manichino, che così sembrava sbagliato e
  non ruotante. Ora il 2D è solo una vista alternativa (bottone 2D/3D),
  mai un sottofondo.
- **Demo animata affidabile**: l'animazione degli esercizi non partiva (il
  manichino restava fermo in posa neutra e la sbarra non compariva): i
  keyframe ora sono guidati da un task a 30 fps sul main actor,
  indipendente dal clock delle SCNAction. Ogni avvio demo lascia una riga
  "demo avviata: <esercizio>" nella diagnostica di SISTEMA.
- **Testa scansionata completata**: la mesh TrueDepth non ha capelli né
  orecchie, la testa risultava nuda: ora si aggiungono calotta, nuca e
  orecchie parametriche sopra la scansione.
- **Volto-foto sul 3D**: il piano della foto finiva DENTRO il cranio e con
  bordo da adesivo: ora sta appena davanti alla superficie con maschera
  ovale a bordo sfumato. Nuovo test della maschera.

## 1.1.4 (build 6)

- **Fix del 3D invisibile (il bug per cui "il 3D non va")**: il corpo è
  costruito in centimetri e la camera sta a 2,2 volte l'altezza, ma i piani
  depth di default di SceneKit tagliano a zFar = 100: tutta la scena finiva
  oltre il piano di taglio e restava invisibile, sotto si vedeva il
  disegno 2D di riserva (per questo non girava nulla). Ora zNear/zFar sono
  espliciti e la camera vede tutto il manichino.
- **Controllo aggiornamenti in-app**: Home mostra un banner quando sul
  canale c'è una build più recente, la scheda SISTEMA ha la sezione
  AGGIORNAMENTI con versione installata, ultima build pubblicata e bottone
  che scarica l'IPA (il numero di versione arriva da versione.json che la
  CI pubblica accanto all'IPA; nessun dato utente lascia l'iPhone).
- Confronto versioni numerico per componenti ("1.2.10" > "1.2.9"),
  parsing tollerante, testo privacy in SISTEMA aggiornato (unica rete:
  il controllo versione). Nuovi test: visibilità camera, parsing
  versione, confronto versioni.

## 1.1.3 (build 5)

- **Rig 3D riscritto da zero** (eccezione voluta dal proprietario alla regola
  "niente riscritture"): il manichino ora è costruito con mesh loftate
  (busto svasato vita/petto, arti con gonfiaggio muscolare, bacino, deltoidi,
  pettorali, trapezio, testa con cranio/mascella/naso/orecchie/capelli,
  scarpe visibili) invece di box e capsule generiche.
- **Pose degli esercizi riprogettate frame per frame** su un renderer di
  riferimento: ogni keyframe ha contatti verificati (mani a terra, punte dei
  piedi a terra, sbarra in mano, schiena appoggiata alla panca) e verso del
  corpo corretto (flessioni e plank proni, panca supina) - nella versione
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
