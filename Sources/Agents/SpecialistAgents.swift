import Foundation

// MARK: - Formato standard del report

/// Parere di uno specialista del consiglio. "short" NON è un ordine di
/// vendita (il conto opera solo in acquisto): è un parere AVVERSO
/// all'acquisto del simbolo in questione.
enum CouncilSignal: String, Codable, Sendable, Equatable {
    case long, neutral, short, abstain

    var label: String {
        switch self {
        case .long: return "FAVOREVOLE"
        case .neutral: return "NEUTRALE"
        case .short: return "AVVERSO"
        case .abstain: return "SOSPESO"
        }
    }
}

/// Identità degli specialisti. Il Contrarian e il Chief non producono qui un
/// report: il Contrarian È il Kimi Reviewer avversario già esistente, il
/// Chief È il Kimi Brain che riceve tutti i report e decide.
enum CouncilAgentID: String, Codable, Sendable, CaseIterable, Identifiable, Equatable {
    case technical, quantitative, news, fundamental, portfolio, contrarian, chief

    var id: String { rawValue }

    var title: String {
        switch self {
        case .technical: return "Analisi tecnica"
        case .quantitative: return "Ricerca quantitativa"
        case .news: return "Notizie ed eventi"
        case .fundamental: return "Analisi fondamentale"
        case .portfolio: return "Portafoglio"
        case .contrarian: return "Contrarian"
        case .chief: return "Capo del consiglio"
        }
    }
}

/// Report standardizzato: TUTTI gli specialisti producono esattamente questo,
/// così il Chief confronta pareri omogenei e la memoria registra sempre lo
/// stesso formato (FASE 2/3 del progetto consiglio).
struct AgentReport: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    let agent: CouncilAgentID
    let timestamp: Date
    let asset: String
    let timeframe: String
    /// Analisi in una frase, con i numeri che la sostengono.
    let analysis: String
    let signal: CouncilSignal
    /// Completezza dei dati dietro la lettura (0...1). NON è una probabilità
    /// statistica calibrata: non va mai usata come win_probability.
    let confidence: Double
    /// Fatti verificabili che motivano il parere.
    let evidence: [String]
    /// Rischi identificati dallo specialista.
    let risks: [String]
    /// Dati che mancano e che non permettono un parere più forte.
    let missingData: [String]
    /// Condizione che invalida la lettura (cosa deve cambiare per smentirla).
    let invalidation: String

    init(agent: CouncilAgentID, timestamp: Date, asset: String, timeframe: String,
         analysis: String, signal: CouncilSignal, confidence: Double,
         evidence: [String], risks: [String] = [], missingData: [String] = [],
         invalidation: String) {
        id = UUID()
        self.agent = agent
        self.timestamp = timestamp
        self.asset = asset
        self.timeframe = timeframe
        self.analysis = analysis
        self.signal = signal
        self.confidence = min(1, max(0, confidence))
        self.evidence = evidence
        self.risks = risks
        self.missingData = missingData
        self.invalidation = invalidation
    }
}

// MARK: - Divergenze

/// Confronto dei pareri del consiglio: chi è favorevole, chi è avverso e se
/// la divergenza è "forte" (convivono pareri opposti). Il Chief deve motivare
/// esplicitamente una decisione che va CONTRO la divergenza rilevata.
enum CouncilDivergence {
    struct Assessment: Codable, Sendable, Equatable {
        /// nil = nessuna divergenza degna di nota.
        let note: String?
        let strong: Bool
        let favorable: [CouncilAgentID]
        let adverse: [CouncilAgentID]
        let abstained: [CouncilAgentID]
    }

    static func assess(_ reports: [AgentReport]) -> Assessment {
        let favorable = reports.filter { $0.signal == .long }.map(\.agent)
        let adverse = reports.filter { $0.signal == .short }.map(\.agent)
        let abstained = reports.filter { $0.signal == .abstain }.map(\.agent)
        let strong = !favorable.isEmpty && !adverse.isEmpty
        let note: String?
        if strong {
            note = "Divergenza nel consiglio: \(names(favorable)) favorevoli contro "
                + "\(names(adverse)) avversi. Il Chief deve motivare perché procede "
                + "nonostante i pareri contrari."
        } else if !adverse.isEmpty && favorable.isEmpty {
            note = "Nessun parere favorevole e \(adverse.count) avversi "
                + "(\(names(adverse))): un acquisto qui va contro tutto il consiglio."
        } else {
            note = nil
        }
        return Assessment(note: note, strong: strong, favorable: favorable,
                          adverse: adverse, abstained: abstained)
    }

