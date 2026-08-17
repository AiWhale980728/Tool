# Completion Review evaluation with OpenJudge

Status: `部分实现`

This isolated tool directly uses OpenJudge's `FunctionGrader`, `GradingRunner`, and
Accuracy/Precision/Recall analyzers to compare bounded independent-evaluator labels with an annotated
Completion Review set. It is an offline/CI evaluation dependency only. It is not bundled in Notch Relay,
does not read Relay runtime stores, and cannot write canonical state or human decisions.

The dependency is pinned to OpenJudge tag `v0.2.2`, commit
`33db7c4a19170142c14a20df32ebaeff1d8d47e4`, under Apache-2.0. That tag reports Python package version
`0.2.0`; the runner checks this upstream version mismatch explicitly. Python 3.10+ is required.

`scripts/verify-openjudge-evaluation.sh` runs the positive synthetic fixture with `uv --offline --locked`
and also verifies that synthetic data without `--allow-synthetic` and an undersized production-shaped
dataset both fail with the bounded contract-error exit code.

Run the non-production integration fixture:

```bash
uv run --project Evaluation/OpenJudge \
  Evaluation/OpenJudge/run_gold_set.py \
  --dataset Evaluation/OpenJudge/fixtures/synthetic-smoke-v1.json \
  --predictions Evaluation/OpenJudge/fixtures/synthetic-predictions-v1.json \
  --allow-synthetic
```

Production use must provide a separately consented, human-annotated dataset and a complete predictions
file through ignored `Evaluation/OpenJudge/private/`. A production dataset requires at least 100 cases and
20 cases per category. The threshold placeholders must be replaced only after product and evaluation review;
no production threshold is accepted yet. The checked-in synthetic fixture verifies only the OpenJudge adapter
and metric contract; it is not a production gold set and does not prove model quality.

Inputs intentionally contain only anonymous case IDs, bounded category names, boolean human labels, and
boolean evaluator predictions. Prompts, transcripts, source code, commands, tool arguments, detailed errors,
credentials, and raw model responses do not belong in these files. Output contains aggregate metrics only.

`Evaluation/LabelStudio/` provides the reviewed local annotation edge for creating this bounded input. It
reuses pinned Label Studio Community Edition, requires independent votes and adjudication, then removes case
presentation, annotator identity, and consent metadata before writing the OpenJudge dataset. Its checked-in
synthetic handoff is verified; no production dataset or threshold is accepted.
