#!/usr/bin/env python3
"""Controlla nel codice dell'app le regole di AGENTS.md che si possono
verificare da sole: niente try!, niente fatalError, niente force-unwrap.

Uso:  python3 tools/controlla_regole.py        (dalla radice del repository)
Esce con errore ed elenca file e riga se trova una violazione.

Commenti e stringhe vengono tolti prima di cercare, così un punto esclamativo
dentro un testo non conta. Il "!" di negazione (if !x) non viene segnalato:
la ricerca guarda solo il "!" attaccato dopo un nome, una parentesi chiusa o
un "?", cioè il force-unwrap, e "as!" e i tipi dichiarati con "!".
"""
import pathlib
import re
import sys

RADICE = pathlib.Path(__file__).resolve().parent.parent
SORGENTI = RADICE / "Sources"


def fine_stringa(src: str, i: int) -> int:
    """src[i] è la virgoletta che apre una stringa normale: restituisce la
    posizione subito dopo quella che la chiude, saltando le interpolazioni
    \\( ... ) anche quando contengono altre stringhe."""
    j, n = i + 1, len(src)
    while j < n:
        c = src[j]
        if c == "\\" and j + 1 < n and src[j + 1] == "(":
            j = fine_parentesi(src, j + 1)
            continue
        if c == "\\":
            j += 2
            continue
        if c == '"':
            return j + 1
        if c == "\n":
            return j
        j += 1
    return n


def fine_parentesi(src: str, i: int) -> int:
    """src[i] è una parentesi aperta: restituisce la posizione subito dopo
    quella che la chiude."""
    j, n, profondita = i + 1, len(src), 1
    while j < n and profondita:
        c = src[j]
        if c == '"':
            j = fine_stringa(src, j)
            continue
        if c == "(":
            profondita += 1
        elif c == ")":
            profondita -= 1
        j += 1
    return j


def interpolazioni(stringa: str) -> str:
    """Il codice dentro le interpolazioni \\( ... ) di una stringa: è codice
    vero e va controllato come il resto."""
    pezzi, j, n = [], 0, len(stringa)
    while j < n:
        if stringa[j] == "\\" and j + 1 < n and stringa[j + 1] == "(":
            fine = fine_parentesi(stringa, j + 1)
            pezzi.append(" (" + solo_codice(stringa[j + 2:fine - 1]) + ") ")
            j = fine
            continue
        if stringa[j] == "\\":
            j += 2
            continue
        j += 1
    return "".join(pezzi)


def solo_codice(src: str) -> str:
    """Restituisce il sorgente senza commenti e con le stringhe svuotate (resta
    solo il codice delle interpolazioni), mantenendo lo stesso numero di righe."""
    out, i, n = [], 0, len(src)
    while i < n:
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i)
            fine = n if j < 0 else j + 2
            out.append("\n" * src[i:fine].count("\n"))
            i = fine
            continue
        grezza = re.match(r'(#+)"', src[i:])
        if grezza:
            chiusura = '"' + grezza.group(1)
            j = src.find(chiusura, i + len(grezza.group(0)))
            fine = n if j < 0 else j + len(chiusura)
            out.append('""' + "\n" * src[i:fine].count("\n"))
            i = fine
            continue
        if src.startswith('"""', i):
            j = src.find('"""', i + 3)
            fine = n if j < 0 else j + 3
            corpo = src[i:fine]
            out.append('""' + interpolazioni(corpo).replace("\n", " ") + "\n" * corpo.count("\n"))
            i = fine
            continue
        if src[i] == '"':
            fine = fine_stringa(src, i)
            out.append('""' + interpolazioni(src[i:fine]).replace("\n", " "))
            i = fine
            continue
        out.append(src[i])
        i += 1
    return "".join(out)


REGOLE = [
    ("try!", re.compile(r"\btry!")),
    ("fatalError", re.compile(r"\bfatalError\s*\(")),
    ("as!", re.compile(r"\bas!")),
    ("force-unwrap", re.compile(r"[A-Za-z0-9_\)\]\?>]!(?!=)")),
]


def main() -> int:
    trovate = []
    for percorso in sorted(SORGENTI.rglob("*.swift")):
        originale = percorso.read_text(encoding="utf-8")
        righe_originali = originale.split("\n")
        for numero, riga in enumerate(solo_codice(originale).split("\n"), 1):
            gia = set()
            for nome, regola in REGOLE:
                if regola.search(riga) and not gia:
                    gia.add(nome)
                    testo = righe_originali[numero - 1].strip()[:140]
                    trovate.append(f"{percorso.relative_to(RADICE)}:{numero}: {nome}: {testo}")
    file_letti = len(list(SORGENTI.rglob("*.swift")))
    if trovate:
        print(f"Regole di AGENTS.md violate in {len(trovate)} punti:")
        print("\n".join(trovate))
        return 1
    print(f"Regole di AGENTS.md rispettate: nessun try!, fatalError o force-unwrap in {file_letti} file Swift.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
