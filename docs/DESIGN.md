# DESIGN · direzione 2.0 "quadro strumenti" · 14/11/2026

Richiesta del proprietario: rifare il design, "studiato e fatto bene, ogni dettaglio definito". Questa sezione vale più di quelle sotto dove si contraddicono.

## Da dove nasce

L'app chiama già la prima schermata **Cruscotto**, il trading **motore**, i comandi **START** e **STOP**: il vocabolario è quello di un'auto. Il design lo prende sul serio: la schermata principale è un **quadro strumenti**. In un quadro strumenti i numeri sono neutri e il colore compare solo quando vuol dire qualcosa (le spie).

Che cosa non andava nella versione precedente (nero con un solo verde acceso):
- il verde voleva dire due cose insieme, "questo è un pulsante" e "stai guadagnando";
- in CRUSCOTTO il riquadro verde pieno "Saldo piccolo" era la cosa più visibile della schermata, più del saldo e dei comandi;
- lo stato del motore era scritto tre volte (riga in alto, titolo della card, riga sotto);
- numeri con la virgola e numeri con il punto nella stessa riga.

## Colori (ognuno con un solo significato)

| Nome | Valore | Dove |
|---|---|---|
| Grafite notte | `#0D1116` | fondo |
| Grafite strumento | `#151B22`, `#1E262F` | card e campi |
| Avorio strumento | `#F2EADA` | comandi (pulsanti pieni, scheda scelta, azioni di sezione) e saldo principale |
| Spia verde | `#33D485` | guadagno, motore acceso, stato a posto |
| Spia ambra | `#FFB840` | attenzione, STOP, consigli |
| Spia rossa | `#FF5459` | perdita, pericolo, LIVE |

Regola: se un elemento è verde, ambra o rosso deve dire uno stato o un risultato. Un comando non è mai verde.

## Caratteri

Solo i caratteri di sistema (nessun file da distribuire). Il **saldo principale** è l'unico numero "strumento": 36 pt, peso heavy, larghezza condensata, cifre a larghezza fissa. Tutti gli altri numeri: cifre a larghezza fissa, peso semibold. Titoli in headline, testi in caption/footnote, mai tutto maiuscolo tranne i due comandi fisici START e STOP.

## Schermata Cruscotto (ordine dall'alto)

```
 1.000,00 $                    [Paper]
 +3,30 $ oggi (+0,33%)
 ● Motore attivo                       <- stato, una volta
 [ consiglio su una riga            > ]
 ┌──────────────────────────────────┐
 │ In attesa: prossimo controllo ... │
 │ ▓▓▓░░░░░░░░░░░░                   │
 │ [ CONTROLLA ORA ]  [   STOP   ]   │  <- avorio / ambra
 └──────────────────────────────────┘
 Oggi · Posizioni · Catena agenti
```
Tutto allineato a sinistra; i comandi sono larghi quanto la card.

## Fasi

