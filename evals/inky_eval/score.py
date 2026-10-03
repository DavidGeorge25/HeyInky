"""Scores one eval case result against its expectations."""
from __future__ import annotations

import math
import re
import unicodedata

PAGE_ACTIONS = {"highlight", "circle", "star", "label", "fillText", "insertMoleculeCard", "insertGraphCard"}


def box_of(r):
    return [r["x"], r["y"], r["width"], r["height"]]


def iou(a, b):
    ix = max(0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]))
    iy = max(0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
    inter = ix * iy
    union = a[2] * a[3] + b[2] * b[3] - inter
    return inter / union if union > 0 else 0.0


def inside(p, b):
    return b[0] <= p[0] <= b[0] + b[2] and b[1] <= p[1] <= b[1] + b[3]


def seg_dist(p, s):
    (x0, y0, x1, y1) = s
    dx, dy = x1 - x0, y1 - y0
    t = max(0, min(1, ((p[0] - x0) * dx + (p[1] - y0) * dy) / (dx * dx + dy * dy)))
    return math.hypot(p[0] - (x0 + t * dx), p[1] - (y0 + t * dy))


# ---- chemistry
def canon(smiles):
    from rdkit import Chem, RDLogger

    RDLogger.DisableLog("rdApp.*")
    m = Chem.MolFromSmiles(smiles)
    return Chem.MolToSmiles(m, isomericSmiles=False) if m else None


def group_atoms(mol, smarts):
    from rdkit import Chem

    p = Chem.MolFromSmarts(smarts)
    if p is None:
        return None
    return {i for match in mol.GetSubstructMatches(p) for i in match}


# ---- graphs
_JS_NAMES = {
    "sin": math.sin, "cos": math.cos, "tan": math.tan, "asin": math.asin, "acos": math.acos, "atan": math.atan,
    "atan2": math.atan2, "sinh": math.sinh, "cosh": math.cosh, "tanh": math.tanh, "exp": math.exp,
    "log": math.log, "log10": math.log10, "log2": math.log2, "sqrt": math.sqrt, "cbrt": lambda v: math.copysign(abs(v) ** (1 / 3), v),
    "abs": abs, "pow": pow, "floor": math.floor, "ceil": math.ceil, "round": round, "sign": lambda v: (v > 0) - (v < 0),
    "min": min, "max": max, "hypot": math.hypot, "PI": math.pi, "E": math.e, "pi": math.pi, "e": math.e, "ln": math.log,
}


def make_fn(expr, params=None):
    src = expr.replace("Math.", "")
    if "?" in src or "=>" in src:
        return None
    try:
        code = compile(src, "<expr>", "eval")
    except SyntaxError:
        return None
    env = dict(_JS_NAMES)
    env.update(params or {})

    def f(x):
        try:
            v = eval(code, {"__builtins__": {}}, {**env, "x": x})
            v = float(v)
            return v if math.isfinite(v) else None
        except Exception:
            return None
    return f


def fn_matches(expected, model_fn, xs):
    ef = make_fn(expected)
    good = total = 0
    for x in xs:
        a, b = ef(x), model_fn(x)
        if a is None:
            continue
        total += 1
        if b is not None and abs(a - b) <= 1e-2 + 0.02 * abs(a):
            good += 1
    return total > 0 and good / total >= 0.8


# ---- text
def norm_text(s):
    s = unicodedata.normalize("NFKC", s).lower()
    s = s.replace("−", "-").replace("·", "*").replace("×", "*").replace("**", "^")
    s = re.sub(r"\s+", "", s)
    s = s.replace("*", "")
    s = s.rstrip(".")
    return s


def text_ok(got, answers):
    g = norm_text(got)
    for a in answers:
        n = norm_text(a)
        if g == n:
            return True
        try:
            if abs(float(g.replace(",", "")) - float(n.replace(",", ""))) < 1e-6 + 0.01 * abs(float(n.replace(",", ""))):
                return True
        except ValueError:
            pass
        # allow units / surrounding words: "6 N", "x²+C"
        if re.fullmatch(rf"{re.escape(n)}[a-z/]*", g):
            return True
    return False


def score_case(case, result):
    e = case["expect"]
    actions = result.get("actions", [])
    types = [a["type"] for a in actions]
    checks = {}
    detail = {}

    req = e.get("types", {}).get("required", [])
    forb = e.get("types", {}).get("forbidden", [])
    checks["types"] = all(t in types for t in req) and not any(t in types for t in forb)
    detail["types"] = types

    ious = []
    for t in e.get("targets", []):
        cands = [box_of(a["region"]) for a in actions if a["type"] in t["types"] and "region" in a]
        best = max((iou(c, r) for c in cands for r in t["regions"]), default=0.0)
        ious.append(best)
        checks.setdefault("regions", True)
        checks["regions"] &= best >= t.get("minIoU", 0.5)
    if ious:
        detail["ious"] = [round(v, 3) for v in ious]

    for p in e.get("points", []):
        ok = False
        for a in actions:
            if a["type"] not in p["types"]:
                continue
            pt = a.get("point") or a.get("anchor")
            xy = (pt["x"], pt["y"])
            where = seg_dist(xy, p["segment"]) <= p["maxDist"] if "segment" in p else inside(xy, p["region"])
            kw = p.get("keywords")
            words = a.get("text", "").lower()
            if where and (not kw or any(k in words for k in kw)):
                ok = True
        detail.setdefault("points", []).append(ok)
        checks.setdefault("points", True)
        checks["points"] &= ok

    if "molecule" in e:
        from rdkit import Chem

        m = e["molecule"]
        card = next((a for a in actions if a["type"] == "insertMoleculeCard"), None)
        smiles_ok = bool(card) and canon(card["smiles"]) == canon(m["smiles"])
        mol = Chem.MolFromSmiles(m["smiles"])
        hits = 0
        if card:
            model_atoms = set()
            for g in card["highlightGroups"] + card["starGroups"]:
                model_atoms |= group_atoms(mol, g) or set()
            for g in m.get("groups", []):
                want = group_atoms(mol, g)
                if want and len(want & model_atoms) >= 0.5 * len(want):
                    hits += 1
        n = len(m.get("groups", []))
        detail["molecule"] = {"smiles": card and card["smiles"], "smilesOk": smiles_ok, "groupRecall": hits / n if n else 1.0}
        checks["smiles"] = smiles_ok
        checks["groups"] = n == 0 or hits == n

    if "graph" in e:
        g = e["graph"]
        card = next((a for a in actions if a["type"] == "insertGraphCard"), None)
        ok_fns = ok_range = ok_asym = False
        if card:
            spec = card["spec"]
            params = {p["name"]: p["value"] for p in spec["params"]}
            fns = [make_fn(f["expression"], params) for f in spec["functions"]]
            fns = [f for f in fns if f]
            lo, hi = spec["xMin"], spec["xMax"]
            xs = [lo + (hi - lo) * i / 40 for i in range(41)]
            ok_fns = all(any(fn_matches(ex, f, xs) for f in fns) for ex in g["fns"])
            ok_range = all(lo <= x <= hi for x in g.get("mustShowX", []))
            ok_asym = all(any(a["orientation"] == w["orientation"] and abs(a["value"] - w["value"]) < 0.05 for a in spec["asymptotes"])
                          for w in g.get("asymptotes", []))
        detail["graph"] = {"fns": ok_fns, "range": ok_range, "asymptotes": ok_asym,
                           "expressions": card and [f["expression"] for f in card["spec"]["functions"]]}
        checks["graph"] = ok_fns and ok_range and ok_asym

    if "fill" in e:
        fills = [a for a in actions if a["type"] == "fillText"]
        results = []
        for blank in e["fill"]:
            ok = False
            for a in fills:
                b = box_of(a["region"])
                c = (b[0] + b[2] / 2, b[1] + b[3] / 2)
                placed = iou(b, blank["box"]) >= blank.get("minIoU", 0.3) or inside(c, blank["box"])
                if placed and text_ok(a["text"], blank["answers"]):
                    ok = True
            results.append(ok)
        for box in e.get("noFillIn", []):
            for a in fills:
                b = box_of(a["region"])
                if inside((b[0] + b[2] / 2, b[1] + b[3] / 2), box):
                    results.append(False)
        detail["fill"] = results
        detail["fillTexts"] = [a["text"] for a in fills]
        checks["fill"] = all(results)

    if "remove" in e:
        checks["remove"] = sorted(result.get("remove", [])) == sorted(e["remove"])
        detail["remove"] = result.get("remove", [])

    if "sidebarKeywords" in e:
        md = " ".join(a["markdown"] for a in actions if a["type"] == "openSidebar").lower()
        checks["sidebar"] = bool(md) and all(k.lower() in md for k in e["sidebarKeywords"])

    if "sayKeywords" in e:
        words = " ".join(a.get("text", "") + a.get("markdown", "") + (a.get("note") or "") for a in actions).lower()
        checks["say"] = any(k in words for k in e["sayKeywords"])

    passed = not result.get("error") and all(checks.values())
    return {
        "id": case["id"],
        "category": case["category"],
        "style": case["style"],
        "passed": passed,
        "checks": checks,
        "detail": detail,
        "sayFirst": bool(types) and types[0] == "say",
        "error": result.get("error"),
    }
