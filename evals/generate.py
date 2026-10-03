#!/usr/bin/env python3
"""Generates the synthetic eval pages (evals/pages/*.png + text layers) and evals/cases.json.

    evals/.venv/bin/python evals/generate.py

Deterministic (seeded). Every expected region comes from the drawing calls themselves.
Case format is documented in evals/README.md.
"""
from __future__ import annotations

import json
import math
from pathlib import Path

from inky_eval.draw import PAGE_H, PAGE_W, Page, draw_molecule, group_box, pad, rnd, union

ROOT = Path(__file__).resolve().parent
PAGES = ROOT / "pages"
CASES: list[dict] = []


def finish(page: Page):
    PAGES.mkdir(exist_ok=True)
    page.save(PAGES / f"{page.id}.png")
    (PAGES / f"{page.id}.json").write_text(json.dumps({"id": page.id, "hand": page.hand, "size": [PAGE_W, PAGE_H], "lines": page.lines}, indent=1))


def case(cid, page: Page, question, expect, *, category, lasso=None, existing=None, history=None, pdf_text=False):
    CASES.append({
        "id": cid,
        "page": page.id,
        "category": category,
        "style": "handwritten" if page.hand else "typed",
        "question": question,
        "lasso": rnd(lasso) if lasso else None,
        "pdfText": pdf_text,
        "existing": existing or [],
        "history": history or [],
        "expect": expect,
    })


def P(x, y):  # page points -> normalized point
    return [round(x / PAGE_W, 4), round(y / PAGE_H, 4)]


def R(x0, y0, x1, y1):
    return rnd(Page.norm(x0, y0, x1, y1))


def hl(box, color="yellow", note=None):
    return {"type": "highlight", "region": {"x": box[0], "y": box[1], "width": box[2], "height": box[3]}, "color": color, "note": note}


def fill(box, text):
    return {"type": "fillText", "region": {"x": box[0], "y": box[1], "width": box[2], "height": box[3]}, "text": text, "handwritingStyle": True}


def say(text):
    return {"type": "say", "text": text}


def target(types, *regions, min_iou=0.5, keywords=None):
    t = {"types": types, "regions": [rnd(r) for r in regions], "minIoU": min_iou}
    if keywords:
        t["keywords"] = keywords
    return t


def point(types, region, keywords=None):
    t = {"types": types, "region": rnd(region)}
    if keywords:
        t["keywords"] = keywords
    return t


def title(page: Page, s, y=60):
    return page.text(72, y, s, size=30, bold=True)


# ============================================================ molecules