    private static func names(_ ids: [CouncilAgentID]) -> String {
        ids.map(\.title).joined(separator: ", ")
    }
}

// MARK: - Specialisti locali (zero crediti Kimi: regole deterministiche)

/// Analisi tecnica multi-timeframe su indicatori già calcolati in codice
/// (nessun livello inventato dal modello). Parere deterministico: conta i fatti
/// tecnici allineati; servono almeno 3 condizioni favorevoli per "long",
/// trend e medie entrambi negativi per "short" (avverso).
enum TechnicalSpecialist {
    static func report(symbol: String, context: MarketContext?, now: Date = Date()) -> AgentReport {
        guard let context else {
            return AgentReport(
                agent: .technical, timestamp: now, asset: symbol, timeframe: "15m + 1m",
                analysis: "Nessuno storico candele disponibile: parere sospeso.",
                signal: .abstain, confidence: 0,
                evidence: [], missingData: ["candele 1m", "candele 15m", "indicatori"],
                invalidation: "Arriva lo storico candele dallo stream o dal backfill.")
        }
        let i15 = context.fifteenMinuteIndicators
        let i1 = context.oneMinuteIndicators
        let close15 = context.fifteenMinuteCandles.last?.close
        guard let close = close15, let sma200 = i15.sma200 else {
            return AgentReport(
                agent: .technical, timestamp: now, asset: symbol, timeframe: "15m + 1m",
                analysis: "Storico insufficiente sui 15m: parere sospeso.",
                signal: .abstain, confidence: 0.1,
                evidence: ["\(context.fifteenMinuteCandles.count) candele 15m disponibili"],
                missingData: ["SMA200 su 15m (servono 200 candele)"],
                invalidation: "Backfill completo dello storico 15m.")
        }
        var evidence: [String] = []
        var favorable = 0
        var unfavorable = 0
        let pct = { (_ v: Double) in String(format: "%.2f%%", locale: Locale(identifier: "en_US_POSIX"), v) }
        // 1. trend di fondo: prezzo sopra la SMA200 su 15m
        let aboveSMA200 = close > sma200
        if aboveSMA200 { favorable += 1 } else { unfavorable += 1 }
        evidence.append("chiusura 15m \(fmt(close)) "
                       + (aboveSMA200 ? "sopra" : "sotto") + " SMA200 \(fmt(sma200)) "
                       + "(" + pct((close / sma200 - 1) * 100) + ")")
        // 2. momentum: EMA12 vs EMA26 su 15m (direzione MACD-like)
        var emaAligned = false
        if let ema12 = i15.ema12, let ema26 = i15.ema26 {
            emaAligned = ema12 > ema26
            if emaAligned { favorable += 1 } else { unfavorable += 1 }
            evidence.append("EMA12 \(fmt(ema12)) " + (emaAligned ? ">" : "≤")
                           + " EMA26 \(fmt(ema26)) su 15m")
        }
        // 3. RSI14 su 15m: né esausto né ipercomprato
        var rsiOK = false
        if let rsi = i15.rsi14 {
            rsiOK = rsi >= 40 && rsi <= 72
            if rsiOK { favorable += 1 }
            evidence.append("RSI14 su 15m a \(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rsi))")
        }
        // 4. struttura: prezzo sui massimi/minimi delle 20 barre
        var nearBreakout = false
        var nearBreakdown = false
        if let high = i15.high20, let low = i15.low20 {
            nearBreakout = close >= high * 0.999
            nearBreakdown = close <= low * 1.001
            if nearBreakout { favorable += 1 }
            if nearBreakdown { unfavorable += 1 }
            evidence.append("range 20 barre 15m: min \(fmt(low)) - max \(fmt(high))")
        }
        // 5. conferma 1m: le medie veloci allineate anche nel breve
        var oneMinuteAligned = false
        if let ema12 = i1.ema12, let ema26 = i1.ema26 {
            oneMinuteAligned = ema12 > ema26
            if oneMinuteAligned { favorable += 1 }
            evidence.append("EMA12 " + (oneMinuteAligned ? ">" : "≤")
                           + " EMA26 anche su 1m (multi-timeframe)")
        }
        // 6. volatilità: ATR in percentuale del prezzo
        if let atr = i15.atr14 {
            evidence.append("ATR14 su 15m \(fmt(atr)) = \(pct(atr / close * 100)) del prezzo")
        }
        var risks: [String] = []
        if let rsi = i15.rsi14, rsi > 72 { risks.append("RSI14 oltre 72: acquisto esteso, rischio correzione immediata") }
        if let atr = i15.atr14, atr / close > 0.015 { risks.append("volatilità elevata (ATR > 1,5% del prezzo): stop più larghi") }

        var missing: [String] = []
        if i15.ema12 == nil || i15.ema26 == nil { missing.append("EMA 12/26 su 15m") }
        if i15.rsi14 == nil { missing.append("RSI14 su 15m") }
        if i15.high20 == nil || i15.low20 == nil { missing.append("massimi/minimi 20 barre") }
        if i1.ema12 == nil || i1.ema26 == nil { missing.append("conferma EMA su 1m") }

        let signal: CouncilSignal
        if favorable >= 3 && unfavorable <= 1 && !nearBreakdown {
            signal = .long
        } else if !aboveSMA200 && !emaAligned && (nearBreakdown || favorable == 0) {
            signal = .short
        } else {
            signal = .neutral
        }
        // Completezza dati: 0,5 base + 0,2 per timeframe completo + 0,1 di accordo multi-timeframe.
        let completeness = 0.5 + (missing.isEmpty ? 0.2 : 0) + (oneMinuteAligned == emaAligned && oneMinuteAligned ? 0.1 : 0)
        let confidence = signal == .abstain ? 0.1 : min(0.8, completeness + Double(min(favorable, 4)) * 0.05)
        return AgentReport(
            agent: .technical, timestamp: now, asset: symbol, timeframe: "15m + 1m",
            analysis: signal == .long
                ? "Quadro tecnico allineato all'acquisto: \(favorable) condizioni favorevoli su 5."
                : signal == .short
                ? "Trend e medie negativi: parere avverso all'acquisto."
                : "Tecnica né a favore né contro: condizioni miste (\(favorable) favorevoli, \(unfavorable) sfavorevoli).",
            signal: signal, confidence: confidence,
            evidence: evidence, risks: risks, missingData: missing,
            invalidation: aboveSMA200
                ? "Chiusura 15m sotto SMA200 \(fmt(sma200)) o EMA12 sotto EMA26."
                : "Chiusura 15m sopra SMA200 \(fmt(sma200)) con EMA12 > EMA26.")
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), v)
    }
}

