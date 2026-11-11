import Foundation

/// Report di sessione in .txt.
///
/// Politica spazio/prestazioni:
/// - durante il trading NON si scrive mai su disco: i log vivono solo in RAM;
/// - il file nasce solo a STOP / HARD KILL / chiusura app (snapshot), in Documents;
/// - ne esiste sempre al massimo UNO: ogni nuovo report sostituisce il precedente;
/// - il pulsante ELIMINA nella dashboard lo cancella dopo l'invio.
enum SessionReportBuilder {
    static let filePrefix = "quantswarm-sessione-"

    static func write(
        startedAt: Date,
        stoppedAt: Date,
        reason: String,
        symbols: [String],
        paperTrading: Bool,
        logs: [AgentLogEntry],
        decisions: [DecisionEntry],
        account: AccountSnapshot?,
        positions: [AlpacaPosition],
        performance: PerformanceStats?,
        capitalLines: [String] = []
    ) -> URL? {
        guard let directory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return nil }

        let url = directory.appendingPathComponent("\(filePrefix)\(fileStamp(stoppedAt)).txt")
        let text = buildText(
            startedAt: startedAt,
            stoppedAt: stoppedAt,
            reason: reason,
            symbols: symbols,
            paperTrading: paperTrading,
            logs: logs,
            decisions: decisions,
            account: account,
            positions: positions,
            performance: performance,
            capitalLines: capitalLines
        )
        do {
            // Un solo report alla volta: elimina i precedenti prima di scrivere.
            deleteAllReports(in: directory)
            // Cifrato con il telefono bloccato ed escluso dai backup iCloud/PC:
            // contiene equity, posizioni e decisioni.
            try Data((text).utf8).write(to: url, options: [.atomic, .completeFileProtection])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try? mutableURL.setResourceValues(values)
            return url
        } catch {
            return nil
        }
    }

    /// Report presente sul disco (es. generato alla chiusura dell'app):
    /// riappare in dashboard al prossimo avvio per essere esportato/eliminato.
    static func existingReportURL() -> URL? {
        guard let directory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first,
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { return nil }
        // Il nome contiene il timestamp yyyyMMdd-HHmmss: l'ordine alfabetico
        // coincide con quello cronologico.
        return files
            .filter { $0.lastPathComponent.hasPrefix(filePrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .last
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func deleteAllReports(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix(filePrefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func buildText(
        startedAt: Date,
        stoppedAt: Date,
        reason: String,
        symbols: [String],
        paperTrading: Bool,
        logs: [AgentLogEntry],
        decisions: [DecisionEntry],
        account: AccountSnapshot?,
        positions: [AlpacaPosition],
        performance: PerformanceStats?,
        capitalLines: [String]
    ) -> String {
        let rule = String(repeating: "=", count: 46)
        let thin = String(repeating: "-", count: 46)
        var lines: [String] = []
        lines.append("QUANTSWARM · ALPHA ZERO — REPORT DI SESSIONE")
        lines.append(rule)
        lines.append("Avvio:     \(dayTime(startedAt))")
        lines.append("Stop:      \(dayTime(stoppedAt))")
        lines.append("Motivo:    \(reason)")
        lines.append("Durata:    \(duration(from: startedAt, to: stoppedAt))")
        lines.append("Ambiente:  \(paperTrading ? "PAPER" : "LIVE")")
        lines.append("Simboli:   \(symbols.joined(separator: ", "))")
        lines.append("")

        lines.append("CONTO")
        lines.append(thin)
        if let account {
            lines.append("Equity:        \(fmt(account.equityValue)) USD")
            lines.append("Cash:          \(fmt(account.cashValue)) USD")
            lines.append("Buying power:  \(fmt(account.buyingPowerValue)) USD")
            if let dayPnL = account.dayPnL {
                lines.append("P&L giornata:  \(signed(dayPnL)) USD")
            }
        } else {
            lines.append("Dati conto non disponibili.")
        }
        lines.append("")

        if !capitalLines.isEmpty {
            lines.append("CAPITALE BOT")
            lines.append(thin)
            lines.append(contentsOf: capitalLines)
            lines.append("")
        }

        lines.append("METRICHE PERFORMANCE (trade chiusi)")
        lines.append(thin)
        if let performance {
            lines.append("Trade chiusi:    \(performance.completedTrades)")
            if let winRate = performance.winRate {
                lines.append("Win rate:        \(fmt(winRate * 100))%")
            }
            let factor = performance.profitFactor.map { fmt($0) } ?? "infinito (nessuna perdita)"
            lines.append("Profit factor:   \(factor)")
            if let expectancy = performance.expectancy {
                lines.append("Expectancy:      \(signed(expectancy)) USD/trade")
            }
            if let maxDrawdown = performance.maxDrawdown {
                lines.append("Max drawdown:    \(fmt(maxDrawdown)) USD")
            }
        } else {
            lines.append("Nessun trade chiuso con esito registrato.")
        }
        lines.append("")

        lines.append("POSIZIONI APERTE: \(positions.count)")
        lines.append(thin)
        if positions.isEmpty {
            lines.append("Nessuna.")
        } else {
            for position in positions {
                let entry = position.averageEntryPriceValue.map { fmt($0) } ?? "n/d"
                let now = position.currentPriceValue.map { fmt($0) } ?? "n/d"
                lines.append(
                    "\(position.symbol) \((position.side ?? "long").uppercased()) "
                        + "qty \(position.quantity) · entry \(entry) -> \(now) "
                        + "· P&L \(signed(position.unrealizedPLValue)) USD"
                )
            }
        }
        lines.append("")

        lines.append("DECISIONI KIMI (\(decisions.count))")
        lines.append(thin)
        if decisions.isEmpty {
            lines.append("Nessuna decisione in sessione.")
        } else {
            for entry in decisions {
                let decision = entry.decision
                lines.append(
                    "\(clockTime(entry.timestamp)) \(decision.symbol) "
                        + "\(decision.action.rawValue.uppercased()) "
                        + "conf \(Int(decision.confidence * 100))% — \(decision.rationale)"
                )
                if decision.action != .hold {
                    lines.append(
                        "    entry \(fmt(decision.entryPrice)) · stop \(fmt(decision.stopLoss)) "
                            + "· target \(fmt(decision.takeProfit))"
                    )
                }
            }
        }
        lines.append("")

        lines.append("DIAGNOSTICA (crash e blocchi segnalati da iOS)")
        lines.append(thin)
        if let diagnostics = DiagnosticsCollector.recentSummary() {
            lines.append(contentsOf: diagnostics)
        } else {
            lines.append("Nessun crash o blocco segnalato.")
        }
        lines.append("")
        lines.append("LOG SESSIONE (\(logs.count) righe)")
        lines.append(thin)
        for entry in logs {
            lines.append("\(clockTime(entry.timestamp)) [\(entry.agent.rawValue)] \(entry.message)")
        }
        lines.append("")
        lines.append("Generato da QuantSwarm Alpha Zero · elimina questo file dopo l'invio.")
        return lines.joined(separator: "\n")
    }

    private static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func dayTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m \(rest)s" }
        if minutes > 0 { return "\(minutes)m \(rest)s" }
        return "\(rest)s"
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func signed(_ value: Double) -> String {
        (value >= 0 ? "+" : "-") + fmt(abs(value))
    }
}