def molecule_pages():
    specs = [
        # id, smiles, hand, page title, notes
        ("mol_ethanol_hand", "CCO", True, "Alcohols", ["bp 78 °C", "found in drinks + hand sanitizer"]),
        ("mol_acetic_acid_typed", "CC(=O)O", False, "Carboxylic Acids", ["Vinegar is ~5% of this acid.", "pKa ≈ 4.76"]),
        ("mol_aspirin_typed", "CC(=O)Oc1ccccc1C(=O)O", False, "Drug structures: Aspirin", ["Analgesic, anti-inflammatory", "C9H8O4"]),
        ("mol_acetone_hand", "CC(=O)C", True, "Solvents", ["nail polish remover", "polar aprotic"]),
        ("mol_benzaldehyde_hand", "O=Cc1ccccc1", True, "Aromatic compounds", ["smells like almonds"]),
        ("mol_glycine_typed", "NCC(=O)O", False, "Amino acids", ["Simplest amino acid", "Achiral"]),
        ("mol_ethyl_acetate_hand", "CCOC(=O)C", True, "Lab 4 — smells", ["fruity smell, used in glue"]),
        ("mol_phenol_typed", "Oc1ccccc1", False, "Phenols", ["Weak acid (pKa ≈ 10)"]),
        ("mol_acetaminophen_hand", "CC(=O)Nc1ccc(O)cc1", True, "Painkillers", ["Tylenol", "max 4 g / day"]),
    ]
    pages = {}
    for pid, smiles, hand, ttl, notes in specs:
        page = Page(pid, hand=hand, paper="grid" if hand else "blank")
        tb = title(page, ttl)
        mol, pos, atom_boxes, mbox = draw_molecule(page, smiles, 300, 330, bond_len=58 if len(smiles) < 12 else 48)
        y = 560
        for n in notes:
            page.text(90, y, n, size=20)
            y += 40
        finish(page)
        pages[pid] = (page, mol, atom_boxes, mbox, tb)

    # 1 identify + groups (card)
    page, mol, ab, mbox, _ = pages["mol_ethanol_hand"]
    case("mol_ethanol_identify", page, "what molecule is this? show me its functional group", {
        "types": {"required": ["insertMoleculeCard"], "forbidden": ["insertGraphCard", "fillText"]},
        "molecule": {"smiles": "CCO", "groups": ["[OX2H]"]},
    }, category="molecule")

    page, mol, ab, mbox, _ = pages["mol_acetic_acid_typed"]
    case("mol_acetic_highlight_acid", page, "highlight the carboxylic acid group", {
        "types": {"required": ["highlight"], "forbidden": ["circle", "insertGraphCard"]},
        "targets": [target(["highlight"], group_box(mol, ab, "C(=O)[OX2H1]"), min_iou=0.3)],
    }, category="molecule")

    page, mol, ab, mbox, _ = pages["mol_aspirin_typed"]
    case("mol_aspirin_groups", page, "identify the functional groups in this structure", {
        "types": {"required": ["insertMoleculeCard"], "forbidden": ["insertGraphCard", "fillText"]},
        "molecule": {"smiles": "CC(=O)Oc1ccccc1C(=O)O", "groups": ["[CX3](=O)[OX2][#6]", "C(=O)[OX2H1]"]},
    }, category="molecule")

    page, mol, ab, mbox, _ = pages["mol_acetone_hand"]
    carbonyl = group_box(mol, ab, "[CX3]=[OX1]")
    case("mol_acetone_circle", page, "circle the carbonyl", {
        "types": {"required": ["circle"], "forbidden": ["highlight", "insertGraphCard"]},
        "targets": [target(["circle"], carbonyl, min_iou=0.3)],
    }, category="molecule")
    # follow-up: undo only the latest turn
    title_box = pages["mol_acetone_hand"][4]
    case("follow_acetone_undo", page, "undo that", {
        "types": {"required": ["say"], "forbidden": ["highlight", "circle", "star", "label", "fillText", "insertMoleculeCard", "insertGraphCard"]},
        "remove": ["m2"],
    }, category="followup", existing=[
        {"action": hl(pad(title_box, 0.005)), "question": "highlight the title"},
        {"action": {"type": "circle", "region": {"x": carbonyl[0], "y": carbonyl[1], "width": carbonyl[2], "height": carbonyl[3]}, "style": "solid"}, "question": "circle the carbonyl"},
    ], history=[
        {"question": "highlight the title", "actions": [say("Highlighted the title."), hl(pad(title_box, 0.005))], "created": [0]},
        {"question": "circle the carbonyl", "actions": [say("Circled the C=O carbonyl."), {"type": "circle", "region": {"x": carbonyl[0], "y": carbonyl[1], "width": carbonyl[2], "height": carbonyl[3]}, "style": "solid"}], "created": [1]},
    ])

    page, mol, ab, mbox, _ = pages["mol_benzaldehyde_hand"]
    case("mol_benzaldehyde_card", page, "what is this compound? make it a molecule card", {
        "types": {"required": ["insertMoleculeCard"], "forbidden": ["insertGraphCard"]},
        "molecule": {"smiles": "O=Cc1ccccc1", "groups": ["[CX3H1](=O)"]},
    }, category="molecule")

    page, mol, ab, mbox, _ = pages["mol_glycine_typed"]
    case("mol_glycine_labels", page, "label the amine and the carboxylic acid", {
        "types": {"required": ["label"], "forbidden": ["insertGraphCard", "fillText"]},
        "points": [
            point(["label"], pad(group_box(mol, ab, "[NX3;H2]"), 0.02), keywords=["amin", "nh"]),
            point(["label"], pad(group_box(mol, ab, "C(=O)[OX2H1]"), 0.02), keywords=["acid", "carbox", "cooh"]),
        ],
    }, category="molecule")

    page, mol, ab, mbox, _ = pages["mol_ethyl_acetate_hand"]
    case("mol_ester_highlight", page, "what functional group is in this molecule? highlight it", {
        "types": {"required": ["highlight"], "forbidden": ["insertGraphCard", "fillText"]},
        "targets": [target(["highlight"], group_box(mol, ab, "[CX3](=O)[OX2][#6]"), group_box(mol, ab, "[CX3](=O)[OX2]"), min_iou=0.3)],
        "sayKeywords": ["ester"],
    }, category="molecule")

    page, mol, ab, mbox, _ = pages["mol_phenol_typed"]
    case("mol_phenol_star", page, "star the hydroxyl group", {
        "types": {"required": ["star"], "forbidden": ["insertGraphCard"]},
        "points": [point(["star"], pad(group_box(mol, ab, "[OX2H]"), 0.035))],
    }, category="molecule")

    page, mol, ab, mbox, _ = pages["mol_acetaminophen_hand"]
    case("mol_acetaminophen_amide", page, "what molecule is this? show me where the amide is", {
        "types": {"required": ["insertMoleculeCard"], "forbidden": ["insertGraphCard"]},
        "molecule": {"smiles": "CC(=O)Nc1ccc(O)cc1", "groups": ["C(=O)N"]},
    }, category="molecule")

    # Two molecules, lasso one.
    page = Page("mol_two_carbonyls_typed", hand=False)
    title(page, "Aldehyde vs ketone")
    page.text(90, 160, "1. propanal", size=20)
    m1, pos1, ab1, box1 = draw_molecule(page, "CCC=O", 210, 300, bond_len=44)
    page.text(470, 160, "2. ?", size=20)
    m2, pos2, ab2, box2 = draw_molecule(page, "CC(=O)C", 580, 300, bond_len=44)
    page.text(90, 480, "Which one gives a positive Tollens' test?", size=20)
    finish(page)
    case("mol_lasso_ketone", page, "what is this one?", {
        "types": {"required": ["insertMoleculeCard"], "forbidden": ["insertGraphCard"]},
        "molecule": {"smiles": "CC(=O)C", "groups": ["[#6][CX3](=O)[#6]"]},
    }, category="molecule", lasso=pad(union(box2, R(470, 160, 520, 185)), 0.03))


