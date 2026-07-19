# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "cvxpy"]
# ///
'''Prototype for roadmap item 6: certificate polishing via the Gamma
fixed-point (run: uv run gamma_polish_prototype.py).

Question: when the inner state w is inexact (the floor regime), how much
of the reported duality gap is slack in the *constructed* certificate
(recoverable by maximizing over Gamma at fixed lambda) vs genuine
suboptimality of the iterate?

Mirrors the solver's own construction in numpy:
  y_i = x_i / (b.x_i);  S = sum w_i y_i y_i^T;  A = (3S)^{-1/2},
  rescaled by sqrt(3/g_max) so containment holds exactly (recoverAPerp's
  budget rescale);  lambda_i = 3 w_i / (b.x_i);
  recipe gamma_i = lambda_i A x_i / ||A x_i||.

Then polishes Gamma by iterating the KKT alignment map of
  max_Gamma  log det Z(Gamma)  s.t.  ||gamma_i|| <= lambda_i,
whose optimality condition is gamma_i propto Z^{-1} x_i:

  gamma_i  <-  lambda_i * normalize((Z + mu I)^{-1} x_i)

(mu > 0 only when Z is not PD; the shift only affects the direction —
dual feasibility is maintained by the norm clip, and the reported value
is always evaluated at the actual Z(Gamma)). Keeps the best iterate.

Compares, for inner-state noise eta in {0, 1e-8, 1e-6, 1e-4}:
  gap_recipe   — the solver's current constructed certificate
  gap_polish   — after <= 10 alignment iterations
  gap_bestG    — exact max over Gamma at fixed lambda (CVXPY)
  gap_true     — p(iterate) - d*  (irreducible at this iterate/lambda)

Reading: (gap_recipe - gap_bestG) is the certificate slack item 6 can
recover; (gap_polish - gap_bestG) shows how much of it the cheap
fixed-point gets. At eta = 0 the recipe is provably optimal already
(inner KKT alignment), so the slack should vanish — that column is the
control.

MEASURED (2026-07-18, seed 3, n = 10):

     eta   gap_recipe   gap_polish    gap_bestG     gap_true
   0e+00    1.176e-09    1.176e-09    1.176e-09    9.471e-10
   1e-08    6.405e-08    6.405e-08    1.261e-07    4.675e-08
   1e-06    5.652e-06    5.652e-06    9.295e-06    4.024e-06
   1e-04    4.961e-04    4.961e-04    4.961e-04    4.794e-04

Findings (see the roadmap item 6 REVISED section for consequences):
  - The recipe is already Gamma-optimal within evaluation resolution:
    polish recovers nothing, and the CVXPY subsolve cannot beat the
    recipe at small eta (gap_bestG > gap_recipe is SCS resolution, not
    a real max — the recipe IS the better dual point).
  - gap_recipe tracks gap_true within ~1.2-1.4x at every eta: the
    reported gap is dominated by the iterate itself (p - d*), not by
    certificate construction slack.
  - gap scales ~6x eta: w-noise at eta maps to a gap floor of ~6 eta
    under this noise model — a testable prediction for the item 4
    probe (measure effective w-noise on floor cells; expect the gap
    floor at ~6x that).
  - This noise model never produced an indefinite Z, so the PSD-repair
    scope of item 6 (the RECERT/Cholesky-failure regime) is NOT tested
    here; that experiment must run in Zig on captured failure states.
'''
import numpy as np
import cvxpy as cp

SEED = 3
N = 10
ETAS = [0.0, 1e-8, 1e-6, 1e-4]
POLISH_ITERS = 10


def make_points(rng, n):
    pts = []
    while len(pts) < n:
        v = rng.normal(size=3)
        v /= np.linalg.norm(v)
        v = v + np.array([0.3, 0, 2.0])
        v /= np.linalg.norm(v)
        if v[2] > 0.4:
            pts.append(v)
    return np.array(pts).T


def solve_inner_w(X, b):
    'Exact inner design weights at fixed b (from the conic duals).'
    n = X.shape[1]
    A = cp.Variable((3, 3), symmetric=True)
    cons = [cp.norm(A @ X[:, i]) <= b @ X[:, i] for i in range(n)]
    cp.Problem(cp.Minimize(-cp.log_det(A)), cons).solve(
        solver=cp.SCS, eps=1e-11, max_iters=400000)
    lam = np.array([float(np.atleast_1d(c.dual_value)[0]) for c in cons])
    return lam * (b @ X) / 3


