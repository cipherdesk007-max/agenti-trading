"""STUDIO (non cambia l'app): portafoglio combinato GIORNALIERA + NOTTE su un conto unico.

Idea del proprietario: invece di tre modalità separate, una modalità PORTAFOGLIO
che fa convivere le due strategie validate (giornaliera e notte) sullo stesso
conto, ognuna col suo budget. La veloce resta a parte (sperimentale).

Modello (fedele al design dell'app: book separati, budget = frazione dell'equity):
- GIORNALIERA: regole esatte dell'app (daily_study_lib.simulate, 15 ETF,
  RSI2<10 sopra SMA200, stop 2,5 ATR, uscita SMA5/10gg, max 3 posizioni,
  rischio 1%, tetto 25%, costi 0,05% per lato).
- NOTTE: ogni notte investe il 97% del proprio budget sui 4 ETF liquidi
  (SPY/QQQ/IWM/GLD a peso uguale, MOC in chiusura e OPG in apertura),
  costi d'asta 0,003% per lato (sensibilità anche a 0,01%).
- Il conto unico divide l'equity tra i due budget. Con capitalCap frazionario
  l'app riequilibra i budget a ogni ciclo (pesi costanti sull'equity corrente):
  qui e' il caso base; la variante "drift" (mai riequilibrare) e' di controllo.
- Regole DINAMICHE (l'idea "divide in base a dove c'è guadagno"), decise
  solo sull'ultimo semestre CHIUSO, applicate dal mese dopo:
  1. winner-tilt: 80% a chi ha reso di più nei 6 mesi precedenti, 20% all'altra;
  2. risk-parity: pesi proporzionali a 1/volatilita' dei 6 mesi precedenti
     (limiti 10–90%), che sposta il capitale verso la strategia piu' stabile.

Anti-autoinganno: le varianti provate sono dichiarate (8 split fissi + 2
dinamiche = 10); la vincitore viene ricontrollata a meta' campione
(2006–2015 vs 2016–oggi) perche' scegliere dopo aver visto tutto e' fortuna.

Output: markdown per il riepilogo del run (backtest.md / step summary).
"""
import numpy as np
import pandas as pd
import yfinance as yf

import daily_study_lib as lib

LIQUID = ["SPY", "QQQ", "IWM", "GLD"]
NIGHT_COST = 0.00003     # 0,003% per lato (aste sui 4 piu' liquidi)
NIGHT_COST_ALT = 0.0001  # sensibilità: 0,01% per lato
NIGHT_FRACTION = 0.97    # l'app investe il 97% del budget notte (cashBuffer 3%)

STATIC_SPLITS = [0.0, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 1.0]  # quota GIORNALIERA
REBAL_LOOKBACK = 126     # 6 mesi di borsa per le regole dinamiche


def load_streams():
    """Rende le due serie di rendimento SUL BUDGET di ciascuna strategia."""
    # GIORNALIERA: regole esatte dell'app, costi 0,05% per lato.
    o, h, l, c = lib.load()
    eq_d, trades = lib.simulate(o, h, l, c)
    r_d = eq_d.pct_change().dropna()

    # NOTTE: prezzi non rettificati (rapporto open/close della stessa notte),
    # paniere a peso uguale, costi per lato.
    closes, opens = {}, {}
    for sym in LIQUID:
        d = yf.download(sym, start="2006-01-01", auto_adjust=False, progress=False)
        if isinstance(d.columns, pd.MultiIndex):
            d.columns = d.columns.get_level_values(0)
        closes[sym], opens[sym] = d["Close"], d["Open"]
    c4 = pd.DataFrame(closes).dropna()
    o4 = pd.DataFrame(opens).reindex(c4.index)
    night = (o4.shift(-1) / c4 - 1).dropna()
    port_night = night.mean(axis=1) - 2 * NIGHT_COST
    port_night_alt = night.mean(axis=1) - 2 * NIGHT_COST_ALT
    r_n = (NIGHT_FRACTION * port_night).dropna()
    r_n_alt = (NIGHT_FRACTION * port_night_alt).dropna()

    # Allineamento sul calendario comune; giorni mancanti = rendimento 0
    # (es. notte festiva per l'una, signal-day per l'altra).
    idx = r_d.index.intersection(r_n.index)
    d_ = r_d.reindex(idx).fillna(0.0)
    n_ = r_n.reindex(idx).fillna(0.0)
    n_alt = r_n_alt.reindex(idx).fillna(0.0)
    return d_, n_, n_alt, trades


