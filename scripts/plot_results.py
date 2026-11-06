#!/usr/bin/env python3
"""Turn results/raw.jsonl into results/RESULTS.md and the charts it embeds.

Nothing here is hand-entered: rerunning regenerates every table and figure.
Where a graph has several repetitions, the median is shown, and the range is
given in the tables so noise is visible.
"""
import json
import statistics
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

OUT = Path("results")

# Identity colors follow the engine, in every chart. Validated palette slots 1-4.
ENGINE_COLOR = {"leveled": "#2a78d6", "tiered": "#eb6834", "nobloom": "#1baf7a", "rocksdb": "#eda100"}
ENGINE_LABEL = {
    "leveled": "Spectrolith leveled",
    "tiered": "Spectrolith tiered",
    "nobloom": "Leveled, no bloom",
    "rocksdb": "RocksDB",
}
ENGINES = ["leveled", "tiered", "nobloom", "rocksdb"]
INK = "#0b0b0b"
MUTED = "#52514e"
GRID = "#e4e3df"
SURFACE = "#fcfcfb"
GRAPH_LABEL = {"ppi": "STRING human PPI", "lj": "com-LiveJournal", "ppi700": "STRING PPI, score >= 700"}

plt.rcParams.update({
    "figure.facecolor": SURFACE,
    "axes.facecolor": SURFACE,
    "savefig.facecolor": SURFACE,
    "font.size": 10,
    "text.color": INK,
    "axes.labelcolor": MUTED,
    "axes.edgecolor": GRID,
    "xtick.color": MUTED,
    "ytick.color": MUTED,
    "axes.spines.top": False,
    "axes.spines.right": False,
    "axes.spines.left": False,
    "axes.grid": True,
    "axes.grid.axis": "y",
    "grid.color": GRID,
    "grid.linewidth": 0.8,
    "axes.axisbelow": True,
    "axes.titlesize": 11,
    "axes.titleweight": "bold",
    "axes.titlelocation": "left",
})


def load():
    rows = [json.loads(line) for line in (OUT / "raw.jsonl").read_text().splitlines() if line.strip()]
    store = defaultdict(list)
    for r in rows:
        if r["kind"] == "store":
            store[(r["dataset"], r["engine"])].append(r)
    return rows, store


def med(runs, key):
    return statistics.median(r[key] for r in runs)


def spread(runs, key, fmt="{:,.0f}"):
    vals = [r[key] for r in runs]
    m = fmt.format(statistics.median(vals))
    return m if len(vals) == 1 else f"{m} ({fmt.format(min(vals))}–{fmt.format(max(vals))})"


def human(v):
    for limit, div, unit in ((1e9, 1e9, "s"), (1e6, 1e6, "ms"), (1e3, 1e3, "µs")):
        if v >= limit:
            return f"{v / div:.3g} {unit}"
    return f"{v:.0f} ns"


def graphs(store):
    return [g for g in ("ppi", "lj", "ppi700") if any(k[0] == g for k in store)]


def engines_of(store, g, skip=()):
    return [e for e in ENGINES if (g, e) in store and e not in skip]


def legend(fig, engines):
    handles = [plt.Rectangle((0, 0), 1, 1, color=ENGINE_COLOR[e]) for e in engines]
    fig.legend(handles, [ENGINE_LABEL[e] for e in engines], loc="lower center",
               ncol=len(engines), frameon=False, bbox_to_anchor=(0.5, -0.02))


def bars_by_engine(store, key, title, ylabel, name, fmt, skip=(), log=False):
    """One small multiple per graph: scales differ, so they get separate axes."""
    gs = graphs(store)
    fig, axes = plt.subplots(1, len(gs), figsize=(4.4 * len(gs), 3.6), squeeze=False)
    for ax, g in zip(axes[0], gs):
        es = engines_of(store, g, skip)
        vals = [med(store[(g, e)], key) for e in es]
        bars = ax.bar(range(len(es)), vals, width=0.62, color=[ENGINE_COLOR[e] for e in es],
                      edgecolor=SURFACE, linewidth=2)
        for b, v in zip(bars, vals):
            ax.annotate(fmt(v), (b.get_x() + b.get_width() / 2, v), ha="center", va="bottom",
                        xytext=(0, 3), textcoords="offset points", color=INK, fontsize=9)
        ax.set_xticks([])
        ax.set_title(GRAPH_LABEL[g])
        ax.set_ylabel(ylabel)
        if log:
            ax.set_yscale("log")
        ax.margins(y=0.14)
    fig.suptitle(title, x=0.01, ha="left", fontsize=12, fontweight="bold")
    fig.tight_layout(rect=(0, 0.06, 1, 0.97))
    legend(fig, [e for e in ENGINES if any((g, e) in store and e not in skip for g in gs)])
    fig.savefig(OUT / name, dpi=160, bbox_inches="tight")
    plt.close(fig)


