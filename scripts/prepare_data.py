#!/usr/bin/env python3
"""Normalize a downloaded graph to "u v w" lines with one line per undirected edge.

usage: prepare_data.py string|snap <in.gz> <out.tsv> <min_score>

STRING lists each pair in both directions, with protein ids like
9606.ENSP00000000233 and a combined score in 0..1000 (used as weight / 1000).
SNAP ungraphs are "u v" lines with # comments. Ids in the output are the input's
own numbers, so the output can be traced back to the source.
"""
import gzip
import os
import sys


def string_edges(path, min_score):
    with gzip.open(path, "rt") as f:
        next(f)  # header
        for line in f:
            a, b, score = line.split()
            score = int(score)
            if score < min_score:
                continue
            u = int(a.split(".ENSP")[1])
            v = int(b.split(".ENSP")[1])
            if u < v:  # the mirror line is the same edge
                yield u, v, score / 1000.0


def snap_edges(path):
    with gzip.open(path, "rt") as f:
        for line in f:
            if line.startswith("#"):
                continue
            a, b = line.split()
            yield int(a), int(b), 1.0


def main():
    kind, src, dst, min_score = sys.argv[1:5]
    edges = string_edges(src, int(min_score)) if kind == "string" else snap_edges(src)
    n = 0
    with open(dst + ".part", "w") as out:
        for u, v, w in edges:
            out.write(f"{u} {v} {w:g}\n")
            n += 1
    os.replace(dst + ".part", dst)
    print(f"{dst}: {n} edges")


if __name__ == "__main__":
    main()
