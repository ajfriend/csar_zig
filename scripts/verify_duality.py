# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "cvxpy"]
# ///
'''Reference oracle for the TEEC duality identities (run: uv run verify_duality.py).

Independently solves the primal and dual with CVXPY and checks every
structural identity the solver and its certificate construction rely on:

  1. strong duality: p* = d*
  2. b is an eigenvector of A with eigenvalue 1/sqrt(3)
  3. Z* = inv(A*) at the optimum
  4. ||X lam|| = 3 and b = X lam / 3
  5. W = sum_i (lam_i / b.x_i) x_i x_i^T equals A^{-2}
  6. constructed-certificate recipe gamma_i = lam_i A x_i / ||A x_i||
  7. active set size <= 6
  8. inner design-dual value h(b) = 0.5 logdet(3 S), S = sum w_i y_i y_i^T
  9. Kiefer-Wolfowitz: g_i = y_i^T S^{-1} y_i <= 3, = 3 on the support
 10. envelope gradient: grad h(b) = -X lam (finite-difference check)
 11. homogeneity: h(cb) = h(b) - 3 log c
 12. the Lagrangian and normalized duals agree: dN* = d* = p*, with
     ||X lam|| = 3 binding at the normalized optimum
 13. foreign-candidate verify: the unconditional rescale
     lam <- 3 lam / ||X lam|| lands on the normalization boundary from
     either side, never worsens the dual value, and the rescaled
     log det Z lower-bounds p*

Derivations: csar_paper, sections "Dual" and "Solution method: partial
minimization" and the appendix ("Derivation of the dual", "Validity
for arbitrary dual-feasible (Gamma, lambda)").
Any change to the certificate construction in src/csar.zig should keep
agreeing with this oracle.
'''
import numpy as np
import cvxpy as cp

SEED = 0
N = 12


def make_points(rng, n):
    'Random elongated bundle strictly inside an open halfspace.'
    pts = []
    while len(pts) < n:
        v = rng.normal(size=3)
        v /= np.linalg.norm(v)
        v = v + np.array([0, 0, 2.0]) + np.array([0.8, 0, 0]) * v[0]
        v /= np.linalg.norm(v)
        if v[2] > 0.3:
            pts.append(v)
    return np.array(pts).T  # 3 x n


def solve_primal(X):
    n = X.shape[1]
    A = cp.Variable((3, 3), symmetric=True)
    b = cp.Variable(3)
    cons = [cp.norm(A @ X[:, i]) <= b @ X[:, i] for i in range(n)]
    cons.append(cp.norm(b) <= 1)
    prob = cp.Problem(cp.Minimize(-cp.log_det(A)), cons)
    prob.solve(solver=cp.SCS, eps=1e-9, max_iters=200000)
    return prob.value, A.value, b.value


def solve_dual(X):
    'Lagrangian dual: scale left free, priced by the +3 - ||X lam|| terms.'
    n = X.shape[1]
    Gam = cp.Variable((3, n))
    lam = cp.Variable(n)
    Z = 0.5 * (X @ Gam.T + Gam @ X.T)
    cons = [cp.norm(Gam[:, i]) <= lam[i] for i in range(n)]
    prob = cp.Problem(cp.Maximize(cp.log_det(Z) + 3 - cp.norm(X @ lam)), cons)
    prob.solve(solver=cp.SCS, eps=1e-9, max_iters=200000)
    return prob.value, Gam.value, lam.value


def solve_dual_normalized(X):
    'Normalized dual (the paper eq:dual): bare log det Z, ||X lam|| <= 3.'
    n = X.shape[1]
    Gam = cp.Variable((3, n))
    lam = cp.Variable(n)
    Z = 0.5 * (X @ Gam.T + Gam @ X.T)
    cons = [cp.norm(Gam[:, i]) <= lam[i] for i in range(n)]
    cons.append(cp.norm(X @ lam) <= 3)
    prob = cp.Problem(cp.Maximize(cp.log_det(Z)), cons)
    prob.solve(solver=cp.SCS, eps=1e-9, max_iters=200000)
    return prob.value, Gam.value, lam.value


def solve_inner(X, b):
    'Inner problem at fixed axis: h(b), conic multipliers lambda, and A.'
    n = X.shape[1]
    A = cp.Variable((3, 3), symmetric=True)
    cons = [cp.norm(A @ X[:, i]) <= b @ X[:, i] for i in range(n)]
    prob = cp.Problem(cp.Minimize(-cp.log_det(A)), cons)
    prob.solve(solver=cp.SCS, eps=1e-10, max_iters=200000)
    lam = np.array([float(np.atleast_1d(c.dual_value)[0]) for c in cons])
    return prob.value, lam, A.value


