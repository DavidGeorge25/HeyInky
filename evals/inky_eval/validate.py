"""Python mirror of App/Modules/AICore/InkyResponseValidator.swift (keep them in sync;
both are tested against /shared/fixtures/validation)."""
from __future__ import annotations

import math
import re

EDGE_TOLERANCE = 0.02
MIN_REGION_SIDE = 0.004
MAX_MARK_AREA = 0.85

MATH_MEMBERS = {
    "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh", "asinh", "acosh", "atanh",
    "exp", "expm1", "log", "log10", "log2", "log1p", "sqrt", "cbrt", "abs", "pow", "floor", "ceil", "round",
    "trunc", "sign", "min", "max", "hypot", "PI", "E", "LN2", "LN10", "SQRT2",
}


def fmt(r):
    return "[%.3f, %.3f, %.3f, %.3f]" % (r["x"], r["y"], r["width"], r["height"])


def check_region(r, what):
    vals = [r["x"], r["y"], r["width"], r["height"]]
    if any(not isinstance(v, (int, float)) or not math.isfinite(v) for v in vals):
        return None, f"{what} region has non-numeric values"
    if r["width"] < MIN_REGION_SIDE or r["height"] < MIN_REGION_SIDE:
        return None, f"{what} region {fmt(r)} is empty; give the target's real width and height"
    if r["x"] < -EDGE_TOLERANCE or r["y"] < -EDGE_TOLERANCE or r["x"] + r["width"] > 1 + EDGE_TOLERANCE or r["y"] + r["height"] > 1 + EDGE_TOLERANCE:
        return None, f"{what} region {fmt(r)} extends outside the page; x+width and y+height must be ≤ 1"
    x = min(max(r["x"], 0), 1)
    y = min(max(r["y"], 0), 1)
    return {"x": x, "y": y, "width": min(max(r["width"], 0), 1 - x), "height": min(max(r["height"], 0), 1 - y)}, None


def balanced(s, o, c):
    d = 0
    for ch in s:
        if ch == o:
            d += 1
        elif ch == c:
            d -= 1
            if d < 0:
                return False
    return d == 0


SMILES_OK = re.compile(r"^[A-Za-z0-9\[\]()=#$:/\\@+\-.%*~]+$")


def smiles_problem(s):
    if not s:
        return "empty"
    if any(ch.isspace() for ch in s):
        return "contains spaces"
    if not SMILES_OK.match(s):
        return "unexpected characters"
    if not balanced(s, "(", ")"):
        return "unbalanced parentheses"
    if not balanced(s, "[", "]"):
        return "unbalanced brackets"
    if not any(ch.isalpha() for ch in s):
        return "no atoms"
    open_ = set()
    in_br = False
    i = 0
    while i < len(s):
        ch = s[i]
        i += 1
        if ch == "[":
            in_br = True
            continue
        if ch == "]":
            in_br = False
            continue
        if in_br:
            continue
        label = None
        if ch == "%":
            label = "%" + s[i:i + 2]
            i += 2
        elif ch.isdigit():
            label = ch
        if label:
            open_.symmetric_difference_update({label})
    if open_:
        return f"unclosed ring bond(s) {sorted(open_)}"
    return None


def smarts_problem(s):
    s = s.strip()
    if not s:
        return "empty"
    if not balanced(s, "(", ")"):
        return "unbalanced parentheses"
    if not balanced(s, "[", "]"):
        return "unbalanced brackets"
    return None


EXPR_OK = re.compile(r"^[A-Za-z0-9_+\-*/%().,<>=?:!&| ]+$")
TOKEN = re.compile(r"(\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?)|([A-Za-z_][A-Za-z0-9_]*)")


def expression_problem(e, params):
    e = e.strip()
    if not e:
        return "empty"
    if "^" in e:
        return "use Math.pow(a, b) or a**b instead of ^"
    if not EXPR_OK.match(e):
        return "only JavaScript math is allowed (no Unicode symbols like ² or π)"
    if not balanced(e, "(", ")"):
        return "unbalanced parentheses"
    i = 0
    while i < len(e):
        m = TOKEN.match(e, i)
        if not m:
            i += 1
            continue
        if m.group(1):
            i = m.end()
            continue
        name = m.group(2)
        j = m.end()
        if name == "Math":
            if j >= len(e) or e[j] != ".":
                return "Math must be followed by a member"
            mm = re.match(r"[A-Za-z0-9]*", e[j + 1:])
            member = mm.group(0)
            if member not in MATH_MEMBERS:
                return f"Math.{member} is not supported"
            i = j + 1 + len(member)
            continue
        if name != "x" and name not in params:
            return f'unknown name "{name}" (use x, the param names, and Math.*; declare constants as params)'
        i = j
    return None