/// Ricerca quantitativa: statistiche calcolate sulle candele (z-score,
/// volatilità realizzata, estensione). Metodi deterministici, nessuna
/// probabilità inventata.
enum QuantSpecialist {
    static func report(symbol: String, context: MarketContext?, now: Date = Date()) -> AgentReport {
        let closes = context?.fifteenMinuteCandles.map(\.close) ?? []
        guard closes.count >= 20 else {
            return AgentReport(
                agent: .quantitative, timestamp: now, asset: symbol, timeframe: "15m",
                analysis: "Servono almeno 20 chiusure 15m per statistiche affidabili: parere sospeso.",
                signal: .abstain, confidence: 0,
                evidence: ["\(closes.count) chiusure disponibili"],
                missingData: ["storico 15m ≥ 20 barre"],
                invalidation: "Backfill con almeno 20 candele 15m.")
        }
        let window = closes.suffix(20)
        let mean = window.reduce(0, +) / Double(window.count)
        let variance = window.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(window.count - 1)
        let sd = max(sqrt(variance), 1e-9)
        // La finestra ha sempre 20 chiusure (controllo sopra): l'ultima è il prezzo attuale.
        let lastClose = window.last ?? mean
        let z = (lastClose - mean) / sd
        // Volatilità realizzata sui rendimenti 15m dell'ultimo giorno di seduta (~26 barre).
        let returns = zip(closes, closes.dropFirst()).map { $1 / $0 - 1 }.suffix(26)
        let rMean = returns.reduce(0, +) / Double(returns.count)
        let rVar = returns.reduce(0) { $0 + ($1 - rMean) * ($1 - rMean) } / max(Double(returns.count - 1), 1)
        let realizedVol = sqrt(rVar)
        let trendUp: Bool
        if let sma200 = context?.fifteenMinuteIndicators.sma200, let last = closes.last {
            trendUp = last > sma200
        } else {
            trendUp = lastClose > mean
        }
        let signal: CouncilSignal
        if z <= -1.5 && trendUp {
            signal = .long
        } else if z >= 1.5 {
            signal = .short
        } else {
            signal = .neutral
        }
        let zText = String(format: "%+.2f", locale: Locale(identifier: "en_US_POSIX"), z)
        let volText = String(format: "%.3f%%", locale: Locale(identifier: "en_US_POSIX"), realizedVol * 100)
        return AgentReport(
            agent: .quantitative, timestamp: now, asset: symbol, timeframe: "15m",
            analysis: signal == .long
                ? "Prezzo statisticamente esteso al ribasso (z \(zText)) dentro un trend di fondo positivo: condizione da rimbalzo."
                : signal == .short
                ? "Prezzo statisticamente esteso al rialzo (z \(zText)): rischio mean-reversion contro un nuovo acquisto."
                : "Prezzo entro 1,5 deviazioni standard dalla media a 20 barre (z \(zText)): nessuna anomalia.",
            signal: signal,
            confidence: min(0.75, 0.3 + Double(min(closes.count, 100)) / 200),
            evidence: [
                "z-score della chiusura vs media 20 barre: \(zText)",
                "volatilità realizzata 15m: \(volText) per barra",
                "trend di fondo: " + (trendUp ? "sopra la SMA200 15m" : "sotto la SMA200/mediera 15m"),
            ],
            risks: abs(z) > 2.5 ? ["estensione oltre 2,5σ: i valori estremi possono estendersi ancora prima di rientrare"] : [],
            missingData: closes.count < 100 ? ["storico 15m corto (\(closes.count)/100 barre): statistiche meno stabili"] : [],
            invalidation: "Il rientro dello z-score oltre ±1 segnala che l'anomalia si è esaurita.")
    }
}

