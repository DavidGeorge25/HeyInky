// Hey Inky chemistry core. Pure functions over an initialized RDKit MinimalLib module.
// Runs in the app's headless WKWebView (engine.html) and in Node for quick checks.
//
//   const core = InkyChemCore.create(RDKit, functionalGroupLibrary)
//   core.analyze({ smiles, highlightGroups, starGroups, bondLength }) -> plain JSON object
//
// Every highlight comes from an RDKit substructure match; nothing here trusts a caller's
// claim about which atoms belong to a group.
(function (root) {
  'use strict';

  const SYMBOLS = ['*', 'H', 'He', 'Li', 'Be', 'B', 'C', 'N', 'O', 'F', 'Ne', 'Na', 'Mg', 'Al', 'Si', 'P', 'S', 'Cl', 'Ar',
    'K', 'Ca', 'Sc', 'Ti', 'V', 'Cr', 'Mn', 'Fe', 'Co', 'Ni', 'Cu', 'Zn', 'Ga', 'Ge', 'As', 'Se', 'Br', 'Kr', 'Rb', 'Sr',
    'Y', 'Zr', 'Nb', 'Mo', 'Tc', 'Ru', 'Rh', 'Pd', 'Ag', 'Cd', 'In', 'Sn', 'Sb', 'Te', 'I', 'Xe', 'Cs', 'Ba', 'La', 'Ce',
    'Pr', 'Nd', 'Pm', 'Sm', 'Eu', 'Gd', 'Tb', 'Dy', 'Ho', 'Er', 'Tm', 'Yb', 'Lu', 'Hf', 'Ta', 'W', 'Re', 'Os', 'Ir', 'Pt',
    'Au', 'Hg', 'Tl', 'Pb', 'Bi', 'Po', 'At', 'Rn', 'Fr', 'Ra', 'Ac', 'Th', 'Pa', 'U', 'Np', 'Pu', 'Am', 'Cm', 'Bk', 'Cf',
    'Es', 'Fm', 'Md', 'No', 'Lr', 'Rf', 'Db', 'Sg', 'Bh', 'Hs', 'Mt', 'Ds', 'Rg', 'Cn', 'Nh', 'Fl', 'Mc', 'Lv', 'Ts', 'Og'];

  // Calm heteroatom colors (RGB 0–1); carbon/bonds stay black and are re-inked natively.
  const PALETTE = {
    '-1': [0, 0, 0], '7': [0.20, 0.38, 0.82], '8': [0.84, 0.25, 0.21], '9': [0.15, 0.58, 0.33],
    '15': [0.85, 0.45, 0.0], '16': [0.72, 0.56, 0.0], '17': [0.15, 0.58, 0.33], '35': [0.62, 0.30, 0.17],
    '53': [0.47, 0.25, 0.63], '5': [0.80, 0.45, 0.45], '14': [0.45, 0.45, 0.45],
  };

  function create(RDKit, library) {
    try { RDKit.prefer_coordgen(true); } catch (_) { /* older builds */ }

    const groups = library.groups.map((g) => ({
      ...g,
      core: g.core || null,
      supersedes: g.supersedes || [],
      queries: g.smarts.map((s) => {
        const q = RDKit.get_qmol(s);
        if (!q || !q.is_valid()) throw new Error(`Invalid SMARTS in library for ${g.id}: ${s}`);
        return q;
      }),
    }));
    const byKey = new Map();
    for (const g of groups) {
      byKey.set(normalizeKey(g.id), g);
      byKey.set(normalizeKey(g.name), g);
    }
    // Loose aliases a model (or a student) might use instead of SMARTS.
    const aliases = {
      alcohol: ['alcohol1', 'alcohol2', 'alcohol3'], hydroxyl: ['alcohol1', 'alcohol2', 'alcohol3', 'phenol'],
      amine: ['amine1', 'amine2', 'amine3'], amide: ['amide1', 'amide2', 'amide3', 'lactam'],
      carbonyl: ['aldehyde', 'ketone'], carboxyl: ['carboxylicAcid'], carboxylate: ['carboxylicAcid'],
      acid: ['carboxylicAcid'], halide: ['alkylHalide', 'arylHalide'], benzene: ['aromaticRing'],
      arene: ['aromaticRing'], aromatic: ['aromaticRing'], phenyl: ['aromaticRing'], thioether: ['sulfide'],
      ketal: ['acetal'], hemiketal: ['hemiacetal'], βlactam: ['lactam'], betalactam: ['lactam'],
    };

    function normalizeKey(s) {
      return String(s).toLowerCase().replace(/[^a-zβ0-9]/g, '').replace(/s$/, '');
    }

    function groupsForKey(text) {
      const key = normalizeKey(text);
      if (!key) return null;
      if (byKey.has(key)) return [byKey.get(key)];
      if (aliases[key]) return aliases[key].map((id) => byKey.get(normalizeKey(id)));
      return null;
    }

    function matchQuery(mol, qmol) {
      const raw = mol.get_substruct_matches(qmol);
      const parsed = raw ? JSON.parse(raw) : [];
      // A single match comes back as an object in some builds.
      return Array.isArray(parsed) ? parsed : (parsed.atoms ? [parsed] : []);
    }

    function bondsBetween(atoms, bonds) {
      const set = new Set(atoms);
      const out = [];
      bonds.forEach((b, i) => { if (set.has(b.a) && set.has(b.b)) out.push(i); });
      return out;
    }

    function detectGroups(mol, bonds) {
      const found = [];
      for (const g of groups) {
        const seen = new Set();
        const matches = [];
        for (const q of g.queries) {
          for (const m of matchQuery(mol, q)) {
            const core = g.core ? g.core.map((i) => m.atoms[i]).filter((a) => a !== undefined) : m.atoms.slice();
            const key = core.slice().sort((x, y) => x - y).join(',');
            if (seen.has(key)) continue;
            seen.add(key);
            matches.push({ atoms: core, bonds: bondsBetween(core, bonds), all: m.atoms });
          }
        }
        if (matches.length) found.push({ group: g, matches });
      }
      // Supersession: a lactone hides the ester it is made of, a hemiacetal hides its alcohol, …
      const byId = new Map(found.map((f) => [f.group.id, f]));
      for (const f of found) {
        for (const loserId of f.group.supersedes) {
          const loser = byId.get(loserId);
          if (!loser) continue;
          loser.matches = loser.matches.filter((lm) =>
            !f.matches.some((wm) => lm.atoms.every((a) => wm.all.includes(a))));
        }
      }
      return found
        .filter((f) => f.matches.length)
        .map((f) => ({
          id: f.group.id,
          name: f.group.name,
          matches: mergeOverlapping(f.matches).map((atoms) => ({ atoms, bonds: bondsBetween(atoms, bonds) })),
        }));
    }

    // Matches of one group that share atoms are one instance (urea's two amide matches,
    // CCl3, a fused aromatic system), so each instance gets one highlight and one label.
    function mergeOverlapping(matches) {
      const sets = [];
      for (const m of matches) {
        let merged = new Set(m.atoms);
        for (let i = sets.length - 1; i >= 0; i--) {
          if ([...sets[i]].some((a) => merged.has(a))) {
            merged = new Set([...sets[i], ...merged]);
            sets.splice(i, 1);
          }
        }
        sets.push(merged);
      }
      return sets.map((s) => [...s].sort((x, y) => x - y));
    }

    // A caller pattern is a library id/name/alias or a SMARTS. Returns its matches and the
    // library group that best explains them (for naming), never trusting the caller's atoms.
    function resolvePatterns(mol, bonds, patterns, detected) {
      return (patterns || []).map((pattern) => {
        const named = groupsForKey(pattern);
        if (named) {
          const ids = new Set(named.map((g) => g.id));
          const matches = detected.filter((d) => ids.has(d.id)).flatMap((d) =>
            d.matches.map((m) => ({ ...m, groupId: d.id })));
          return { pattern, valid: true, groupIds: [...ids], matches };
        }
        let q = null;
        try { q = RDKit.get_qmol(pattern); } catch (_) { q = null; }
        if (!q || !q.is_valid()) {
          if (q) q.delete();
          return { pattern, valid: false, groupIds: [], matches: [] };
        }
        const seen = new Set();
        const matches = [];
        for (const m of matchQuery(mol, q)) {
          const key = m.atoms.slice().sort((x, y) => x - y).join(',');
          if (seen.has(key)) continue;
          seen.add(key);
          matches.push({ atoms: m.atoms, bonds: bondsBetween(m.atoms, bonds), groupId: bestGroup(m.atoms, detected) });
        }
        q.delete();
        return { pattern, valid: true, groupIds: [...new Set(matches.map((m) => m.groupId).filter(Boolean))], matches };
      });
    }

    function bestGroup(atoms, detected) {
      let best = null, bestScore = 0;
      const set = new Set(atoms);
      for (const d of detected) {
        for (const m of d.matches) {
          const overlap = m.atoms.filter((a) => set.has(a)).length;
          // Jaccard similarity; ties go to the more specific (earlier) library group.
          const score = overlap / (set.size + m.atoms.length - overlap);
          if (score > bestScore + 1e-9) { best = d.id; bestScore = score; }
        }
      }
      return bestScore >= 0.5 ? best : null;
    }

    function parseSVG(svg) {
      const size = svg.match(/<svg[^>]*width='([\d.]+)px'[^>]*height='([\d.]+)px'/);
      const width = size ? parseFloat(size[1]) : 0;
      const height = size ? parseFloat(size[2]) : 0;
      const prims = [];
      const re = /<path\b([^>]*?)\/?>/g;
      let m;
      while ((m = re.exec(svg))) {
        const attrs = {};
        const are = /([\w-]+)='([^']*)'/g;
        let a;
        while ((a = are.exec(m[1]))) attrs[a[1]] = a[2];
        if (!attrs.d) continue;
        const style = {};
        (attrs.style || '').split(';').forEach((kv) => {
          const i = kv.indexOf(':');
          if (i > 0) style[kv.slice(0, i).trim()] = kv.slice(i + 1).trim();
        });
        const fill = attrs.fill || style.fill;
        const stroke = style.stroke;
        prims.push({
          d: attrs.d.replace(/\s+/g, ' ').trim(),
          cls: attrs.class || '',
          fill: fill && fill !== 'none' ? fill : null,
          stroke: stroke && stroke !== 'none' ? stroke : null,
          lineWidth: style['stroke-width'] ? parseFloat(style['stroke-width']) : 0,
          dashed: !!style['stroke-dasharray'] && style['stroke-dasharray'] !== 'none',
        });
      }
      return { width, height, primitives: prims };
    }

    function formulaOf(atoms) {
      const counts = {};
      for (const at of atoms) {
        const sym = SYMBOLS[at.z] || '*';
        counts[sym] = (counts[sym] || 0) + 1;
        if (at.impHs) counts.H = (counts.H || 0) + at.impHs;
      }
      const order = Object.keys(counts).sort((a, b) => a.localeCompare(b));
      const hill = counts.C ? ['C', 'H', ...order.filter((s) => s !== 'C' && s !== 'H')] : order;
      let f = '';
      for (const s of hill) if (counts[s]) f += s + (counts[s] > 1 ? counts[s] : '');
      return f;
    }

    function analyzeOne(smiles, params) {
      const mol = RDKit.get_mol(smiles);
      if (!mol || !mol.is_valid()) {
        if (mol) mol.delete();
        return { ok: false, input: smiles, error: 'RDKit could not parse this SMILES.' };
      }
      try {
        try { mol.set_new_coords(true); } catch (_) { mol.set_new_coords(); }
        try { mol.normalize_depiction(1); mol.straighten_depiction(); } catch (_) { /* optional */ }
        return depict(mol, smiles, params, true);
      } finally {
        mol.delete();
      }
    }

    // Depiction + analysis of a molecule that already has 2D coordinates.
    function depict(mol, smiles, params, canRelayout) {
      {
        const json = JSON.parse(mol.get_json()).molecules[0];
        const defaults = { z: 6, impHs: 0, chg: 0 };
        const atoms = (json.atoms || []).map((a) => ({ ...defaults, ...a }));
        const bonds = (json.bonds || []).map((b) => ({ a: b.atoms[0], b: b.atoms[1], order: b.bo === undefined ? 1 : b.bo }));
        const drawOptions = {
          width: -1, height: -1,
          fixedBondLength: params.bondLength || 30,
          padding: 0.08,
          bondLineWidth: 2,
          scaleBondWidth: false,
          clearBackground: false,
          returnDrawCoords: true,
          atomColourPalette: PALETTE,
          additionalAtomLabelPadding: 0.08,
        };
        let draw = JSON.parse(mol.get_svg_with_highlights(JSON.stringify(drawOptions)));
        const usable = (d) => d.drawCoords.length === atoms.length && d.drawCoords.every((p) => p && p[0] !== null && p[1] !== null);
        if (!usable(draw) && canRelayout) {
          // CoordGen can't lay out a few edge cases (e.g. [H][H]); RDKit's own depictor can.
          mol.set_new_coords(false);
          draw = JSON.parse(mol.get_svg_with_highlights(JSON.stringify(drawOptions)));
        }
        if (!usable(draw)) return { ok: false, input: smiles, error: 'RDKit could not lay out this structure.' };
        const svg = parseSVG(draw.svg);
        const aromatic = new Set();
        const qa = RDKit.get_qmol('[a]');
        for (const m of matchQuery(mol, qa)) m.atoms.forEach((i) => aromatic.add(i));
        qa.delete();
        const detected = detectGroups(mol, bonds);

        let stereo = { CIP_atoms: [], CIP_bonds: [] };
        try { stereo = JSON.parse(mol.get_stereo_tags()); } catch (_) { /* none */ }
        let inchiKey = null;
        try { const inchi = mol.get_inchi(); if (inchi) inchiKey = RDKit.get_inchikey_for_inchi(inchi); } catch (_) { /* optional */ }
        let descriptors = {};
        try { descriptors = JSON.parse(mol.get_descriptors()); } catch (_) { /* optional */ }

        return {
          ok: true,
          input: smiles,
          smiles: mol.get_smiles(),
          formula: formulaOf(atoms),
          charge: atoms.reduce((sum, a) => sum + (a.chg || 0), 0),
          molWeight: descriptors.amw || null,
          inchiKey,
          width: svg.width,
          height: svg.height,
          bondLength: params.bondLength || 30,
          // Bond length as actually drawn (RDKit may shrink some depictions), for schemes that
          // scale every structure to the same bond length.
          drawnBondLength: (() => {
            const ls = bonds.map((b) => Math.hypot(draw.drawCoords[b.a][0] - draw.drawCoords[b.b][0], draw.drawCoords[b.a][1] - draw.drawCoords[b.b][1])).sort((x, y) => x - y);
            return ls.length ? ls[Math.floor(ls.length / 2)] : (params.bondLength || 30);
          })(),
          primitives: svg.primitives,
          atoms: atoms.map((a, i) => ({
            index: i,
            symbol: SYMBOLS[a.z] || '*',
            x: draw.drawCoords[i][0],
            y: draw.drawCoords[i][1],
            charge: a.chg || 0,
            hydrogens: a.impHs || 0,
            aromatic: aromatic.has(i),
          })),
          bonds: bonds.map((b, i) => ({ index: i, a: b.a, b: b.b, order: b.order })),
          groups: detected,
          highlights: resolvePatterns(mol, bonds, params.highlightGroups, detected),
          stars: resolvePatterns(mol, bonds, params.starGroups, detected),
          // Only assigned descriptors; RDKit reports unspecified centers as "(?)".
          stereocenters: (stereo.CIP_atoms || []).map(([atom, label]) => ({ atom, label: String(label).replace(/[()]/g, '') }))
            .filter((s) => /^[RSrs]$/.test(s.label)),
          stereobonds: (stereo.CIP_bonds || []).map(([a, b, label]) => ({ a, b, label: String(label).replace(/[()]/g, '') }))
            .filter((s) => /^[EZ]$/.test(s.label)),
        };
      }
    }


    // ---- Recognized drawings -------------------------------------------------------------

    // A bond graph read from a drawing (atoms in drawing order with their 2D positions) as an
    // RDKit molecule: SMILES, hydrogens per atom (same order), and pattern matches. If RDKit
    // rejects it (an atom over its valence, usually a misread double bond), the fewest bond
    // orders are lowered until it accepts, and those bonds are reported.
    function molblockFor(atoms, bonds) {
      const pad = (v, n) => String(v).padStart(n);
      let mb = '\n  InkyRecognizer\n\n' + pad(atoms.length, 3) + pad(bonds.length, 3) + '  0  0  0  0  0  0  0  0999 V2000\n';
      for (const a of atoms) {
        const sym = (!a.symbol || a.symbol === '?') ? '*' : a.symbol;
        const chg = { 0: 0, 1: 3, 2: 2, 3: 1, '-1': 5, '-2': 6, '-3': 7 }[a.charge || 0] || 0;
        mb += pad(Number(a.x).toFixed(4), 10) + pad((-Number(a.y)).toFixed(4), 10) + pad('0.0000', 10) + ' ' + sym.padEnd(3) +
          ' 0' + pad(chg, 3) + '  0  0  0  0  0  0  0  0  0  0\n';
      }
      for (const b of bonds) mb += pad(b.a + 1, 3) + pad(b.b + 1, 3) + pad(b.order, 3) + '  0\n';
      return mb + 'M  END\n';
    }

    function fromGraph(params) {
      const atoms = params.atoms || [], bonds = params.bonds || [];
      if (!atoms.length) return { ok: false, error: 'No atoms.' };
      const tryBuild = (bs) => {
        const mol = RDKit.get_mol(molblockFor(atoms, bs));
        if (mol && mol.is_valid()) return mol;
        if (mol) mol.delete();
        return null;
      };
      let used = bonds.map((b) => ({ ...b }));
      let mol = tryBuild(used);
      const lowered = [];
      if (!mol) {
        // Lower one multiple bond at a time, then pairs.
        const multi = used.map((b, i) => (b.order > 1 ? i : -1)).filter((i) => i >= 0);
        outer: for (const i of multi) {
          const trial = used.map((b, k) => (k === i ? { ...b, order: b.order - 1 } : b));
          mol = tryBuild(trial);
          if (mol) { used = trial; lowered.push(i); break outer; }
        }
        if (!mol) {
          outer2: for (const i of multi) for (const j of multi) {
            if (j <= i) continue;
            const trial = used.map((b, k) => (k === i || k === j ? { ...b, order: b.order - 1 } : b));
            mol = tryBuild(trial);
            if (mol) { used = trial; lowered.push(i, j); break outer2; }
          }
        }
      }
      if (!mol) return { ok: false, error: 'RDKit could not make a valid molecule from the drawing.' };
      try {
        const json = JSON.parse(mol.get_json()).molecules[0];
        const defaults = { z: 6, impHs: 0, chg: 0 };
        const ratoms = (json.atoms || []).map((a) => ({ ...defaults, ...a }));
        const rbonds = (json.bonds || []).map((b) => ({ a: b.atoms[0], b: b.atoms[1], order: b.bo === undefined ? 1 : b.bo }));
        const aromatic = new Set();
        const qa = RDKit.get_qmol('[a]');
        for (const m of matchQuery(mol, qa)) m.atoms.forEach((i) => aromatic.add(i));
        qa.delete();
        const detected = detectGroups(mol, rbonds);
        let stereo = { CIP_atoms: [] };
        try { stereo = JSON.parse(mol.get_stereo_tags()); } catch (_) { /* none */ }
        let inchiKey = null;
        try { const inchi = mol.get_inchi(); if (inchi) inchiKey = RDKit.get_inchikey_for_inchi(inchi); } catch (_) { /* optional */ }
        let molWeight = null;
        try { molWeight = JSON.parse(mol.get_descriptors()).amw || null; } catch (_) { /* optional */ }
        const ext = (json.extensions || []).find((e) => e.name === 'rdkitRepresentation') || {};
        return {
          ok: true,
          smiles: mol.get_smiles(),
          formula: formulaOf(ratoms),
          molWeight,
          inchiKey,
          // Every stereocenter, assigned (R/S) or not ("?": a flat drawing doesn't say).
          stereocenters: (stereo.CIP_atoms || []).map(([atom, label]) => ({ atom, label: String(label).replace(/[()]/g, '') })),
          rings: ext.atomRings || [],
          atoms: ratoms.map((a, i) => ({ index: i, symbol: SYMBOLS[a.z] || '*', hydrogens: a.impHs || 0, charge: a.chg || 0, aromatic: aromatic.has(i) })),
          loweredBonds: lowered,
          groups: detected.map((g) => ({ id: g.id, name: g.name, matches: g.matches })),
          highlights: resolvePatterns(mol, rbonds, params.highlightGroups || [], detected),
        };
      } finally {
        mol.delete();
      }
    }

    // ---- Schemes ---------------------------------------------------------------------------

    // Atom index by atom-map number, read from the V3000 molblock's aamap field.
    function atomMaps(mol) {
      const maps = {};
      let mb = '';
      try { mb = mol.get_v3Kmolblock(); } catch (_) { return maps; }
      let inAtoms = false, index = 0;
      for (const line of mb.split('\n')) {
        if (line.includes('BEGIN ATOM')) { inAtoms = true; continue; }
        if (line.includes('END ATOM')) break;
        if (!inAtoms) continue;
        // "M  V30 <idx> <symbol> <x> <y> <z> <aamap> [props]"
        const tokens = line.trim().split(/\s+/);
        const map = parseInt(tokens[7], 10);
        if (map > 0) maps[String(map)] = index;
        index += 1;
      }
      return maps;
    }

    // A template with the same skeleton but any bond orders and no charges, so every resonance
    // form (and most steps of a mechanism) lines up with the first structure.
    function genericTemplate(mol) {
      const lines = mol.get_molblock().split('\n');
      const na = parseInt(lines[3].slice(0, 3), 10), nb = parseInt(lines[3].slice(3, 6), 10);
      for (let i = 4 + na; i < 4 + na + nb; i++) lines[i] = lines[i].slice(0, 6) + '  8' + lines[i].slice(9);
      const generic = lines.filter((l) => !l.startsWith('M  CHG') && !l.startsWith('M  RAD')).join('\n');
      return RDKit.get_mol(generic, JSON.stringify({ sanitize: false }));
    }

    // Adds the hydrogens RDKit finds missing (radical electrons) to bracketed atoms, by SMILES token.
    function withoutRadicals(smiles, details) {
      const mol = RDKit.get_mol(smiles, details);
      if (!mol || !mol.is_valid()) { if (mol) mol.delete(); return smiles; }
      const atoms = JSON.parse(mol.get_json()).molecules[0].atoms || [];
      mol.delete();
      const radicals = atoms.map((a) => a.nRad || 0);
      if (!radicals.some((r) => r > 0)) return smiles;
      let k = -1;
      return smiles.replace(/\[[^\]]+\]|Br|Cl|[BCNOPSFI]|[bcnops]/g, (token) => {
        k += 1;
        const n = radicals[k] || 0;
        if (!n || token[0] !== '[') return token;
        const m = token.match(/^\[(\d*)([A-Z][a-z]?|[a-z]{1,2})(@*)(?:H(\d*))?(.*)\]$/);
        if (!m) return token;
        const h = (m[4] !== undefined ? (m[4] === '' ? 1 : parseInt(m[4], 10)) : 0) + n;
        return '[' + m[1] + m[2] + m[3] + 'H' + (h > 1 ? h : '') + m[5] + ']';
      });
    }

    function scheme(params) {
      const steps = params.steps || [];
      const results = [];
      let template = null;
      try {
        for (const raw of steps) {
          const details = JSON.stringify({ setAromaticity: false });
          // Atoms bracketed only to carry a map number ("[C:3]", "[C-:3]") have no H's in SMILES and
          // would be drawn as radicals; unless the scheme is about radicals, give them their H's.
          const smiles = params.keepRadicals ? String(raw || '').trim() : withoutRadicals(String(raw || '').trim(), details);
          const mapped = RDKit.get_mol(smiles, details);
          if (!mapped || !mapped.is_valid()) {
            if (mapped) mapped.delete();
            results.push({ ok: false, input: smiles, error: 'RDKit could not parse this SMILES.', maps: {} });
            continue;
          }
          const maps = atomMaps(mapped);
          mapped.delete();
          // Same SMILES without map numbers: identical atom order, no "O:1" labels in the drawing.
          const plain = smiles.replace(/:(\d+)\]/g, ']');
          const mol = RDKit.get_mol(plain, details);
          if (!mol || !mol.is_valid()) {
            if (mol) mol.delete();
            results.push({ ok: false, input: smiles, error: 'RDKit could not parse this SMILES.', maps: {} });
            continue;
          }
          try {
            let aligned = false;
            if (template) {
              try {
                const r = mol.generate_aligned_coords(template, JSON.stringify({ useCoordGen: true, acceptFailure: false }));
                aligned = !!r && r !== '{}' && r !== '';
              } catch (_) { aligned = false; }
            }
            if (!aligned) {
              try { mol.set_new_coords(true); } catch (_) { mol.set_new_coords(); }
              try { mol.normalize_depiction(1); mol.straighten_depiction(); } catch (_) { /* optional */ }
              if (!template) template = genericTemplate(mol);
            }
            const d = depict(mol, plain, params, false);
            results.push({ ...d, input: smiles, maps, aligned });
          } finally {
            mol.delete();
          }
        }
      } finally {
        if (template) template.delete();
      }
      return { ok: results.length > 0 && results.every((r) => r.ok), steps: results, error: (results.find((r) => !r.ok) || {}).error || null };
    }

    // `smiles` may be a reaction ("A.B>>C" or "A>reagent>C"): each species is depicted on its own.
    function analyze(params) {
      const text = String(params.smiles || '').trim();
      if (!text) return { ok: false, input: text, error: 'No SMILES given.', molecules: [], arrowAfter: null, agents: [] };
      if (text.includes('>')) {
        const parts = text.split('>');
        if (parts.length !== 3) return { ok: false, input: text, error: 'A reaction needs the form reactants>>products.', molecules: [], arrowAfter: null, agents: [] };
        const species = (s) => s.split('.').map((x) => x.trim()).filter(Boolean);
        const reactants = species(parts[0]).map((s) => analyzeOne(s, params));
        const products = species(parts[2]).map((s) => analyzeOne(s, params));
        const molecules = [...reactants, ...products];
        const failed = molecules.find((m) => !m.ok);
        const ok = !failed && reactants.length > 0 && products.length > 0;
        return {
          ok,
          input: text,
          error: failed ? failed.error : (ok ? null : 'A reaction needs reactants and products.'),
          molecules: ok ? molecules : [],
          arrowAfter: reactants.length,
          agents: species(parts[1]),
        };
      }
      const one = analyzeOne(text, params);
      return { ok: one.ok, input: text, error: one.ok ? null : one.error, molecules: one.ok ? [one] : [], arrowAfter: null, agents: [] };
    }

    return { analyze, fromGraph, scheme, library: groups.map(({ queries, ...g }) => g), version: RDKit.version() };
  }

  const api = { create };
  root.InkyChemCore = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