def full_dual_opt(X):
    n = X.shape[1]
    Gam = cp.Variable((3, n))
    lam = cp.Variable(n)
    Z = 0.5 * (X @ Gam.T + Gam @ X.T)
    cons = [cp.norm(Gam[:, i]) <= lam[i] for i in range(n)]
    prob = cp.Problem(cp.Maximize(cp.log_det(Z) + 3 - cp.norm(X @ lam)), cons)
    prob.solve(solver=cp.SCS, eps=1e-11, max_iters=400000)
    return prob.value


def dual_value(X, Gam, lam):
    'd(Gamma, lambda), or None if Z is not PD (no certificate).'
    Z = 0.5 * (X @ Gam.T + Gam @ X.T)
    ev = np.linalg.eigvalsh(Z)
    if ev.min() <= 0:
        return None
    return np.linalg.slogdet(Z)[1] + 3 - np.linalg.norm(X @ lam)


def build_iterate(X, b, w):
    'Solver-style structural iterate: A from moments + budget rescale.'
    yt = X / (b @ X)
    S = (yt * w) @ yt.T
    ev, V = np.linalg.eigh(3 * S)
    A = V @ np.diag(ev ** -0.5) @ V.T  # (3S)^{-1/2}
    g = np.einsum('ij,ji->i', yt.T @ np.linalg.inv(3 * S), yt)  # ||A y_i||^2
    A *= min(1.0, 1.0 / np.sqrt(g.max()))  # containment exactly tight
    return A


def recipe_gamma(X, A, lam):
    AX = A @ X
    return lam * AX / np.linalg.norm(AX, axis=0)


def polish(X, lam, Gam0, iters):
    best_gam, best_d = Gam0, dual_value(X, Gam0, lam)
    Gam = Gam0.copy()
    for _ in range(iters):
        Z = 0.5 * (X @ Gam.T + Gam @ X.T)
        ev = np.linalg.eigvalsh(Z)
        mu = max(0.0, -1.25 * ev.min()) + 1e-300
        D = np.linalg.solve(Z + mu * np.eye(3), X)
        Gam = lam * D / np.linalg.norm(D, axis=0)
        d = dual_value(X, Gam, lam)
        if d is not None and (best_d is None or d > best_d):
            best_d, best_gam = d, Gam.copy()
    return best_gam, best_d


def best_gamma_exact(X, lam):
    n = X.shape[1]
    Gam = cp.Variable((3, n))
    Z = 0.5 * (X @ Gam.T + Gam @ X.T)
    cons = [cp.norm(Gam[:, i]) <= lam[i] for i in range(n)]
    prob = cp.Problem(cp.Maximize(cp.log_det(Z)), cons)
    prob.solve(solver=cp.SCS, eps=1e-11, max_iters=400000)
    # SCS returns slightly SOC-infeasible columns; clip into the cone so
    # the evaluated point is genuinely dual-feasible.
    G = Gam.value
    nrm = np.linalg.norm(G, axis=0)
    scale = np.minimum(1.0, lam / np.maximum(nrm, 1e-300))
    return dual_value(X, G * scale, lam)


def main():
    rng = np.random.default_rng(SEED)
    X = make_points(rng, N)

    # optimal axis via the full primal, then a small endgame-style offset
    A = cp.Variable((3, 3), symmetric=True)
    bv = cp.Variable(3)
    cons = [cp.norm(A @ X[:, i]) <= bv @ X[:, i] for i in range(X.shape[1])]
    cons.append(cp.norm(bv) <= 1)
    cp.Problem(cp.Minimize(-cp.log_det(A)), cons).solve(
        solver=cp.SCS, eps=1e-11, max_iters=400000)
    b = bv.value + np.array([1e-5, -2e-5, 0])
    b /= np.linalg.norm(b)

    w_exact = solve_inner_w(X, b)
    d_star = full_dual_opt(X)

    print(f'{"eta":>8} {"gap_recipe":>12} {"gap_polish":>12} {"gap_bestG":>12} {"gap_true":>12}')
    for eta in ETAS:
        w = np.clip(w_exact + eta * rng.normal(size=w_exact.shape), 0, None)
        w /= w.sum()
        Ait = build_iterate(X, b, w)
        p = -np.linalg.slogdet(Ait)[1]
        lam = 3 * w / (b @ X)
        G0 = recipe_gamma(X, Ait, lam)

        d0 = dual_value(X, G0, lam)
        _, d1 = polish(X, lam, G0, POLISH_ITERS)
        d2 = best_gamma_exact(X, lam)

        fmt = lambda d: f'{p - d:12.3e}' if d is not None else '   Z not PD '
        print(f'{eta:8.0e} {fmt(d0)} {fmt(d1)} {fmt(d2)} {p - d_star:12.3e}')


main()