/// Notizie ed eventi dai titoli Benzinga già scaricati dall'app: conta i
/// titoli, estrae gli argomenti ad alto impatto e distingue le parole chiave
/// negativa/positiva. NON inventa sentiment: senza titoli si astiene.
enum NewsSpecialist {
    private static let highImpact = ["fed", "fomc", "inflation", "cpi", "rate", "interest", "payroll",
                                     "jobs", "earnings", "guidance", "gdp", "recession", "default",
                                     "downgrade", "bankrupt", "war", "sanction", "crash", "selloff",
                                     "stimulus", "election", "tariff", "cut", "hike"]
    private static let negative = ["crash", "selloff", "downgrade", "default", "bankrupt", "recession",
                                    "plunge", "drop", "miss", "warning", "fear", "risk", "layoff"]
    private static let positive = ["beat", "upgrade", "record", "rally", "surge", "soar", "growth",
                                    "profit", "bullish", "strong"]

    static func report(symbol: String, headlines: [String], now: Date = Date()) -> AgentReport {
        let clean = headlines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !clean.isEmpty else {
            return AgentReport(
                agent: .news, timestamp: now, asset: symbol, timeframe: "48h",
                analysis: "Nessuna notizia recente disponibile: il parere sulle notizie resta sospeso.",
                signal: .abstain, confidence: 0,
                evidence: [],
                missingData: ["titoli Benzinga delle ultime 48 ore"],
                invalidation: "L'arrivo di titoli di notizie riattiva questo parere.")
        }
        let lower = clean.map { $0.lowercased() }
        func hits(_ words: [String]) -> [String] {
            var found: Set<String> = []
            for word in words {
                // Confine di parola a inizio (come EventFilter48h): "war" non
                // falso-positiva su "software" o "toward", "rate" non su
                // "moderate", "cut" non su "haircut" o "shortcut". I titoli
                // sono gia' in minuscolo ma il match resta case-insensitive.
                if lower.contains(where: {
                    $0.range(of: "\\b\(word)", options: [.regularExpression, .caseInsensitive]) != nil
                }) { found.insert(word) }
            }
            return found.sorted()
        }
        let impact = hits(highImpact)
        let neg = hits(negative)
        let pos = hits(positive)
        let signal: CouncilSignal
        if neg.count >= 2 && neg.count > pos.count {
            signal = .short
        } else if pos.count >= 2 && pos.count > neg.count {
            signal = .long
        } else {
            signal = .neutral
        }
        var risks: [String] = []
        if !impact.isEmpty {
            risks.append("eventi macro/aziendali in giro (\(impact.joined(separator: ", "))): rischio di movimenti a gap")
        }
        return AgentReport(
            agent: .news, timestamp: now, asset: symbol, timeframe: "48h",
            analysis: signal == .short
                ? "\(clean.count) titoli con prevalenza negativa (\(neg.joined(separator: ", ")))."
                : signal == .long
                ? "\(clean.count) titoli con prevalenza positiva (\(pos.joined(separator: ", ")))."
                : "\(clean.count) titoli senza un orientamento chiaro.",
            signal: signal,
            confidence: 0.4,
            evidence: ["titoli delle ultime 48 ore: \(clean.count)",
                       "argomenti ad alto impatto: " + (impact.isEmpty ? "nessuno" : impact.joined(separator: ", "))],
            risks: risks,
            missingData: ["il sentiment è da parole chiave, non da analisi semantica: trattarlo come indizio, non come dato"],
            invalidation: "Nuove notizie dopo questo report cambiano il quadro degli eventi.")
    }

