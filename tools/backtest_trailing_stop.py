"""STUDIO (non cambia l'app): stop che segue il prezzo (trailing) vs stop fisso 2,5 ATR.

Il trailing GTC di Alpaca salirebbe con il prezzo e proteggerebbe i profitti.
Qui si simula lo stop trailing sullo stesso K*ATR14 usato dall'app, trainato
sulla chiusura precedente (stop_t = max(stop_{t-1}, close_{t-1} - K*ATR14)).

CRITERIO DI SCARTO (prima di guardare i numeri): si scarta il trailing se non
migliora il rapporto CAGR/perdita-max SIA su 2006\u2013oggi SIA su 2016\u2013oggi
rispetto allo stop fisso. Con 4 varianti provate (fissa + 3 K) lo Sharpe massimo
\u00e8 gonfiato dal multi-testing (Deflated Sharpe, Bailey & L\u00f3pez de Prado 2014,
https://ssrn.com/abstract=2460551): la scelta si fa su CAGR/maxDD, non sul picco
di Sharpe.
"""

import numpy as np

from daily_study_lib import ETFS, HEADER, load, row, simulate


def main():
    o, h, l, c = load()
    print("## STUDIO: trailing stop vs stop fisso 2,5 ATR (regole dell'app, costo 0,05%/lato)\n")
    print("Criterio di scarto: entra solo se CAGR/maxDD migliora su ENTRAMBI i periodi lunghi. "
          "Deflated Sharpe: 4 varianti, no scelta sul picco di Sharpe.\n")
    print(HEADER)
    base_eq, base_tr = simulate(o, h, l, c, trail=False)
    print(row("BASE stop fisso 2,5 ATR", base_eq, base_tr))
    for k in (2.0, 2.5, 3.0):
        eq, tr = simulate(o, h, l, c, stop_atr=k, trail=True)
        print(row(f"trailing {k} ATR", eq, tr))


if __name__ == "__main__":
    main()
