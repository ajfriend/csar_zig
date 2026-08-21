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

Each `.zon`'s `converged_at_least` pin comes from PINS below: the
converged counts measured under zig's two backends, minus a slack (the
cells that clear the f64 gap floor are decided at FP-noise level and
differ between backends — CLAUDE.md). A batch absent from PINS is written
unpinned (0) for its first measurement. dev.md "Test layout".

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
# name -> (converged under LLVM, converged under self-hosted, slack);
# the pin is min(...) - slack. Measured by tests/batches_test.zig's failure
# diagnostics on each backend (#36: every batch converged in full on both).
PINS = {
    "h3_r9": (1000, 1000, 0),
    "h3_r15": (1000, 1000, 0),
    "s2_L15": (1000, 1000, 0),
    "s2_L19": (1000, 1000, 0),
    "s2_L23": (1000, 1000, 0),
    "a5_r14": (1000, 1000, 0),
    "a5_r18": (1000, 1000, 0),
    "a5_r23": (1000, 1000, 0),
}

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


def corners(latlng):
    """Reduce an open (lat, lng)-degree ring to its corners."""
    la, lo = np.radians(np.asarray(latlng, dtype=float)).T
    v = np.column_stack([np.cos(la) * np.cos(lo), np.cos(la) * np.sin(lo), np.sin(la)])
    e = np.roll(v, -1, axis=0) - v
    e /= np.linalg.norm(e, axis=1, keepdims=True)
    cosang = np.clip(np.einsum("ij,ij->i", np.roll(e, 1, axis=0), e), -1, 1)
    idx = np.nonzero(np.degrees(np.arccos(cosang)) > TURN_DEG)[0]
    return [latlng[i] for i in idx] if len(idx) >= 3 else latlng


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
            n = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
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
        ring = [(lat, lng) for lng, lat in a5.cell_to_boundary(c)[:-1]]  # drop the closing repeat
        return [latlng_to_xyz(*ll) for ll in corners(ring)]


FAMILIES = {"h3": H3(), "s2": S2(), "a5": A5()}


# ---------------------------------------------------------------- sampling
def sample_uniform_latlng(n, rng):
    """Uniform on the sphere as (lat_deg, lng_deg); lng drawn first, as in dggs_compare."""
    lng = 360.0 * rng.random(n) - 180.0
    lat = np.degrees(np.arcsin(2.0 * rng.random(n) - 1.0))
    return np.column_stack([lat, lng])


def sample_distinct(fam, res):
    rng = np.random.default_rng([SEED, res])
    seen, cells, drawn = set(), [], 0
    while len(cells) < N_CELLS:
        if drawn >= MAX_DRAW_FACTOR * N_CELLS:
            raise RuntimeError(f"{drawn} draws yielded only {len(cells)}/{N_CELLS} distinct cells")
        pts = sample_uniform_latlng(DRAW_BATCH, rng).tolist()
        for c in fam.cells_at(res, pts):
            if c not in seen:
                seen.add(c)
                cells.append(c)
                if len(cells) == N_CELLS:
                    break
        drawn += DRAW_BATCH
    return cells


# ---------------------------------------------------------------- output
def batch_name(family, res):
    return f"{family}_{FAMILIES[family].prefix}{res}"


def zon_text(name, family, res, cells):
    fam = FAMILIES[family]
    if name in PINS:
        llvm, selfhosted, slack = PINS[name]
        pin = min(llvm, selfhosted) - slack
        pinned = f"llvm {llvm} / selfhosted {selfhosted}, slack {slack}"
    else:
        pin, pinned = 0, "unpinned"
    lines = [
        ".{",
        f'    .description = "{family.upper()} {fam.prefix}{res}, {len(cells)} cells uniform over the sphere, seed {SEED:#x}; {pinned}",',
        f"    .converged_at_least = {pin},",
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
        (OUT_DIR / f"{name}.zon").write_text(zon_text(name, family, res, cells))
        print(f"  {name}: {len(cells)} cells")


if __name__ == "__main__":
    main()