    /// Il testo notizie della modalità veloce è un blocco di righe: le righe
    /// non vuote sono i titoli.
    static func headlines(from text: String) -> [String] {
        text.components(separatedBy: .newlines)
    }
}

/// Analisi fondamentale: NON ci sono API di dati fondamentali tra i tre
/// servizi collegati (Alpaca fornisce barre e notizie, Kimi è il ragionatore).
/// Lo specialista esiste, dichiara il vincolo e SI ASTIENE sempre: è il
/// comportamento richiesto quando mancano i dati (mai inventarli).
enum FundamentalSpecialist {
    static func report(symbol: String, now: Date = Date()) -> AgentReport {
        AgentReport(
            agent: .fundamental, timestamp: now, asset: symbol, timeframe: "n/d",
            analysis: "Nessuna fonte di dati fondamentali collegata (bilanci, utili, "
                + "dividendi, macro): parere sempre sospeso, mai inventato.",
            signal: .abstain, confidence: 0,
            evidence: [],
            missingData: ["quotazioni fundamental (P/E, utili, ricavi)",
                          "data macro di riferimento per lo strumento"],
            invalidation: "Collegare una API di dati fondamentali sblocca questo parere.")
    }
}

/// Portafoglio: esposizione reale del bot (posizioni + ordini d'ingresso
/// pendenti), tetto posizioni, concentrazione e sovrapposizione per famiglia
/// di ETF. Parere avverso quando non c'è spazio o il simbolo è già in portafoglio.
enum PortfolioSpecialist {
    /// Famiglie di ETF per sovrapposizione di rischio (stesso indice/settore).
    private static let families: [[String]] = [
        ["SPY", "VOO", "IVV", "DIA"],       // large cap USA
        ["QQQ", "QQQM"],                     // Nasdaq 100
        ["IWM"],                             // small cap
        ["XLK", "VGT"],                      // tecnologia
        ["XLF", "VFH"],                      // finanziario
        ["XLE", "VDE"],                      // energia
        ["XLV", "VHT"],                      // salute
        ["XLY", "XLP", "XLI", "XLU", "XLB"], // altri settori (una famiglia ciascuno di fatto)
        ["GLD", "IAU"],                      // oro
        ["TLT", "IEF"],                      // obbligazioni lunghe
    ]

