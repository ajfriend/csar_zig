# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = ["numpy", "h3>=4", "s2sphere", "a5_fast"]
# ///
"""
Generate the batch fixtures: cases/batches/<family>_<res>.{ids,zon}.

A batch is N_CELLS distinct cells of one DGGS family at one resolution,
drawn by sampling points uniformly on the sphere until that many distinct
cells are hit — the procedure (and seed) of ajfriend/dggs_compare, so the
two repos agree on what a batch is. Per cell the `.zon` carries the corner
vertices as unit vectors (the hot-path shapes: 6-point H3 hexagons,
4-point S2 quads, 5-point A5 pentagons); the `.ids` carries the cell ids,
one per line, in the library's canonical string form — the portable
artifact, from which the vertices can be regenerated (verify_batches.py).

The contract is the same for every batch and lives in the test, not the
file: every cell converges at `cases.pin` (tests/batches_test.zig).
dev.md "Test layout".

Edit the constants below in place — no CLI args by project convention.
Run with:  uv run scripts/batches/gen_batches.py
"""

import math
from pathlib import Path

import a5_fast as a5
import h3
import numpy as np
import s2sphere

# ---------------------------------------------------------------- config
SEED = 0xDECAF  # dggs_compare's; a distinct stream per resolution
N_CELLS = 1000
# (family, resolution). S2 and A5 are count-matched to H3 r9 / r12 / r15 —
# closest total cell count in log-ratio, dggs_compare's criterion.
BATCHES = [
    ("h3", 9),
    ("h3", 15),
    ("s2", 15),
    ("s2", 19),
    ("s2", 23),
    ("a5", 14),
    ("a5", 18),
    ("a5", 23),
]
OUT_DIR = Path(__file__).resolve().parents[2] / "cases" / "batches"
MAX_DRAW_FACTOR = 20  # give up if N_CELLS distinct cells need more draws than this
DRAW_BATCH = 10_000
# A5 boundaries can come back densified; a true corner turns by tens of
# degrees, a densification point by a fraction of one (dggs_compare).
TURN_DEG = 5.0


# ---------------------------------------------------------------- families
def latlng_to_xyz(lat, lng):
    la, lo = math.radians(lat), math.radians(lng)
    return (math.cos(la) * math.cos(lo), math.cos(la) * math.sin(lo), math.sin(la))


def corners(xyz):
    """Reduce an open ring of unit vectors to its corners."""
    v = np.asarray(xyz, dtype=float)
    e = np.roll(v, -1, axis=0) - v
    e /= np.linalg.norm(e, axis=1, keepdims=True)
    cosang = np.clip(np.einsum("ij,ij->i", np.roll(e, 1, axis=0), e), -1, 1)
    idx = np.nonzero(np.degrees(np.arccos(cosang)) > TURN_DEG)[0]
    return [xyz[i] for i in idx] if len(idx) >= 3 else xyz


class H3:
    prefix = "r"

    def cells_at(self, res, pts):
        return [h3.latlng_to_cell(lat, lng, res) for lat, lng in pts]

    def to_str(self, c):
        return str(c)

    def from_str(self, s):
        return s

    def vertices(self, c):
        return [latlng_to_xyz(*ll) for ll in h3.cell_to_boundary(c)]


class S2:
    prefix = "L"

    def cells_at(self, res, pts):
        return [
            s2sphere.CellId.from_lat_lng(s2sphere.LatLng.from_degrees(lat, lng)).parent(res).id()
            for lat, lng in pts
        ]

    def to_str(self, c):
        return format(c, "016x")

    def from_str(self, s):
        return int(s, 16)

    def vertices(self, c):
        cell = s2sphere.Cell(s2sphere.CellId(c))
        out = []
        for i in range(4):
            v = cell.get_vertex(i)
            n = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])  # not hypot: last-ulp stability of the committed data
            out.append((v[0] / n, v[1] / n, v[2] / n))
        return out


class A5:
    prefix = "r"

    def cells_at(self, res, pts):
        return [a5.lonlat_to_cell(lng, lat, res) for lat, lng in pts]

    def to_str(self, c):
        return a5.u64_to_hex(c)

    def from_str(self, s):
        return a5.hex_to_u64(s)

    def vertices(self, c):
        ring = a5.cell_to_boundary(c)[:-1]  # (lng, lat), closed; drop the repeat
        return corners([latlng_to_xyz(lat, lng) for lng, lat in ring])


FAMILIES = {"h3": H3(), "s2": S2(), "a5": A5()}


# ---------------------------------------------------------------- sampling
def sample_uniform_latlng(n, rng):
    """Uniform on the sphere as (lat_deg, lng_deg); lng drawn first, as in dggs_compare."""
    lng = 360.0 * rng.random(n) - 180.0
    lat = np.degrees(np.arcsin(2.0 * rng.random(n) - 1.0))
    return np.column_stack([lat, lng])


def sample_distinct(fam, res):
    """The first N_CELLS distinct cells hit, in draw order (a dict keeps it)."""
    rng = np.random.default_rng([SEED, res])
    cells = {}
    for _ in range(MAX_DRAW_FACTOR * N_CELLS // DRAW_BATCH):
        pts = sample_uniform_latlng(DRAW_BATCH, rng).tolist()
        cells.update(dict.fromkeys(fam.cells_at(res, pts)))
        if len(cells) >= N_CELLS:
            return list(cells)[:N_CELLS]
    raise RuntimeError(f"{MAX_DRAW_FACTOR * N_CELLS} draws yielded only {len(cells)}/{N_CELLS} distinct cells")


# ---------------------------------------------------------------- output
def batch_name(family, res):
    return f"{family}_{FAMILIES[family].prefix}{res}"


def zon_text(family, res, cells):
    fam = FAMILIES[family]
    lines = [
        ".{",
        f'    .description = "{family.upper()} {fam.prefix}{res}, {len(cells)} cells uniform over the sphere, seed {SEED:#x}",',
        "    .cells = .{",
    ]
    for c in cells:
        pts = ", ".join(".{ %.17g, %.17g, %.17g }" % v for v in fam.vertices(c))
        lines.append(f"        .{{ {pts} }},")
    lines += ["    },", "}", ""]
    return "\n".join(lines)


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for family, res in BATCHES:
        fam, name = FAMILIES[family], batch_name(family, res)
        cells = sample_distinct(fam, res)
        (OUT_DIR / f"{name}.ids").write_text("".join(fam.to_str(c) + "\n" for c in cells))
        (OUT_DIR / f"{name}.zon").write_text(zon_text(family, res, cells))
        print(f"  {name}: {len(cells)} cells")


if __name__ == "__main__":
    main()