def main():
    rng = np.random.default_rng(SEED)
    X = make_points(rng, N)
    n = X.shape[1]

    p_star, A_, b_ = solve_primal(X)
    d_star, G_, lam_ = solve_dual(X)
    dN_star, _, lamN_ = solve_dual_normalized(X)

    print(f'p* = {p_star:.8f}   d* = {d_star:.8f}   gap = {p_star - d_star:.2e}')
    print(f'dN* = {dN_star:.8f}   dN* - d* = {dN_star - d_star:.2e} (want 0)')
    print(f'||X lamN|| = {np.linalg.norm(X @ lamN_):.10f}  (want 3: binding)')

    evals, evecs = np.linalg.eigh(A_)
    print(f'eigs(A) = {evals}   1/sqrt(3) = {1 / np.sqrt(3):.10f}')
    print(f'|Q^T b| (alignment) = {np.abs(evecs.T @ b_)}')

    Z_ = 0.5 * (X @ G_.T + G_ @ X.T)
    print(f'||Z - inv(A)||_F = {np.linalg.norm(Z_ - np.linalg.inv(A_)):.2e}')
    print(f'||X lam|| = {np.linalg.norm(X @ lam_):.10f}  (want 3)')
    print(f'||b - X lam / 3|| = {np.linalg.norm(b_ - X @ lam_ / 3):.2e}')

    W = sum(lam_[i] / (b_ @ X[:, i]) * np.outer(X[:, i], X[:, i]) for i in range(n))
    A2inv = np.linalg.inv(A_ @ A_)
    print(f'||W - A^-2|| / ||A^-2|| = {np.linalg.norm(W - A2inv) / np.linalg.norm(A2inv):.2e}')

    err = max(
        np.linalg.norm(lam_[i] * (A_ @ X[:, i]) / np.linalg.norm(A_ @ X[:, i]) - G_[:, i])
        for i in range(n) if lam_[i] > 1e-6
    )
    n_active = int(np.sum(lam_ > 1e-6))
    print(f'recipe error on active set = {err:.2e}   active = {n_active} (want <= 6)')

    # inner problem / reduced function at a non-optimal axis
    b0 = b_ + np.array([0.05, -0.03, 0])
    b0 /= np.linalg.norm(b0)
    h0, lam0, A0 = solve_inner(X, b0)

    yt = X / (b0 @ X)
    w = lam0 * (b0 @ X) / 3
    S = (yt * w) @ yt.T
    print(f'sum w = {w.sum():.10f} (want 1)')
    print(f'h(b) = {h0:.8f}   0.5 logdet(3S) = {0.5 * np.linalg.slogdet(3 * S)[1]:.8f}')

    g = np.einsum('ij,jk,ki->i', yt.T, np.linalg.inv(S), yt)
    print(f'KW: max g_i = {g.max():.6f} (want 3)   on support: {np.round(g[w > 1e-6], 6)}')

    g_analytic = -X @ lam0
    eps = 1e-5
    g_fd = np.zeros(3)
    for k in range(3):
        e = np.zeros(3)
        e[k] = eps
        hp, _, _ = solve_inner(X, b0 + e)
        hm, _, _ = solve_inner(X, b0 - e)
        g_fd[k] = (hp - hm) / (2 * eps)
    rel = np.linalg.norm(g_fd - g_analytic) / np.linalg.norm(g_fd)
    print(f'grad h vs -X lam rel err = {rel:.2e} (FD-limited)')

    c = 1.37
    hc, _, _ = solve_inner(X, c * b0)
    print(f'homogeneity residual = {hc - (h0 - 3 * np.log(c)):.2e}')

    # foreign-candidate verify: the unconditional rescale, from both sides.
    # (a) From above: the recipe multipliers at the perturbed axis have
    # ||X lam|| > 3 (off-centering); with the aligned Gamma at the
    # inner-optimal A they are Lagrangian-feasible but violate the
    # normalized dual's ||X lam|| <= 3. The verifier rescale
    # lam <- 3 lam / ||X lam|| lands on the boundary, and the rescaled
    # log det Z is a valid bound, no worse than the Lagrangian value.
    def rescale_check(tag, Z, t):
        s = 3.0 / t
        sign, logdet = np.linalg.slogdet(s * Z)
        d_resc = logdet if sign > 0 else -np.inf
        d_lagr = np.linalg.slogdet(Z)[1] + 3 - t
        print(
            f'{tag}: ||X lam|| = {t:.6f} -> 3;  d_rescaled = {d_resc:.8f}'
            f'  >= d_lagrangian by {d_resc - d_lagr:.2e} (want >= 0)'
            f';  p* - d_rescaled = {p_star - d_resc:.2e} (want >= 0)'
        )

    G0 = np.stack(
        [lam0[i] * (A0 @ X[:, i]) / np.linalg.norm(A0 @ X[:, i]) for i in range(n)],
        axis=1,
    )
    Z0 = 0.5 * (X @ G0.T + G0 @ X.T)
    rescale_check('rescale down', Z0, np.linalg.norm(X @ lam0))

    # (b) From below: shrink the optimal dual point strictly inside the
    # normalization ball (feasible, slack constraint); rescaling UP is
    # equally feasible -- the SOC constraints are homogeneous -- and
    # improves the bound (by t - 3 - 3 log(t/3) at t = 2.7, vs the
    # point's Lagrangian value). Z_ from the Z = inv(A) check above.
    rescale_check('rescale up  ', 0.9 * Z_, 0.9 * np.linalg.norm(X @ lam_))


main()
