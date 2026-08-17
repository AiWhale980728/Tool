#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
evaluation_root="$project_root/Evaluation/OpenJudge"
uv_cache="$project_root/.build/uv-cache"
uv_python="$project_root/.build/uv-python"

if ! command -v uv >/dev/null 2>&1; then
    print -u2 "OpenJudge evaluation verification requires uv"
    exit 1
fi

run_evaluation() {
    env \
        UV_CACHE_DIR="$uv_cache" \
        UV_PYTHON_INSTALL_DIR="$uv_python" \
        uv run \
        --offline \
        --locked \
        --project "$evaluation_root" \
        "$evaluation_root/run_gold_set.py" "$@"
}

expect_contract_rejection() {
    set +e
    run_evaluation "$@" >/dev/null 2>&1
    local evaluation_exit_code=$?
    set -e
    if [[ $evaluation_exit_code -ne 2 ]]; then
        print -u2 "OpenJudge evaluation contract rejection returned $evaluation_exit_code instead of 2"
        exit 1
    fi
}

run_evaluation \
    --dataset "$evaluation_root/fixtures/synthetic-smoke-v1.json" \
    --predictions "$evaluation_root/fixtures/synthetic-predictions-v1.json" \
    --allow-synthetic

expect_contract_rejection \
    --dataset "$evaluation_root/fixtures/synthetic-smoke-v1.json" \
    --predictions "$evaluation_root/fixtures/synthetic-predictions-v1.json"

expect_contract_rejection \
    --dataset "$evaluation_root/fixtures/invalid-production-too-small-v1.json" \
    --predictions "$evaluation_root/fixtures/invalid-production-too-small-predictions-v1.json"