def latency_chart(store, prefix, title, name):
    """p50, p99, p99.9 per engine, log scale: they span orders of magnitude."""
    gs = graphs(store)
    qs = [("p50", "p50"), ("p99", "p99"), ("p999", "p99.9")]
    fig, axes = plt.subplots(1, len(gs), figsize=(4.8 * len(gs), 3.8), squeeze=False)
    for ax, g in zip(axes[0], gs):
        es = engines_of(store, g, ("nobloom",))
        w = 0.8 / len(es)
        for i, e in enumerate(es):
            vals = [med(store[(g, e)], f"{prefix}_{q}_ns") for q, _ in qs]
            ax.bar([x + i * w for x in range(len(qs))], vals, width=w * 0.92,
                   color=ENGINE_COLOR[e], edgecolor=SURFACE, linewidth=1)
        ax.set_yscale("log")
        ax.set_xticks([x + w * (len(es) - 1) / 2 for x in range(len(qs))], [q for _, q in qs])
        ax.set_title(GRAPH_LABEL[g])
        ax.set_ylabel("nanoseconds (log)")
        ax.tick_params(axis="x", length=0)
    fig.suptitle(title, x=0.01, ha="left", fontsize=12, fontweight="bold")
    fig.tight_layout(rect=(0, 0.06, 1, 0.97))
    legend(fig, [e for e in ENGINES if e != "nobloom" and any((g, e) in store for g in gs)])
    fig.savefig(OUT / name, dpi=160, bbox_inches="tight")
    plt.close(fig)


def level_chart(store, name):
    """Where write amplification comes from, one small multiple per policy."""
    g = "lj" if ("lj", "leveled") in store else graphs(store)[0]
    es = [e for e in ("leveled", "tiered") if (g, e) in store]
    fig, axes = plt.subplots(1, len(es), figsize=(4.4 * len(es), 3.4), squeeze=False, sharey=True)
    for ax, e in zip(axes[0], es):
        levels = store[(g, e)][0]["levels"]
        xs = [f"L{lv['level']}" for lv in levels]
        vals = [lv["bytes_written"] / 2**30 for lv in levels]
        bars = ax.bar(xs, vals, width=0.6, color=ENGINE_COLOR[e], edgecolor=SURFACE, linewidth=2)
        for b, v in zip(bars, vals):
            ax.annotate(f"{v:.1f}", (b.get_x() + b.get_width() / 2, v), ha="center", va="bottom",
                        xytext=(0, 3), textcoords="offset points", fontsize=9)
        ax.set_title(ENGINE_LABEL[e])
        ax.set_ylabel("GiB written")
        ax.tick_params(axis="x", length=0)
        ax.margins(y=0.14)
    fig.suptitle(f"Bytes written per level, {GRAPH_LABEL[g]}", x=0.01, ha="left", fontsize=12, fontweight="bold")
    fig.tight_layout(rect=(0, 0, 1, 0.97))
    fig.savefig(OUT / name, dpi=160, bbox_inches="tight")
    plt.close(fig)


