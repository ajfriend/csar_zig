# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy"]
# ///
"""Generate stress fixtures whose optimal TEEC is known in CLOSED FORM.

No solver produces the expected values -- not csar, not a generic conic
solver. The construction pins the optimum, so the pins stay valid
independently of any solver's robustness (and of its gap_tol).

Construction
------------
Pick a unit axis b and an orthonormal tangent frame (f1, f2). Place N >= 3
points at equally spaced PARAMETER angles on an ellipse in the tangent plane
at b, then normalise onto the sphere:

    u_k = (a1 cos t_k, a2 sin t_k),  t_k = 2 pi k / N,
    x_k = normalise(b + u_k1 f1 + u_k2 f2).

For N >= 3: sum cos t = sum sin t = 0, sum cos^2 = sum sin^2 = N/2 and
sum cos sin = 0. So with UNIFORM weights w = 1/N,

  * the weighted centre is the tangency point -> the axis is optimal (v = 0);
  * the weighted scatter is diag(a1^2/2, a2^2/2), so the free-centre MVEE is
    H = diag(1/a1^2, 1/a2^2) -- the very ellipse through the points;
  * all lifted g_i are equal by symmetry and sum_i w_i g_i = 3 always, hence
    g_i = 3: the Kiefer-Wolfowitz condition holds exactly.

So the points are exactly the support set of their own TEEC, and with
sigma_i = sqrt(2/3)/a_i,

    CSAR       = max(a1, a2) / min(a1, a2)      (exact)
    -log det A = log(a1 a2) - 0.5 log(4/27)     (exact)
    angular half-width in direction i = atan(a_i)

a1 and a2 dial angular width and aspect ratio INDEPENDENTLY, which is what
lets these probe the wide-and-elongated corner that a random cap cannot reach.

Strictly-interior filler points (radius factor < 1 on the same ellipse) leave
the support -- and so the expected AR -- unchanged; they exercise hull
reduction and sparse init without moving the answer.

N is kept ODD. With even N the ring points fall in antipodal pairs, so the
configuration is centrally symmetric about the tangency point, the min-norm
starting axis is already optimal, and the outer loop runs ZERO iterations --
the fixture would exercise the inner MVEE and the certificate but never the
axis search. AR depends only on (a1, a2), so parity does not move the pins.

Writes cases/zon/exact_*.zon and prints the manifest lines for
cases/cases.zig; cross-check by running the case suite (zig build test)
after registering.

Edit the constants below in place -- no CLI args by project convention.
Run with:  uv run scripts/exact_cases.py
"""
import math
from pathlib import Path

import numpy as np

OUT_DIR = Path(__file__).resolve().parents[1] / 'cases' / 'zon'
SEED = 20260822

# name -> (a1, a2, N_ring, n_interior, note); the generated description is
# 'width <atan max(a1,a2)>°, AR <a-ratio> — <note>'.
CASES = {
    'exact_w82_ar1p4':    (5.0000, 7.1154, 9,   0,   'wide and near-circular'),
    'exact_w85_ar2':      (5.6713, 11.430, 9,   0,   'wide, moderate AR'),
    'exact_w88_ar1p5':    (19.081, 28.636, 11,  0,   'very wide, near-circular'),
    'exact_w89_ar2':      (28.636, 57.290, 11,  0,   'extreme width'),
    'exact_w88_ar10':     (3.0000, 30.000, 9,   0,   'wide and elongated'),
    'exact_w76_ar20':     (0.2000, 4.0000, 7,   0,   'wide and elongated'),
    'exact_w84_ar1000':   (0.0100, 10.000, 11,  0,   'wide and extreme AR'),
    'exact_min3_ar5':     (0.4000, 2.0000, 3,   0,   'minimal support set (N = 3)'),
    # Converges in 0 outer iterations regardless of parity: at this scale the
    # objective is flat enough in b that the starting axis is already optimal.
    # It pins fine-scale conditioning of the inner solve, not the axis search.
    'exact_tiny_ar3':     (5.0e-4, 1.5e-3, 7,   0,   'fine-scale conditioning'),
    'exact_w85_ar2_fill': (5.6713, 11.430, 9,   180, '180 interior filler points'),
}


def tangent_basis(b):
    # NOT the argmin-axis pick of scripts/states/states_plot.py: changing the
    # candidate axis (or anything else rng-visible below) changes every
    # emitted fixture byte-for-byte, invalidating the deltas measured for the
    # committed corpus. Keep the construction frozen.
    t = np.array([0.0, 0.0, 1.0]) if abs(b[2]) < 0.9 else np.array([1.0, 0.0, 0.0])
    f1 = np.cross(t, b)
    f1 /= np.linalg.norm(f1)
    return f1, np.cross(b, f1)


def build(a1, a2, n_ring, n_fill, rng):
    b = np.array([0.31, -0.22, 0.90])
    b /= np.linalg.norm(b)
    f1, f2 = tangent_basis(b)
    pts = []
    for k in range(n_ring):
        t = 2.0 * math.pi * k / n_ring
        pts.append(b + a1 * math.cos(t) * f1 + a2 * math.sin(t) * f2)
    for _ in range(n_fill):
        r = 0.999 * math.sqrt(rng.random())
        t = 2.0 * math.pi * rng.random()
        pts.append(b + r * a1 * math.cos(t) * f1 + r * a2 * math.sin(t) * f2)
    P = np.array([p / np.linalg.norm(p) for p in pts])
    # A fixed random rotation so no fixture is axis-aligned. (The Haar
    # sign-fix is rng-visible; frozen, see tangent_basis.)
    Q, R = np.linalg.qr(rng.normal(size=(3, 3)))
    Q = Q * np.sign(np.diag(R))
    if np.linalg.det(Q) < 0:
        Q[:, 0] = -Q[:, 0]
    return np.array([p / np.linalg.norm(p) for p in P @ Q.T])


def zon(P, ar, description):
    out = ['.{',
           f'    .description = "{description}; optimum known in closed form (scripts/exact_cases.py)",',
           '    .points = .{']
    out += ['        .{ %s },' % ', '.join(f'{v:.17g}' for v in p) for p in P]
    out += ['    },',
            '    .tier = 1,',
            '    .claim = .converges,',
            '    .ar = %.17g,' % ar,
            '}']
    return '\n'.join(out) + '\n'


rng = np.random.default_rng(SEED)
manifest = []
print(f'{"case":<22}{"n":>5}{"width deg":>11}{"exact AR":>15}{"-logdetA":>12}')
for name, (a1, a2, n_ring, n_fill, note) in CASES.items():
    P = build(a1, a2, n_ring, n_fill, rng)
    ar = max(a1, a2) / min(a1, a2)
    width = math.degrees(math.atan(max(a1, a2)))
    description = f'width {width:.3g}°, AR {ar:.4g} — {note}'
    with open(OUT_DIR / f'{name}.zon', 'w') as fh:
        fh.write(zon(P, ar, description))
    manifest.append(f'    .{{ .name = "{name}", .case = @import("zon/{name}.zon") }},')
    print(f'{name:<22}{len(P):>5}{width:>11.3f}{ar:>15.6f}'
          f'{math.log(a1 * a2) - 0.5 * math.log(4.0 / 27.0):>12.6f}')

print(f'\nwrote {len(CASES)} fixtures to {OUT_DIR}/')
print('\nmanifest lines for cases/cases.zig (sorted):')
print('\n'.join(sorted(manifest)))
