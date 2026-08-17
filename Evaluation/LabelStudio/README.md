# Completion Review annotation with Label Studio

Status: `部分实现`

This isolated workflow directly reuses Label Studio Community Edition for human annotation instead of
building a Notch Relay labeling service. It is not bundled in the macOS App, has no Relay runtime-store
access, and cannot write canonical state or HumanDecision records.

The reviewed dependency is HumanSignal Label Studio `1.23.0`, release commit
`2a9bfbcbf0a844b999de97e601d16050a893f5fb`, under Apache-2.0. `compose.yaml` pins the official
multi-architecture image digest
`sha256:aa461572e8f9d86a1bf9520c1db620204e86160fd2f80dd7e9d40ac84a8828ea`, binds only to
`127.0.0.1`, and uses an internal Docker network. The checked-in synthetic adapter does not establish
container or consented production-data acceptance.

## Bounded workflow

1. A separately reviewed process creates consented, sanitized tasks under
   `Evaluation/LabelStudio/private/`. Each task must contain only `caseID`, `category`,
   `consentContractID`, `consentExpiresAt`, `sanitizationVersion`, and a bounded
   `casePresentation`. This repository does not provide a path that copies Relay runtime data into the
   annotation tool.
2. A local Label Studio project imports `labeling-config.xml` and the private task file. At least two
   distinct annotators independently label every case. A rejection must identify one or more bounded
   failure modes.
3. Any disagreement requires a third, independent adjudicator. The adjudicated Label Studio annotation
   must be the only annotation exported with `ground_truth: true`.
4. Product and evaluation owners approve thresholds separately using a private copy of
   `approved-thresholds-template.json`. Placeholders are intentionally rejected.
5. The exporter validates consent expiry, annotation independence, adjudication, production-set size,
   category coverage, and threshold approval metadata. It writes only anonymous case ID, category, and
   boolean label plus the already approved aggregate thresholds.
6. The resulting file is evaluated by the pinned OpenJudge environment. Raw task presentation,
   annotator identity, consent fields, annotation notes, prompt, transcript, source code, raw commands,
   tool arguments, detailed errors, credentials, and model responses are never written to the OpenJudge
   dataset.

Label Studio and OpenJudge remain evaluation-edge tools. They do not become App dependencies and do not
receive canonical-state or human-decision authority.

## Local commands

After installing Docker separately and reviewing the image source, pull the exact reviewed image:

```bash
docker pull \
  heartexlabs/label-studio:1.23.0@sha256:aa461572e8f9d86a1bf9520c1db620204e86160fd2f80dd7e9d40ac84a8828ea
docker compose -f Evaluation/LabelStudio/compose.yaml up
```

Export a consented production set only into ignored private storage:

```bash
/usr/bin/python3 -I -B Evaluation/LabelStudio/export_gold_set.py \
  --export Evaluation/LabelStudio/private/label-studio-export.json \
  --thresholds Evaluation/LabelStudio/private/approved-thresholds.json \
  --output Evaluation/OpenJudge/private/completion-review-gold-set.json
```

Run the checked-in synthetic adapter verification:

```bash
./scripts/verify-labelstudio-evaluation.sh
```

The synthetic fixture proves only schema, consensus/adjudication, data-minimization, and OpenJudge handoff
behavior. The production Gold Set remains `未开发` until separately consented cases are actually collected,
independently annotated, adjudicated, and approved. Production thresholds and online model acceptance also
remain `未开发`.
