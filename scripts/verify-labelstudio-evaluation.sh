#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
evaluation_root="$project_root/Evaluation/LabelStudio"
openjudge_root="$project_root/Evaluation/OpenJudge"
uv_cache="$project_root/.build/uv-cache"
uv_python="$project_root/.build/uv-python"
temporary_root="$(mktemp -d /tmp/notch-relay-labelstudio-verification.XXXXXX)"

cleanup() {
    rm -rf "$temporary_root"
}
trap cleanup EXIT

/usr/bin/python3 -I -B -c \
    'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' \
    "$evaluation_root/labeling-config.xml"

/usr/bin/python3 -I -B -m unittest discover \
    -s "$evaluation_root" \
    -p 'test_*.py'

/usr/bin/python3 -I -B "$evaluation_root/export_gold_set.py" \
    --export "$evaluation_root/fixtures/synthetic-label-studio-export-v1.json" \
    --thresholds "$evaluation_root/fixtures/synthetic-approved-thresholds-v1.json" \
    --output "$temporary_root/gold-set.json" \
    --allow-synthetic \
    --as-of '2026-08-16T12:00:00Z'

cmp \
    "$temporary_root/gold-set.json" \
    "$evaluation_root/fixtures/synthetic-gold-set-v1.json"

if ! command -v uv >/dev/null 2>&1; then
    print -u2 "Label Studio to OpenJudge verification requires uv"
    exit 1
fi

env \
    UV_CACHE_DIR="$uv_cache" \
    UV_PYTHON_INSTALL_DIR="$uv_python" \
    uv run \
    --offline \
    --locked \
    --project "$openjudge_root" \
    "$openjudge_root/run_gold_set.py" \
    --dataset "$temporary_root/gold-set.json" \
    --predictions "$evaluation_root/fixtures/synthetic-predictions-v1.json" \
    --allow-synthetic

print "Label Studio evaluation adapter verification passed"
