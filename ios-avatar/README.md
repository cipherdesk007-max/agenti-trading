# AvatarFit · app iOS personale (avatar 3D + tracker)

App iPhone iOS 17+ (Swift 6, SwiftUI + SceneKit + ARKit) pensata per sideloading
(LiveContainer / AltStore / Sideloadly). Interfaccia dark minimale stile dashboard,
tutti i dati **solo sul dispositivo** (nessuna rete, nessun server, nessun account).

## Schermate

- **Home** — avatar 3D interattivo al centro (ruota a 360° trascinando, zoom con il
  pizzico). Il modello è parametrico e si rebuilda in tempo reale dalle misure:
  altezza, peso, scarpe, testa, collo, spalle, petto, braccia, vita, fianchi, gambe.
  BMI e peso cambiano lo spessore del corpo; gli allenamenti degli ultimi 30 giorni
  (`fitness`) aumentano la massa muscolare. colori pelle/capelli/outfit
  personalizzabili in "Le mie misure" → "Aspetto".
- **Scansione viso (opzionale)** — con la fotocamera frontale TrueDepth (ARKit
  `ARFaceTrackingConfiguration`) acquisisce la mesh reale del viso e la applica
  alla testa dell'avatar. Su iPhone senza TrueDepth resta la testa parametrica.
  La mesh è salvata solo in locale.
- **Foto di riferimento** — selettore foto del rullino (PHPicker): la foto viene
  salvata solo nella sandbox dell'app (`Documents/AvatarFit/foto-riferimento.jpg`)
  e mostrata come riferimento accanto all'avatar. **Non viene mai caricata da
  nessuna parte.** Non mandare foto in chat: restano nei log di sessione.
- **Calendario & routine** — striscia settimanale, eventi con data/ora, spunta
  "fatto" per le abitudini, promemoria (campanella), eliminazione con swipe.
- **No Smoke** — contatore in tempo reale (giorni/ore/min/sec) dall'ultimo
  mozzicone, soldi risparmiati (prezzo pacchetto + sigarette al giorno),
  barre di progresso del recupero della salute (20 min → 10 anni).
- **Workout** — registra pesi × ripetizioni o cardio a tempo, timer di recupero
  tra le serie, storico; il volume degli ultimi 30 giorni alimenta la "forma
  fisica" dell'avatar 3D.
- **Tracker personali** — pulsante "+" per creare tracker custom (nome, emoji,
  unità, obiettivo giornaliero) con modelli rapidi (acqua, sonno, dieta, passi,
  lettura); anello di progresso, +/−, reset giornaliero automatico.

## Privacy e dati

- Tutto è salvato in locale: `Documents/AvatarFit/dati.json` (misure, impostazioni,
  eventi, allenamenti, tracker, mesh viso) e `foto-riferimento.jpg`.
- L'app non fa nessuna chiamata di rete. Funziona offline.
- Nessuna credenziale, nessun token, nessun tracciamento nel codice.

## Struttura

```
ios-avatar/
├── project.yml            # spec XcodeGen (come il progetto principale del repo)
├── ExportOptions.plist    # per xcodebuild -exportArchive (metodo development)
├── Sources/
│   ├── AvatarFitApp.swift        # entry point, dark mode di default
│   ├── ContentView.swift         # TabView a 5 schede
│   ├── Models.swift              # modelli Codable (misure, fumo, eventi, workout, tracker)
│   ├── AppStore.swift            # store @Observable, persistenza JSON locale, fitness
│   ├── Theme.swift               # colori, card, hex
│   ├── HomeView.swift            # avatar 3D + chip + pulsanti
│   ├── AvatarSceneView.swift     # scena SceneKit parametrica (rotazione/zoom camera)
│   ├── FaceScanView.swift        # scansione viso TrueDepth (ARKit) → mesh locale
│   ├── MeasurementsEditorView.swift  # "Le mie misure" + aspetto
│   ├── PhotoCard.swift           # foto di riferimento solo-locale (PHPicker)
│   ├── SmokeTrackerView.swift    # contatore no-smoke, risparmi, salute
│   ├── CalendarView.swift        # calendario settimanale + eventi/routine
│   ├── WorkoutView.swift         # allenamenti, timer recupero, storico, forma
│   └── CustomTrackersView.swift  # tracker personalizzabili con "+"
└── Resources/Assets.xcassets
```

## Build su macOS (serve un Mac con Xcode 15+)

```sh
cd ios-avatar
brew install xcodegen
xcodegen generate          # crea AvatarFit.xcodeproj
open AvatarFit.xcodeproj
# oppure da riga di comando:
xcodebuild -project AvatarFit.xcodeproj -scheme AvatarFit \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Prova su iPhone reale: in Xcode seleziona il tuo iPhone come destinazione e
firma con il tuo Apple ID (Signing & Capabilities → Team personale, gratuita).

## Esportare il .IPA

1. In Xcode: destinazione "Any iOS Device (arm64)" → **Product → Archive**.
2. Nell'organizer: **Distribute App → Custom → Copy App** → ottieni `AvatarFit.ipa`.
   In alternativa da riga di comando dopo l'archive:
   ```sh
   xcodebuild -exportArchive -archivePath build/AvatarFit.xcarchive \
     -exportOptionsPlist ExportOptions.plist -exportPath build/
   ```
   (metti il tuo `teamID` in `ExportOptions.plist`; metodo `development` per
   sideload con firma del tuo Apple ID).
3. **Nota**: l'.ipa è un binario firmato che può essere compilato **solo su macOS
   con Xcode**. In questa sandbox Linux non è possibile generare il binario: qui
   c'è il codice completo e lo spec del progetto, pronto per la build.

## Sideload su iPhone

- **AltStore / SideStore** con Apple ID gratuito: installa l'ipa, si ri-firma
  automaticamente ogni 7 giorni (serve il computer acceso con AltServer, o
  l'installazione on-device di SideStore).
- **Sideloadly** (Windows/macOS): inserisci Apple ID, firma e installa.
- **LiveContainer**: apri LiveContainer, tocca "+" e scegli `AvatarFit.ipa`:
  viene iniettato nel container senza ri-firma ogni 7 giorni. L'app gira dentro
  il suo container con i propri dati locali.

## Verifica rapida del codice

Nessun `try!`, `fatalError` o force-unwrap (regola del repo, `tools/controlla_regole.py`
del progetto principale). Swift 6 strict concurrency: lo store è `@MainActor`.
