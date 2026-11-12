"""STUDIO (non cambia l'app): pesi risk-parity (1/volatilit\u00e0 20gg) nella NOTTE vs peso uguale.

La NOTTE compra SPY/QQQ/IWM/GLD a peso uguale in asta di chiusura e vende
all'apertura. Qui si pesa ogni ETF per 1/vol(20) (ATR% o std dei rendimenti).

CRITERIO DI SCARTO: si scarta risk-parity se non migliora CAGR/perdita-max SIA
su 2006\u2013oggi SIA sugli ultimi 2 anni rispetto a peso uguale. 2 varianti provate
(peso uguale + 1/vol): il Deflated Sharpe (Bailey & L\u00f3pez de Prado 2014,
https://ssrn.com/abstract=2460551) conta poco con 2 sole prove, ma la scelta resta
su CAGR/maxDD, non sul picco di Sharpe.
"""

import numpy as np
import pandas as pd

from daily_study_lib import load_series

LIQUID = ["SPY", "QQQ", "IWM", "GLD"]
COST = 0.00003


def main():
    c = pd.DataFrame({s: load_series(s, "Close", start="2006-01-01", auto_adjust=False)
                      for s in LIQUID}).dropna()
    o = pd.DataFrame({s: load_series(s, "Open", start="2006-01-01", auto_adjust=False)
                      for s in LIQUID}).reindex(c.index)

    night = (o.shift(-1) / c - 1).dropna()  # close t -> open t+1
    vol = night.rolling(20).std()

    print("## STUDIO: NOTTE a peso uguale vs risk-parity 1/vol(20), costo 0,003%/lato\n")
    print("Criterio di scarto: entra solo se CAGR/maxDD migliora su ENTRAMBI i periodi.\n")
    print("| variante | 2006\u2013oggi CAGR / maxDD / Sharpe | ultimi 2 anni CAGR / maxDD |")
    print("|---|---|---|")

    def stats(r):
        eq = np.cumprod(1 + r.values)
        years = len(r) / 252
        cagr = eq[-1] ** (1 / years) - 1
        dd = (eq / np.maximum.accumulate(eq) - 1).min()
        sharpe = r.mean() / r.std(ddof=1) * np.sqrt(252)
        return cagr, dd, sharpe

    for label, w in [("peso uguale", pd.DataFrame(0.25, index=night.index, columns=night.columns)),
                     ("1/vol(20)", None)]:
        if w is None:
            w = (1 / vol).div((1 / vol).sum(axis=1), axis=0).shift(1).fillna(0.25)
        r = (night * w).sum(axis=1) - 2 * COST
        cagr, dd, sharpe = stats(r)
        rec = r[r.index >= r.index[-1] - pd.Timedelta(days=730)]
        rc, rd, _ = stats(rec)
        print(f"| {label} | {cagr:+.1%} / {dd:.0%} / {sharpe:.2f} | {rc:+.1%} / {rd:.0%} |")


if __name__ == "__main__":
    main()
