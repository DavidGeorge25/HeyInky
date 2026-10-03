"""Sends a packet (exact app request body) through the proxy, streams SSE, decodes actions
incrementally, validates them and retries once — mirroring ValidatingInkyModelClient."""
from __future__ import annotations

import json
import threading
import time

import requests

from . import validate


class ActionScanner:
    """Python twin of IncrementalActionScanner: yields action objects as they close."""

    def __init__(self):
        self.buf = []
        self.depth = 0
        self.in_str = False
        self.esc = False
        self.start = None

    def feed(self, chunk):
        out = []
        for ch in chunk:
            self.buf.append(ch)
            if self.in_str:
                if self.esc:
                    self.esc = False
                elif ch == "\\":
                    self.esc = True
                elif ch == '"':
                    self.in_str = False
                continue
            if ch == '"':
                self.in_str = True
            elif ch in "{[":
                self.depth += 1
                if ch == "{" and self.depth == 3:
                    self.start = len(self.buf) - 1
            elif ch in "}]":
                if ch == "}" and self.depth == 3 and self.start is not None:
                    out.append("".join(self.buf[self.start:]))
                    self.start = None
                self.depth -= 1
        return out


def clip(s, n):
    return s if len(s) <= n else s[: n - 1] + "…"


def describe(a):
    """Mirror of InkyPromptBuilder.describe (used in the retry correction)."""
    t = a["type"]
    f = validate.fmt
    if t == "highlight":
        return f'{a["color"]} highlight {f(a["region"])}' + (f' note "{a["note"]}"' if a.get("note") else "")
    if t == "circle":
        return f"circle {f(a['region'])}"
    if t == "star":
        return "star at (%.3f, %.3f)" % (a["point"]["x"], a["point"]["y"])
    if t == "label":
        return 'label "%s" at (%.3f, %.3f)' % (clip(a["text"], 60), a["anchor"]["x"], a["anchor"]["y"])
    if t == "fillText":
        return f'wrote "{clip(a["text"], 80)}" in {f(a["region"])}'
    if t == "insertMoleculeCard":
        return f"molecule card {a['smiles']}" + (f" ({clip(a['caption'], 60)})" if a.get("caption") else "")
    if t == "insertGraphCard":
        fns = ", ".join(fn["expression"] for fn in a["spec"]["functions"])
        title = f'"{clip(a["spec"]["title"], 60)}" ' if a["spec"].get("title") else ""
        return f"graph card {title}y = {clip(fns, 120)}"
    if t == "openSidebar":
        return f'explained in the sidebar: "{clip(a["markdown"].replace(chr(10), " "), 120)}"'
    if t == "say":
        return f'said "{clip(a["text"], 200)}"'
    return t


def with_correction(body, problems, applied):
    """Mirror of InkyPromptBuilder.questionText's correction block."""
    body = json.loads(json.dumps(body))
    content = body["input"][0]["content"]
    last = content[-1]
    text = last["text"] + "\n\nYour previous answer to this was rejected:"
    for p in problems:
        text += f"\n- {p}"
    if not applied:
        text += "\nReturn a corrected, complete answer."
    else:
        text += "\nThese actions from it were valid and are already applied; do not repeat them:"
        for a in applied:
            text += f"\n- {describe(a)}"
        text += "\nReturn only the corrected or missing actions."
    last["text"] = text
    return body


class StreamError(Exception):
    pass


class QuotaExhausted(Exception):
    """The account's daily request cap for this model is used up; stop the run."""


def stream_once(proxy, body, t0, timeline, timeout=120):
    """Yields ('action', dict) and finally ('completed', response, usage)."""
    res = requests.post(f"{proxy}/inky", json=body, stream=True, timeout=timeout,
                        headers={"accept": "text/event-stream"})
    if res.status_code != 200:
        raise StreamError(f"proxy {res.status_code}: {res.text[:300]}")
    scanner = ActionScanner()
    text = ""
    usage = None
    completed = False
    for raw in res.iter_lines(decode_unicode=True):
        if not raw or not raw.startswith("data:"):
            continue
        payload = raw[5:].strip()
        if not payload or payload == "[DONE]":
            continue
        ev = json.loads(payload)
        typ = ev.get("type")
        if typ == "response.output_text.delta":
            if "first_token" not in timeline:
                timeline["first_token"] = time.time() - t0
            text += ev["delta"]
            for obj in scanner.feed(ev["delta"]):
                try:
                    yield ("action", json.loads(obj))
                except json.JSONDecodeError:
                    pass
        elif typ == "response.completed":
            usage = ev.get("response", {}).get("usage")
            completed = True
        elif typ == "response.incomplete":
            reason = (ev.get("response", {}).get("incomplete_details") or {}).get("reason")
            raise StreamError(f"incomplete ({reason})")
        elif typ in ("response.failed", "error"):
            err = ev.get("error") or (ev.get("response") or {}).get("error") or {}
            raise StreamError(f"model failed: {err.get('code')}: {err.get('message') or json.dumps(ev)[:300]}")
    try:
        response = json.loads(text)
    except json.JSONDecodeError as e:
        raise StreamError(f"invalid JSON: {e}") from e
    if not completed and not text:
        raise StreamError("empty response")
    yield ("completed", response, usage)


