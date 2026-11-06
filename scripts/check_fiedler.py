#!/usr/bin/env python3
"""Numerical check, second half: compare Spectrolith with scipy's eigsh.

usage: check_fiedler.py <workdir> [input_edges.tsv]

Reads the graph the snapshot exported, builds the normalized adjacency of its
largest connected component, and solves for its top two eigenpairs. The Fiedler
vector and lambda2 must match Spectrolith's up to sign. With the input edge list
it also checks that the export is exactly that graph, so a store that lost edges
cannot pass by being self-consistent. Exits non-zero on a mismatch.
"""
import json
import sys

import numpy as np
import scipy.sparse as sp
from scipy.sparse.csgraph import connected_components
from scipy.sparse.linalg import eigsh

LAMBDA_TOL = 1e-8
VECTOR_TOL = 1e-6


def main():
    work = sys.argv[1]
    data = np.loadtxt(f"{work}/edges.tsv", ndmin=2)
    src, dst, w = data[:, 0].astype(np.int64), data[:, 1].astype(np.int64), data[:, 2]
    ids, inv = np.unique(np.concatenate([src, dst]), return_inverse=True)
    n = len(ids)
    A = sp.csr_matrix((w, (inv[: len(src)], inv[len(src):])), shape=(n, n))

    if len(sys.argv) > 2:
        check_against_input(sys.argv[2], src, dst, w)

    assert abs(A - A.T).max() == 0, "export is not symmetric"
    ncomp, labels = connected_components(A, directed=False)
    big = np.argmax(np.bincount(labels))
    keep = np.flatnonzero(labels == big)
    A = A[keep][:, keep]
    deg = np.asarray(A.sum(axis=1)).ravel()
    Dinv = sp.diags(1.0 / np.sqrt(deg))
    M = Dinv @ A @ Dinv
    vals, vecs = eigsh(M, k=3, which="LA", tol=1e-12, ncv=min(256, M.shape[0] - 1))
    order = np.argsort(-vals)
    vals, vecs = vals[order], vecs[:, order]
    lambda2 = 1.0 - vals[1]
    u = vecs[:, 1]

    got = np.loadtxt(f"{work}/fiedler.tsv", ndmin=2)
    got_ids = got[:, 0].astype(np.int64)
    v = got[:, 1]
    summary = json.load(open(f"{work}/summary.json"))
    assert np.array_equal(got_ids, ids[keep]), "component membership differs"
    u, v = u / np.linalg.norm(u), v / np.linalg.norm(v)
    if u @ v < 0:
        v = -v

    d_lambda = abs(lambda2 - summary["lambda2"])
    d_vec = np.abs(u - v).max()
    print(f"graph: n={n} lcc={len(keep)} components={ncomp} directed_records={len(src)}")
    print(f"store: base_edges={summary['base_edges']} delta_triples={summary['delta_triples']} "
          f"new_vertices={summary['new_vertices']}")
    print(f"scipy      lambda2={lambda2:.12f}  (lambda3={1 - vals[2]:.12f})")
    print(f"spectrolith lambda2={summary['lambda2']:.12f} applications={summary['iters']} "
          f"residual={summary['residual']:.2e}")
    print(f"|d lambda2| = {d_lambda:.2e}   max|d vector| = {d_vec:.2e}   cosine = {abs(u @ v):.12f}")
    ok = d_lambda < LAMBDA_TOL and d_vec < VECTOR_TOL
    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


def check_against_input(path, src, dst, w):
    """The export must be the input graph: same pairs, last write wins."""
    want = {}
    with open(path) as f:
        for line in f:
            parts = line.split()
            a, b = int(parts[0]), int(parts[1])
            x = float(parts[2]) if len(parts) > 2 else 1.0
            want[(a, b)] = x
            want[(b, a)] = x
    got = {(int(a), int(b)): float(x) for a, b, x in zip(src, dst, w)}
    assert len(got) == len(src), "export has a duplicate edge"
    assert got.keys() == want.keys(), "export and input have different edges"
    worst = max(abs(got[k] - want[k]) for k in got)
    assert worst < 1e-6, f"weight differs by {worst}"
    print(f"export equals input: {len(got)} directed edges")


if __name__ == "__main__":
    main()