- **Fase 1 (fatta in questa versione)**: fondo grafite, comandi in avorio, saldo "strumento", consiglio su una riga, percentuale del giorno con la virgola, "CONTROLLA ORA" su una riga.
- **Fase 2 (dopo l'ok del proprietario sulle schermate della fase 1)**: separare in tutto il codice il colore dei comandi da quello degli stati (oggi `Theme.accent` è ancora verde in circa 80 punti, alcuni comandi e alcuni stati); stato del motore detto una volta sola; riga di spie (motore, mercato, protezioni, rete); numeri con la virgola ovunque; link "Passa a CRYPTO" non più blu.
- **Come si verifica**: screenshot delle 6 schermate prima e dopo, sul ramo `screenshot`; nessun elemento verde che sia un comando.

---

# DESIGN · da prototipo a prodotto finito · 12/11/2026

Studio fatto su: `Sources/Views/*.swift` + `Theme.swift`, i 6 screenshot sul ramo
`screenshot` (CRUSCOTTO, MERCATI, GRAFICO, DETTAGLI, BROKER, SISTEMA) e le Human
Interface Guidelines di Apple (https://developer.apple.com/design/human-interface-guidelines
— in particolare Typography, Color, Layout, Accessibility).

Scope: **solo `Sources/Views/*.swift` e `Theme.swift`**. Motore, cicli, servizi e
regole di rischio non si toccano. Tutte le funzioni di oggi restano raggiungibili.

## Cosa non funziona oggi (schermata per schermata)

- **CRUSCOTTO**: tutti i pannelli impilati e visibili insieme (stato, catena agenti,
  registro eventi, posizioni, ordini, Kimi, P&L): gerarchia debole, l'occhio non sa
  dove andare. Titoli e etichette tutti in MAIUSCOLO, bordo verde su ogni card.
- **MERCATI**: griglia 3×5 di tile, ognuna con bordo colorato (verde/blu) e chip
  gialle/arancioni ("FUORI CAPITALE", "TREND SU"): caotico. Il prezzo c'è ma non è
  il protagonista.
- **GRAFICO**: struttura buona (prezzo in alto — ora sempre visibile dopo i fix
  `05c3542`/`384a8d3` — picker intervallo, candele, sezioni sotto), ma etichette in
  maiuscolo, chip colorati ovunque, riquadri con bordo.
- **DETTAGLI**: curva + decisioni + pagella in card con bordo; testi d'aiuto lunghi inline.
- **BROKER**: lista ordini/posizioni con azioni manuali; ok funzionalmente, stile
  "terminale" (monospaziato dappertutto, maiuscole).
- **SISTEMA**: una lista lunga unica con testi d'aiuto sotto ogni riga ("Per cambiare
  conto ferma prima il motore", "Validata dal backtest…"): senza sezioni, il muro di
  testo è il problema principale.
- **LOGIN**: form chiavi; stile coerente ma con titres in maiuscolo e bordo verde.

Problemi trasversali: troppi colori d'accento (verde + ciano + amber + rosso sparsi),
monospaziato usato per testi e non solo per log/numeri, maiuscole come unico modo di
fare gerarchia, riquadri dentro riquadri con bordi colorati, testi d'aiuto sempre
visibili (in PRO spariscono ma la struttura resta "da prototipo").

## Sistema nuovo

### Colori (un solo accento)

- Sfondo e superfici: toni actuales (`Theme.background`/`surface`/`surfaceHigh`), ma
  **card a superficie piena senza bordo colorato**; bordo solo hairline
  `white.opacity(0.06)` se serve separare.
- **Accento unico: il verde** (`Theme.green`) per l'azione primaria e gli stati
  positivi. **Rosso/verde solo per guadagno/perdita e stati semantici**;
  **arancione solo per avvisi**. Il ciano (`DashboardPalette.cyan`) sparisce: al suo
  posto accento o `textSecondary`.
- Contrasto testi ≥ 4,5:1: `textPrimary` bianco, `textSecondary` white 0.65,
  `textTertiary` white 0.50 (senza scendere sotto).

### Tipografia

- **SF Pro (system) per tutti i testi**; **cifre tabellari** (`.monospacedDigit()`)
  per ogni numero (saldi, prezzi, P&L, percentuali). Monospaziato vero solo nel
  **registro eventi/log**.
- Niente titoli in maiuscolo: gerarchia con **dimensione e peso** — numero protagonista
  in `title3`/`largeTitle` heavy con cifre tabellari, etichette in `caption`/`caption2`
  `textSecondary`, corpo in `body`/`callout`.

### Spaziatura e forme

- Griglia **8 pt** (padding 8 / 16 / 24), angoli continui (`RoundedRectangle` continuous,
  radius 14 card / 10 piccole), **niente riquadri dentro riquadri**.

### Componenti unici (definiti in `Theme.swift`, usati ovunque)

- `AppCard` — superficie piena, niente bordo accento.
- `ValueRow` — etichetta sinistra `caption` secundaria, valore destra con cifre
  tabellari (opzionale colore con segno).
- `StatusChip` — pillola di stato con un solo colore semantico.
- `PrimaryButton` / `SecondaryButton` — uno pieno (accent), uno ghost.
- `SectionHeader` — titolo sezione `headline` + opzionale azione destra.
- `InfoButton` ("i") — mostra la spiegazione su tocco; in **MODALITÀ PRO** sparisce
  (come oggi, ma di default le spiegazioni sono corte: una riga).

### Struttura

- **CRUSCOTTO**: solo stato motore, azione principale (START/STOP), numeri di oggi
  (P&L, ordini, posizioni aperte) e posizioni. Catena agenti e registro eventi si
  aprono a richiesta (secondo livello).
- **SISTEMA**: diviso in sezioni — **Conto, Strategia, Rischio, Kimi, App** — invece
  di un'unica lista.

### Accessibilità

- Dynamic Type (niente `fixedSize` che tronca i numeri: `minimumScaleFactor` al più),
  contrasto ≥ 4,5:1, aree toccabili ≥ 44 pt, etichette VoiceOver su tutti i pulsanti
  a icona.

### Animazioni e aptica

- Animazioni brevi e sobrie (0,15–0,2 s, easeOut). Feedback aptico **solo su START,
  STOP e invio ordini** (già così: остав).

## Piano di realizzazione (un commit per schermata)

Ordine: **Theme e componenti → CRUSCOTTO → MERCATI e GRAFICO → DETTAGLI → BROKER →
SISTEMA → LOGIN**. Build verde dopo ogni commit; test UI aggiornati se cambiano gli
identificatori. Dopo ogni 2 schermate: `SCREENSHOT` e stop, gli screenshot li lancia
e guarda l'altro revisore.
