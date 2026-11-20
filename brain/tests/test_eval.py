"""The golden set is well-formed and the scorer agrees with a model that answers perfectly."""
import asyncio
import io
import json

from app.config import load_config
from app.eval import EXAMPLE_CONFIG, load_cases, run, score
from conftest import FakeLLM


def perfect_extraction(case):
    exp = case["expect"]
    if not exp["actionable"]:
        return {"actionable": False, "actions": [], "confidence": 0.95, "reasoning_brief": "n/a"}
    actions = []
    for a in exp["actions"]:
        base = {k: None for k in ["list", "due_date", "due_time", "start", "end", "location", "calendar", "notes"]}
        base.update(type=a["type"], title=f"Do {a['title_any'][0]}", all_day=False, source_quote=case["text"])
        for k in ("list", "due_date", "due_time", "start", "end", "all_day"):
            if k in a:
                base[k] = a[k]
        actions.append(base)
    return {"actionable": True, "actions": actions, "confidence": 0.95, "reasoning_brief": "n/a"}


def test_golden_set_shape():
    cases = load_cases()
    assert len(cases) >= 30
    assert len({c["id"] for c in cases}) == len(cases)
    kinds = {a["type"] for c in cases for a in c["expect"].get("actions", [])}
    assert kinds == {"create_reminder", "create_event"}
    assert sum(not c["expect"]["actionable"] for c in cases) >= 8


def test_perfect_model_scores_100():
    cfg = load_config(EXAMPLE_CONFIG)
    cases = load_cases()
    by_text = {c["text"]: c for c in cases}
    llm = FakeLLM()

    def responder(prompt):
        for text, c in by_text.items():
            if text in prompt:
                return perfect_extraction(c)
        raise AssertionError("unknown prompt")

    llm.responder = responder
    buf = io.StringIO()
    pct = asyncio.run(run(cfg, llm, cases, out=buf))
    assert pct == 100, buf.getvalue()


def test_scorer_catches_wrong_date():
    cfg = load_config(EXAMPLE_CONFIG)
    case = next(c for c in load_cases() if c["id"] == "groceries-eggs-tomorrow")
    cmd = {"op": "create_reminder", "payload": {"title": "Pick up eggs", "list": "Groceries", "due": "2026-11-21",
                                                "due_time": None}}
    ok, problems = score(case, [cmd], cfg)
    assert not ok and "due_date" in problems[0]
