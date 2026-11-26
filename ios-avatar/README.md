# AvatarFit · Personal Operating System (iOS)

App iPhone iOS 17+ (Swift 6, SwiftUI + SceneKit + ARKit + Charts) pensata per
sideloading (.ipa su **LiveContainer** / AltStore / Sideloadly). Estetica
**pure black (#000000)** con accenti **neon ciano (#00E5FF)** e **oro (#FFD60A)**,
stile HUD (WHOOP / Nike Training Club / Iron Man). Tutti i dati **solo sul
dispositivo**: nessuna rete, nessun server, nessun account.

## Schermate (6 tab)

- **Home · AVATAR OS** — avatar 3D biomeccanico al centro, ruotabile a 360° e
  zoomabile con le gesture. **Animato**: scegli un esercizio dal selettore
  "Demo 3D esercizio" e l'avatar lo esegue in loop (trazioni, piegamenti, panca,
  squat, affondi, rematore, curl, alzate laterali, plank, movimento libero) con
  **glow pulsante sui gruppi muscolari che lavorano**. Il modello è parametrico
  dalle tue misure (altezza, peso, scarpe, testa, collo, spalle, petto, braccia,
  vita, fianchi, gambe) e rebuilda in tempo reale; BMI → spessore corporeo,
  allenamenti ultimi 30 giorni → definizione muscolare (evoluzione visiva).
  Scansione viso **TrueDepth** opzionale (mesh reale aplicada alla testa 3D) e
  foto di riferimento dal rullino salvata **solo nella sandbox dell'app**
  (mai caricata; non mandare foto in chat).
- **Giornata · TIMELINE 24H** — striscia dei giorni, anello di **completamento
  giornaliero %**, timeline ore 0–23 con eventi, spunta rapida e promemoria.
- **No Smoke** — contatore al secondo (giorni/ore/min/sec), **soldi risparmiati**
  (prezzo pacchetto + sigarette/giorno), barre di **rigenerazione fisica** con
  traguardi sbloccabili (20 min → 10 anni: cuore, sangue, polmoni, rischi).
- **Workout Pro** — **libreria esercizi** per gruppo muscolare e attrezzatura
  (trazioni, chin-up, flessioni e varianti, panca piana, rematore, curl, alzate
  laterali, squat, affondi, plank) con tasto **"+ Crea Nuovo Esercizio"**
  (nome, muscolo target, tipo di movimento 3D, serie, ripetizioni, carico).
  Ogni riga ha ▶ demo 3D e + per la sessione. **Workout attivo**: avatar che
  esegue l'esercizio corrente, contatore serie/ripetizioni, timer di recupero
  intelligente auto-avviato (anche tra un esercizio e il prossimo, vibrazione a
  fine recupero), **1RM stimato (Epley)** live e record, con **peso corporeo
  incluso per gli esercizi a corpo libero** (trazioni 100%, piegamenti ~64%,
  squat/affondi ~65% del peso del corpo, più eventuale zavorra), storico;
  grafico **progresso 1RM nel tempo** (SwiftUI Charts).
- **Tracker** — sezione modulare con "+": tracker personalizzabili (nome, emoji,
  unità, obiettivo giornaliero; modelli rapidi acqua/sonno/dieta/passi/lettura),
  anello di progresso, reset automatico a mezzanotte.
- **Sistema** — **Esporta/Importa backup JSON** (condivisione via share sheet e
  file picker: utile quando aggiorni l'ipa su LiveContainer), conteggi dei dati
  locali, azzeramento completo. Feedback **aptico** sui pulsanti principali.

## Volto dell'avatar: Memoji o selfie dalla galleria

iOS non lascia leggere le Memoji alle app di terze parti (nessuna API pubblica).
La via supportata: salva il tuo Memoji o uno selfie in Foto, poi in Home usa
"Volto dell'avatar (Memoji o selfie)": scelta manuale con il selettore di
sistema, oppure attiva "Automatica dalla galleria" e l'app prende da sola
l'ultimo selfie (in mancanza, l'ultima immagine del rullino). Il volto viene
ritagliato in cerchio e applicato alla testa dell'avatar 3D e 2D. La scansione
TrueDepth resta available dove il container la permette; se esiste una mesh
scansionata, ha la precedenza sulla foto. Tutto resta nella sandbox dell'app.

## Privacy e dati

- Tutto in locale: `Documents/AvatarFit/dati.json` (misure, aspetto, mesh viso,
  esercizi + storico, sessioni, calendario, fumo, tracker) e
  `foto-riferimento.jpg`. Zero chiamate di rete, funziona offline.
- Backup JSON esportabile/importabile da Sistema; la foto e la scansione viso
  restano sempre solo on-device.

## Struttura