    static func report(symbol: String, positions: [AlpacaPosition], openOrders: [AlpacaOrder],
                       botEquity: Double, maxOpenPositions: Int, now: Date = Date()) -> AgentReport {
        let key = symbol.uppercased()
        let held = Set(positions.map { $0.symbol.uppercased() })
        let pending = Set(openOrders.filter(\.isEntryOrder).map { $0.symbol.uppercased() })
        var exposure = held
        exposure.formUnion(pending)
        exposure.insert(key)
        let alreadyThere = held.contains(key) || pending.contains(key)
        var evidence: [String] = [
            "posizioni aperte: \(held.count) per \(fmt(positions.reduce(0) { $0 + ($1.marketValueNumber ?? 0) })) USD",
            "ordini d'ingresso pendenti: \(pending.count)",
            "esposizione con \(key): \(exposure.count)/\(maxOpenPositions) simboli",
        ]
        var risks: [String] = []
        if let value = positions.first(where: { $0.symbol.uppercased() == key })?.marketValueNumber,
           botEquity > 0, value / botEquity > 0.25 {
            risks.append("\(key) già al \(String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value / botEquity * 100))% del capitale bot: concentrazione")
        }
        if let family = families.first(where: { $0.contains(key) }) {
            let overlap = family.filter { held.contains($0) && $0 != key }
            if let overlapFirst = overlap.first {
                risks.append("in portafoglio c'è già \(overlapFirst), stessa famiglia di \(key): rischio sovrapposto")
            }
        }
        let signal: CouncilSignal
        if alreadyThere {
            signal = .short
            evidence.append("\(key) è già in portafoglio o ha un ordine d'ingresso pendente")
        } else if exposure.count > maxOpenPositions {
            signal = .short
            evidence.append("tetto esposizione raggiunto (\(exposure.count)/\(maxOpenPositions))")
        } else {
            signal = .long
            evidence.append("posto libero: il portafoglio può accogliere \(key)")
        }
        return AgentReport(
            agent: .portfolio, timestamp: now, asset: symbol, timeframe: "ora",
            analysis: signal == .short
                ? "Il portafoglio non ha spazio per un nuovo acquisto di \(key)."
                : "Il portafoglio può accogliere \(key) entro i limiti di esposizione.",
            signal: signal,
            confidence: 0.9,
            evidence: evidence, risks: risks,
            missingData: botEquity <= 0 ? ["saldo del conto non ancora letto: la valutazione è sui conteggi, non sui valori"] : [],
            invalidation: "Il quadro cambia al prossimo ordine, uscita o al nuovo saldo del conto.")
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), v)
    }
}

// MARK: - Consiglio

/// Fotografia del consiglio per la dashboard: report, divergenza e decisione
/// finale, più l'esito del Contrarian quando è arrivato.
struct CouncilSnapshot: Identifiable, Sendable, Equatable {
    let id = UUID()
    let symbol: String
    let timestamp: Date
    let reports: [AgentReport]
    let divergence: CouncilDivergence.Assessment?
    let action: String
    let rationale: String
    var reviewerApproved: Bool?
}

enum Council {
    /// Report di tutti gli specialisti per una decisione della modalità veloce.
    static func fastModeReports(
        symbol: String,
        context: MarketContext?,
        newsText: String,
        positions: [AlpacaPosition],
        openOrders: [AlpacaOrder],
        botEquity: Double,
        maxOpenPositions: Int,
        now: Date = Date()
    ) -> [AgentReport] {
        [
            TechnicalSpecialist.report(symbol: symbol, context: context, now: now),
            QuantSpecialist.report(symbol: symbol, context: context, now: now),
            NewsSpecialist.report(symbol: symbol, headlines: NewsSpecialist.headlines(from: newsText), now: now),
            FundamentalSpecialist.report(symbol: symbol, now: now),
            PortfolioSpecialist.report(symbol: symbol, positions: positions, openOrders: openOrders,
                                       botEquity: botEquity, maxOpenPositions: maxOpenPositions, now: now),
        ]
    }