def graph_problem(spec):
    nums = [spec["xMin"], spec["xMax"], spec["yMin"], spec["yMax"]]
    if any(not math.isfinite(v) for v in nums):
        return "axis ranges must be numbers"
    if spec["xMin"] >= spec["xMax"]:
        return "xMin must be less than xMax"
    if spec["yMin"] >= spec["yMax"]:
        return "yMin must be less than yMax"
    if not spec["functions"]:
        return "add at least one function"
    names = {p["name"] for p in spec["params"]}
    for p in spec["params"]:
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", p["name"]):
            return f'param name "{p["name"]}" must be an identifier'
        if p["name"] == "x":
            return '"x" is the variable, not a param'
        if not (p["min"] <= p["value"] <= p["max"]) or p["min"] == p["max"]:
            return f'param {p["name"]} needs min < max and min ≤ value ≤ max'
    for f in spec["functions"]:
        prob = expression_problem(f["expression"], names)
        if prob:
            return f'expression "{f["expression"]}": {prob}'
    return None


def check(action):
    """Returns (fixed_action, None) or (None, problem)."""
    a = dict(action)
    t = a["type"]
    if t in ("highlight", "circle", "fillText"):
        r, p = check_region(a["region"], t)
        if p:
            return None, p
        a["region"] = r
        if t in ("highlight", "circle") and r["width"] * r["height"] > MAX_MARK_AREA:
            return None, f"{t} covers almost the whole page; mark only the target"
        if t == "highlight" and a.get("note") and len(a["note"]) > 60:
            return None, "highlight note is too long (max ~4 words)"
        if t == "fillText" and not a["text"].strip():
            return None, "fillText text is empty"
        return a, None
    if t == "star":
        return a, None
    if t == "label":
        text = a["text"].strip()
        if not text:
            return None, "label text is empty"
        if len(text) > 80:
            return None, "label text is too long (use 1–6 words; put explanations in openSidebar)"
        return a, None
    if t == "insertMoleculeCard":
        a["smiles"] = a["smiles"].strip()
        p = smiles_problem(a["smiles"])
        if p:
            return None, f'insertMoleculeCard smiles "{a["smiles"]}" is not valid SMILES: {p}'
        for g in a["highlightGroups"] + a["starGroups"]:
            p = smarts_problem(g)
            if p:
                return None, f'insertMoleculeCard group "{g}" is not valid SMARTS: {p}'
        r, p = check_region(a["near"], "insertMoleculeCard near")
        if p:
            return None, p
        a["near"] = r
        return a, None
    if t == "insertGraphCard":
        p = graph_problem(a["spec"])
        if p:
            return None, f"insertGraphCard: {p}"
        r, p = check_region(a["near"], "insertGraphCard near")
        if p:
            return None, p
        a["near"] = r
        return a, None
    if t == "openSidebar":
        if not a["markdown"].strip():
            return None, "openSidebar markdown is empty"
        return a, None
    if t == "say":
        text = a["text"].strip()
        if not text:
            return None, "say text is empty"
        if len(text) > 400:
            return None, "say is too long; keep it to one sentence and put longer explanations in openSidebar"
        return a, None
    return None, f"unknown action type {t}"


def resolve_id(raw, n_marks):
    s = raw.strip().lower()
    if s.startswith("m"):
        s = s[1:]
    try:
        k = int(s)
    except ValueError:
        return None
    return f"m{k}" if 1 <= k <= n_marks else None


def response_problems(response, n_marks):
    problems = []
    if not response.get("actions") and not response.get("removeAnnotations"):
        problems.append("the answer has no actions; include at least a say")
    unknown = [r for r in response.get("removeAnnotations", []) if resolve_id(r, n_marks) is None]
    if unknown:
        known = ", ".join(f"m{i + 1}" for i in range(n_marks)) or "none"
        problems.append(f"removeAnnotations has unknown ids {unknown} (existing marks: {known})")
    return problems
