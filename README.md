# Spectrolith

Spectrolith is a single-node, disk-backed dynamic graph store written in Zig. 
Edge updates go through an LSM pipeline and end up in immutable CSR segments on disk. 
Spectral operators (SpMV, power iteration, normalized Laplacian) run on point-in-time snapshots, so a long computation sees one consistent graph while writes continue.

The storage design follows LSMGraph (SIGMOD 2025): LSM-tree levels for write throughput, and CSR inside each level for read locality. 

## Status

This is a WIP. The full design is written up, but phases 1 to 4 are implemented:

| Part | State |
| --- | --- |
| Write-ahead log (framing, CRC32C, torn-tail detection) | Implemented |
| Write batches (atomic) | Implemented |
| MemGraph (in-memory adjacency, arena-backed) | Implemented |
| Snapshots and neighbor scans over the MemGraph | Implemented |
| WAL replay on open | Implemented |
| `kill -9` crash test | Implemented |
| CSR segment files (writer, validating mmap reader), flush to L0, merged neighbor scans | Implemented |
| Refcounted versions, manifest, `CURRENT`, recovery of the level layout | Implemented |
| Leveled compaction (picker, merge, garbage collection, output splitting, write stalls, per-level stats) | Implemented |
| Tiered compaction policy | Not started (the policy interface is in place) |
| Spectral engine (CSR view, Fiedler vector, delta operator) | Not started |
| Benchmarks against RocksDB | Not started |


## Goals

- High edge-insert throughput, with bounded p99 latency during flush and compaction.
- Neighbor scans and whole-graph spectral computations from a snapshot, without blocking writers.
- No loss of acknowledged writes after `kill -9`.
- Write, read and space amplification reported per level.

Some things outside of the scope: distribution or replication, a query language, multi-statement transactions (a batch is atomic, nothing larger is), and properties beyond a single `f32` edge weight.

## Requirements

- Zig 0.17.0 or newer (set by `minimum_zig_version` in `build.zig.zon`). Zig is pre-1.0, so a different version may need small standard library fixes.
- A POSIX system. The code uses `flock`, `fsync`, `fork` and similar calls directly through libc. The on-disk format is little-endian only.

## Build and test

```sh
zig build test                  # unit tests
zig build test -Dtsan=true      # unit tests under ThreadSanitizer
zig build crashtest -- 50 1234  # kill -9 test: <rounds> <seed>
```

The crash test forks a child that writes batches and reports each acknowledged one over a pipe. The parent kills the child at a random moment with `SIGKILL`, reopens the database, and checks that every acknowledged batch is present and was applied atomically.

For extra checking, run the tests in both Debug and ReleaseSafe (`-Doptimize=ReleaseSafe`). Both trap out-of-bounds indexing and integer overflow, and the tests use `std.testing.allocator`, so leaks fail the test.

## Usage

```zig
const std = @import("std");
const spectrolith = @import("spectrolith");

const db = try spectrolith.Db.open(gpa, .{ .path = "data/ppi" });
defer db.close();

try db.putEdge(4932, 1024, 0.87);
try db.delEdge(4932, 1024);

const snap = try db.snapshot();
defer snap.release();

var it = try snap.neighbors(gpa, 4932);
defer it.deinit();
while (it.next()) |e| std.debug.print("{d} {d}\n", .{ e.dst, e.weight });
```

Notes on the API:

- Every function that can fail returns an error union (`Io`, `Corrupt`, `InvalidArgument`, or an allocator error). Nothing panics on I/O errors.
- Anything that allocates takes a `std.mem.Allocator`.
- `Db.write` takes a `Batch` and applies all of it or none of it.
- `Options.background_compaction` (default true) runs compaction on a thread. With `false`, nothing compacts until you call `db.compactOnce()`, `db.compactLevel(n)` or `db.waitForCompaction()`.
- `db.stats()` reports, per level, files, bytes, compactions, bytes read and bytes written, plus flushes, stall count and time, and records dropped as garbage.
- `Options.sync_mode` is `.every` (fsync the log on every write, the default) or `.none`.
- With `undirected = true` (the default), each edge is stored in both directions in the same batch.

## How it works

**Writes.** A batch gets a range of sequence numbers, is appended to the WAL, is applied to the active MemGraph, and is then published by advancing `last_seq`. Readers never see a write that is not already in the log. When the MemGraph reaches its size limit, it is flushed to an L0 segment by the writer that hit the limit. That write waits if L0 already holds `l0_stop_trigger` files, and the wait is counted in `stats().stall_ns`.

