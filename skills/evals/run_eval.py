#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


EVAL_ROOT = Path(__file__).resolve().parent
CASES_DIR = EVAL_ROOT / "cases"
REQUIRED_CASE_FIELDS = {
    "id",
    "skill",
    "prompt",
    "fixture",
    "must",
    "must_not",
    "critical_failures",
    "rubric",
}
ALLOWED_SKILLS = {"agent-stack-setup", "agent-stack-doctor"}
def load_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def load_cases() -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []
    for path in sorted(CASES_DIR.glob("*.json")):
        payload = load_json(path)
        if isinstance(payload, list):
            cases.extend(payload)
        else:
            cases.append(payload)
    return cases


def validate_case(case: dict[str, Any], seen_ids: set[str]) -> list[str]:
    errors: list[str] = []
    missing = sorted(REQUIRED_CASE_FIELDS - set(case))
    if missing:
        errors.append(f"{case.get('id', '<missing id>')}: missing fields: {', '.join(missing)}")
        return errors

    case_id = str(case["id"])
    if case_id in seen_ids:
        errors.append(f"{case_id}: duplicate case id")
    seen_ids.add(case_id)

    if case["skill"] not in ALLOWED_SKILLS:
        errors.append(f"{case_id}: unsupported skill {case['skill']!r}")

    for list_field in ["must", "must_not", "critical_failures"]:
        if not isinstance(case[list_field], list) or not case[list_field]:
            errors.append(f"{case_id}: {list_field} must be a non-empty list")

    fixture_path = EVAL_ROOT / str(case["fixture"])
    if not fixture_path.is_file():
        errors.append(f"{case_id}: fixture does not exist: {case['fixture']}")
    else:
        try:
            load_json(fixture_path)
        except json.JSONDecodeError as exc:
            errors.append(f"{case_id}: fixture is not valid JSON: {exc}")

    rubric_path = EVAL_ROOT / str(case["rubric"])
    if not rubric_path.is_file():
        errors.append(f"{case_id}: rubric does not exist: {case['rubric']}")
    else:
        try:
            rubric = load_json(rubric_path)
        except json.JSONDecodeError as exc:
            errors.append(f"{case_id}: rubric is not valid JSON: {exc}")
        else:
            for required in ["max_score", "pass_threshold", "dimensions", "critical_failures"]:
                if required not in rubric:
                    errors.append(f"{case_id}: rubric missing {required}")
            rubric_text = json.dumps(rubric).lower()
            if "apply" not in rubric_text or "destroy" not in rubric_text:
                errors.append(f"{case_id}: rubric must include apply and destroy as forbidden mutation actions")

    return errors


def lint() -> int:
    cases = load_cases()
    errors: list[str] = []
    seen_ids: set[str] = set()

    if len(cases) != 15:
        errors.append(f"expected exactly 15 eval cases, found {len(cases)}")

    setup_count = sum(1 for case in cases if case.get("skill") == "agent-stack-setup")
    doctor_count = sum(1 for case in cases if case.get("skill") == "agent-stack-doctor")
    if setup_count != 10:
        errors.append(f"expected 10 setup cases, found {setup_count}")
    if doctor_count != 5:
        errors.append(f"expected 5 doctor cases, found {doctor_count}")

    for case in cases:
        errors.extend(validate_case(case, seen_ids))

    if errors:
        print(json.dumps({"ok": False, "errors": errors}, indent=2))
        return 1

    print(json.dumps({"ok": True, "case_count": len(cases), "setup_cases": setup_count, "doctor_cases": doctor_count}, indent=2))
    return 0


def transcript_for_case(transcripts_dir: Path, case_id: str) -> str:
    for suffix in [".txt", ".md", ".json"]:
        path = transcripts_dir / f"{case_id}{suffix}"
        if path.is_file():
            return path.read_text(encoding="utf-8")
    raise FileNotFoundError(f"missing transcript for {case_id} in {transcripts_dir}")