def combine(r_d, r_n, weights_d):
    """Conto unico: pesi (quota giornaliera per giorno) sull'equity corrente.
    Pesi costanti = riequilibro a ogni ciclo (capitalCap frazionario dell'app).
    `weights_d` e' una Series allineata a r_d (per le regole dinamiche) o None."""
    if weights_d is None:
        w = pd.Series(0.5, index=r_d.index)  # ignorato: vedi chiamanti statici
    else:
        w = weights_d
    r = w * r_d + (1 - w) * r_n
    return (1 + r).cumprod(), r


def monthly_decision_weights(r_d, r_n, rule):
    """Serie dei pesi della GIORNALIERA, decisi a fine mese sui 6 mesi
    precedenti e applicati dal mese dopo (mai col senno di poi)."""
    w = pd.Series(np.nan, index=r_d.index)
    dates = r_d.index
    months = [(y, m) for y, m in zip(dates.year, dates.month)]
    month_starts = pd.Series(range(len(dates)), index=dates).groupby(
        [dates.year, dates.month]).first()
    month_ends = pd.Series(range(len(dates)), index=dates).groupby(
        [dates.year, dates.month]).last()
    for i, ((y, m), i_end) in enumerate(month_ends.items()):
        i_start = int(month_starts.iloc[i])
        if i_end - REBAL_LOOKBACK < 5:
            continue  # serve un semestre di storia prima di decidere
        past_d = r_d.iloc[max(0, i_end - REBAL_LOOKBACK): i_end]
        past_n = r_n.iloc[max(0, i_end - REBAL_LOOKBACK): i_end]
        if rule == "winner":
            wd = 0.8 if (1 + past_d).prod() >= (1 + past_n).prod() else 0.2
        elif rule == "invvol":
            vd, vn = past_d.std(), past_n.std()
            if vd <= 0 or vn <= 0:
                wd = 0.5
            else:
                wd = (1 / vd) / (1 / vd + 1 / vn)
                wd = min(max(wd, 0.10), 0.90)
        else:
            raise ValueError(rule)
        # applica dal giorno dopo la fine del mese fino alla fine del mese dopo
        nxt = i + 1
        end_next = int(month_ends.iloc[nxt]) if nxt < len(month_ends) else len(dates) - 1
        w.iloc[i_end + 1: end_next + 1] = wd
    w = w.fillna(0.5)  # primo semestre: 50/50
    return w


def drift_equity(r_d, r_n, w0):
    """Variante di controllo: budget iniziali fissi, MAI riequilibrati
    (ogni strategia ricompone da sola sul proprio budget)."""
    ed = (1 + r_d).cumprod()
    en = (1 + r_n).cumprod()
    return w0 * ed + (1 - w0) * en


def metrics3(eq):
    """CAGR / maxDD / Sharpe sulle tre finestre standard degli studi."""
    cells = []
    for start, end, _ in lib.WINDOWS:
        m = lib.metrics(eq, start, end)
        cells.append(f"{m['cagr']:+.1%} / {m['dd']:.0%} / {m['sharpe']:.2f}" if m else "—")
    return " | ".join(cells)