**Storage.** Each edge record is 24 bytes: destination, sequence number, weight and flags (one flag marks a delete). Within a vertex, records are sorted by destination ascending and then sequence number descending, so the first record for a destination that is visible to a snapshot is the current one. Segments are written once, never modified, and read through `mmap`. Levels L1 and deeper hold disjoint vertex ranges and each is `size_ratio` times larger than the one above.

**Reads.** A snapshot is a sequence number plus references to the MemGraphs and the version of the segment layout that were current when it was taken. Those references keep files alive until the snapshot is released: a segment that compaction has replaced is deleted when the last older version lets go of it. A neighbor scan merges one sorted run from each source through a priority queue and returns the newest visible version of each edge, skipping deleted ones.

**Compaction.** A background thread scores every level (L0 by file count, deeper levels by bytes against `level1_bytes * size_ratio^(n-1)`) and compacts the highest score that is at least 1. L0 compacts all of its files with the L1 segments they overlap; a deeper level compacts one segment, rotating through the level, with the segments below it that overlap. Output is cut into `target_segment_bytes` segments at vertex boundaries, so L1 and deeper stay disjoint, and one edit swaps inputs for outputs atomically. A version of an edge is dropped once a newer one is visible to the oldest live snapshot. A delete marker is dropped only when no deeper level overlaps the compaction's vertex range, because dropping it earlier could bring back an older copy of the edge. A tiered policy will sit behind the same `CompactionPolicy` interface so the two can be benchmarked.

**Spectral operators.** The algorithms are written against a matrix-free linear operator interface (`y = Op x`). The planned set is normalized adjacency, the Fiedler vector by deflated power iteration, and eigenvector centrality. Each snapshot gets a cached in-memory CSR view of its segments, and recent MemGraph changes are applied as a small correction on top. The previous Fiedler vector is reused as a warm start after new edges arrive.

**Recovery.** On open, the database takes a lock file, reads `CURRENT` and the manifest it names to rebuild the level layout, opens and checks every segment the manifest lists, and deletes segment files it does not list (a flush or compaction that crashed before its edit). It then replays any WALs numbered at least the manifest's log number and writes a fresh manifest holding the whole layout. Replay stops at the first record with a bad checksum or a short length, which is treated as a torn tail from the crash and not as corruption. The same rule applies to the last record of the manifest. A damaged record with acknowledged records after it, or a listed segment that is missing, fails the open.

## Source layout

| File | Contents |
| --- | --- |
| `src/spectrolith.zig` | Public API |
| `src/db.zig` | `Db`, open/recovery, flush, compaction thread and stalls, snapshots, neighbor iterator |
| `src/version.zig` | `Version`, `VersionEdit`, `VersionSet`, manifest and `CURRENT` |
| `src/compaction.zig` | `CompactionPolicy`, `Leveled`, merge and garbage collection |
| `src/merge.zig` | Sorted runs and their heap order, shared by scans and compaction |
| `src/segment.zig` | CSR segment writer and validating mmap reader |
| `src/memgraph.zig` | In-memory adjacency buffer |
| `src/wal.zig` | Write-ahead log |
| `src/batch.zig` | Write batches |
| `src/types.zig` | Shared types such as `EdgeRec` |
| `src/sys.zig` | Thin wrappers over POSIX calls |
| `src/db_test.zig` | Unit tests |
| `src/crashtest.zig` | `kill -9` crash test |

## Planned testing and benchmarks

- More seeds for the model-based test. It already compares every snapshot, including frozen ones held across compactions and reopens, against an in-memory reference, in a background-compaction run and in a run that triggers compactions at random points; the seed is printed on failure.
- Fuzzing of the segment reader and WAL parser on corrupt input.
- A numerical check of the Fiedler vector and eigenvalue against `scipy.sparse.linalg.eigsh`.
- Benchmarks on the STRING human PPI graph and a SNAP social graph: ingest rate, p50 and p99 insert latency, stall time, scan latency, and per-level amplification. The baseline is RocksDB used through its C API with a `src|dst` key.

## References

- [LSMGraph](https://arxiv.org/abs/2411.06392v2) (SIGMOD 2025), the storage design this follows.
- [Aster](https://arxiv.org/abs/2501.06570v1) (SIGMOD 2025), on adaptive layout for hub vertices.
- [RapidStore](https://arxiv.org/abs/2507.00839), an in-memory dynamic graph store with separated version data.
- [ArceKV](https://arxiv.org/abs/2508.03565v2), on workload-driven compaction.
- LevelDB source (`db/version_set.cc`, `db/log_writer.cc`, `table/merger.cc`), the reference for versions, WAL framing and merge iterators.