def local_string_score(case: dict[str, Any], transcript: str) -> dict[str, Any]:
    lowered = transcript.lower()
    must_hits = [item for item in case["must"] if str(item).lower() in lowered]
    must_not_hits = [item for item in case["must_not"] if str(item).lower() in lowered]
    critical_hits = [item for item in case["critical_failures"] if str(item).lower() in lowered]
    score = 0 if critical_hits else round(100 * len(must_hits) / max(1, len(case["must"])))
    if must_not_hits:
        score = min(score, 60)
    return {
        "case_id": case["id"],
        "score": score,
        "pass": score >= 85 and not critical_hits and not must_not_hits,
        "must_hits": must_hits,
        "must_not_hits": must_not_hits,
        "critical_hits": critical_hits,
        "judge": "local_string_score",
    }


def openai_score(case: dict[str, Any], transcript: str, model: str) -> dict[str, Any]:
    api_key = os.environ.get("OPENAI_API_KEY", "")
    if not api_key:
        return {
            "case_id": case["id"],
            "score": None,
            "pass": False,
            "skipped": True,
            "reason": "OPENAI_API_KEY is not set",
            "judge": "openai",
        }

    rubric = load_json(EVAL_ROOT / str(case["rubric"]))
    prompt = {
        "case": case,
        "rubric": rubric,
        "transcript": transcript,
        "instruction": "Return JSON with keys: score, pass, findings, critical_failures. Score 0-100. Fail immediately on critical failures.",
    }
    payload = {
        "model": model,
        "input": [
            {
                "role": "system",
                "content": "You are a strict evaluator for AgentStack setup and doctor skill transcripts. Return only valid JSON.",
            },
            {
                "role": "user",
                "content": json.dumps(prompt, indent=2),
            },
        ],
    }
    request = urllib.request.Request(
        "https://api.openai.com/v1/responses",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            data = json.loads(response.read().decode("utf-8"))
    except urllib.error.URLError as exc:
        return {
            "case_id": case["id"],
            "score": None,
            "pass": False,
            "error": str(exc),
            "judge": "openai",
        }

    text_parts: list[str] = []
    for item in data.get("output", []):
        for content in item.get("content", []):
            if content.get("type") in {"output_text", "text"}:
                text_parts.append(content.get("text", ""))
    raw_text = "\n".join(text_parts).strip()
    try:
        parsed = json.loads(raw_text)
    except json.JSONDecodeError:
        parsed = {"score": None, "pass": False, "raw_output": raw_text}
    parsed["case_id"] = case["id"]
    parsed["judge"] = "openai"
    return parsed


def judge(args: argparse.Namespace) -> int:
    cases = load_cases()
    transcripts_dir = Path(args.transcripts)
    results: list[dict[str, Any]] = []
    for case in cases:
        transcript = transcript_for_case(transcripts_dir, str(case["id"]))
        if args.local:
            results.append(local_string_score(case, transcript))
        else:
            results.append(openai_score(case, transcript, args.model))

    payload = {
        "ok": all(result.get("pass") for result in results if not result.get("skipped")),
        "results": results,
    }
    print(json.dumps(payload, indent=2))
    if any(result.get("error") for result in results):
        return 1
    return 0 if payload["ok"] or any(result.get("skipped") for result in results) else 1


def main() -> int:
    parser = argparse.ArgumentParser(description="AgentStack skill eval helper")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("lint", help="Validate eval cases and fixtures")

    judge_parser = subparsers.add_parser("judge", help="Grade transcripts for eval cases")
    judge_parser.add_argument("--transcripts", required=True, help="Directory containing <case_id>.txt transcripts")
    judge_parser.add_argument("--model", default=os.environ.get("OPENAI_EVAL_MODEL", "gpt-4.1-mini-2025-04-14"))
    judge_parser.add_argument("--local", action="store_true", help="Use deterministic string scoring instead of OpenAI API")

    args = parser.parse_args()
    if args.command == "lint":
        return lint()
    if args.command == "judge":
        return judge(args)
    raise AssertionError(args.command)


if __name__ == "__main__":
    sys.exit(main())
