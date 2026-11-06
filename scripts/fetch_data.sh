#!/bin/sh
# Download and normalize the benchmark graphs into data/<name>.tsv ("u v w",
# numeric ids, one line per undirected edge). Safe to re-run.
set -eu
cd "$(dirname "$0")/.."
mkdir -p data
PY=${PYTHON:-python3}

fetch() { # url file
    [ -f "$2" ] || curl -fsSL --retry 3 -o "$2.part" "$1" && { [ -f "$2" ] || mv "$2.part" "$2"; }
}

fetch https://stringdb-downloads.org/download/protein.links.v12.0/9606.protein.links.v12.0.txt.gz \
      data/string-human.txt.gz
fetch https://snap.stanford.edu/data/bigdata/communities/com-lj.ungraph.txt.gz \
      data/com-lj.txt.gz

[ -f data/ppi.tsv ] || "$PY" scripts/prepare_data.py string data/string-human.txt.gz data/ppi.tsv 0
[ -f data/ppi700.tsv ] || "$PY" scripts/prepare_data.py string data/string-human.txt.gz data/ppi700.tsv 700
[ -f data/lj.tsv ] || "$PY" scripts/prepare_data.py snap data/com-lj.txt.gz data/lj.tsv 0
wc -l data/*.tsv
