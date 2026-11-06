#!/usr/bin/env python3
"""Print a small weighted community graph, so CI can run the numerical check
without downloading anything. Deterministic."""
import random

rng = random.Random(1234)
COMMUNITIES = 4
SIZE = 300
edges = {}
for c in range(COMMUNITIES):
    base = c * SIZE
    for _ in range(SIZE * 6):
        a, b = base + rng.randrange(SIZE), base + rng.randrange(SIZE)
        if a != b:
            edges[(min(a, b), max(a, b))] = round(0.2 + rng.random(), 3)
    if c + 1 < COMMUNITIES:
        for _ in range(12):
            a, b = base + rng.randrange(SIZE), base + SIZE + rng.randrange(SIZE)
            edges[(a, b)] = round(0.2 + rng.random(), 3)
for (a, b), w in sorted(edges.items()):
    print(a, b, w)