# ============================================================ functions / graphs

def function_pages():
    page = Page("fn_quadratic_hand", hand=True, paper="lined")
    title(page, "HW 3 — quadratics", y=40)
    q = page.text(70, 128, "Q1. Sketch f(x) = x² − 4x + 3", size=24)
    page.text(70, 192, "find the roots + vertex", size=22)
    finish(page)
    case("fn_quadratic_graph", page, "graph this", {
        "types": {"required": ["insertGraphCard"], "forbidden": ["fillText"]},
        "graph": {"fns": ["x**2 - 4*x + 3"], "mustShowX": [1, 2, 3]},
    }, category="graph")
    case("follow_quadratic_why_vertex", page, "how did you find the vertex? explain", {
        "types": {"required": ["openSidebar"], "forbidden": ["insertMoleculeCard"]},
        "sidebarKeywords": ["vertex", "2"],
    }, category="followup", existing=[
        {"action": {"type": "insertGraphCard", "spec": {"title": "f(x) = x² − 4x + 3", "xMin": -1, "xMax": 5, "yMin": -2, "yMax": 8, "xLabel": None, "yLabel": None,
                    "functions": [{"expression": "x**2 - 4*x + 3", "label": "f(x)", "color": None}], "params": [], "asymptotes": [],
                    "points": [{"x": 1, "y": 0, "label": "root", "draggable": False}, {"x": 3, "y": 0, "label": "root", "draggable": False}, {"x": 2, "y": -1, "label": "vertex", "draggable": False}], "labels": []},
                    "near": {"x": 0.1, "y": 0.3, "width": 0.42, "height": 0.28}}, "question": "graph this"},
    ], history=[{"question": "graph this", "actions": [say("Here's f(x) with its roots and vertex."), {"type": "insertGraphCard", "spec": {"title": "f(x) = x² − 4x + 3", "xMin": -1, "xMax": 5, "yMin": -2, "yMax": 8, "xLabel": None, "yLabel": None,
                    "functions": [{"expression": "x**2 - 4*x + 3", "label": "f(x)", "color": None}], "params": [], "asymptotes": [],
                    "points": [{"x": 1, "y": 0, "label": "root", "draggable": False}, {"x": 3, "y": 0, "label": "root", "draggable": False}, {"x": 2, "y": -1, "label": "vertex", "draggable": False}], "labels": []},
                    "near": {"x": 0.1, "y": 0.3, "width": 0.42, "height": 0.28}}], "created": [0]}])

    page = Page("fn_sine_typed", hand=False)
    title(page, "Trigonometric functions")
    page.text(72, 130, "Example 2.  y = 2 sin(3x)", size=22)
    page.text(72, 170, "Amplitude = ?     Period = ?", size=20)
    finish(page)
    case("fn_sine_graph", page, "plot this so I can see the period", {
        "types": {"required": ["insertGraphCard"]},
        "graph": {"fns": ["2*sin(3*x)"], "mustShowX": [0, 2.0944]},
    }, category="graph")

    page = Page("fn_rational_hand", hand=True, paper="grid")
    title(page, "Asymptotes", y=50)
    page.text(70, 130, "f(x) = 1 / (x − 2)", size=28)
    page.text(70, 190, "vertical asymptote at x = ?", size=22)
    page.text(70, 230, "horizontal asymptote y = ?", size=22)
    finish(page)
    case("fn_rational_asymptotes", page, "graph it and show the asymptotes", {
        "types": {"required": ["insertGraphCard"]},
        "graph": {"fns": ["1/(x-2)"], "asymptotes": [{"orientation": "vertical", "value": 2}, {"orientation": "horizontal", "value": 0}], "mustShowX": [2]},
    }, category="graph")

    page = Page("fn_decay_typed", hand=False)
    title(page, "Nuclear decay")
    page.text(72, 130, "N(t) = 100 e^(−0.5 t)", size=24)
    page.text(72, 175, "N = number of nuclei, t in hours", size=18)
    page.text(72, 205, "Half-life t½ = ln 2 / 0.5 ≈ 1.39 h", size=18)
    finish(page)
    case("fn_decay_graph", page, "graph this decay curve", {
        "types": {"required": ["insertGraphCard"]},
        "graph": {"fns": ["100*exp(-0.5*x)"], "mustShowX": [0, 4]},
    }, category="graph")

    page = Page("fn_log_exp_hand", hand=True)
    title(page, "Inverse functions", y=50)
    page.text(70, 130, "y = ln(x)  and  y = e^x", size=26)
    page.text(70, 185, "reflections in y = x", size=22)
    finish(page)
    case("fn_log_exp_two", page, "plot both of these on one graph", {
        "types": {"required": ["insertGraphCard"]},
        "graph": {"fns": ["log(x)", "exp(x)"], "mustShowX": [1]},
    }, category="graph")

    page = Page("fn_projectile_typed", hand=False)
    title(page, "Projectile motion")
    page.text(72, 130, "Launch at 45° with v = 10 m/s, g = 9.8 m/s²", size=19)
    page.text(72, 170, "Trajectory: y = x − 0.098 x²", size=22)
    page.text(72, 210, "Range R = v² sin(2θ) / g ≈ 10.2 m", size=19)
    finish(page)
    case("fn_projectile_graph", page, "graph the trajectory", {
        "types": {"required": ["insertGraphCard"]},
        "graph": {"fns": ["x - 0.098*x**2"], "mustShowX": [0, 10.2]},
    }, category="graph")