def run_packet(proxy, body, n_marks, model=None, instructions=None, reasoning=None, max_retries=1):
    """Returns a result dict with forwarded actions, removals, timings and attempt info."""
    body = json.loads(json.dumps(body))
    if model:
        body["model"] = model
    if instructions is not None:
        body["instructions"] = instructions
    if reasoning:
        body["reasoning"] = {"effort": reasoning}
    t0 = time.time()
    timeline = {}
    forwarded, removals, all_problems, usages, raw_responses = [], [], [], [], []
    attempt = 0
    attempt_body = body
    while True:
        problems = []
        streamed = 0
        completed = None
        try:
            events = _with_rate_limit_backoff(lambda: list(stream_once(proxy, attempt_body, t0, timeline)))
            for ev in events:
                if ev[0] == "action":
                    streamed += 1
                    _accept(ev[1], attempt, forwarded, problems, timeline, t0)
                else:
                    completed, usage = ev[1], ev[2]
                    usages.append(usage)
                    raw_responses.append(completed)
                    for a in completed.get("actions", [])[streamed:]:
                        _accept(a, attempt, forwarded, problems, timeline, t0)
        except StreamError as e:
            msg = str(e)
            if msg.startswith("proxy") or msg.startswith("model failed"):
                return {"error": msg, "actions": forwarded, "remove": removals, "attempts": attempt + 1,
                        "problems": all_problems, "timeline": timeline, "total": time.time() - t0, "usage": usages}
            if "incomplete" in msg:
                problems.append(f"the answer was cut off ({msg}); answer with fewer, shorter actions")
            else:
                problems.append(f"the output was not valid JSON for the schema ({msg[:160]})")
        if completed is not None:
            problems += validate.response_problems(completed, n_marks)
            for raw in completed.get("removeAnnotations", []):
                rid = validate.resolve_id(raw, n_marks)
                if rid and rid not in removals:
                    removals.append(rid)
        all_problems.append(problems)
        if not problems or attempt >= max_retries:
            ok = not problems or bool(forwarded or removals)
            return {"error": None if ok else "; ".join(problems), "actions": forwarded, "remove": removals,
                    "attempts": attempt + 1, "problems": all_problems, "timeline": timeline,
                    "total": time.time() - t0, "usage": usages, "raw": raw_responses}
        attempt += 1
        attempt_body = with_correction(body, problems, forwarded)


_pace_lock = threading.Lock()
_last_start = [0.0]
MIN_INTERVAL = [0.0]


def _with_rate_limit_backoff(fn, tries=3):
    """Rate limits are an eval-harness concern, not model retries. Every rejected request
    still counts against the account's daily cap, so pace requests and retry sparingly."""
    for i in range(tries):
        with _pace_lock:
            wait = _last_start[0] + MIN_INTERVAL[0] - time.time()
            if wait > 0:
                time.sleep(wait)
            _last_start[0] = time.time()
        try:
            return fn()
        except StreamError as e:
            msg = str(e)
            if "per day" in msg:
                raise QuotaExhausted(msg) from e
            if ("rate_limit" not in msg and "proxy 429" not in msg) or i == tries - 1:
                raise
            time.sleep(20 * (i + 1))


def _accept(action, attempt, forwarded, problems, timeline, t0):
    fixed, problem = validate.check(action)
    if problem:
        problems.append(problem)
        return
    if attempt > 0 and fixed in forwarded:
        return
    forwarded.append(fixed)
    now = time.time() - t0
    timeline.setdefault("first_action", now)
    if fixed["type"] == "say":
        timeline.setdefault("first_say", now)
    elif fixed["type"] not in ("openSidebar",):
        timeline.setdefault("first_mark", now)
