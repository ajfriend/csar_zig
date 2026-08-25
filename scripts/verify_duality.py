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
 13. foreign-candidate verify: unconditional rescale
     lam <- 3 lam / ||X lam||: boundary from either side,
     d_rescaled >= d_lagrangian, and d_rescaled <= p*

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


def sym_Z(X, Gam):
    'Dual-variable-to-Z map: Z = (X Gam^T + Gam X^T) / 2.'
    return 0.5 * (X @ Gam.T + Gam @ X.T)


def recipe_gamma(X, A, lam):
    'Constructed-certificate recipe: gamma_i = lam_i A x_i / ||A x_i||.'
    AX = A @ X
    return lam * AX / np.linalg.norm(AX, axis=0)


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
    Z = sym_Z(X, Gam)
    cons = [cp.norm(Gam[:, i]) <= lam[i] for i in range(n)]
    prob = cp.Problem(cp.Maximize(cp.log_det(Z) + 3 - cp.norm(X @ lam)), cons)
    prob.solve(solver=cp.SCS, eps=1e-9, max_iters=200000)
    return prob.value, Gam.value, lam.value


def solve_dual_normalized(X):
    'Normalized dual (the paper eq:dual): bare log det Z, ||X lam|| <= 3.'
    n = X.shape[1]
    Gam = cp.Variable((3, n))
    lam = cp.Variable(n)
    Z = sym_Z(X, Gam)
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

    Z_ = sym_Z(X, G_)
    print(f'||Z - inv(A)||_F = {np.linalg.norm(Z_ - np.linalg.inv(A_)):.2e}')
    print(f'||X lam|| = {np.linalg.norm(X @ lam_):.10f}  (want 3)')
    print(f'||b - X lam / 3|| = {np.linalg.norm(b_ - X @ lam_ / 3):.2e}')

    W = sum(lam_[i] / (b_ @ X[:, i]) * np.outer(X[:, i], X[:, i]) for i in range(n))
    A2inv = np.linalg.inv(A_ @ A_)
    print(f'||W - A^-2|| / ||A^-2|| = {np.linalg.norm(W - A2inv) / np.linalg.norm(A2inv):.2e}')

    Grec = recipe_gamma(X, A_, lam_)
    err = max(np.linalg.norm(Grec[:, i] - G_[:, i]) for i in range(n) if lam_[i] > 1e-6)
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
    # normalized dual's ||X lam|| <= 3.
    def rescale_check(tag, Z, t):
        sign, logdet = np.linalg.slogdet(Z)
        if sign <= 0:
            print(f'{tag}: Z not PD -- no bound to check')
            return
        d_resc = logdet + 3 * np.log(3.0 / t)
        d_lagr = logdet + 3 - t
        print(
            f'{tag}: ||X lam|| = {t:.6f} -> 3;  d_rescaled = {d_resc:.8f}'
            f'  >= d_lagrangian by {d_resc - d_lagr:.2e} (want >= 0)'
            f';  p* - d_rescaled = {p_star - d_resc:.2e} (want >= 0)'
        )

    rescale_check(
        'rescale down', sym_Z(X, recipe_gamma(X, A0, lam0)), np.linalg.norm(X @ lam0)
    )

    # (b) From below: a truncated variant of the optimal dual point --
    # zero its smallest active multiplier, Gamma column with it. The
    # support shrinks and ||X lam|| falls below 3; rescaling UP is
    # equally feasible (the SOC constraints are homogeneous) and
    # improves the bound.
    act = np.flatnonzero(lam_ > 1e-6)
    k = act[np.argmin(lam_[act])]
    lam_t = lam_.copy()
    G_t = G_.copy()
    lam_t[k] = 0.0
    G_t[:, k] = 0.0
    rescale_check('rescale up', sym_Z(X, G_t), np.linalg.norm(X @ lam_t))


main()
