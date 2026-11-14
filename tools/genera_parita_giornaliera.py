#!/usr/bin/env python3
"""Test di parita' studio <-> app per la GIORNALIERA (proposta 24 di docs/PROPOSTE.md).

Lo studio (tools/backtest_app.py) e l'app (DailyStrategy + Indicators in Swift)
devono calcolare gli stessi indicatori e riconoscere gli stessi segnali. Questo
script fa girare IL CODICE DELLO STUDIO (la funzione `indicators` e le sue due
condizioni: ingresso `chiusura > SMA200 e RSI2 < 10`, uscita `chiusura > SMA5`)
su una serie finta e fissa, e scrive i valori barra per barra. Il test Swift
Tests/DailyParityTests.swift rifa' le stesse barre con il codice dell'app.

Che cosa NON confronta, perche' nell'app non e' una formula: quale candidato
comprare fra piu' segnali (lo studio prende l'RSI2 piu' basso, l'app chiede a
Kimi; la prova in ombra della proposta 22 misura proprio questa differenza) e
le quantita' (RiskRules, con i suoi test).

Uso: python3 tools/genera_parita_giornaliera.py
"""
import os
import sys
import types

import numpy as np
import pandas as pd

QUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, QUI)
try:
    import yfinance  # noqa: F401
except ImportError:  # lo studio lo importa in testa ma qui non si scarica niente
    sys.modules["yfinance"] = types.ModuleType("yfinance")
import backtest_app as studio  # noqa: E402

SEME = 20261115
BARRE = 560
PRIMA = 204          # l'app decide da 205 barre (DailyStrategy.minimumBars)
RSI_SOGLIA = 10.0    # come rsi_thr dello studio e rsiEntryThreshold dell'app


def serie_finta():
    """Salita di fondo con ritracciamenti bruschi: tanti pullback sopra la media a 200."""
    rng = np.random.RandomState(SEME)
    fasi = [(230, 0.0012), (60, -0.0030), (120, 0.0016), (50, -0.0045), (100, 0.0020)]
    deriva = np.concatenate([np.full(n, d) for n, d in fasi])[:BARRE]
    rendimenti = deriva + rng.normal(0, 0.011, BARRE)
    close = 100 * np.exp(np.cumsum(rendimenti))
    open_ = np.concatenate([[100.0], close[:-1]]) * (1 + rng.normal(0, 0.002, BARRE))
    high = np.maximum(open_, close) * (1 + np.abs(rng.normal(0, 0.005, BARRE)))
    low = np.minimum(open_, close) * (1 - np.abs(rng.normal(0, 0.005, BARRE)))
    indice = pd.bdate_range("2024-01-02", periods=BARRE)
    return {k: pd.DataFrame({"X": np.round(v, 4)}, index=indice)
            for k, v in (("o", open_), ("h", high), ("l", low), ("c", close))}


def main():
    s = serie_finta()
    ind = studio.indicators(s["o"], s["h"], s["l"], s["c"], 5)
    C = s["c"]["X"].values
    S200, S5, R2, A = (ind[k][:, 0] for k in ("sma200", "smax", "rsi2", "atr"))
    righe, ingressi, uscite = [], 0, 0
    for i in range(BARRE):
        o, h, l, c = (s[k]["X"].iat[i] for k in ("o", "h", "l", "c"))
        if i < PRIMA:
            righe.append(f"{o:.4f},{h:.4f},{l:.4f},{c:.4f},,,,,,")
            continue
        # Le due condizioni dello studio (backtest_app.simulate, punto 3).
        entra = bool(C[i] > S200[i] and R2[i] < RSI_SOGLIA)
        esce = bool(C[i] > S5[i])
        assert abs(C[i] - S200[i]) > 1e-6 and abs(R2[i] - RSI_SOGLIA) > 1e-6 and abs(C[i] - S5[i]) > 1e-7, f"barra {i} sul filo"
        ingressi += entra
        uscite += esce
        righe.append(f"{o:.4f},{h:.4f},{l:.4f},{c:.4f},{S200[i]:.10f},{S5[i]:.10f},{R2[i]:.10f},{A[i]:.10f},"
                     f"{1 if entra else 0},{1 if esce else 0}")
    assert ingressi >= 15, f"serie troppo povera: {ingressi} segnali"
    uscita = os.path.join(QUI, "..", "Tests", "Fixtures", "DailyParityFixture.swift")
    os.makedirs(os.path.dirname(uscita), exist_ok=True)
    with open(uscita, "w") as f:
        f.write("// GENERATO da tools/genera_parita_giornaliera.py: non modificare a mano.\n")
        f.write("// Indicatori e condizioni calcolati dallo STUDIO (tools/backtest_app.py, funzione\n")
        f.write(f"// indicators) barra per barra su una serie finta e fissa (seme {SEME}, {BARRE} barre).\n")
        f.write("// Colonne: open,high,low,close,SMA200,SMA5,RSI2,ATR14,segnale d'ingresso (1/0),\n")
        f.write("// chiusura sopra la SMA5 = uscita (1/0). Vuote prima della barra 204.\n")
        f.write("enum DailyParityFixture {\n")
        f.write(f"    static let firstDecisionBar = {PRIMA}\n")
        f.write(f"    static let studyEntrySignals = {ingressi}\n")
        f.write('    static let csv = """\n')
        f.write("\n".join(righe) + "\n")
        f.write('"""\n}\n')
    print(f"scritto {os.path.relpath(uscita)}: {BARRE} barre, {ingressi} segnali d'ingresso, "
          f"{uscite} barre con chiusura sopra la SMA5, confronto dalla barra {PRIMA}")


if __name__ == "__main__":
    main()
