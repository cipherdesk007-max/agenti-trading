#!/usr/bin/env python3
"""Test di parita' studio <-> app per la CRYPTO V4 (proposta 24 di docs/PROPOSTE.md).

Lo studio (tools/backtest_trend_crypto.py, variante "donchian") e l'app
(Sources/Core/CryptoStrategy.swift) sono scritti in due linguaggi: possono
divergere senza che nessuno se ne accorga (il 14/11/2026 l'ATR era diverso).
Questo script fa girare IL CODICE DELLO STUDIO, non una sua copia, su una serie
di prezzi finta ma fissa (seme dichiarato) e scrive che cosa lo studio decide
barra per barra: in posizione o fuori, ATR22, SMA200, Donchian20. Il test Swift
Tests/CryptoParityTests.swift rifa' le stesse barre con il codice dell'app e
deve ottenere gli stessi valori.

La serie e' finta apposta: qui non si misura se la strategia guadagna (quello e'
lo studio sui prezzi veri), si misura se app e studio applicano la stessa regola.

Uso: python3 tools/genera_parita_crypto.py   (riscrive Tests/Fixtures/CryptoParityFixture.swift)
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
except ImportError:  # lo studio lo importa in testa ma qui non serve: nessun dato scaricato
    sys.modules["yfinance"] = types.ModuleType("yfinance")
import backtest_trend_crypto as studio  # noqa: E402

SEME = 20261114
BARRE = 720


def serie_finta():
    """Cammino casuale con fasi di salita e discesa: abbastanza rotture e uscite da provare la regola."""
    rng = np.random.RandomState(SEME)
    fasi = [(210, 0.0005), (90, 0.006), (70, -0.007), (100, 0.007), (60, -0.009), (110, 0.005), (80, -0.004)]
    deriva = np.concatenate([np.full(n, d) for n, d in fasi])[:BARRE]
    rendimenti = deriva + rng.normal(0, 0.025, BARRE)
    close = 100 * np.exp(np.cumsum(rendimenti))
    open_ = np.concatenate([[100.0], close[:-1]])
    high = np.maximum(open_, close) * (1 + np.abs(rng.normal(0, 0.012, BARRE)))
    low = np.minimum(open_, close) * (1 - np.abs(rng.normal(0, 0.012, BARRE)))
    # 6 decimali: gli stessi numeri, cifra per cifra, finiscono nel file letto dall'app.
    dati = {"Open": np.round(open_, 6), "High": np.round(high, 6), "Low": np.round(low, 6), "Close": np.round(close, 6)}
    return pd.DataFrame(dati, index=pd.date_range("2024-01-01", periods=BARRE, freq="D"))


def main():
    df = serie_finta()
    traccia = []
    _, operazioni = studio.simulate_trend(df, "donchian", 0.2, trace=traccia)
    stato = {i: (dentro, atr, sma, don) for i, dentro, atr, sma, don in traccia}
    ingressi = sum(1 for i in sorted(stato) if stato[i][0] and not stato.get(i - 1, (False,))[0])
    uscite = sum(1 for i in sorted(stato) if not stato[i][0] and stato.get(i - 1, (False,))[0])
    assert ingressi >= 5 and uscite >= 4, f"serie troppo povera: {ingressi} ingressi, {uscite} uscite"
    # Nessun confronto sul filo: una differenza di arrotondamento non deve poter cambiare un segnale.
    for i, (dentro, atr, sma, don) in stato.items():
        px = df["Close"].iat[i]
        assert abs(px - sma) > 1e-6 and abs(px - don) > 1e-6, f"barra {i} sul filo"

    righe = []
    for i in range(BARRE):
        o, h, l, c = (df[k].iat[i] for k in ("Open", "High", "Low", "Close"))
        if i in stato:
            dentro, atr, sma, don = stato[i]
            righe.append(f"{o:.6f},{h:.6f},{l:.6f},{c:.6f},{1 if dentro else 0},{atr:.10f},{sma:.10f},{don:.6f}")
        else:
            righe.append(f"{o:.6f},{h:.6f},{l:.6f},{c:.6f},,,,")
    uscita = os.path.join(QUI, "..", "Tests", "Fixtures", "CryptoParityFixture.swift")
    os.makedirs(os.path.dirname(uscita), exist_ok=True)
    with open(uscita, "w") as f:
        f.write("// GENERATO da tools/genera_parita_crypto.py: non modificare a mano.\n")
        f.write("// Che cosa decide LO STUDIO (tools/backtest_trend_crypto.py, variante \"donchian\")\n")
        f.write(f"// barra per barra su una serie finta e fissa (seme {SEME}, {BARRE} barre).\n")
        f.write("// Colonne: open,high,low,close,in posizione a fine barra (1/0),ATR22,SMA200,Donchian20.\n")
        f.write("// Le prime barre non hanno decisione: lo studio parte dalla barra 200.\n")
        f.write("enum CryptoParityFixture {\n")
        f.write(f"    static let firstDecisionBar = {min(stato)}\n")
        f.write(f"    static let studyEntries = {ingressi}\n")
        f.write(f"    static let studyExits = {uscite}\n")
        f.write('    static let csv = """\n')
        for riga in righe:
            f.write(riga + "\n")
        f.write('"""\n}\n')
    print(f"scritto {os.path.relpath(uscita)}: {BARRE} barre, {ingressi} ingressi, {uscite} uscite, "
          f"{len(operazioni)} operazioni contate dallo studio, prima decisione alla barra {min(stato)}")


if __name__ == "__main__":
    main()