# ============================================================ diagrams

def diagram_pages():
    # Reaction energy diagram
    page = Page("dia_energy_typed", hand=False)
    title(page, "Reaction energy diagram")
    ox, oy, w, h = 140, 620, 520, 380
    page.arrow(ox, oy, ox, oy - h, 2)
    page.arrow(ox, oy, ox + w, oy, 2)
    page.text(ox - 60, oy - h - 30, "Energy", size=16)
    page.text(ox + w - 120, oy + 12, "Reaction progress", size=16)

    def energy(x):
        # reactants level 520 -> peak 330 -> products 570
        t = (x - ox) / w
        base = 520 + (570 - 520) * (1 / (1 + math.exp(-(t - 0.5) * 14)))
        return base - 190 * math.exp(-((t - 0.45) ** 2) / 0.012)
    page.curve(energy, ox + 20, ox + w - 20, width=2.5)
    page.text(ox + 10, 485, "Reactants", size=16)
    page.text(ox + w - 120, 585, "Products", size=16)
    peak_x = ox + 0.45 * w
    ts = page.text(peak_x - 60, 290, "Transition state", size=16)
    ea_arrow = page.arrow(ox + 0.25 * w, 520, ox + 0.25 * w, energy(peak_x) + 4, 1.5)
    ea_label = page.text(ox + 0.25 * w - 34, 410, "Ea", size=18)
    dh_arrow = page.arrow(ox + w - 40, 520, ox + w - 40, 568, 1.5)
    dh_label = page.text(ox + w - 30, 535, "ΔH", size=18)
    page.line(ox + w - 160, 520, ox + w - 30, 520, 1)  # reference level
    page.text(72, 700, "Endothermic: products are higher in energy than reactants.", size=17)
    finish(page)
    case("dia_energy_highlight_ea", page, "highlight the activation energy", {
        "types": {"required": ["highlight"], "forbidden": ["insertGraphCard"]},
        "targets": [target(["highlight"], ea_label, union(ea_arrow, ea_label), min_iou=0.3)],
    }, category="diagram")
    peak = Page.norm(peak_x - 30, energy(peak_x) - 25, peak_x + 30, energy(peak_x) + 25)
    case("dia_energy_star_ts", page, "star the transition state on the curve", {
        "types": {"required": ["star"]},
        "points": [point(["star"], union(pad(peak, 0.03), pad(ts, 0.01)))],
    }, category="diagram")

    # Cell diagram (hand)
    page = Page("dia_cell_hand", hand=True)
    title(page, "Animal cell", y=50)
    cell = page.ellipse(380, 420, 250, 190, 2.5)
    nucleus = page.ellipse(360, 410, 70, 55, 2)
    page.ellipse(355, 405, 16, 13, 2, fill=(110, 110, 140))
    mito = page.ellipse(520, 340, 45, 20, 2)
    page.stroke([(485, 340), (495, 330), (505, 350), (515, 330), (525, 350), (535, 330), (548, 345)], 1.5)
    ribo_boxes = [page.ellipse(cx, cy, 4, 4, 2, fill=(40, 40, 80)) for cx, cy in [(250, 500), (262, 512), (240, 520), (480, 520)]]
    page.line(300, 370, 140, 260, 1.5)
    page.text(70, 230, "nucleus", size=22)
    page.line(560, 345, 680, 250, 1.5)
    page.text(640, 220, "mitochondrion", size=22)
    page.line(250, 505, 120, 650, 1.5)
    page.text(70, 655, "ribosomes", size=22)
    page.line(620, 480, 700, 640, 1.5)
    page.text(620, 645, "cell membrane", size=22)
    finish(page)
    case("dia_cell_circle_mito", page, "circle the mitochondrion in the drawing", {
        "types": {"required": ["circle"], "forbidden": ["highlight"]},
        "targets": [target(["circle"], mito, min_iou=0.3)],
    }, category="diagram")

    # Series circuit
    page = Page("dia_circuit_typed", hand=False)
    title(page, "Series circuit")
    # loop
    page.line(150, 250, 330, 250)
    r1 = page.stroke([(330, 250), (340, 240), (355, 260), (370, 240), (385, 260), (400, 240), (410, 250)], 2, wobble=0)
    page.line(410, 250, 600, 250)
    page.line(600, 250, 600, 330)
    r2 = page.stroke([(600, 330), (590, 340), (610, 355), (590, 370), (610, 385), (590, 400), (600, 410)], 2, wobble=0)
    page.line(600, 410, 600, 500)
    page.line(600, 500, 400, 500)
    batt = union(page.line(400, 470, 400, 530, 2), page.line(380, 485, 380, 515, 4))
    page.line(380, 500, 150, 500)
    page.line(150, 500, 150, 250)
    r1l = page.text(330, 205, "R1 = 4 Ω", size=18)
    r2l = page.text(625, 355, "R2 = 6 Ω", size=18)
    bl = page.text(350, 540, "V = 12 V", size=18)
    page.text(72, 620, "Find the current I and the voltage across each resistor.", size=18)
    finish(page)
    case("dia_circuit_bigger_r", page, "which resistor has the larger resistance? highlight it", {
        "types": {"required": ["highlight"]},
        "targets": [target(["highlight"], r2, r2l, union(r2, r2l), min_iou=0.3)],
        "sayKeywords": ["r2", "6"],
    }, category="diagram")

    # Free-body diagram (hand)
    page = Page("dia_fbd_hand", hand=True, paper="grid")
    title(page, "Free-body diagram", y=50)
    page.line(150, 520, 650, 520, 2.5)
    block = page.rect(330, 420, 140, 100, 2.5)
    n_arrow = page.arrow(400, 420, 400, 300, 2)
    n_label = page.text(412, 300, "N", size=26)
    g_arrow = page.arrow(400, 520, 400, 640, 2)
    g_label = page.text(412, 610, "mg", size=26)
    f_arrow = page.arrow(470, 470, 590, 470, 2)
    f_label = page.text(560, 430, "F", size=26)
    fr_arrow = page.arrow(330, 470, 220, 470, 2)
    fr_label = page.text(220, 430, "f", size=26)
    page.text(90, 720, "block pushed to the right at const. speed", size=20)
    finish(page)
    case("dia_fbd_circle_normal", page, "circle the normal force", {
        "types": {"required": ["circle"]},
        "targets": [target(["circle"], union(n_arrow, n_label), n_arrow, n_label, min_iou=0.3)],
    }, category="diagram")
    case("dia_fbd_label_friction", page, "label the friction force", {
        "types": {"required": ["label"]},
        "points": [point(["label"], pad(union(fr_arrow, fr_label), 0.02), keywords=["fric"])],
    }, category="diagram")

    # Titration curve
    page = Page("dia_titration_typed", hand=False)
    title(page, "Titration of HCl with NaOH")
    ox, oy, w, h = 130, 640, 540, 400
    page.arrow(ox, oy, ox, oy - h)
    page.arrow(ox, oy, ox + w, oy)
    page.text(ox - 40, oy - h - 28, "pH", size=16)
    page.text(ox + w - 160, oy + 12, "Volume NaOH (mL)", size=16)
    for i, v in enumerate([0, 10, 20, 30, 40]):
        x = ox + 40 + i * 110
        page.line(x, oy, x, oy + 6, 1)
        page.text(x - 8, oy + 10, str(v), size=13)
    eq_x = ox + 40 + 2.5 * 110  # 25 mL

    def ph(x):
        t = (x - eq_x) / 22
        return oy - 40 - 300 / (1 + math.exp(-t))
    page.curve(ph, ox + 10, ox + w - 20, width=2.5)
    page.text(72, 720, "25.0 mL of 0.10 M HCl titrated with 0.10 M NaOH", size=17)
    finish(page)
    eq = Page.norm(eq_x - 22, ph(eq_x) - 22, eq_x + 22, ph(eq_x) + 22)
    case("dia_titration_star_eq", page, "star the equivalence point", {
        "types": {"required": ["star"]},
        "points": [point(["star"], pad(eq, 0.02))],
    }, category="diagram")

    # Right triangle (hand)
    page = Page("dia_triangle_hand", hand=True)
    title(page, "Pythagoras", y=50)
    A, B, C = (180, 560), (520, 560), (180, 300)
    page.line(*A, *B, 2.5)
    page.line(*A, *C, 2.5)
    hyp = page.line(*C, *B, 2.5)
    page.rect(180, 540, 20, 20, 1.5)
    page.text(330, 572, "b = 4", size=24)
    page.text(110, 420, "a = 3", size=24)
    page.text(90, 680, "c = ?", size=26)
    finish(page)
    case("dia_triangle_label_hyp", page, "label the hypotenuse", {
        "types": {"required": ["label"]},
        "points": [dict(point(["label"], pad(hyp, 0.02), keywords=["hypot", "c"]), segment=P(*C) + P(*B), maxDist=0.035)],
    }, category="diagram")

    # Phase diagram
    page = Page("dia_phase_typed", hand=False)
    title(page, "Phase diagram of water")
    ox, oy, w, h = 130, 620, 520, 380
    page.arrow(ox, oy, ox, oy - h)
    page.arrow(ox, oy, ox + w, oy)
    page.text(ox - 70, oy - h - 28, "Pressure", size=16)
    page.text(ox + w - 120, oy + 12, "Temperature", size=16)
    tp = (ox + 190, oy - 140)
    page.stroke([(ox + 20, oy - 10), (ox + 100, oy - 60), tp], 2.5, wobble=0)  # sublimation
    page.stroke([tp, (ox + 330, oy - 260), (ox + 470, oy - 330)], 2.5, wobble=0)  # vaporization
    page.stroke([tp, (ox + 205, oy - 260), (ox + 215, oy - 360)], 2.5, wobble=0)  # fusion
    page.ellipse(*tp, 5, 5, 2, fill=(20, 20, 25))
    page.text(ox + 40, oy - 280, "Solid", size=20)
    page.text(ox + 260, oy - 330, "Liquid", size=20)
    page.text(ox + 330, oy - 100, "Gas", size=20)
    finish(page)
    case("dia_phase_star_triple", page, "where is the triple point? star it", {
        "types": {"required": ["star"]},
        "points": [point(["star"], pad(Page.norm(tp[0] - 12, tp[1] - 12, tp[0] + 12, tp[1] + 12), 0.03))],
    }, category="diagram")


