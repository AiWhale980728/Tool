#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import tempfile
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path


SUPPORTED_THRESHOLD_SCHEMA_VERSION = 1
PRODUCTION_MINIMUM_CASES = 100
PRODUCTION_MINIMUM_CASES_PER_CATEGORY = 20
ALLOWED_RESULT_NAMES = {
    "supports_assessment",
    "failure_modes",
    "annotator_confidence",
}
ALLOWED_FAILURE_MODES = {
    "missing_evidence",
    "unsupported_claim",
    "criterion_uncovered",
    "risk_miscalibrated",
    "unsafe_recommendation",
    "identity_expiry_or_policy_invalid",
}
ALLOWED_CONFIDENCE = {"high", "medium", "low"}
EXPECTED_TASK_DATA_FIELDS = {
    "caseID",
    "category",
    "consentContractID",
    "consentExpiresAt",
    "sanitizationVersion",
    "casePresentation",
}


def fail(message: str) -> None:
    raise ValueError(message)


def load_json(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"))


def bounded_string(value: object, field: str, maximum: int = 128) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum:
        fail(f"{field} must be a non-empty string of at most {maximum} characters")
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in value):
        fail(f"{field} contains control characters")
    return value


def bounded_rate(value: object, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        fail(f"{field} must be a number")
    rate = float(value)
    if not math.isfinite(rate) or not 0 <= rate <= 1:
        fail(f"{field} must be between 0 and 1")
    return rate


def parse_utc_timestamp(value: object, field: str) -> datetime:
    text = bounded_string(value, field, maximum=40)
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        fail(f"{field} must be an ISO-8601 timestamp")
    if parsed.tzinfo is None:
        fail(f"{field} must include a timezone")
    return parsed.astimezone(timezone.utc)


def load_threshold_policy(path: Path, as_of: datetime) -> dict:
    document = load_json(path)
    expected = {
        "schemaVersion",
        "datasetID",
        "datasetKind",
        "thresholdApprovalID",
        "approvedAt",
        "minimumAccuracy",
        "minimumPrecision",
        "minimumRecall",
    }
    if not isinstance(document, dict) or set(document) != expected:
        fail("threshold policy contains unsupported or missing fields")
    if document["schemaVersion"] != SUPPORTED_THRESHOLD_SCHEMA_VERSION:
        fail("threshold policy schema version is unsupported")

    dataset_kind = document["datasetKind"]
    if dataset_kind not in {"synthetic_smoke", "human_labeled_gold"}:
        fail("threshold policy datasetKind is unsupported")
    approved_at = parse_utc_timestamp(document["approvedAt"], "approvedAt")
    if approved_at > as_of:
        fail("threshold policy approval time is in the future")

    dataset_id = bounded_string(document["datasetID"], "datasetID")
    approval_id = bounded_string(
        document["thresholdApprovalID"],
        "thresholdApprovalID",
    )
    if dataset_kind == "human_labeled_gold" and (
        dataset_id.lower().startswith(("replace", "synthetic"))
        or approval_id.lower().startswith(("replace", "synthetic"))
    ):
        fail("production threshold policy contains a placeholder or synthetic identity")

    return {
        "datasetID": dataset_id,
        "datasetKind": dataset_kind,
        "thresholdApprovalID": approval_id,
        "thresholds": {
            "minimumAccuracy": bounded_rate(
                document["minimumAccuracy"],
                "minimumAccuracy",
            ),
            "minimumPrecision": bounded_rate(
                document["minimumPrecision"],
                "minimumPrecision",
            ),
            "minimumRecall": bounded_rate(
                document["minimumRecall"],
                "minimumRecall",
            ),
        },
    }


def annotation_identity(annotation: dict, field: str) -> str:
    value = annotation.get("completed_by")
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        fail(f"{field}.completed_by must identify one annotator")
    return bounded_string(str(value), f"{field}.completed_by", maximum=80)


def result_choices(annotation: dict, annotation_field: str) -> dict[str, list[str]]:
    results = annotation.get("result")
    if not isinstance(results, list):
        fail(f"{annotation_field}.result must be an array")

    choices_by_name: dict[str, list[str]] = {}
    for index, result in enumerate(results):
        field = f"{annotation_field}.result[{index}]"
        if not isinstance(result, dict):
            fail(f"{field} must be an object")
        name = result.get("from_name")
        if name not in ALLOWED_RESULT_NAMES:
            fail(f"{field}.from_name is unsupported")
        if name in choices_by_name:
            fail(f"{annotation_field} contains duplicate {name} results")
        if result.get("to_name") != "case" or result.get("type") != "choices":
            fail(f"{field} does not match the reviewed Label Studio contract")
        value = result.get("value")
        choices = value.get("choices") if isinstance(value, dict) else None
        if not isinstance(choices, list) or not choices or not all(
            isinstance(choice, str) for choice in choices
        ):
            fail(f"{field}.value.choices must be a non-empty string array")
        choices_by_name[name] = choices
    return choices_by_name


def annotation_vote(annotation: object, annotation_field: str) -> tuple[str, bool]:
    if not isinstance(annotation, dict):
        fail(f"{annotation_field} must be an object")
    if annotation.get("was_cancelled") is not False:
        fail(f"{annotation_field} is cancelled or lacks an explicit cancellation state")
    if not isinstance(annotation.get("ground_truth"), bool):
        fail(f"{annotation_field}.ground_truth must be boolean")

    annotator = annotation_identity(annotation, annotation_field)
    choices = result_choices(annotation, annotation_field)
    support = choices.get("supports_assessment")
    confidence = choices.get("annotator_confidence")
    if support is None or len(support) != 1 or support[0] not in {
        "supports",
        "does_not_support",
    }:
        fail(f"{annotation_field} must provide one supported assessment label")
    if confidence is None or len(confidence) != 1 or confidence[0] not in ALLOWED_CONFIDENCE:
        fail(f"{annotation_field} must provide one bounded confidence label")

    failure_modes = choices.get("failure_modes", [])
    if len(failure_modes) != len(set(failure_modes)) or not set(failure_modes).issubset(
        ALLOWED_FAILURE_MODES
    ):
        fail(f"{annotation_field} contains unsupported or duplicate failure modes")
    supports = support[0] == "supports"
    if not supports and not failure_modes:
        fail(f"{annotation_field} must identify a failure mode when rejecting an assessment")
    return annotator, supports


def final_case_label(task: object, task_index: int, as_of: datetime) -> dict:
    task_field = f"tasks[{task_index}]"
    if not isinstance(task, dict):
        fail(f"{task_field} must be an object")
    data = task.get("data")
    if not isinstance(data, dict) or set(data) != EXPECTED_TASK_DATA_FIELDS:
        fail(f"{task_field}.data contains unsupported or missing fields")

    case_id = bounded_string(data["caseID"], f"{task_field}.data.caseID")
    category = bounded_string(data["category"], f"{task_field}.data.category", maximum=80)
    bounded_string(
        data["consentContractID"],
        f"{task_field}.data.consentContractID",
    )
    bounded_string(
        data["sanitizationVersion"],
        f"{task_field}.data.sanitizationVersion",
        maximum=80,
    )
    bounded_string(
        data["casePresentation"],
        f"{task_field}.data.casePresentation",
        maximum=20_000,
    )
    expires_at = parse_utc_timestamp(
        data["consentExpiresAt"],
        f"{task_field}.data.consentExpiresAt",
    )
    if expires_at <= as_of:
        fail(f"{task_field} consent has expired")

    annotations = task.get("annotations")
    if not isinstance(annotations, list):
        fail(f"{task_field}.annotations must be an array")

    votes: dict[str, bool] = {}
    adjudication: tuple[str, bool] | None = None
    for annotation_index, annotation in enumerate(annotations):
        annotation_field = f"{task_field}.annotations[{annotation_index}]"
        annotator, supports = annotation_vote(annotation, annotation_field)
        if annotation["ground_truth"]:
            if adjudication is not None:
                fail(f"{task_field} contains more than one adjudication")
            adjudication = (annotator, supports)
        else:
            if annotator in votes:
                fail(f"{task_field} contains duplicate votes from one annotator")
            votes[annotator] = supports

    if len(votes) < 2:
        fail(f"{task_field} requires at least two independent annotation votes")
    if adjudication is not None and adjudication[0] in votes:
        fail(f"{task_field} adjudicator must be independent from the annotators")
    vote_values = set(votes.values())
    if len(vote_values) > 1 and adjudication is None:
        fail(f"{task_field} disagreement requires an independent ground-truth adjudication")

    label = adjudication[1] if adjudication is not None else next(iter(vote_values))
    return {"id": case_id, "category": category, "label": label}


def convert(
    export_document: object,
    threshold_policy: dict,
    allow_synthetic: bool,
    as_of: datetime,
) -> tuple[dict, dict]:
    if not isinstance(export_document, list) or not export_document:
        fail("Label Studio export must be a non-empty task array")
    if threshold_policy["datasetKind"] == "synthetic_smoke" and not allow_synthetic:
        fail("synthetic data requires --allow-synthetic and never proves production quality")

    cases = [
        final_case_label(task, index, as_of)
        for index, task in enumerate(export_document)
    ]
    case_ids = [case["id"] for case in cases]
    if len(case_ids) != len(set(case_ids)):
        fail("Label Studio export contains duplicate case IDs")

    category_counts = Counter(case["category"] for case in cases)
    if threshold_policy["datasetKind"] == "human_labeled_gold":
        if len(cases) < PRODUCTION_MINIMUM_CASES:
            fail(f"production gold set requires at least {PRODUCTION_MINIMUM_CASES} cases")
        if min(category_counts.values()) < PRODUCTION_MINIMUM_CASES_PER_CATEGORY:
            fail(
                "production gold set requires at least "
                f"{PRODUCTION_MINIMUM_CASES_PER_CATEGORY} cases in every category"
            )

    output = {
        "schemaVersion": 1,
        "datasetID": threshold_policy["datasetID"],
        "datasetKind": threshold_policy["datasetKind"],
        "thresholds": threshold_policy["thresholds"],
        "cases": cases,
    }
    receipt = {
        "schemaVersion": 1,
        "datasetID": threshold_policy["datasetID"],
        "datasetKind": threshold_policy["datasetKind"],
        "thresholdApprovalID": threshold_policy["thresholdApprovalID"],
        "caseCount": len(cases),
        "categoryCounts": dict(sorted(category_counts.items())),
    }
    return output, receipt


def atomic_write_json(path: Path, document: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_path = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(document, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
    except Exception:
        try:
            os.unlink(temporary_path)
        except OSError:
            pass
        raise


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Export a consented Label Studio Completion Review set for OpenJudge."
    )
    parser.add_argument("--export", type=Path, required=True)
    parser.add_argument("--thresholds", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--allow-synthetic", action="store_true")
    parser.add_argument(
        "--as-of",
        help="ISO-8601 validation time; defaults to the current UTC time.",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    as_of = (
        parse_utc_timestamp(arguments.as_of, "asOf")
        if arguments.as_of
        else datetime.now(timezone.utc)
    )
    threshold_policy = load_threshold_policy(arguments.thresholds, as_of)
    output, receipt = convert(
        load_json(arguments.export),
        threshold_policy,
        arguments.allow_synthetic,
        as_of,
    )
    atomic_write_json(arguments.output, output)
    print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"Label Studio export failed: {error}", file=sys.stderr)
        sys.exit(2)
