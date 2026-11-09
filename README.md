# QuantSwarm-Alpha-Zero

Applicazione iOS 17+ in Swift 6, SwiftUI e SwiftData. Kimi (`kimi-k3.1-pro-highspeed`) genera segnali JSON vincolati; Alpaca fornisce market data IEX, conto, ordini bracket e liquidazione. Il progetto non contiene credenziali.

## Build e artifact

1. Mantieni la struttura della repository e effettua il push sul branch `main`.
2. GitHub Actions installa XcodeGen, genera il progetto e compila con `CODE_SIGNING_ALLOWED=NO`.
3. Scarica l'artifact `QuantSwarm-Alpha-Zero-unsigned`, contenente `QuantSwarm-Alpha-Zero.ipa`.
4. L'IPA è non firmato. AltStore e Sideloadly normalmente richiedono una fase di firma con un profilo valido; la compatibilità con TrollStore dipende da versione di iOS e metodo di installazione. Gli entitlement effettivi dipendono dal profilo usato per la firma finale.

Per una build locale su macOS:

```sh
brew install xcodegen
xcodegen generate --spec project.yml
xcodebuild -project QuantSwarmAlphaZero.xcodeproj -scheme QuantSwarmAlphaZero -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

## Avvio

1. Crea una API key Moonshot/Kimi sulla stessa piattaforma regionale dell'endpoint globale `https://api.moonshot.ai/v1`.
2. Usa inizialmente credenziali Alpaca paper. L'app convalida Kimi tramite `GET /v1/models` e Alpaca tramite `GET /v2/account` prima del salvataggio.
3. Inserisci simboli e news datate con fonte. Non è presente un aggregatore news automatico.
4. Attendi almeno 14 barre per il primo ATR. Il motore valuta ciascun simbolo al massimo una volta per ciclo di 60 secondi.
5. `STOP` ferma il motore senza chiudere posizioni. `HARD KILL SWITCH`, dopo conferma, cancella tutti gli ordini e richiede la chiusura a mercato di tutte le posizioni del conto configurato.

## Controlli implementati

- Keychain `kSecClassGenericPassword`, `kSecAccessControlBiometryAny`, `WhenUnlockedThisDeviceOnly`.
- JSON Schema Kimi rigido, parsing del solo `message.content`, sanificazione Markdown e validazione locale del segnale.
- WebSocket Alpaca con autenticazione, trade/barre, riconnessione con backoff e monitoraggio `NWPathMonitor`.
- ATR di Wilder su 14 barre; il valore viene riletto a ogni trade e aggiornato a ogni nuova barra.
- Kelly frazionato a un quarto, quantità intera, rischio massimo teorico dell'1%, controllo di feed e round-trip REST a 150 ms, deviazione massima dello 0,05%.
- Ordine bracket `limit` con take-profit e stop-loss server-side. Il limite riduce lo slippage ma non garantisce l'esecuzione né il prezzo dello stop in gap di mercato.
- Persistenza SwiftData degli ordini e aggiornamento degli esiti dai fill Alpaca. Il P&L calcolato non include commissioni o imposte non fornite dal broker.
- Un solo ordine/posizione per simbolo; nessuna mediazione o apertura duplicata.

## Limiti reali

- iOS decide quando eseguire BGTask e può sospendere WebSocket, rete e processi in background. Il codice non simula navigazione e non può garantire operatività 24/7. Per trading continuo serve un servizio server-side sempre attivo.
- Kimi K3.1 Pro usa temperatura fissa e reasoning sempre attivo; il connettore omette `temperature`. Nessun modello garantisce assenza di errori o rendimenti superiori.
- Il Keychain protegge i dati con le protezioni del dispositivo e Face ID, ma una generic password non diventa una chiave privata non esportabile nel Secure Enclave.
- Una API key usata direttamente da un'app distribuita è una credenziale lato cliente: non equivale a un segreto server-side. Usa chiavi con privilegi minimi e rotazione.
- La modalità live può causare perdite, inclusa perdita superiore al rischio teorico in caso di gap, rifiuti, liquidità insufficiente o indisponibilità del broker. Testare in paper trading non dimostra performance future.

## Riferimenti ufficiali

- Kimi K3.1 Pro: https://platform.moonshot.ai/docs/guide/kimi-k3-1-pro-quickstart
- Kimi JSON Mode: https://platform.moonshot.ai/docs/guide/use-json-mode-feature-of-kimi-api
- Alpaca streaming: https://docs.alpaca.markets/us/docs/streaming-market-data
- Alpaca ordini: https://docs.alpaca.markets/us/docs/orders-at-alpaca
- XcodeGen Project Spec: https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md
- Apple BackgroundTasks: https://developer.apple.com/documentation/backgroundtasks
- Swift Concurrency: https://docs.swift.org/latest/documentation/the-swift-programming-language/concurrency
