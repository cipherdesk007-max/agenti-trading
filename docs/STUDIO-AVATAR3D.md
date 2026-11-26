# Studio: portare l'avatar 3D oltre il manichino

Data: 26/11/2026, chiesto dal proprietario dopo aver indicato i modelli palestra
in vendita online (es. TurboSquid) come riferimento di qualita'.

## Obiettivo e vincoli

- Obiettivo: un avatar che sembri un personaggio "da vetrina", non un manichino
  da demo.
- Vincoli dell'app: SceneKit su iOS 17, tutto nel bundle (niente download a
  runtime), misure del corpo prese realmente dall'utente, nessun server,
  licenze pulite (nel repo NON entro mai asset di terzi senza licenza verificata).
- Cosa NON si puo' fare: prendere modelli altrui e metterli nell'app gratis.
  Le raccolte che il proprietario ha mostrato (TurboSquid, Sketchfab) restano
  RIFERIMENTO VISIVO: si possono guardare, non copiare.

## Cosa c'e' online (verificato il 26/11/2026)

| Fonte | Costo | Licenza per l'app | Formati | Note |
|---|---|---|---|---|
| TurboSquid | 20-200 $ a modello | Royalty-free per l'ACQUIRENTE: si puo' usare renderizzato in app, MA non si ridistribuisce l'asset | FBX, OBJ, 3DS, Max | I modelli "gym" rigged spesso includono pose/animate di serie |
| Sketchfab | Gratis (CC) o a pagamento | CC-BY gratis ma CHIEDE attribuzione; a pagamento licenza standard (uso in app ok) | glTF/GLB/USDZ automatici + originali | Download API serve chiave; oltre 1 milione downloadable |
| Quaternius | 0 € | CC0: uso commerciale senza attribuzione | FBX, OBJ, Blend (glTF su richiesta) | Personaggi rigged e animati, stile low-poly stilizzato |
| MakeHuman | 0 € | Asset CC0 (il solo codice e' AGPL, i modelli esportati no) | FBX, DAE, OBJ, glTF | Corpo parametrico: si materializzano misure reali |
| Mixamo (Adobe) | 0 € | Royalty-free dentro progetti commerciali, MA non ridistribuire gli asset; serve account Adobe e download A MANO | FBX con scheletro | Miglior banco di animazioni umane gratis in rete |

## Pero' del manichino procedurale attuale

Il rig di AvatarFit e' generato da codice (loft di profili con le misure
dell'utente). Punte di forza: coerenza totale con le misure (spalle, vita,
bacino, testa), zero dipendenze, zero asset. Tetto onesto: sara' sempre un
manichino stilizzato, non una scultura. Da 1.1.7 ha anche mani complete
(palmo, quattro dita, pollice) e ombra di contatto.

## Tre percorsi possibili

### A. Continuare il procedurale (fatto fino a 1.1.7)
- Costo: 0 €. Sforzo: piccolo per ogni miglioramento.
- Risultato: manichino curato ma tetto estetico basso rispetto ai modelli
  venduti. Vantaggio unico incommensurabile: il corpo sono LE TUE misure.

### B. Personaggio rigged CC0 dentro l'app
- Fonti: Quaternius (stilizzato) o MakeHuman (realistico, parametrico).
- Tecnica verificata: SceneKit supporta animazioni skeletal da Collada
  (SCNSkinner / CAAnimation) e da USDZ; i DAE di Mixamo/Blender girano in
  SceneKit da anni. Il file DAE/USDZ entra nel bundle e le pose che oggi
  guidano il manichino si riportano sull'osso dello scheletro.
- Ostacolo onesto: la conversione/pose serve Blender; nella sandbox di
  sviluppo non si puo' installare (pip vietato). Alternativa: fare la
  conversione DENTRO la CI macOS (Homebrew + cache Actions), piu' lenta da
  iterare (run da ~16 minuti), oppure fare la conversione una volta sola e
  committare il file gia' pronto.
- Risultato: aspetto umanoide ok ma CC0 = stilizzato, non da vetrina.
- Personalizzazione: si perde quella fine (le misure diventano proporzioni a
  blocchi scalando gli ossi).