    /// Digest per un candidato della modalità giornaliera: tecnica e
    /// statistica dagli indicatori già calcolati in DailyStrategy, notizie
    /// dal candidato, fondamentali sempre sospesi. Il portafoglio non è qui
    /// perché il Brain giornaliero riceve già posizioni aperte e correlazioni.
    static func dailyDigest(for candidate: DailyStrategy.Candidate, now: Date = Date()) -> [AgentReport] {
        let s = candidate.snapshot
        let trendUp = s.close > s.sma200
        let pullbackDepth = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), s.rsi2)
        let atrPct = s.atr14 > 0 ? String(format: "%.2f%%", locale: Locale(identifier: "en_US_POSIX"), s.atr14 / s.close * 100) : "n/d"
        let technical = AgentReport(
            agent: .technical, timestamp: now, asset: candidate.symbol, timeframe: "giornaliero",
            analysis: trendUp
                ? "Ribasso di breve (RSI2 \(pullbackDepth)) dentro un trend sopra la SMA200: setup della strategia."
                : "Prezzo sotto la SMA200: il trend di fondo è negativo, niente setup.",
            signal: trendUp ? .long : .short,
            confidence: 0.7,
            evidence: [
                "chiusura \(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), s.close)) vs SMA200 \(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), s.sma200))",
                "RSI2 a \(pullbackDepth), soglia segnale < 10",
                "SMA5 a \(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), s.sma5)) (uscita a regola)",
                "ATR14 = \(atrPct) del prezzo (stop a 2,5 ATR)",
            ],
            missingData: [],
            invalidation: "Chiusura sotto la SMA200 o RSI2 che risale sopra 10 senza rimbalzo.")
        // Statistica: estensione del ribasso sulle ultime chiusure note.
        let closes = candidate.recentCloses
        var quantitative = AgentReport(
            agent: .quantitative, timestamp: now, asset: candidate.symbol, timeframe: "giornaliero",
            analysis: "Servono le chiusure recenti per la statistica: parere sospeso.",
            signal: .abstain, confidence: 0, evidence: [],
            missingData: ["ultime chiusure"], invalidation: "Chiusure recenti disponibili.")
        if closes.count >= 10 {
            let window = closes.suffix(10)
            let mean = window.reduce(0, +) / Double(window.count)
            let sd = max(sqrt(window.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(window.count - 1)), 1e-9)
            let z = ((window.last ?? mean) - mean) / sd
            quantitative = AgentReport(
                agent: .quantitative, timestamp: now, asset: candidate.symbol, timeframe: "giornaliero",
                analysis: z <= -1
                    ? "Chiusura estesa sotto la media a 10 sedute (z \(String(format: "%+.2f", locale: Locale(identifier: "en_US_POSIX"), z))): tipico del pullback profondo."
                    : "Chiusura entro un deviation standard dalla media a 10 sedute (z \(String(format: "%+.2f", locale: Locale(identifier: "en_US_POSIX"), z))).",
                signal: z <= -1 && trendUp ? .long : .neutral,
                confidence: 0.5,
                evidence: ["z-score a 10 sedute: \(String(format: "%+.2f", locale: Locale(identifier: "en_US_POSIX"), z))"],
                missingData: [],
                invalidation: "Il rientro dello z-score sopra 0 chiude l'anomalia statistica.")
        }
        let news = NewsSpecialist.report(symbol: candidate.symbol, headlines: candidate.news, now: now)
        let fundamental = FundamentalSpecialist.report(symbol: candidate.symbol, now: now)
        return [technical, quantitative, news, fundamental]
    }
}

// MARK: - Pagella retrospettiva per agente

/// Valutazione retrospettiva dei pareri di UN agente: ogni parere favorevole
/// è "vinto" se il prezzo è salito entro l'orizzonte di valutazione, ogni
/// parere avverso è "vinto" se è sceso. Neutri e sospesi non si giudicano.
/// È un'euristica documentata di primo ordine, non una statistica calibrata.
struct AgentScorecard: Codable, Sendable, Identifiable, Equatable {
    let agent: CouncilAgentID
    let judged: Int
    let hits: Int

    var id: String { agent.rawValue }
    var hitRate: Double? { judged >= 5 ? Double(hits) / Double(judged) : nil }

    /// Colleziona i punteggi da coppie (report, movimento % successivo).
    static func scorecards(from entries: [(reports: [AgentReport], outcomeMovePct: Double)]) -> [AgentScorecard] {
        var judged: [CouncilAgentID: Int] = [:]
        var hits: [CouncilAgentID: Int] = [:]
        for (reports, move) in entries {
            for report in reports {
                switch report.signal {
                case .long:
                    judged[report.agent, default: 0] += 1
                    if move > 0 { hits[report.agent, default: 0] += 1 }
                case .short:
                    judged[report.agent, default: 0] += 1
                    if move < 0 { hits[report.agent, default: 0] += 1 }
                case .neutral, .abstain:
                    break
                }
            }
        }
        return CouncilAgentID.allCases.compactMap { agent in
            guard let count = judged[agent] else { return nil }
            return AgentScorecard(agent: agent, judged: count, hits: hits[agent, default: 0])
        }
    }
}
