
"""Quanto capitale per notte? (decisione R1, da prendere con i dati)



La modalità NOTTE investe il 97% del conto ogni notte (cashBuffer 3%) e non può

avere stop sul broker: compra in asta di chiusura (MOC) e vende in asta di

apertura (OPG), fra le due non c'è prezzo. Questo studio risponde: se invece

investisse solo una frazione fissa f del conto, come cambiano CAGR e perdita

massima SUL CONTO?



I rendimenti a notte sono per importo, quindi lo Sharpe per dollaro investito

non cambia con f: cambia quanto del conto è esposto quando arriva la notte

peggiore (lo studio di STATO.md misura fino a −22% a frazione piena).



Criterio di decisione (da scrivere in docs/STATO.md insieme al risultato):

- tenere la frazione più piccola che mantiene il CAGR sul conto almeno metà di

  quello a frazione piena DOPO i costi;

- scartare qualunque frazione con CAGR prossimo a zero dopo i costi;

- la perdita massima sul conto deve scendere almeno in proporzione alla

  frazione (è l'unico motivo per ridurla).



Se nessuna frazione battibile emerge, la frazione resta 97% (comportamento

attuale) e la protezione resta il tetto del capitale (capitalCap), già presente.

"""

import numpy as np

import pandas as pd

import yfinance as yf



LIQUID = ["SPY", "QQQ", "IWM", "GLD"]

COST = 0.00003

FRACTIONS = [0.97, 0.75, 0.5, 0.25, 0.10]





def main():

    closes, opens = {}, {}

    for sym in LIQUID:

        d = yf.download(sym, start="2006-01-01", auto_adjust=False, progress=False)

        if isinstance(d.columns, pd.MultiIndex):

            d.columns = d.columns.get_level_values(0)

        closes[sym], opens[sym] = d["Close"], d["Open"]

    c = pd.DataFrame(closes).dropna()

    o = pd.DataFrame(opens).reindex(c.index)

    night = (o.shift(-1) / c - 1).dropna()

    port = night.mean(axis=1) - 2 * COST



    print("## NOTTE: frazione del conto investita ogni notte (R1)")

    print()

    print("Paniere a peso uguale SPY/QQQ/IWM/GLD (come l'app), costo 0,003% per lato,")

    print("2006–oggi. Ogni notte si investe la frazione fissa f del conto, il resto in cassa.")

    print("f = 97% è il comportamento attuale dell'app (cashBuffer 3%).")

    print()

    print("| frazione f | CAGR sul conto | perdita max sul conto | Sharpe sul conto | CAGR / \\|perdita\\| |")

    print("|---|---|---|---|---|")

    for f in FRACTIONS:

        r = f * port.values

        eq = np.cumprod(1 + r)

        years = len(r) / 252

        cagr = eq[-1] ** (1 / years) - 1

        dd = (eq / np.maximum.accumulate(eq) - 1).min()

        sharpe = r.mean() / r.std(ddof=1) * np.sqrt(252)

        ratio = cagr / abs(dd) if dd < 0 else float("nan")

        print(f"| {f:.0%} | {cagr:+.1%} | {dd:.0%} | {sharpe:.2f} | {ratio:.2f} |")



    rec = port[port.index >= port.index[-1] - pd.Timedelta(days=730)]

    print()

    print("Ultimi 2 anni (controllo che l'effetto non si sia spento):")

    print()

    print("| frazione f | rendimento 2 anni sul conto | perdita max sul conto |")

    print("|---|---|---|")

    for f in FRACTIONS:

        r = f * rec.values

        eq = np.cumprod(1 + r)

        total = eq[-1] - 1

        dd = (eq / np.maximum.accumulate(eq) - 1).min()

        print(f"| {f:.0%} | {total:+.1%} | {dd:.0%} |")

    print()

    print("Giudizio: ridurre f riduce la perdita max quasi in proporzione e il CAGR in")

    print("proporzione. Serve solo se il drawdown sul conto (−22% a f piena) è troppo.")

    print("Con l'app che può limitare il capitale notte via capitalCap, il tetto resta")

    print("la protezione principale: NON cambiare f senza riportare questi numeri in")

    print("docs/STATO.md.")





if __name__ == "__main__":

    main()