def warm_chart(rows, name):
    """Operator applications, cold vs warm, as the graph grows."""
    rs = [r for r in rows if r["kind"] == "analytics" and r["has_prev"]]
    if not rs:
        return False
    fig, axes = plt.subplots(1, 2, figsize=(8.8, 3.4), sharex=True)
    xs = [r["seq"] / 1e6 for r in rs]
    for ax, method, title in ((axes[0], "lanczos", "Lanczos"), (axes[1], "power", "Power iteration")):
        cold = [r[f"{method}_cold_iters"] for r in rs]
        warm = [r[f"{method}_warm_iters"] for r in rs]
        ax.plot(xs, cold, color=MUTED, linewidth=2, marker="o", markersize=5, label="Cold start")
        ax.plot(xs, warm, color=ENGINE_COLOR["leveled"], linewidth=2, marker="o", markersize=5, label="Warm start")
        ax.set_title(title)
        ax.set_xlabel("records ingested (millions)")
        ax.set_ylabel("operator applications")
        ax.set_ylim(bottom=0)
        ax.legend(frameon=False)
    fig.suptitle("Warm starts during ingest", x=0.01, ha="left", fontsize=12, fontweight="bold")
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    fig.savefig(OUT / name, dpi=160, bbox_inches="tight")
    plt.close(fig)
    return True


def table(headers, rows):
    out = ["| " + " | ".join(headers) + " |", "| " + " | ".join("---" for _ in headers) + " |"]
    out += ["| " + " | ".join(str(c) for c in row) + " |" for row in rows]
    return "\n".join(out)