# ============================================================ worksheets

def blank_box(page: Page, x, y, w=120, h=40):
    b = page.rect(x, y, w, h, 1.6)
    inner = Page.norm(x, y, x + w, y + h)
    return rnd(inner)


def worksheet_pages():
    page = Page("ws_arith_typed", hand=False)
    title(page, "Warm-up")
    rows = [("1.  7 × 8 =", ["56"]), ("2.  144 ÷ 12 =", ["12"]), ("3.  15% of 80 =", ["12"])]
    boxes = []
    for i, (q, a) in enumerate(rows):
        y = 150 + i * 90
        page.text(80, y, q, size=24)
        boxes.append((blank_box(page, 300, y - 6, 120, 42), a))
    finish(page)
    case("ws_arith_fill", page, "fill in the blanks", {
        "types": {"required": ["fillText"], "forbidden": ["openSidebar"]},
        "fill": [{"box": b, "answers": a} for b, a in boxes],
    }, category="worksheet")
    existing = [{"action": fill(b, a[0]), "question": "fill in the blanks"} for b, a in boxes]
    case("follow_arith_undo", page, "undo that", {
        "types": {"required": ["say"], "forbidden": ["fillText", "highlight", "circle", "label", "star"]},
        "remove": ["m1", "m2", "m3"],
    }, category="followup", existing=existing, history=[
        {"question": "fill in the blanks", "actions": [say("Filled in all three answers.")] + [e["action"] for e in existing], "created": [0, 1, 2]},
    ])

    page = Page("ws_balance_hand", hand=True, paper="lined")
    title(page, "Balancing equations", y=40)
    y = 150
    b1 = blank_box(page, 80, y, 50, 44)
    page.text(140, y + 4, "H₂  +", size=26)
    b2 = blank_box(page, 230, y, 50, 44)
    page.text(290, y + 4, "O₂", size=26)
    page.arrow(350, y + 22, 420, y + 22, 2)
    b3 = blank_box(page, 440, y, 50, 44)
    page.text(500, y + 4, "H₂O", size=26)
    finish(page)
    case("ws_balance_fill", page, "fill in the coefficients", {
        "types": {"required": ["fillText"]},
        "fill": [{"box": b1, "answers": ["2"]}, {"box": b2, "answers": ["1"]}, {"box": b3, "answers": ["2"]}],
    }, category="worksheet")

    page = Page("ws_calculus_typed", hand=False)
    title(page, "Quiz 2 — derivatives & integrals")
    rows = [("a)  d/dx ( x³ ) =", ["3x^2", "3x²", "3*x^2", "3x**2", "3*x**2"]),
            ("b)  d/dx ( sin x ) =", ["cos x", "cosx", "cos(x)"]),
            ("c)  ∫ 2x dx =", ["x^2 + C", "x² + C", "x^2+c", "x**2 + C"])]
    boxes = []
    for i, (q, a) in enumerate(rows):
        y = 150 + i * 90
        page.text(80, y, q, size=24)
        boxes.append((blank_box(page, 330, y - 8, 170, 44), a))
    finish(page)
    case("ws_calculus_solve", page, "solve these", {
        "types": {"required": ["fillText"]},
        "fill": [{"box": b, "answers": a} for b, a in boxes],
    }, category="worksheet")

    page = Page("ws_units_hand", hand=True, paper="lined")
    title(page, "Unit conversions", y=40)
    rows = [("1 km =", ["1000", "1,000"], "m"), ("2.5 h =", ["150"], "min"), ("500 mg =", ["0.5", ".5"], "g")]
    boxes = []
    for i, (q, a, unit) in enumerate(rows):
        y = 150 + i * 96
        page.text(80, y, q, size=26)
        boxes.append((blank_box(page, 230, y - 4, 130, 46), a))
        page.text(375, y, unit, size=26)
    finish(page)
    case("ws_units_fill", page, "can you fill these in", {
        "types": {"required": ["fillText"]},
        "fill": [{"box": b, "answers": a} for b, a in boxes],
    }, category="worksheet")

    page = Page("ws_chem_typed", hand=False)
    title(page, "Chem review")
    page.text(80, 150, "1. Molar mass of H2O:", size=22)
    c1 = blank_box(page, 330, 142, 110, 42)
    page.text(450, 150, "g/mol", size=22)
    q2 = page.text(80, 250, "2. Number of protons in a carbon atom:", size=22)
    c2 = blank_box(page, 500, 242, 90, 42)
    page.text(80, 350, "3. Charge of an electron:", size=22)
    blank_box(page, 360, 342, 110, 42)
    finish(page)
    case("ws_chem_lasso_one", page, "fill this one in", {
        "types": {"required": ["fillText"]},
        "fill": [{"box": c2, "answers": ["6"]}],
        "noFillIn": [c1],
    }, category="worksheet", lasso=pad(union(q2, c2), 0.015))

    page = Page("ws_physics_hand", hand=True, paper="lined")
    title(page, "Physics practice", y=40)
    page.text(70, 130, "1) F = ma,  m = 2 kg,  a = 3 m/s²", size=22)
    page.text(90, 180, "F =", size=24)
    p1 = blank_box(page, 140, 172, 110, 44)
    page.text(262, 180, "N", size=24)
    page.text(70, 290, "2) v = d / t,  d = 100 m,  t = 20 s", size=22)
    page.text(90, 340, "v =", size=24)
    p2 = blank_box(page, 140, 332, 110, 44)
    page.text(262, 340, "m/s", size=24)
    finish(page)
    case("follow_physics_next", page, "now do the second one too", {
        "types": {"required": ["fillText"]},
        "fill": [{"box": p2, "answers": ["5"]}],
        "remove": [],
    }, category="followup", existing=[{"action": fill(p1, "6"), "question": "fill in the first one"}],
        history=[{"question": "fill in the first one", "actions": [say("F = 2 × 3 = 6 N."), fill(p1, "6")], "created": [0]}])

    page = Page("ws_vocab_typed", hand=False)
    title(page, "Biology vocabulary")
    page.text(80, 150, "The powerhouse of the cell is the", size=21)
    v1 = page.line(420, 172, 600, 172, 1.5)
    page.text(605, 150, ".", size=21)
    page.text(80, 240, "Photosynthesis takes place in the", size=21)
    v2 = page.line(418, 262, 600, 262, 1.5)
    page.text(605, 240, ".", size=21)
    finish(page)
    case("ws_vocab_fill", page, "fill in the blanks", {
        "types": {"required": ["fillText"]},
        "fill": [{"box": rnd(Page.norm(420, 140, 600, 176)), "answers": ["mitochondria", "mitochondrion"], "minIoU": 0.2},
                 {"box": rnd(Page.norm(418, 230, 600, 266)), "answers": ["chloroplast", "chloroplasts"], "minIoU": 0.2}],
    }, category="worksheet")

    page = Page("ws_mcq_hand", hand=True)
    title(page, "Quiz: periodic table", y=50)
    page.text(70, 140, "Which of these is a noble gas?", size=24)
    opts = {}
    for i, o in enumerate(["(a) O", "(b) Ne", "(c) Na", "(d) Cl"]):
        opts[o] = page.text(100 + i * 150, 200, o, size=24)
    finish(page)
    case("ws_mcq_circle", page, "circle the right answer", {
        "types": {"required": ["circle"]},
        "targets": [target(["circle"], opts["(b) Ne"], min_iou=0.3)],
    }, category="worksheet")


