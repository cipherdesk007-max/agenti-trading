import XCTest
@testable import QuantSwarmAlphaZero

/// Parità studio ↔ app per la GIORNALIERA (proposta 24 di docs/PROPOSTE.md).
///
/// `DailyParityFixture` contiene gli indicatori e le due condizioni calcolati
/// dallo STUDIO (tools/backtest_app.py) barra per barra su una serie fissa.
/// Qui le stesse barre passano da `DailyStrategy`: SMA200, SMA5, RSI2, ATR14,
/// segnale d'ingresso (chiusura sopra la SMA200 e RSI2 sotto 10) e condizione
/// d'uscita (chiusura sopra la SMA5) devono coincidere a ogni barra.
/// Non confronta quale candidato comprare fra più segnali: lì l'app chiede a
/// Kimi e lo studio prende l'RSI2 più basso (differenza misurata dalla prova
/// in ombra della proposta 22).
final class DailyParityTests: XCTestCase {
    private struct Row {
        let candle: Candle
        let sma200: Double
        let sma5: Double
        let rsi2: Double
        let atr14: Double
        let entry: Bool?
        let aboveSMA5: Bool
    }

    private func loadRows() -> [Row] {
        let start = Date(timeIntervalSince1970: 1_704_153_600) // 2024-01-02 UTC
        var rows: [Row] = []
        for (index, line) in DailyParityFixture.csv.split(separator: "\n").enumerated() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 10,
                  let open = Double(fields[0]), let high = Double(fields[1]),
                  let low = Double(fields[2]), let close = Double(fields[3]) else { continue }
            let candle = Candle(timestamp: start.addingTimeInterval(Double(index) * 86_400),
                                open: open, high: high, low: low, close: close, volume: 1_000)
            rows.append(Row(candle: candle,
                            sma200: Double(fields[4]) ?? 0, sma5: Double(fields[5]) ?? 0,
                            rsi2: Double(fields[6]) ?? 0, atr14: Double(fields[7]) ?? 0,
                            entry: fields[8].isEmpty ? nil : fields[8] == "1",
                            aboveSMA5: fields[9] == "1"))
        }
        return rows
    }

    func testAppComputesTheStudyIndicatorsAndSignalsOnEveryBar() {
        let rows = loadRows()
        XCTAssertEqual(rows.count, 560, "file di riferimento incompleto o illeggibile")
        guard rows.count == 560 else { return }
        let bars = rows.map(\.candle)
        var entries = 0
        var compared = 0
        for index in DailyParityFixture.firstDecisionBar..<rows.count {
            let row = rows[index]
            guard let expectedEntry = row.entry else {
                XCTFail("barra \(index): lo studio non ha valori")
                return
            }
            let prefix = Array(bars[0...index])
            guard let snapshot = DailyStrategy.snapshot(of: prefix) else {
                XCTFail("barra \(index): l'app non calcola gli indicatori")
                return
            }
            XCTAssertEqual(snapshot.sma200, row.sma200, accuracy: row.sma200 * 1e-9, "SMA200 alla barra \(index)")
            XCTAssertEqual(snapshot.sma5, row.sma5, accuracy: row.sma5 * 1e-9, "SMA5 alla barra \(index)")
            XCTAssertEqual(snapshot.rsi2, row.rsi2, accuracy: 1e-6, "RSI2 alla barra \(index)")
            // L'ATR parte da un valore iniziale diverso (media delle prime 14
            // escursioni nell'app, prima escursione nello studio): dopo 200
            // barre la differenza è sotto una parte su un milione.
            XCTAssertEqual(snapshot.atr14, row.atr14, accuracy: row.atr14 * 1e-5, "ATR14 alla barra \(index)")
            let entry = DailyStrategy.entryCandidate(symbol: "PARITA", bars: prefix) != nil
            XCTAssertEqual(entry, expectedEntry, "segnale d'ingresso alla barra \(index)")
            XCTAssertEqual(snapshot.close > snapshot.sma5, row.aboveSMA5, "uscita sopra la SMA5 alla barra \(index)")
            if entry { entries += 1 }
            compared += 1
        }
        XCTAssertEqual(compared, 560 - DailyParityFixture.firstDecisionBar)
        XCTAssertEqual(entries, DailyParityFixture.studyEntrySignals)
        XCTAssertGreaterThanOrEqual(entries, 15, "la serie deve contenere abbastanza segnali")
    }

    /// Sotto le 205 barre l'app non decide: nessun segnale con storico corto.
    func testNoSignalBelowTheMinimumHistory() {
        let rows = loadRows()
        guard rows.count == 560 else { return XCTFail("file di riferimento incompleto") }
        let short = Array(rows.map(\.candle)[0..<204])
        XCTAssertNil(DailyStrategy.snapshot(of: short))
        XCTAssertNil(DailyStrategy.entryCandidate(symbol: "PARITA", bars: short))
    }
}
