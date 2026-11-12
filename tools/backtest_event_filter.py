"""STUDIO (non cambia l'app): filtro "evento 48h" prima dell'ingresso (giornaliera).

Nell'app il filtro sarebbe sulle notizie Benzinga delle 48h (Fed, CPI, halt).
Qui il backtest non ha le notizie: si usa un PROXY di prezzo/volatilit\u00e0 —
blocca i nuovi ingressi se nelle ultime 2 sedute SPY ha fatto |return| > 2,5%
o il VIX \u00e8 salito del >20% in una seduta. Se il proxy non migliora, non si
pu\u00f2 concludere nulla sulle notizie vere (da provare in ombra in paper).

CRITERIO DI SCARTO: si scarta se CAGR/maxDD non migliora su ENTRAMBI 2006\u2013oggi
e 2016\u2013oggi. 2 varianti (senza filtro + filtro proxy): Deflated Sharpe
(Bailey & L\u00f3pez de Prado 2014, https://ssrn.com/abstract=2460551) irrilevante
a 2 prove, ma la scelta resta su CAGR/maxDD.
"""

import numpy as np
import pandas as pd
import yfinance as yf

from daily_study_lib import HEADER, load, row, simulate


def main():
    o, h, l, c = load()
    spy_ret = c["SPY"].pct_change().abs()
    vix = yf.download("^VIX", start="2004-06-01", auto_adjust=True, progress=False)["Close"]
    vix_ret = vix.pct_change()
    event = ((spy_ret > 0.025) | (vix_ret > 0.20)).rolling(2).max().reindex(c.index).fillna(False)

    print("## STUDIO: filtro evento 48h (proxy prezzo/vol) prima dell'ingresso\n")
    print("Criterio di scarto: entra solo se CAGR/maxDD migliora su ENTRAMBI i periodi lunghi. "
          "Il proxy non \u00e8 la notizia vera: prima di applicarlo davvero va provato in ombra.\n")
    print(HEADER)
    base_eq, base_tr = simulate(o, h, l, c)
    print(row("BASE senza filtro", base_eq, base_tr))
    eq, tr = simulate(o, h, l, c, block=lambda d: bool(event.get(d, False)))
    print(row("filtro evento 48h (proxy)", eq, tr))


if __name__ == "__main__":
    main()
