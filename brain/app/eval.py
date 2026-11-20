"""Golden-set evaluation against the live model:  `make eval`  (or `python -m app.eval`).

Each case pins a fixed "now"; we run gate → extraction → planner and compare the planned
commands with the expectation. Fields absent from an expectation are not checked.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any

from .config import Config, load_config
from .extract import LLMClient, LLMError, PromptTemplate, VLLMClient, extract
from .gate import gate
from .planner import plan
from .schemas import Event

DEFAULT_FIXTURES = Path(__file__).parent.parent / "tests" / "fixtures" / "messages.jsonl"
EXAMPLE_CONFIG = Path(__file__).parent.parent.parent / "config.example.yaml"


def load_cases(path: Path = DEFAULT_FIXTURES) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def case_event(case: dict[str, Any]) -> Event:
    return Event(
        event_id=f"eval:{case['id']}", source=case.get("source", "imessage"), sender_handle="",
        sender_label=case.get("sender", "Wife"), received_at=datetime.fromisoformat(case["now"]),
        text=case["text"], recent_context=case.get("context", []), subject=case.get("subject"),
    )


def _local(iso: str, cfg: Config, date_only: bool) -> str:
    dt = datetime.fromisoformat(iso).astimezone(cfg.tz)
    return dt.date().isoformat() if date_only else dt.strftime("%Y-%m-%dT%H:%M")


def _cmd_view(cmd: dict[str, Any], cfg: Config) -> dict[str, Any]:
    p = cmd["payload"]
    if cmd["op"] == "create_reminder":
        return {"type": "create_reminder", "title": p["title"], "due_date": p["due"],
                "due_time": p["due_time"]}
    return {"type": "create_event", "title": p["title"], "all_day": p["all_day"],
            "start": _local(p["start"], cfg, p["all_day"]), "end": _local(p["end"], cfg, p["all_day"])}


def _matches(exp: dict[str, Any], got: dict[str, Any]) -> list[str]:
    problems = []
    if exp["type"] != got["type"]:
        return [f"type {got['type']} != {exp['type']}"]
    if not any(t.lower() in got["title"].lower() for t in exp["title_any"]):
        problems.append(f"title {got['title']!r} lacks any of {exp['title_any']}")
    for k in ("due_date", "due_time", "start", "end", "all_day"):
        if k in exp and got.get(k) != exp[k]:
            problems.append(f"{k} {got.get(k)!r} != {exp[k]!r}")
    return problems


def score(case: dict[str, Any], commands: list[dict[str, Any]], cfg: Config) -> tuple[bool, list[str]]:
    exp = case["expect"]
    got = [_cmd_view(c, cfg) for c in commands]
    if not exp["actionable"]:
        return (not got), ([f"expected nothing, got {[g['title'] for g in got]}"] if got else [])
    want = exp["actions"]
    if len(got) != len(want):
        return False, [f"expected {len(want)} actions, got {len(got)}: {[g['title'] for g in got]}"]
    remaining = list(got)
    problems: list[str] = []
    for w in want:
        best = None
        for g in remaining:
            p = _matches(w, g)
            if best is None or len(p) < len(best[1]):
                best = (g, p)
        assert best is not None
        if best[1]:
            problems.extend(best[1])
        remaining.remove(best[0])
    return not problems, problems


async def run_case(cfg: Config, llm: LLMClient, tpl: PromptTemplate, case: dict[str, Any]) -> dict[str, Any]:
    ev = case_event(case)
    now = ev.received_at
    out: dict[str, Any] = {"id": case["id"], "text": case["text"]}
    reason = gate(cfg, ev)
    if reason:
        out.update(commands=[], gate=reason, ms=0)
    else:
        try:
            res = await extract(cfg, llm, tpl, ev, now)
        except LLMError as e:
            out.update(passed=False, problems=[f"LLM error: {e}"], raw=getattr(e, "raw", None))
            return out
        p = plan(cfg, ev, res.extraction, now)
        out.update(commands=[c.model_dump() for c in p.commands], ms=res.duration_ms, raw=res.raw,
                   confidence=res.extraction.confidence, review=p.review_reasons)
    out["passed"], out["problems"] = score(case, out["commands"], cfg)
    return out


async def run(cfg: Config, llm: LLMClient, cases: list[dict[str, Any]], *, verbose: bool = False,
              out=sys.stdout) -> float:
    tpl = PromptTemplate.load()
    print(f"prompt {tpl.version} · model {cfg.llm.model} @ {cfg.llm.base_url} · {len(cases)} cases\n", file=out)
    passed = 0
    t0 = time.perf_counter()
    for case in cases:
        r = await run_case(cfg, llm, tpl, case)
        passed += r["passed"]
        mark = "PASS" if r["passed"] else "FAIL"
        extra = f"  [{r.get('ms', 0)} ms" + (f", conf {r['confidence']:.2f}" if "confidence" in r else "") + "]"
        if r.get("review"):
            extra += " (would need review)"
        print(f"{mark}  {r['id']:<28}{extra}", file=out)
        if not r["passed"] or verbose:
            print(f"      text: {r['text']!r}", file=out)
            for p in r.get("problems", []):
                print(f"      - {p}", file=out)
            for c in r.get("commands", []):
                view = _cmd_view(c, cfg)
                print(f"      got: {json.dumps(view, ensure_ascii=False)}", file=out)
            if not r["passed"] and r.get("raw") and verbose:
                print(f"      raw: {r['raw']}", file=out)
    pct = 100 * passed / len(cases) if cases else 0
    print(f"\n{passed}/{len(cases)} passed ({pct:.0f}%) in {time.perf_counter() - t0:.1f}s", file=out)
    return pct


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--config", default=None, help="config.yaml (default: $HA_CONFIG or ../config.yaml)")
    ap.add_argument("--fixtures", default=str(DEFAULT_FIXTURES))
    ap.add_argument("--only", action="append", help="case id (repeatable)")
    ap.add_argument("--min-pct", type=float, default=90.0)
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    cfg_path = args.config
    if not cfg_path:
        import os
        cfg_path = os.environ.get("HA_CONFIG") or str(Path(__file__).parent.parent.parent / "config.yaml")
    # The golden set's expectations assume the example config's rules (list names, routes,
    # timezone); only the LLM connection comes from your config.
    cfg = load_config(EXAMPLE_CONFIG)
    cfg.llm = load_config(cfg_path).llm
    cases = load_cases(Path(args.fixtures))
    if args.only:
        cases = [c for c in cases if c["id"] in args.only]
    llm = VLLMClient(cfg.llm)
    pct = asyncio.run(run(cfg, llm, cases, verbose=args.verbose))
    sys.exit(0 if pct >= args.min_pct else 1)


if __name__ == "__main__":
    main()
