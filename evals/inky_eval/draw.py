"""Synthetic page drawing with ground truth.

Pages are authored in page points (816 x 1056, US Letter at 96 dpi, like the app) and
rendered at SCALE. Every drawing call returns the normalized bounding box of the ink it
put down, so expectations are exact. "hand" pages use handwriting fonts, wobbly strokes,
slight rotation and ink colors, to look like Apple Pencil notes.
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass, field

from PIL import Image, ImageDraw, ImageFont

PAGE_W, PAGE_H = 816, 1056
SCALE = 1.5

FONTS = {
    "typed": "/System/Library/Fonts/Supplemental/Arial.ttf",
    "typed_bold": "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "hand": "/System/Library/Fonts/Noteworthy.ttc",
    "hand2": "/System/Library/Fonts/Supplemental/Bradley Hand Bold.ttf",
}

INK_TYPED = (20, 20, 25)
INK_HAND = [(28, 36, 92), (20, 20, 30), (25, 60, 120)]


Box = list  # [x, y, w, h] normalized


def union(*boxes: Box) -> Box:
    boxes = [b for b in boxes if b]
    x0 = min(b[0] for b in boxes)
    y0 = min(b[1] for b in boxes)
    x1 = max(b[0] + b[2] for b in boxes)
    y1 = max(b[1] + b[3] for b in boxes)
    return [x0, y0, x1 - x0, y1 - y0]


def pad(b: Box, px: float, py: float | None = None) -> Box:
    py = px if py is None else py
    return [b[0] - px, b[1] - py, b[2] + 2 * px, b[3] + 2 * py]


def rnd(b: Box) -> Box:
    return [round(v, 4) for v in b]


@dataclass
class Page:
    id: str
    hand: bool
    seed: int = 0
    paper: str = "blank"  # blank | lined | grid
    lines: list = field(default_factory=list)  # text layer: {"text", "box"}

    def __post_init__(self):
        self.rng = random.Random(self.seed or hash(self.id) & 0xFFFF)
        self.img = Image.new("RGB", (int(PAGE_W * SCALE), int(PAGE_H * SCALE)), "white")
        self.d = ImageDraw.Draw(self.img)
        self.ink = self.rng.choice(INK_HAND) if self.hand else INK_TYPED
        if self.paper == "lined":
            for y in range(96, PAGE_H - 24, 32):
                self.d.line([(0, y * SCALE), (PAGE_W * SCALE, y * SCALE)], fill=(196, 210, 230), width=1)
        elif self.paper == "grid":
            for v in range(0, max(PAGE_W, PAGE_H), 24):
                self.d.line([(v * SCALE, 0), (v * SCALE, PAGE_H * SCALE)], fill=(225, 232, 242), width=1)
                self.d.line([(0, v * SCALE), (PAGE_W * SCALE, v * SCALE)], fill=(225, 232, 242), width=1)

    # ---- coordinates
    @staticmethod
    def norm(x0, y0, x1, y1) -> Box:
        return [x0 / PAGE_W, y0 / PAGE_H, (x1 - x0) / PAGE_W, (y1 - y0) / PAGE_H]

    def font(self, size: float, bold=False, alt=False):
        if self.hand:
            path = FONTS["hand2"] if alt else FONTS["hand"]
        else:
            path = FONTS["typed_bold"] if bold else FONTS["typed"]
        return ImageFont.truetype(path, int(size * SCALE))

    # ---- text
    def text(self, x, y, s, size=18, bold=False, alt=False, color=None, record=True, angle=None) -> Box:
        """Draws text with its top-left near (x, y) in page points. Returns the ink box."""
        font = self.font(size, bold, alt)
        color = color or self.ink
        if not self.hand:
            self.d.text((x * SCALE, y * SCALE), s, font=font, fill=color)
            l, t, r, b = self.d.textbbox((x * SCALE, y * SCALE), s, font=font)
            box = self.norm(l / SCALE, t / SCALE, r / SCALE, b / SCALE)
        else:
            angle = self.rng.uniform(-1.6, 1.6) if angle is None else angle
            l, t, r, b = font.getbbox(s)
            layer = Image.new("RGBA", (r + 20, b + 20), (0, 0, 0, 0))
            ImageDraw.Draw(layer).text((10, 10), s, font=font, fill=color + (255,))
            layer = layer.rotate(angle, resample=Image.BICUBIC, expand=True)
            jx, jy = self.rng.uniform(-2, 2), self.rng.uniform(-2, 2)
            ox, oy = int((x + jx) * SCALE) - 10, int((y + jy) * SCALE) - 10
            self.img.paste(layer, (ox, oy), layer)
            bb = layer.getchannel("A").point(lambda a: 255 if a > 60 else 0).getbbox()
            box = self.norm((ox + bb[0]) / SCALE, (oy + bb[1]) / SCALE, (ox + bb[2]) / SCALE, (oy + bb[3]) / SCALE)
        if record:
            self.lines.append({"text": s, "box": rnd(box)})
        return rnd(box)

    def text_width(self, s, size=18, bold=False, alt=False) -> float:
        l, t, r, b = self.font(size, bold, alt).getbbox(s)
        return (r - l) / SCALE

    # ---- strokes
    def _wobble(self, pts, amount):
        if not self.hand or amount == 0:
            return pts
        out = []
        for i in range(len(pts) - 1):
            (x0, y0), (x1, y1) = pts[i], pts[i + 1]
            n = max(2, int(math.hypot(x1 - x0, y1 - y0) / 12))
            phase = self.rng.uniform(0, math.tau)
            nx, ny = -(y1 - y0), x1 - x0
            ln = math.hypot(nx, ny) or 1
            nx, ny = nx / ln, ny / ln
            for k in range(n):
                t = k / n
                w = amount * math.sin(phase + t * math.pi * 2 * self.rng.uniform(0.6, 1.2))
                out.append((x0 + (x1 - x0) * t + nx * w, y0 + (y1 - y0) * t + ny * w))
        out.append(pts[-1])
        return out

    def stroke(self, pts, width=2.0, color=None, wobble=1.2) -> Box:
        color = color or self.ink
        pts = self._wobble(pts, wobble)
        w = max(1, int(width * SCALE * (1.15 if self.hand else 1)))
        self.d.line([(px * SCALE, py * SCALE) for px, py in pts], fill=color, width=w, joint="curve")
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        hw = width / 2
        return rnd(self.norm(min(xs) - hw, min(ys) - hw, max(xs) + hw, max(ys) + hw))

    def line(self, x0, y0, x1, y1, width=2.0, color=None) -> Box:
        return self.stroke([(x0, y0), (x1, y1)], width, color)

    def arrow(self, x0, y0, x1, y1, width=2.0, color=None, head=10) -> Box:
        b = self.line(x0, y0, x1, y1, width, color)
        ang = math.atan2(y1 - y0, x1 - x0)
        hs = []
        for da in (2.6, -2.6):
            hx, hy = x1 + head * math.cos(ang + da), y1 + head * math.sin(ang + da)
            hs.append(self.line(x1, y1, hx, hy, width, color))
        return union(b, *hs)

    def rect(self, x, y, w, h, width=2.0, color=None) -> Box:
        pts = [(x, y), (x + w, y), (x + w, y + h), (x, y + h), (x, y)]
        return self.stroke(pts, width, color, wobble=0.8)

    def ellipse(self, cx, cy, rx, ry, width=2.0, color=None, fill=None) -> Box:
        n = 64
        pts = [(cx + rx * math.cos(t * math.tau / n), cy + ry * math.sin(t * math.tau / n)) for t in range(n + 1)]
        if fill:
            self.d.polygon([(px * SCALE, py * SCALE) for px, py in pts], fill=fill)
        return self.stroke(pts, width, color, wobble=0.6)

    def curve(self, f, x0, x1, n=120, width=2.2, color=None) -> Box:
        pts = [(x0 + (x1 - x0) * i / n, 0) for i in range(n + 1)]
        pts = [(px, f(px)) for px, _ in pts]
        return self.stroke(pts, width, color, wobble=0.5)

    def save(self, path):
        self.img.save(path, optimize=True)


# ---- molecules -----------------------------------------------------------------

def draw_molecule(page: Page, smiles: str, cx: float, cy: float, bond_len: float = 42, rotate: float = 0):
    """Skeletal formula centered at (cx, cy). Returns {atom index: (x, y)} and the drawing box."""
    from rdkit import Chem
    from rdkit.Chem import AllChem, rdDepictor

    mol = Chem.MolFromSmiles(smiles)
    rdDepictor.SetPreferCoordGen(True)
    AllChem.Compute2DCoords(mol)
    Chem.Kekulize(mol, clearAromaticFlags=True)
    conf = mol.GetConformer()
    raw = [(conf.GetAtomPosition(i).x, -conf.GetAtomPosition(i).y) for i in range(mol.GetNumAtoms())]
    # RDKit bond length is 1.5 (coordgen ~1.0); normalize to bond_len.
    lens = [math.dist(raw[b.GetBeginAtomIdx()], raw[b.GetEndAtomIdx()]) for b in mol.GetBonds()]
    k = bond_len / (sum(lens) / len(lens))
    mx = sum(p[0] for p in raw) / len(raw)
    my = sum(p[1] for p in raw) / len(raw)
    ca, sa = math.cos(rotate), math.sin(rotate)
    pos = {}
    for i, (x, y) in enumerate(raw):
        x, y = (x - mx) * k, (y - my) * k
        pos[i] = (cx + x * ca - y * sa, cy + x * sa + y * ca)

    labeled = {}
    for atom in mol.GetAtoms():
        sym = atom.GetSymbol()
        if sym != "C":
            h = atom.GetTotalNumHs()
            label = sym + ("H" if h == 1 else f"H{h}" if h > 1 else "")
            if page.hand and h > 1:
                label = sym + "H" + str(h)
            labeled[atom.GetIdx()] = label

    boxes = []
    ring_info = mol.GetRingInfo()
    for bond in mol.GetBonds():
        a, b = bond.GetBeginAtomIdx(), bond.GetEndAtomIdx()
        (x0, y0), (x1, y1) = pos[a], pos[b]
        dx, dy = x1 - x0, y1 - y0
        ln = math.hypot(dx, dy)
        ux, uy = dx / ln, dy / ln
        # shorten at labeled atoms
        s0 = 11 if a in labeled else 0
        s1 = 11 if b in labeled else 0
        x0s, y0s = x0 + ux * s0, y0 + uy * s0
        x1s, y1s = x1 - ux * s1, y1 - uy * s1
        order = bond.GetBondTypeAsDouble()
        nx, ny = -uy, ux
        if order == 1:
            boxes.append(page.line(x0s, y0s, x1s, y1s, 2))
        elif order == 2:
            if ring_info.NumBondRings(bond.GetIdx()):
                # inner line toward ring center
                ring = next(r for r in ring_info.AtomRings() if a in r and b in r)
                rcx = sum(pos[i][0] for i in ring) / len(ring)
                rcy = sum(pos[i][1] for i in ring) / len(ring)
                side = 1 if (rcx - x0) * nx + (rcy - y0) * ny > 0 else -1
                o = 6 * side
                boxes.append(page.line(x0s, y0s, x1s, y1s, 2))
                boxes.append(page.line(x0s + nx * o + ux * 5, y0s + ny * o + uy * 5, x1s + nx * o - ux * 5, y1s + ny * o - uy * 5, 2))
            else:
                for o in (-3.5, 3.5):
                    boxes.append(page.line(x0s + nx * o, y0s + ny * o, x1s + nx * o, y1s + ny * o, 2))
        else:
            for o in (-5, 0, 5):
                boxes.append(page.line(x0s + nx * o, y0s + ny * o, x1s + nx * o, y1s + ny * o, 2))

    atom_boxes = {}
    for i, (x, y) in pos.items():
        if i in labeled:
            label = labeled[i]
            size = 19
            w = page.text_width(label, size)
            # Keep the heteroatom letter centered on the atom.
            first = page.text_width(label[0], size)
            tb = page.text(x - first / 2, y - size * 0.62, label, size=size, record=False, angle=0)
            atom_boxes[i] = tb
            boxes.append(tb)
        else:
            atom_boxes[i] = rnd(page.norm(x - 4, y - 4, x + 4, y + 4))
    # Return an un-kekulized copy (same atom order) so aromatic SMARTS match.
    return Chem.MolFromSmiles(smiles), pos, atom_boxes, union(*boxes)


def group_box(mol, atom_boxes, smarts: str, which: int = 0, pad_pts: float = 6) -> Box:
    from rdkit import Chem

    patt = Chem.MolFromSmarts(smarts)
    matches = mol.GetSubstructMatches(patt)
    if not matches:
        raise ValueError(f"{smarts} not in molecule")
    atoms = matches[which]
    b = union(*[atom_boxes[i] for i in atoms])
    return rnd(pad(b, pad_pts / PAGE_W, pad_pts / PAGE_H))
