import XCTest
@testable import QuantSwarmAlphaZero

/// Parità studio ↔ app per la CRYPTO V4 (proposta 24 di docs/PROPOSTE.md).
///
/// Lo studio è in Python (tools/backtest_trend_crypto.py), l'app in Swift: due
/// codici che devono applicare la stessa regola. `CryptoParityFixture` contiene
/// che cosa decide LO STUDIO barra per barra su una serie fissa (lo scrive
/// tools/genera_parita_crypto.py facendo girare il codice dello studio, non una
/// copia). Qui le stesse barre passano dal codice dell'app: stato (dentro o
/// fuori), ATR22, SMA200 e Donchian20 devono coincidere a ogni barra. Se una
/// delle due parti cambia formula, questo test si rompe.
final class CryptoParityTests: XCTestCase {
    private struct Row {
        let candle: Candle
        let inPosition: Bool?
        let atr: Double
        let sma: Double
        let donchian: Double
    }

    private func loadRows() -> [Row] {
        let start = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01 UTC
        var rows: [Row] = []
        for (index, line) in CryptoParityFixture.csv.split(separator: "\n").enumerated() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 8,
                  let open = Double(fields[0]), let high = Double(fields[1]),
                  let low = Double(fields[2]), let close = Double(fields[3]) else { continue }
            let candle = Candle(timestamp: start.addingTimeInterval(Double(index) * 86_400),
                                open: open, high: high, low: low, close: close, volume: 1)
            rows.append(Row(candle: candle,
                            inPosition: fields[4].isEmpty ? nil : fields[4] == "1",
                            atr: Double(fields[5]) ?? 0,
                            sma: Double(fields[6]) ?? 0,
                            donchian: Double(fields[7]) ?? 0))
        }
        return rows
    }

    func testAppDecidesLikeTheStudyOnEveryBar() {
        let rows = loadRows()
        XCTAssertEqual(rows.count, 720, "file di riferimento incompleto o illeggibile")
        guard rows.count == 720 else { return }
        let bars = rows.map(\.candle)
        var highest: Double?
        var entries = 0
        var exits = 0
        var compared = 0
        for index in CryptoParityFixture.firstDecisionBar..<rows.count {
            guard let expected = rows[index].inPosition else {
                XCTFail("barra \(index): lo studio non ha una decisione")
                return
            }
            guard let signal = CryptoStrategy.evaluate(symbol: "PARITA", closedBars: Array(bars[0...index]),
                                                       heldHighestClose: highest) else {
                XCTFail("barra \(index): l'app non ha dato un segnale")
                return
            }
            switch signal.state {
            case .entry:
                highest = signal.close
                entries += 1
            case .hold:
                highest = max(highest ?? signal.close, signal.close)
            case .exit:
                highest = nil
                exits += 1
            case .flat, .warmup:
                break
            }
            XCTAssertEqual(highest != nil, expected,
                           "barra \(index): l'app dice \(signal.state), lo studio \(expected ? "in posizione" : "fuori")")
            XCTAssertEqual(signal.atr22, rows[index].atr, accuracy: rows[index].atr * 1e-8, "ATR22 alla barra \(index)")
            XCTAssertEqual(signal.sma200, rows[index].sma, accuracy: rows[index].sma * 1e-8, "SMA200 alla barra \(index)")
            XCTAssertEqual(signal.donchianHigh, rows[index].donchian, accuracy: 1e-6, "Donchian20 alla barra \(index)")
            compared += 1
        }
        XCTAssertEqual(compared, 720 - CryptoParityFixture.firstDecisionBar)
        // La serie deve mettere alla prova la regola: ingressi e uscite veri.
        XCTAssertEqual(entries, CryptoParityFixture.studyEntries)
        XCTAssertEqual(exits, CryptoParityFixture.studyExits)
        XCTAssertGreaterThanOrEqual(entries, 5)
    }

    /// Con meno barre della media a 200 l'app non decide (lo studio parte
    /// dalla barra 200): nessun segnale operativo durante il riscaldamento.
    func testNoDecisionDuringWarmup() {
        let rows = loadRows()
        guard rows.count == 720 else { return XCTFail("file di riferimento incompleto") }
        let bars = Array(rows.map(\.candle)[0..<150])
        let signal = CryptoStrategy.evaluate(symbol: "PARITA", closedBars: bars, heldHighestClose: nil)
        XCTAssertEqual(signal?.state, .warmup)
    }
}
