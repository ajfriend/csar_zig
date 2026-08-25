//! Public entry point for the `csar` package.
//!
//! `csar` solves the spherical aspect-ratio problem: given a point set on
//! the unit sphere, find the tightest ellipsoidal cone enclosing it.
//!
//! Where to look:
//!   - `src/api.zig` — the solver's public surface: types, methods,
//!     `checkFeasibility`, and the errors-vs-outcome rationale.
//!   - `src/cert.zig` — foreign-candidate certification:
//!     `cert_primal` / `cert_dual` / `primal_violation` and their
//!     result types.
//!   - `src/csar.zig` — algorithm implementation; defines `solve`.
//!
//! This file is just a re-export shim so consumers can write
//! `@import("csar")` and reach everything from one namespace.

const linalg = @import("linalg.zig");
const api = @import("api.zig");
const cert = @import("cert.zig");
const csar = @import("csar.zig");

// Linear-algebra types surfaced by the public solver API:
//   Vec3 — returned by `Converged.b()`.
//   Mat3 — `Converged.Q`, returned by `Converged.A()`.
// Other linalg primitives (Vec2, Mat2, Mat3x2, Chol3, Eig2, eig2) are
// internal — see `src/linalg.zig`.
pub const Vec3 = linalg.Vec3;
pub const Mat3 = linalg.Mat3;

// Public API (`src/api.zig`).
pub const Outcome = api.Outcome;
pub const Converged = api.Converged;
pub const Infeasible = api.Infeasible;
pub const Uncertified = api.Uncertified;
pub const Cert = api.Cert;
pub const SolveError = api.SolveError;
pub const InputError = api.InputError;
pub const SolveOptions = api.SolveOptions;
pub const Method = api.Method;
pub const Diagnostics = api.Diagnostics;
pub const TrustDiagnostics = api.TrustDiagnostics;
pub const checkFeasibility = api.checkFeasibility;

// Solver entry point (`src/csar.zig`).
pub const solve = csar.solve;

// Foreign-candidate certification (`src/cert.zig`): certify (A, b)
// cones from any source — `cert_primal` from the primal variables
// alone, `cert_dual` given the dual multipliers as well.
pub const cert_primal = cert.cert_primal;
pub const cert_dual = cert.cert_dual;
pub const primal_violation = cert.primal_violation;
pub const PrimalOutcome = cert.PrimalOutcome;
pub const DualOutcome = cert.DualOutcome;
pub const PrimalCert = cert.PrimalCert;
pub const DualCert = cert.DualCert;
pub const NoCertReason = cert.NoCertReason;