def report(rows, store, have_warm):
    md = ["# Benchmark results", "",
          "Generated by `scripts/run_benchmarks.sh`; do not edit by hand. See "
          "[BENCHMARKS.md](../BENCHMARKS.md) for the method and what the numbers mean.", "",
          "```text", (OUT / "environment.txt").read_text().strip(), "```", ""]
    gs = graphs(store)

    md += ["## Bulk ingest", "", "One edge per write, both directions, no fsync per write. "
           "Cells are the median, with the range across repetitions when there are several.", "",
           "![Ingest throughput](ingest_throughput.png)", "", "![Insert latency](insert_latency.png)", ""]
    t = []
    for g in gs:
        for e in engines_of(store, g):
            r = store[(g, e)]
            t.append([g, ENGINE_LABEL[e], spread(r, "ingest_edges_per_sec"), human(med(r, "ingest_p50_ns")),
                      human(med(r, "ingest_p99_ns")), human(med(r, "ingest_p999_ns")), human(med(r, "ingest_max_ns")),
                      f"{med(r, 'stall_ns') / 1e9:.2f} s", f"{med(r, 'settle_s'):.1f} s"])
    md += [table(["graph", "engine", "edges/s", "p50", "p99", "p99.9", "max", "stalled", "settle"], t), ""]

    md += ["## Mixed reads and writes", "", "![Scan latency](scan_latency.png)", ""]
    t = []
    for g in gs:
        for e in engines_of(store, g):
            r = store[(g, e)]
            for mix, label in (("mix90", "90/10"), ("mix50", "50/50")):
                t.append([g, ENGINE_LABEL[e], label, spread(r, f"{mix}_ops_per_sec"), human(med(r, f"{mix}_read_p50_ns")),
                          human(med(r, f"{mix}_read_p99_ns")), human(med(r, f"{mix}_write_p99_ns"))])
    md += [table(["graph", "engine", "read/write", "ops/s", "scan p50", "scan p99", "write p99"], t), ""]

    md += ["## Amplification", "", "![Amplification](write_amp.png)", "", "![Space](space_amp.png)", "",
           "![Per level](levels.png)", ""]
    t = []
    for g in gs:
        for e in engines_of(store, g):
            r = store[(g, e)]
            ra = f"{med(r, 'read_amp'):.2f}" if "read_amp" in r[0] else "n/a"
            t.append([g, ENGINE_LABEL[e], f"{med(r, 'write_amp'):.2f}", f"{med(r, 'space_amp'):.2f}", ra,
                      f"{med(r, 'disk_bytes') / 2**30:.2f} GiB"])
    md += [table(["graph", "engine", "write amp", "space amp", "runs per scan", "on disk"], t), ""]
    t = []
    for g in gs:
        for e in ("leveled", "tiered"):
            if (g, e) not in store:
                continue
            for lv in store[(g, e)][0]["levels"]:
                t.append([g, ENGINE_LABEL[e], f"L{lv['level']}", lv["files"], f"{lv['bytes'] / 2**30:.2f}",
                          lv["compactions"], f"{lv['bytes_written'] / 2**30:.2f}", f"{lv['write_amp']:.2f}"])
    md += ["Per level, first repetition:", "",
           table(["graph", "engine", "level", "files", "GiB now", "runs into it", "GiB written", "write amp"], t), ""]

    sync = [r for r in rows if r["kind"] == "sync"]
    if sync:
        md += ["## Durable writes (fsync on every write)", "",
               table(["graph", "engine", "edges/s", "p50", "p99"],
                     [[r["dataset"], ENGINE_LABEL[r["engine"]], f"{r['edges_per_sec']:,.0f}", human(r["write_p50_ns"]),
                       human(r["write_p99_ns"])] for r in sync]), ""]

    sp = [r for r in rows if r["kind"] == "spectral"]
    md += ["## Spectral costs", "",
           "A snapshot with 99% of the edges compacted and 1% in the MemGraph.", "",
           table(["graph", "vertices", "edges in view", "delta entries", "build view", "build delta", "SpMV", "SpMV with delta", "M edges/s"],
                 [[r["dataset"], f"{r['n']:,}", f"{r['view_edges']:,}", f"{r['delta_triples']:,}", f"{r['view_ms']:,.0f} ms",
                   f"{r['delta_ms']:,.0f} ms", f"{r['base_spmv_ms']:.1f} ms", f"{r['delta_spmv_ms']:.1f} ms",
                   f"{r['medges_per_sec']:,.0f}"] for r in sp]), ""]

    an = [r for r in rows if r["kind"] == "analytics"]
    md += ["## Analytics during ingest", ""]
    if have_warm:
        md += ["![Warm starts](warm_start.png)", ""]
    md += [table(["round", "records", "lambda2", "view", "delta", "Lanczos cold", "warm", "power cold", "warm", "behind by"],
                 [[r["round"], f"{r['seq']:,}", f"{r['lambda2']:.5f}", f"{r['view_ms']:,.0f} ms", f"{r['delta_ms']:,.0f} ms",
                   f"{r['lanczos_cold_iters']} / {r['lanczos_cold_ms']:,.0f} ms",
                   f"{r['lanczos_warm_iters']} / {r['lanczos_warm_ms']:,.0f} ms",
                   f"{r['power_cold_iters']}{'' if r['power_cold_converged'] else '*'} / {r['power_cold_ms']:,.0f} ms",
                   f"{r['power_warm_iters']}{'' if r['power_warm_converged'] else '*'} / {r['power_warm_ms']:,.0f} ms",
                   f"{r['staleness_seq']:,}"] for r in an]), "",
           "Iterations are operator applications. `*` means power iteration hit its cap of 3000 without converging. "
           "`behind by` is how many sequence numbers ingest moved during the round's solves.", ""]

    k = next((r for r in rows if r["kind"] == "kernels"), None)
    if k:
        md += ["## Vector kernels", "", table(["kernel", "plain loop GB/s", "`@Vector(4, f64)` GB/s", "speedup"],
               [[n, f"{k[n + '_scalar_gbps']:.1f}", f"{k[n + '_simd_gbps']:.1f}", f"{k[n + '_simd_gbps'] / k[n + '_scalar_gbps']:.1f}x"]
                for n in ("dot", "distsq", "axpy")]), ""]

    num = OUT / "numerics.txt"
    if num.exists():
        md += ["## Numerical check against SciPy", "", "```text", num.read_text().strip(), "```", ""]
    (OUT / "RESULTS.md").write_text("\n".join(md))


def main():
    rows, store = load()
    bars_by_engine(store, "ingest_edges_per_sec", "Ingest throughput", "edges per second", "ingest_throughput.png",
                   lambda v: f"{v / 1e3:,.0f}k", skip=("nobloom",))
    latency_chart(store, "ingest", "Insert latency", "insert_latency.png")
    latency_chart(store, "mix90_read", "Neighbor scan latency, 90% reads", "scan_latency.png")
    bars_by_engine(store, "write_amp", "Write amplification", "bytes written / bytes ingested", "write_amp.png",
                   lambda v: f"{v:.1f}", skip=("nobloom",))
    bars_by_engine(store, "space_amp", "Space amplification", "bytes on disk / live bytes", "space_amp.png",
                   lambda v: f"{v:.2f}", skip=("nobloom",))
    level_chart(store, "levels.png")
    report(rows, store, warm_chart(rows, "warm_start.png"))


if __name__ == "__main__":
    main()
