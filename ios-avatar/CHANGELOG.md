# CHANGELOG · AvatarFit

## 1.1.1 (build 3)

- Demo e screenshot della UI in CI: l'app accetta l'argomento di lancio
  `--tab=<home|giornata|nosmoke|workout|tracker|sistema>` (valore sconosciuto
  o assente → Home); il workflow scatta le schermate delle 6 schede sul
  simulatore con l'avatar di prova e le pubblica sul branch
  `bozza-screenshot-avatarfit`. Nessun cambiamento per chi usa l'app.

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
