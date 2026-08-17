#!/usr/bin/env python3

import argparse
import asyncio
import json
import math
import sys
from pathlib import Path

import openjudge
from openjudge.analyzer.validation import AccuracyAnalyzer, PrecisionAnalyzer, RecallAnalyzer
from openjudge.graders.function_grader import FunctionGrader
from openjudge.graders.schema import GraderScore
from openjudge.runner.grading_runner import GradingRunner


EXPECTED_OPENJUDGE_VERSION = "0.2.0"
SUPPORTED_SCHEMA_VERSION = 1
PRODUCTION_MINIMUM_CASES = 100
PRODUCTION_MINIMUM_CASES_PER_CATEGORY = 20


def fail(message: str) -> None:
    raise ValueError(message)


def load_object(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        fail(f"{path.name} must contain a JSON object")
    return value


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


def validate_dataset(document: dict, allow_synthetic: bool) -> tuple[list[dict], dict, str]:
    if set(document) != {"schemaVersion", "datasetID", "datasetKind", "thresholds", "cases"}:
        fail("dataset contains unsupported or missing top-level fields")
    if document["schemaVersion"] != SUPPORTED_SCHEMA_VERSION:
        fail("dataset schema version is unsupported")
    dataset_id = bounded_string(document["datasetID"], "datasetID")
    dataset_kind = document["datasetKind"]
    if dataset_kind not in {"synthetic_smoke", "human_labeled_gold"}:
        fail("datasetKind is unsupported")
    if dataset_kind == "synthetic_smoke" and not allow_synthetic:
        fail("synthetic data requires --allow-synthetic and never proves production quality")

    thresholds = document["thresholds"]
    if not isinstance(thresholds, dict) or set(thresholds) != {
        "minimumAccuracy",
        "minimumPrecision",
        "minimumRecall",
    }:
        fail("thresholds must define only accuracy, precision, and recall minimums")
    normalized_thresholds = {
        "accuracy": bounded_rate(thresholds["minimumAccuracy"], "minimumAccuracy"),
        "precision": bounded_rate(thresholds["minimumPrecision"], "minimumPrecision"),
        "recall": bounded_rate(thresholds["minimumRecall"], "minimumRecall"),
    }

    cases = document["cases"]
    if not isinstance(cases, list) or not cases:
        fail("dataset must contain at least one case")
    normalized_cases: list[dict] = []
    seen_ids: set[str] = set()
    category_counts: dict[str, int] = {}
    for index, case in enumerate(cases):
        if not isinstance(case, dict) or set(case) != {"id", "category", "label"}:
            fail(f"case {index} contains unsupported or missing fields")
        case_id = bounded_string(case["id"], f"cases[{index}].id")
        category = bounded_string(case["category"], f"cases[{index}].category", maximum=80)
        if case_id in seen_ids:
            fail(f"duplicate case id: {case_id}")
        if not isinstance(case["label"], bool):
            fail(f"cases[{index}].label must be boolean")
        seen_ids.add(case_id)
        category_counts[category] = category_counts.get(category, 0) + 1
        normalized_cases.append({"case_id": case_id, "category": category, "label": int(case["label"])})

    if dataset_kind == "human_labeled_gold":
        if len(normalized_cases) < PRODUCTION_MINIMUM_CASES:
            fail(f"production gold set requires at least {PRODUCTION_MINIMUM_CASES} cases")
        if min(category_counts.values()) < PRODUCTION_MINIMUM_CASES_PER_CATEGORY:
            fail(
                "production gold set requires at least "
                f"{PRODUCTION_MINIMUM_CASES_PER_CATEGORY} cases in every category"
            )

    return normalized_cases, normalized_thresholds, dataset_id


def validate_predictions(document: dict, dataset_id: str, case_ids: set[str]) -> dict[str, bool]:
    if set(document) != {
        "schemaVersion",
        "datasetID",
        "evaluatorID",
        "evaluatorVersion",
        "predictions",
    }:
        fail("predictions contain unsupported or missing top-level fields")
    if document["schemaVersion"] != SUPPORTED_SCHEMA_VERSION or document["datasetID"] != dataset_id:
        fail("prediction schema or dataset identity does not match")
    bounded_string(document["evaluatorID"], "evaluatorID")
    bounded_string(document["evaluatorVersion"], "evaluatorVersion", maximum=80)
    predictions = document["predictions"]
    if not isinstance(predictions, list):
        fail("predictions must be an array")

    normalized: dict[str, bool] = {}
    for index, prediction in enumerate(predictions):
        if not isinstance(prediction, dict) or set(prediction) != {"caseID", "supportsAssessment"}:
            fail(f"prediction {index} contains unsupported or missing fields")
        case_id = bounded_string(prediction["caseID"], f"predictions[{index}].caseID")
        if case_id in normalized:
            fail(f"duplicate prediction case id: {case_id}")
        if case_id not in case_ids:
            fail(f"prediction references an unknown case: {case_id}")
        if not isinstance(prediction["supportsAssessment"], bool):
            fail(f"predictions[{index}].supportsAssessment must be boolean")
        normalized[case_id] = prediction["supportsAssessment"]
    if set(normalized) != case_ids:
        fail("predictions must cover every gold-set case exactly once")
    return normalized


async def evaluate(cases: list[dict], predictions: dict[str, bool]) -> dict[str, float]:
    async def candidate_label(case_id: str, **_: object) -> GraderScore:
        return GraderScore(
            name="completion_review_support",
            score=1.0 if predictions[case_id] else 0.0,
            reason="Bounded candidate label supplied to the OpenJudge validation runner.",
        )

    runner = GradingRunner(
        grader_configs={
            "completion_review_support": FunctionGrader(
                func=candidate_label,
                name="completion_review_support",
            )
        },
        max_concurrency=1,
        show_progress=False,
    )
    results = await runner.arun(cases)
    grader_results = results["completion_review_support"]
    return {
        "accuracy": AccuracyAnalyzer().analyze(cases, grader_results).accuracy,
        "precision": PrecisionAnalyzer(prediction_threshold=0.5).analyze(cases, grader_results).precision,
        "recall": RecallAnalyzer(prediction_threshold=0.5).analyze(cases, grader_results).recall,
    }


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate bounded Completion Review labels with OpenJudge.")
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--predictions", type=Path, required=True)
    parser.add_argument("--allow-synthetic", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if openjudge.__version__ != EXPECTED_OPENJUDGE_VERSION:
        fail(
            f"unexpected OpenJudge package version {openjudge.__version__}; "
            f"expected {EXPECTED_OPENJUDGE_VERSION} from the pinned v0.2.2 commit"
        )
    dataset_document = load_object(arguments.dataset)
    cases, thresholds, dataset_id = validate_dataset(dataset_document, arguments.allow_synthetic)
    predictions = validate_predictions(
        load_object(arguments.predictions),
        dataset_id,
        {case["case_id"] for case in cases},
    )
    metrics = asyncio.run(evaluate(cases, predictions))
    passed = all(metrics[name] >= threshold for name, threshold in thresholds.items())
    result = {
        "schemaVersion": 1,
        "datasetID": dataset_id,
        "datasetKind": dataset_document["datasetKind"],
        "caseCount": len(cases),
        "openJudgePackageVersion": openjudge.__version__,
        "metrics": metrics,
        "thresholds": thresholds,
        "passed": passed,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if passed else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"OpenJudge evaluation failed: {error}", file=sys.stderr)
        sys.exit(2)