# ============================================================ notes

def notes_pages():
    page = Page("notes_equilibrium_typed", hand=False)
    t = page.text(72, 60, "Lecture 7: Chemical Equilibrium", size=30, bold=True)
    d1 = page.text(72, 140, "Le Chatelier's principle: a system at equilibrium shifts to", size=19)
    d2 = page.text(72, 168, "oppose any change in concentration, temperature or pressure.", size=19)
    page.text(72, 230, "Equilibrium constant:  K = [C]^c [D]^d / [A]^a [B]^b", size=19)
    page.text(72, 290, "• Adding reactant shifts the equilibrium to the right.", size=19)
    page.text(72, 322, "• Raising T favors the endothermic direction.", size=19)
    page.text(72, 354, "• A catalyst does not change K.", size=19)
    finish(page)
    case("notes_title", page, "highlight the title of this page", {
        "types": {"required": ["highlight"], "forbidden": ["circle", "openSidebar"]},
        "targets": [target(["highlight"], t)],
    }, category="notes", pdf_text=True)
    definition = union(d1, d2)
    case("notes_definition", page, "highlight the definition of Le Chatelier's principle", {
        "types": {"required": ["highlight"], "forbidden": ["openSidebar"]},
        "targets": [target(["highlight"], definition, d1)],
    }, category="notes", pdf_text=True)
    case("follow_equilibrium_why", page, "now explain why", {
        "types": {"required": ["openSidebar"], "forbidden": ["fillText", "insertGraphCard"]},
        "sidebarKeywords": ["equilibrium"],
        "remove": [],
    }, category="followup", pdf_text=True, existing=[{"action": hl(pad(definition, 0.005)), "question": "highlight the definition of Le Chatelier's principle"}],
        history=[{"question": "highlight the definition of Le Chatelier's principle", "actions": [say("Highlighted Le Chatelier's principle."), hl(pad(definition, 0.005))], "created": [0]}])

    page = Page("notes_kinematics_hand", hand=True, paper="lined")
    title(page, "Kinematics (const. a)", y=40)
    e1 = page.text(80, 130, "v = u + at", size=28)
    e2 = page.text(80, 194, "s = ut + ½at²", size=28)
    e3 = page.text(80, 258, "v² = u² + 2as", size=28)
    page.text(80, 330, "u = initial velocity, s = displacement", size=20)
    finish(page)
    case("notes_kinematics_no_time", page, "which equation doesn't have time in it? highlight it", {
        "types": {"required": ["highlight"]},
        "targets": [target(["highlight"], e3)],
    }, category="notes")
    case("follow_kinematics_other_one", page, "no, the other one — the one without t", {
        "types": {"required": ["highlight"]},
        "targets": [target(["highlight"], e3)],
        "remove": ["m1"],
    }, category="followup", existing=[{"action": hl(pad(e2, 0.005)), "question": "highlight the equation without time"}],
        history=[{"question": "highlight the equation without time", "actions": [say("Highlighted it."), hl(pad(e2, 0.005))], "created": [0]}])

    page = Page("notes_thermo_typed", hand=False)
    title(page, "Gibbs free energy")
    g = page.text(72, 140, "ΔG = ΔH − TΔS", size=26)
    s_line = page.text(72, 200, "Entropy S is measured in J/K; enthalpy H in kJ/mol.", size=19)
    page.text(72, 240, "ΔG < 0 : spontaneous      ΔG > 0 : non-spontaneous", size=19)
    finish(page)
    # "J/K" sits inside the line: estimate its box by character position (text is typed Arial).
    full = "Entropy S is measured in J/K; enthalpy H in kJ/mol."
    pre = page.text_width("Entropy S is measured in ", 19)
    jk = page.text_width("J/K", 19)
    x0 = 72 / PAGE_W
    jk_box = [round(s_line[0] + pre / PAGE_W - (s_line[0] - x0), 4), s_line[1], round(jk / PAGE_W, 4), s_line[3]]
    case("notes_thermo_units", page, "highlight the units of entropy", {
        "types": {"required": ["highlight"]},
        "targets": [target(["highlight"], jk_box, min_iou=0.3)],
    }, category="notes", pdf_text=True)
    case("notes_thermo_quick", page, "what does a negative ΔG mean?", {
        "types": {"required": ["say"], "forbidden": ["fillText", "insertGraphCard", "insertMoleculeCard"]},
        "sayKeywords": ["spontaneous"],
    }, category="notes", pdf_text=True)

    page = Page("notes_mitosis_hand", hand=True, paper="lined")
    title(page, "Mitosis", y=40)
    phases = {}
    for i, (name, desc) in enumerate([("Prophase", "chromosomes condense"), ("Metaphase", "chromosomes line up in the middle"),
                                       ("Anaphase", "sister chromatids pulled apart"), ("Telophase", "two nuclei form")]):
        y = 130 + i * 64
        nb = page.text(80, y, f"{i + 1}. {name} -", size=24)
        db = page.text(80 + page.text_width(f"{i + 1}. {name} - ", 24) + 6, y + 2, desc, size=22)
        phases[name] = (nb, db)
    finish(page)
    nb, db = phases["Metaphase"]
    case("notes_mitosis_lineup", page, "highlight the phase where the chromosomes line up", {
        "types": {"required": ["highlight"]},
        "targets": [target(["highlight"], nb, union(nb, db), min_iou=0.3)],
    }, category="notes")
    case("notes_mitosis_explain", page, "explain the difference between anaphase and telophase", {
        "types": {"required": ["openSidebar"], "forbidden": ["fillText"]},
        "sidebarKeywords": ["anaphase", "telophase"],
    }, category="notes")


def main():
    molecule_pages()
    function_pages()
    diagram_pages()
    worksheet_pages()
    notes_pages()
    pages = sorted({c["page"] for c in CASES})
    (ROOT / "cases.json").write_text(json.dumps({"version": 1, "pages": pages, "cases": CASES}, indent=1, ensure_ascii=False))
    print(f"{len(pages)} pages, {len(CASES)} cases")


if __name__ == "__main__":
    main()