def main():
    r_d, r_n, r_n_alt, trades = load_streams()
    print("## STUDIO: portafoglio unico GIORNALIERA + NOTTE (conto paper unico)")
    print()
    print("Modello: due budget sullo stesso conto, capitalCap frazionario")
    print("(riequilibro dei budget a ogni ciclo, come farebbe l'app).")
    print("Colonne: CAGR / perdita max / Sharpe su 2006–oggi, 2016–oggi, ultimi 3 anni.")
    print()
    print(f"- giorni allineati: {len(r_d)}, {r_d.index[0].date()} → {r_d.index[-1].date()}")
    corr = r_d.corr(r_n)
    print(f"- correlazione rendimenti giornaliera/notte: {corr:+.2f} "
          "(vicina a 0 = la combinazione diversifica, come sperato)")
    n_tr_d = len(trades)
    print(f"- giornaliera: {n_tr_d} trade simulati con le regole esatte dell'app;")
    print(f"- notte: ogni notte il {NIGHT_FRACTION:.0%} del budget notte sui 4 liquidi, "
          f"costi {NIGHT_COST:.3%}/lato ({NIGHT_COST_ALT:.2%} nella sensibilità).")
    print()

    # 1) Split fissi (incluse le due strategie da sole come estremi).
    print("### 1 · Split fissi del conto (quota GIORNALIERA / quota NOTTE)")
    print()
    print("| split G/N | 2006–oggi | 2016–oggi | ultimi 3 anni |")
    print("|---|---|---|---|")
    best_static = {}
    rows = {}
    for wd in STATIC_SPLITS:
        eq, r = combine(r_d, r_n, pd.Series(wd, index=r_d.index))
        rows[wd] = eq
        print(f"| {wd:.0%} / {1 - wd:.0%} | {metrics3(eq)} |")
    print()
    print("Riferimento: 100%/0% e' la GIORNALIERA da sola, 0%/100% la NOTTE da sola.")
    print()

    # 2) Regole dinamiche "insegui chi guadagna" (decisioni solo su dati passati).
    print("### 2 · Allocazione dinamica (decisa a fine mese sui 6 mesi precedenti)")
    print()
    print("| regola | 2006–oggi | 2016–oggi | ultimi 3 anni |")
    print("|---|---|---|---|")
    dyn_eq = {}
    for rule, label in [("winner", "winner-tilt 80/20"), ("invvol", "risk-parity 1/vol (10–90%)")]:
        w = monthly_decision_weights(r_d, r_n, rule)
        eq, _ = combine(r_d, r_n, w)
        dyn_eq[rule] = eq
        print(f"| {label} | {metrics3(eq)} |")
    print()
    print("Le regole dinamiche guardano SOLO il semestre precedente: nessun senno")
    print("di poi dentro la serie, ma scegliere la migliore dopo aver visto tutte")
    print("le tabelle resta una scelta post-hoc (vedi controllo qui sotto).")
    print()

    # 3) Controllo meta' campione: la regola migliore regge fuori campione?
    print("### 3 · Controllo anti-fortuna: prima metà (2006–2015) contro seconda (2016–oggi)")
    print()
    half = pd.Timestamp("2016-01-01")
    print("| variante | 2006–2015 | 2016–oggi |")
    print("|---|---|---|")

    def half_cells(eq):
        out = []
        for lo, hi in [("2006-01-01", "2015-12-31"), ("2016-01-01", None)]:
            m = lib.metrics(eq, lo, hi)
            out.append(f"{m['cagr']:+.1%} / {m['dd']:.0%} / {m['sharpe']:.2f}" if m else "—")
        return " | ".join(out)

    checks = [("split 30/70", rows[0.3]), ("split 50/50", rows[0.5]),
              ("split 40/60", rows[0.4]), ("winner-tilt", dyn_eq["winner"]),
              ("risk-parity", dyn_eq["invvol"])]
    for label, eq in checks:
        print(f"| {label} | {half_cells(eq)} |")
    print()

    # 4) Sensibilita': costi notte piu' alti e niente riequilibro (drift).
    print("### 4 · Sensibilità")
    print()
    print("| variante | 2006–oggi | 2016–oggi | ultimi 3 anni |")
    print("|---|---|---|---|")
    for wd in [0.3, 0.5]:
        eq, _ = combine(r_d, r_n_alt, pd.Series(wd, index=r_d.index))
        print(f"| split {wd:.0%}/{1 - wd:.0%}, costi notte 0,01%/lato | {metrics3(eq)} |")
    for wd in [0.3, 0.5]:
        eq_drift = drift_equity(r_d, r_n, wd)
        print(f"| split {wd:.0%}/{1 - wd:.0%}, MAI riequilibrato (drift) | {metrics3(eq_drift)} |")
    print()
    print("Giudizio da scrivere in docs/STATO.md SOLO con questi numeri: la")
    print("modalita' PORTAFOGLIO entra nell'app solo se (1) il CAGR combinato e'")
    print("sopra la media pesata delle due da sole OPPURE la perdita max scende")
    print("in modo robusto su TUTTE le finestre, (2) la variante scelta regge il")
    print("controllo a meta' campione, (3) la correlazione non esplode nei periodi")
    print("di crisi. Altrimenti restano due budget separati che l'utente cambia a mano.")


if __name__ == "__main__":
    main()
