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
- **Accento único: il verde** (`Theme.green`) per l'azione primaria e gli stati
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
