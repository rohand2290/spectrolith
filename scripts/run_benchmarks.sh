#!/bin/sh
# Regenerate every number and chart in results/ from scratch.
#
#   scripts/fetch_data.sh          # once, downloads about 200 MB
#   scripts/run_benchmarks.sh      # about 45 minutes on a laptop
#
# Needs RocksDB (brew install rocksdb, or set ROCKSDB_PREFIX) and a Python with
# numpy, scipy and matplotlib (set PYTHON if it is not python3). Close other
# work first: these are wall-clock measurements on one machine.
#
# REPS=1 FAST=1 runs one repetition on the small graph only, to test the script.
set -eu
cd "$(dirname "$0")/.."

PY=${PYTHON:-python3}
REPS=${REPS:-3}
FAST=${FAST:-0}
PREFIX=${ROCKSDB_PREFIX:-$(brew --prefix rocksdb 2>/dev/null || echo /usr/local)}
WORK=${WORK:-bench-work}
RAW=results/raw.jsonl

zig build -Doptimize=ReleaseFast -Drocksdb=true -Drocksdb_prefix="$PREFIX"
BENCH=./zig-out/bin/bench

mkdir -p results "$WORK"
: > "$RAW"
{
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "commit: $(git rev-parse --short HEAD)$(git diff --quiet || echo ' + uncommitted changes')"
    echo "zig: $(zig version)"
    echo "rocksdb: $(ls -d "$(brew --prefix)"/Cellar/rocksdb/* 2>/dev/null | sed 's|.*/||' || echo unknown)"
    echo "cpu: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m), $(sysctl -n hw.ncpu 2>/dev/null || nproc) threads"
    echo "memory_gib: $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))"
    echo "os: $(uname -sr)"
    echo "reps: $REPS"
} > results/environment.txt

# Each run gets an empty directory, and appends its JSON to the log.
store() { # mode engine graph
    rm -rf "$WORK/current"
    "$BENCH" "$1" "$2" "data/$3.tsv" "$WORK/current" "$3" >> "$RAW"
    rm -rf "$WORK/current"
}
analysis() { # mode graph
    rm -rf "$WORK/current"
    "$BENCH" "$1" "data/$2.tsv" "$WORK/current" "$2" >> "$RAW"
    rm -rf "$WORK/current"
}

if [ "$FAST" = 1 ]; then
    GRAPHS="ppi700"
else
    GRAPHS="ppi lj"
fi

"$BENCH" kernels >> "$RAW"

for g in $GRAPHS; do
    # The large graph gets one repetition: it takes minutes per engine and
    # averages over far more operations anyway.
    r=$REPS
    [ "$g" = lj ] && r=1
    i=0
    while [ "$i" -lt "$r" ]; do
        i=$((i + 1))
        # Order rotates, so slow drift (heat, background work) favours nobody.
        case $((i % 4)) in
            1) order="leveled rocksdb tiered nobloom" ;;
            2) order="rocksdb tiered nobloom leveled" ;;
            3) order="tiered nobloom leveled rocksdb" ;;
            0) order="nobloom leveled rocksdb tiered" ;;
        esac
        for e in $order; do
            echo "== store $g $e (rep $i/$r)"
            store store "$e" "$g"
        done
    done
    for e in leveled rocksdb; do
        echo "== sync $g $e"
        store sync "$e" "$g"
    done
    echo "== spectral $g"
    analysis spectral "$g"
done

# Analytics while ingesting, on the graph small enough to solve repeatedly.
a=ppi
[ "$FAST" = 1 ] && a=ppi700
echo "== analytics $a"
analysis analytics "$a"

# The numerical check is part of the published result.
echo "== fiedler check against scipy"
rm -rf "$WORK/check"
./zig-out/bin/fiedlercheck "data/$a.tsv" "$WORK/check" 5 2>/dev/null
"$PY" scripts/check_fiedler.py "$WORK/check" "data/$a.tsv" | tee results/numerics.txt
rm -rf "$WORK/check"

"$PY" scripts/plot_results.py
echo "done: see results/RESULTS.md"
