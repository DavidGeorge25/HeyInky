"""Draws expected (green) and predicted (red) regions on a page image for debugging."""
from __future__ import annotations

from PIL import Image, ImageDraw

REGION_TYPES = {"highlight", "circle", "fillText"}


def _rect(d, img, box, color, width=3):
    W, H = img.size
    x, y, w, h = box
    d.rectangle([x * W, y * H, (x + w) * W, (y + h) * H], outline=color, width=width)


def _point(d, img, p, color):
    W, H = img.size
    x, y = p[0] * W, p[1] * H
    d.ellipse([x - 8, y - 8, x + 8, y + 8], outline=color, width=3)


def render(page_png, case, actions=None, out_path=None):
    img = Image.open(page_png).convert("RGB")
    d = ImageDraw.Draw(img)
    e = case["expect"]
    for t in e.get("targets", []):
        for r in t["regions"]:
            _rect(d, img, r, (0, 170, 0))
    for p in e.get("points", []):
        _rect(d, img, p["region"], (0, 120, 220))
    for f in e.get("fill", []):
        _rect(d, img, f["box"], (0, 170, 0))
    if case.get("lasso"):
        _rect(d, img, case["lasso"], (140, 60, 240), 2)
    for a in actions or []:
        t = a.get("type")
        if t in REGION_TYPES:
            r = a["region"]
            _rect(d, img, [r["x"], r["y"], r["width"], r["height"]], (220, 30, 30))
        elif t == "star":
            _point(d, img, [a["point"]["x"], a["point"]["y"]], (220, 30, 30))
        elif t == "label":
            _point(d, img, [a["anchor"]["x"], a["anchor"]["y"]], (220, 120, 0))
        elif t in ("insertMoleculeCard", "insertGraphCard"):
            r = a["near"]
            _rect(d, img, [r["x"], r["y"], r["width"], r["height"]], (220, 120, 0), 2)
    if out_path:
        img.save(out_path)
    return img