### C. Comprare il modello che piace e integrarlo
- Il proprietario sceglie il modello (TurboSquid/Sketchfab, budget tipico
  30-150 €), io verifico PRIMA dell'acquisto che formato e animazioni siano
  usabili (rigged + skeletal anim, FBX/glTF/USDZ), poi lo converto
  (pipeline Blender della CI come in B) e lo metto nell'app.
- Risultato: esattamente il look delle vetrine online, animationi comprese.
- Licenza: royalty-free per acquirente, uso in app lecito.

## Consiglio (opinione dichiarata, non verita')

- Se il "wow" e' l'obiettivo: C. Con 30-150 € si compra quello che il codice
  non potra' mai produrre.
- Se il budget e' zero: B con aspettative oneste (CC0 = stilizzato).
- A resta per la coerenza con le misure: e' la sola via in cui l'avatar ha
  il fisico misurato dell'utente.

## Cosa resta da decidere (proprietario)

1. Budget (se percorso C) e modello scelto.
2. Accettare di perdere la personalizzazione fine del corpo (B e C).
3. Se il volto-foto selfie/current deve restare (in B e C si sovrappone alla
   testa del modello: da studiare caso per caso).

## Mandato del 26/11 sera: motore nuovo in fasi, fase 1 consegnata

Il proprietario ha scelto: niente piu' solo manichino procedurale, si passa
all'architettura professionale (modello reale con scheletro e skinning,
animazioni skeletal, volto foto sul modello nuovo, tasto di importazione
del suo .usdz, aggiornamenti col link IPA copiabile per LiveContainer).
Il lavoro va a FASI, una build verde per fase (regole AGENTS.md: modifiche
piccole, una run CI a turno).

- **Fase 1 (build 1.1.8, consegnata)**: tasto "Importa avatar 3D" in
  SISTEMA (.usdz/.usda/.dae/.obj, SceneKit nativo, il modello sostituisce
  il manichino nell'Home ruotando col dito; onestà: gli esercizi non lo
  animano ancora) + copia link IPA (banner e SISTEMA).
- **Fase 2 (in corso)**: personaggio CC0 rigged dentro l'app, guidato dalle
  pose già calibrate del rig. Personaggio scelto: Quaternius Universal Base
  Characters (maschio e femmina "Superhero"): licenza CC0 verificata dentro
  il pack (License_Standard.txt), scheletro Unreal standard a 65 giunti
  (root/pelvis/spine_01..03/neck_01/Head/clavicle_l/upperarm_l/lowerarm_l/
  hand_l + dita/thigh_l/calf_l/foot_l/ball_l), occhi inclusi.
  Download: il flusso itch.io chiede "payment method" via API e non è
  automizzabile; si usa il mirror GitHub (release hkht-dev/
  b2k-poc-android tag quaternius-packs-2026-10-20, zip identici al pack).
  La CI (passo SPERIMENTALE, non blocca la build, da rimuovere a fine
  fase) installa Blender headless, converte i glTF in .dae (via collaudata
  per SceneKit/SCNSkinner) e .usd e pubblica tutto sul branch
  bozza-modello-3d con le texture. Poi: studio numerico offline del DAE
  (assi di riposo dei giunti) PRIMA di toccare Swift, mapping
  keyframe→ossa per tutti gli esercizi, e solo allora il personaggio
  sostituisce il manichino quando l'utente lo sceglie.
- **Fase 3**: volto-foto sulla testa del personaggio (texture/UV da
  verificare caso per caso) e scala degli ossi dalle misure dell'utente
  (a blocchi: la personalizzazione fine resta del manichino).
- **Onestà dichiarata**: le animazioni da palestra gratis di qualità NON
  esistono (le pose restano le nostre, già calibrate sui contatti), il
  personaggio CC0 è stilizzato non "da vetrina", e il percorso C (modello
  comprato su TurboSquid/Fab, 30-150 € + animazioni) resta aperto se il
  proprietario vuole quel look: la fase 2 rende il motore pronto anche
  per quel file