```
ios-avatar/
├── project.yml            # spec XcodeGen (come il progetto principale del repo)
├── ExportOptions.plist    # per xcodebuild -exportArchive (metodo development)
├── Sources/
│   ├── AvatarFitApp.swift        # entry point, dark mode di default
│   ├── ContentView.swift         # TabView a 6 schede
│   ├── Models.swift              # modelli Codable + MuscleGroup/MovementType + 1RM
│   ├── AppStore.swift            # store @Observable, JSON locale, backup, fitness
│   ├── Theme.swift               # pure black + neon ciano/oro, card HUD, aptici
│   ├── HomeView.swift            # avatar 3D (2D solo come vista alternativa) + banner aggiornamenti
│   ├── AvatarRig.swift           # rig loftato: pose con contatti verificati, demo a 30 fps, volto sfumato
│   ├── AvatarSceneView.swift     # wrapper SceneKit (rotazione/zoom, demo animata)
│   ├── FaceScanView.swift        # scansione viso TrueDepth (ARKit) → mesh locale
│   ├── MeasurementsEditorView.swift  # "Le mie misure" + aspetto
│   ├── PhotoCard.swift           # foto di riferimento solo-locale (PHPicker)
│   ├── ExerciseLibraryView.swift # libreria esercizi espandibile (+ custom)
│   ├── ActiveWorkoutView.swift   # workout attivo: serie, recupero, 1RM
│   ├── WorkoutView.swift         # forma fisica, grafico 1RM, storico
│   ├── SmokeTrackerView.swift    # contatore no-smoke, risparmi, salute
│   ├── CalendarView.swift        # timeline 24h + completamento giornaliero
│   ├── CustomTrackersView.swift  # tracker modulari con "+"
│   ├── Aggiornamenti.swift       # controllo versione dal canale CI + banner/card di download
│   └── SystemView.swift          # aggiornamenti, backup export/import JSON, statistiche, reset
└── Resources/Assets.xcassets
```

## Build su macOS (serve un Mac con Xcode 15+)

```sh
cd ios-avatar
brew install xcodegen
xcodegen generate          # crea AvatarFit.xcodeproj
open AvatarFit.xcodeproj
# oppure:
xcodebuild -project AvatarFit.xcodeproj -scheme AvatarFit \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Su iPhone reale: seleziona il dispositivo in Xcode e firma con il tuo Apple ID
(gratuito) in Signing & Capabilities.

## Esportare il .IPA

1. Xcode: destinazione "Any iOS Device (arm64)" → **Product → Archive** →
   **Distribute App → Custom → Copy App** → `AvatarFit.ipa`.
2. Da riga di comando:
   ```sh
   xcodebuild -exportArchive -archivePath build/AvatarFit.xcarchive \
     -exportOptionsPlist ExportOptions.plist -exportPath build/
   ```
   (metti il tuo `teamID` in `ExportOptions.plist`; metodo `development`).
3. **Nota**: l'.ipa è un binario firmato compilabile **solo su macOS con Xcode**;
   in sandbox Linux non si può generare. Qui c'è il codice completo pronto.

## IPA automatico via CI (verificato)

Il workflow `.github/workflows/ipa-avatarfit.yml` gira a ogni push su
`vibe/avatarfit-ios-3061f8` (o a mano da Actions) su runner `macos-15`:
controlla le regole di codice, genera il progetto con XcodeGen, **esegue i
test unitari su simulatore (bloccanti: se falliscono niente IPA)**, compila la
Release non firmata per `generic/platform=iOS`, impacchetta e **verifica** la
struttura dell'`.ipa`, poi pubblica:

- artifact `AvatarFit-unsigned` del run (30 giorni di retention), e
- `AvatarFit.ipa` sul branch `bozza-ipa-avatarfit` (un commit sovrascritto ogni
  build): URL diretto
  `https://github.com/cipherdesk007-max/agenti-trading/raw/bozza-ipa-avatarfit/AvatarFit.ipa`

L'IPA è **non firmato**: per installarlo firma con il tuo Apple ID gratuito
(Sideloadly/AltStore/SideStore ri-firmano in automatico) oppure caricalo in
LiveContainer. Prima di aggiornare l'ipa esporta il backup JSON da SISTEMA.

## Screenshot automatici in CI

Il workflow scatta le schermate delle 6 schede sul simulatore con l'avatar di
prova (misure di un atleta famoso, rigenerate a ogni run) e le pubblica sul
branch `bozza-screenshot-avatarfit`. L'app accetta l'argomento di lancio
`--tab=<home|giornata|nosmoke|workout|tracker|sistema>` (whitelist, valore
sconosciuto → Home).

## Sideload su iPhone

- **LiveContainer**: apri l'app, "+", scegli `AvatarFit.ipa` → gira nel container
  con dati propri persistenti (usa Esporta backup prima di aggiornare l'ipa).
- **AltStore / SideStore** o **Sideloadly** con Apple ID gratuito: firma e
  installa, ri-firma automatica ogni 7 giorni.

## Verifica rapida del codice

Nessun `try!`, `fatalError` o force-unwrap (regola del repo). Swift 6 strict
concurrency: store `@MainActor`, viste SwiftUI. Non compilato in questa sandbox:
prima build da verificare su Mac con Xcode.
