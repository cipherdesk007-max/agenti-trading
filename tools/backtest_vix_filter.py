"""STUDIO (non cambia l'app): filtro VIX sulla GIORNALIERA (blocca ingressi con VIX alto).

Dato ^VIX da yfinance (in app sarebbe la serie VIXCLS di FRED, vedi PROPOSTE 10).
Varianti: senza filtro, VIX > 25, > 30, > 35, e VIX > SMA20(VIX) + 2\u03c3.

CRITERIO DI SCARTO (per ogni variante): entra solo se CAGR/perdita-max migliora
SIA su 2006\u2013oggi SIA su 2016\u2013oggi E sugli ultimi 3 anni, non solo in un
sotto-periodo. Con 5 varianti provate lo Sharpe massimo \u00e8 gonfiato:
Deflated Sharpe (Bailey & L\u00f3pez de Prado 2014, https://ssrn.com/abstract=2460551)
— la scelta si fa su CAGR/maxDD robusti, non sul picco di Sharpe.
"""

import numpy as np
import pandas as pd
import yfinance as yf

from daily_study_lib import HEADER, load, row, simulate


def main():
    o, h, l, c = load()
    vix = yf.download("^VIX", start="2004-06-01", auto_adjust=True, progress=False)["Close"].reindex(c.index).ffill()
    vix_ma = vix.rolling(20).mean()
    vix_sd = vix.rolling(20).std()

    print("## STUDIO: filtro VIX sulla giornaliera (regole dell'app, ^VIX da yfinance)\n")
    print("Criterio di scarto: entra una soglia solo se CAGR/maxDD migliora su TUTTI e tre i periodi. "
          "5 varianti: Deflated Sharpe, no scelta sul picco di Sharpe.\n")
    print(HEADER)
    base_eq, base_tr = simulate(o, h, l, c)
    print(row("BASE senza filtro VIX", base_eq, base_tr))
    variants = [
        ("VIX > 25", lambda d: vix.get(d, 0) > 25),
        ("VIX > 30", lambda d: vix.get(d, 0) > 30),
        ("VIX > 35", lambda d: vix.get(d, 0) > 35),
        ("VIX > SMA20+2\u03c3", lambda d: vix.get(d, 0) > vix_ma.get(d, 0) + 2 * vix_sd.get(d, 0)),
    ]
    for label, blk in variants:
        eq, tr = simulate(o, h, l, c, block=blk)
        print(row(label, eq, tr))


if __name__ == "__main__":
    main()
