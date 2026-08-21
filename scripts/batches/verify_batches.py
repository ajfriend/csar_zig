# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = ["numpy", "h3>=4", "s2sphere", "a5_fast"]
# ///
"""
Verify the committed batch fixtures against their `.ids`: regenerate every
cell's vertices from the ids and compare with the `.zon`, vertex by vertex,
by chord distance. A tolerance, not bytes — h3 wheels differ in the last
ulp between platforms, so the committed files are canonical whichever
machine produced them. Exits nonzero on any mismatch.

Run with:  uv run scripts/batches/verify_batches.py
"""

import math
import re
import sys

from gen_batches import BATCHES, FAMILIES, OUT_DIR, batch_name

CHORD_TOL = 1e-12
TRIPLE = re.compile(r"\.\{\s*([-+0-9.eE]+),\s*([-+0-9.eE]+),\s*([-+0-9.eE]+)\s*\}")
CELL = re.compile(r"\.\{((?:\s*\.\{[^{}]*\},?)+)\s*\}")


def zon_cells(text):
    body = text[text.index(".cells = .{") :]
    return [[tuple(map(float, t)) for t in TRIPLE.findall(m)] for m in CELL.findall(body)]


def main():
    bad = 0
    for family, res in BATCHES:
        fam, name = FAMILIES[family], batch_name(family, res)
        ids = (OUT_DIR / f"{name}.ids").read_text().split()
        cells = zon_cells((OUT_DIR / f"{name}.zon").read_text())
        if len(ids) != len(cells):
            print(f"  {name}: {len(ids)} ids but {len(cells)} cells")
            bad += 1
            continue
        worst = 0.0
        for s, got in zip(ids, cells):
            want = fam.vertices(fam.from_str(s))
            if len(want) != len(got):
                print(f"  {name} {s}: {len(want)} vertices expected, {len(got)} in .zon")
                bad += 1
                continue
            for a, b in zip(want, got):
                worst = max(worst, math.dist(a, b))
        if worst > CHORD_TOL:
            print(f"  {name}: max chord distance {worst:.3e} > {CHORD_TOL:g}")
            bad += 1
        else:
            print(f"  {name}: ok (max chord distance {worst:.1e})")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
