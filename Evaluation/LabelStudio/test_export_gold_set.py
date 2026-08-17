from __future__ import annotations

import copy
import importlib.util
import unittest
from datetime import datetime, timezone
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("export_gold_set.py")
SPEC = importlib.util.spec_from_file_location("label_studio_export", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
EXPORTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXPORTER)


AS_OF = datetime(2026, 8, 16, 12, 0, tzinfo=timezone.utc)


def choice(name: str, values: list[str]) -> dict:
    return {
        "from_name": name,
        "to_name": "case",
        "type": "choices",
        "value": {"choices": values},
    }


def annotation(
    annotator: int,
    supports: bool,
    *,
    ground_truth: bool = False,
    failure_modes: list[str] | None = None,
) -> dict:
    results = [
        choice(
            "supports_assessment",
            ["supports" if supports else "does_not_support"],
        )
    ]
    if not supports:
        results.append(choice("failure_modes", failure_modes or ["missing_evidence"]))
    results.append(choice("annotator_confidence", ["high"]))
    return {
        "completed_by": annotator,
        "was_cancelled": False,
        "ground_truth": ground_truth,
        "result": results,
    }


def task(case_id: str = "case-1") -> dict:
    return {
        "data": {
            "caseID": case_id,
            "category": "evidence-boundary",
            "consentContractID": "consent-v1",
            "consentExpiresAt": "2026-08-17T12:00:00Z",
            "sanitizationVersion": "sanitizer-v1",
            "casePresentation": "Bounded and consented evaluation case.",
        },
        "annotations": [annotation(1, True), annotation(2, True)],
    }


def thresholds(kind: str = "synthetic_smoke") -> dict:
    return {
        "datasetID": "dataset-v1",
        "datasetKind": kind,
        "thresholdApprovalID": "approval-v1",
        "thresholds": {
            "minimumAccuracy": 0.8,
            "minimumPrecision": 0.8,
            "minimumRecall": 0.8,
        },
    }


class LabelStudioGoldSetExportTests(unittest.TestCase):
    def test_unanimous_votes_export_only_bounded_openjudge_fields(self) -> None:
        document, receipt = EXPORTER.convert([task()], thresholds(), True, AS_OF)

        self.assertEqual(
            document["cases"],
            [{"id": "case-1", "category": "evidence-boundary", "label": True}],
        )
        serialized = str(document)
        self.assertNotIn("casePresentation", serialized)
        self.assertNotIn("consentContractID", serialized)
        self.assertNotIn("completed_by", serialized)
        self.assertEqual(receipt["thresholdApprovalID"], "approval-v1")

    def test_disagreement_requires_independent_adjudication(self) -> None:
        disputed = task()
        disputed["annotations"] = [annotation(1, True), annotation(2, False)]

        with self.assertRaisesRegex(ValueError, "disagreement requires"):
            EXPORTER.convert([disputed], thresholds(), True, AS_OF)

        disputed["annotations"].append(annotation(3, False, ground_truth=True))
        document, _ = EXPORTER.convert([disputed], thresholds(), True, AS_OF)
        self.assertFalse(document["cases"][0]["label"])

    def test_adjudicator_must_not_be_one_of_the_voters(self) -> None:
        disputed = task()
        disputed["annotations"] = [
            annotation(1, True),
            annotation(2, False),
            annotation(1, False, ground_truth=True),
        ]

        with self.assertRaisesRegex(ValueError, "adjudicator must be independent"):
            EXPORTER.convert([disputed], thresholds(), True, AS_OF)

    def test_duplicate_voter_is_rejected(self) -> None:
        duplicate = task()
        duplicate["annotations"] = [annotation(1, True), annotation(1, True)]

        with self.assertRaisesRegex(ValueError, "duplicate votes"):
            EXPORTER.convert([duplicate], thresholds(), True, AS_OF)

    def test_expired_consent_is_rejected(self) -> None:
        expired = task()
        expired["data"]["consentExpiresAt"] = "2026-08-16T11:59:59Z"

        with self.assertRaisesRegex(ValueError, "consent has expired"):
            EXPORTER.convert([expired], thresholds(), True, AS_OF)

    def test_production_dataset_minimum_is_enforced(self) -> None:
        with self.assertRaisesRegex(ValueError, "at least 100 cases"):
            EXPORTER.convert([task()], thresholds("human_labeled_gold"), False, AS_OF)

    def test_production_threshold_policy_rejects_template_identities(self) -> None:
        policy = {
            "schemaVersion": 1,
            "datasetID": "replace-with-consented-dataset-id",
            "datasetKind": "human_labeled_gold",
            "thresholdApprovalID": "approval-v1",
            "approvedAt": "2026-08-16T11:00:00Z",
            "minimumAccuracy": 0.8,
            "minimumPrecision": 0.8,
            "minimumRecall": 0.8,
        }

        with self.subTest("dataset placeholder"):
            with self.assertRaisesRegex(ValueError, "placeholder or synthetic identity"):
                self._load_threshold_policy(policy)

        policy["datasetID"] = "production-dataset-v1"
        policy["thresholdApprovalID"] = "synthetic-not-approved"
        with self.subTest("synthetic approval"):
            with self.assertRaisesRegex(ValueError, "placeholder or synthetic identity"):
                self._load_threshold_policy(policy)

    def test_rejection_requires_a_bounded_failure_mode(self) -> None:
        invalid = task()
        invalid_annotation = annotation(2, False)
        invalid_annotation["result"] = [
            result
            for result in invalid_annotation["result"]
            if result["from_name"] != "failure_modes"
        ]
        invalid["annotations"] = [annotation(1, False), invalid_annotation]

        with self.assertRaisesRegex(ValueError, "must identify a failure mode"):
            EXPORTER.convert([invalid], thresholds(), True, AS_OF)

    def test_unknown_task_data_is_rejected(self) -> None:
        invalid = copy.deepcopy(task())
        invalid["data"]["transcript"] = "must not be accepted"

        with self.assertRaisesRegex(ValueError, "unsupported or missing fields"):
            EXPORTER.convert([invalid], thresholds(), True, AS_OF)

    def _load_threshold_policy(self, policy: dict) -> dict:
        import json
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "thresholds.json"
            path.write_text(json.dumps(policy), encoding="utf-8")
            return EXPORTER.load_threshold_policy(path, AS_OF)


if __name__ == "__main__":
    unittest.main()
