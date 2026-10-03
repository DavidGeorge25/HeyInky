// Hey Inky graph card — JSXGraph board driven by Swift (GraphWebController).
//
// Safety: expressions arrive as *expression trees* (JSON data) produced by the Swift parser,
// and are interpreted here with a fixed function table. Nothing is ever passed to eval,
// new Function or JessieCode, and all text is rendered as plain SVG text.
(function () {
  'use strict';

  function post(message) {
    try { window.webkit.messageHandlers.inky.postMessage(message); } catch (e) { /* not in the app */ }
  }

  // ---------------------------------------------------------------------------------------
  // Expression interpreter (mirrors GraphExpr.evaluate in Swift)

  function powReal(a, b) {
    if (a < 0 && isFinite(b) && Math.round(b) !== b) {
      var qs = [3, 5, 7, 9];
      for (var k = 0; k < qs.length; k++) {
        var q = qs[k], p = b * q;
        if (Math.round(p) === p && Math.abs(p) < 1e6) {
          return Math.pow(-Math.pow(-a, 1 / q), Math.round(p));
        }
      }
    }
    return Math.pow(a, b);
  }

  function nanAware(fn) {
    return function () {
      for (var i = 0; i < arguments.length; i++) { if (arguments[i] !== arguments[i]) { return NaN; } }
      return fn.apply(null, arguments);
    };
  }

  var FUNCTIONS = Object.freeze({
    sin: Math.sin, cos: Math.cos, tan: Math.tan, asin: Math.asin, acos: Math.acos, atan: Math.atan,
    atan2: Math.atan2, sinh: Math.sinh, cosh: Math.cosh, tanh: Math.tanh, asinh: Math.asinh,
    acosh: Math.acosh, atanh: Math.atanh,
    sec: function (x) { return 1 / Math.cos(x); },
    csc: function (x) { return 1 / Math.sin(x); },
    cot: function (x) { return 1 / Math.tan(x); },
    exp: Math.exp, expm1: Math.expm1, log: Math.log, ln: Math.log, log10: Math.log10, log2: Math.log2,
    log1p: Math.log1p, sqrt: Math.sqrt, cbrt: Math.cbrt, abs: Math.abs, floor: Math.floor,
    ceil: Math.ceil, round: Math.round, trunc: Math.trunc, sign: Math.sign,
    min: nanAware(Math.min), max: nanAware(Math.max), pow: powReal, hypot: Math.hypot
  });

  function truth(v) { return v === v && v !== 0; }

  var BINARY = Object.freeze({
    '+': function (a, b) { return a + b; },
    '-': function (a, b) { return a - b; },
    '*': function (a, b) { return a * b; },
    '/': function (a, b) { return a / b; },
    '^': powReal,
    '%': function (a, b) { return a % b; },
    '<': function (a, b) { return a < b ? 1 : 0; },
    '>': function (a, b) { return a > b ? 1 : 0; },
    '<=': function (a, b) { return a <= b ? 1 : 0; },
    '>=': function (a, b) { return a >= b ? 1 : 0; },
    '==': function (a, b) { return a === b ? 1 : 0; },
    '!=': function (a, b) { return a !== b ? 1 : 0; }
  });

  // Compiles a tree into a closure (x, params) -> number. Unknown nodes throw.
  function compile(node) {
    if (!Array.isArray(node)) { throw new Error('bad expression'); }
    switch (node[0]) {
      case 'n': { var v = Number(node[1]); return function () { return v; }; }
      case 'x': return function (x) { return x; };
      case 'p': { var i = node[1] | 0; return function (x, p) { return p[i]; }; }
      case 'neg': { var e = compile(node[1]); return function (x, p) { return -e(x, p); }; }
      case 'not': { var n = compile(node[1]); return function (x, p) { return truth(n(x, p)) ? 0 : 1; }; }
      case 'b': {
        var op = node[1], l = compile(node[2]), r = compile(node[3]);
        if (op === '&&') { return function (x, p) { return truth(l(x, p)) ? (truth(r(x, p)) ? 1 : 0) : 0; }; }
        if (op === '||') { return function (x, p) { return truth(l(x, p)) ? 1 : (truth(r(x, p)) ? 1 : 0); }; }
        if (!Object.prototype.hasOwnProperty.call(BINARY, op)) { throw new Error('bad operator'); }
        var f = BINARY[op];
        return function (x, p) { return f(l(x, p), r(x, p)); };
      }
      case 'f': {
        var name = node[1];
        if (!Object.prototype.hasOwnProperty.call(FUNCTIONS, name)) { throw new Error('bad function'); }
        var fn = FUNCTIONS[name], args = node[2].map(compile);
        if (args.length === 1) { var a0 = args[0]; return function (x, p) { return fn(a0(x, p)); }; }
        if (args.length === 2) { var b0 = args[0], b1 = args[1]; return function (x, p) { return fn(b0(x, p), b1(x, p)); }; }
        return function (x, p) { return fn.apply(null, args.map(function (a) { return a(x, p); })); };
      }
      case '?': {
        var c = compile(node[1]), t = compile(node[2]), o = compile(node[3]);
        return function (x, p) { return truth(c(x, p)) ? t(x, p) : o(x, p); };
      }
      default: throw new Error('bad expression');
    }
  }

  // ---------------------------------------------------------------------------------------
  // Board

  JXG.Options.text.display = 'internal';
  JXG.Options.text.parse = false;
  JXG.Options.text.useMathJax = false;
  JXG.Options.text.useKatex = false;
  JXG.Options.label.display = 'internal';
  JXG.Options.label.parse = false;
  JXG.Options.infobox.display = 'internal';

  var state = {
    board: null,
    scene: null,
    params: [],
    fns: [],
    curves: [],
    overlay: [],     // asymptotes + features (rebuilt on update)
    points: [],
    downCurve: null,
    downAt: null,
    viewTimer: null
  };

  function px(v) { return v * (state.scene ? state.scene.scale || 1 : 1); }

  function rebuildBoard(scene) {
    if (state.board) { JXG.JSXGraph.freeBoard(state.board); state.board = null; }
    var v = scene.view, theme = scene.theme;
    document.body.style.background = theme.background;
    var board = JXG.JSXGraph.initBoard('board', {
      boundingbox: [v.xMin, v.yMax, v.xMax, v.yMin],
      keepaspectratio: false,
      axis: false,
      grid: false,
      showCopyright: false,
      showNavigation: false,
      showInfobox: false,
      pan: { enabled: true, needTwoFingers: false, needShift: false },
      zoom: { enabled: true, wheel: true, needShift: false, pinch: true, factorX: 1.25, factorY: 1.25, min: 1e-4, max: 1e4 },
      browserPan: false,
      resize: { enabled: true, throttle: 40 },
      precision: { touch: 24, mouse: 6, hasPoint: 6 },
      renderer: 'svg'
    });
    state.board = board;

    var tickLabel = { fontSize: px(10), strokeColor: theme.text, highlight: false, display: 'internal', parse: false };
    var axisCommon = {
      strokeColor: theme.axis, strokeWidth: px(1), highlight: false, fixed: true, lastArrow: { type: 2, size: 6 },
      position: 'sticky', withLabel: true
    };
    var ticks = {
      strokeColor: theme.grid, strokeOpacity: 1, majorHeight: -1, minorHeight: 0, minorTicks: 0,
      insertTicks: true, ticksDistance: 1, minTicksDistance: px(42), drawZero: false, highlight: false,
      label: tickLabel
    };
    board.create('axis', [[0, 0], [1, 0]], JXG.merge(axisCommon, {
      name: scene.axes.x, anchor: 'left', ticks: JXG.merge(ticks, { label: JXG.merge(tickLabel, { offset: [-px(3), -px(10)], anchorX: 'middle' }) }),
      label: { position: 'rt', offset: [-px(6), px(12)], anchorX: 'right', fontSize: px(12), strokeColor: theme.text, highlight: false }
    }));
    board.create('axis', [[0, 0], [0, 1]], JXG.merge(axisCommon, {
      name: scene.axes.y, anchor: 'right', ticks: JXG.merge(ticks, { label: JXG.merge(tickLabel, { offset: [-px(6), 0], anchorX: 'right', anchorY: 'middle' }) }),
      label: { position: 'rt', offset: [px(8), -px(4)], anchorX: 'left', fontSize: px(12), strokeColor: theme.text, highlight: false }
    }));

    board.on('boundingbox', function () { reportView(false); });
    board.on('up', onBoardUp);
    return board;
  }

  function reportView(final) {
    if (!state.board) { return; }
    var bb = state.board.getBoundingBox();
    var msg = { type: 'view', xMin: bb[0], yMax: bb[1], xMax: bb[2], yMin: bb[3], final: final };
    clearTimeout(state.viewTimer);
    if (final) { post(msg); return; }
    // Coalesce pinch/pan streams; report the resting view.
    state.viewTimer = setTimeout(function () { msg.final = true; post(msg); }, 250);
  }

  function pointerPosition(e) {
    if (!e) { return null; }
    var t = (e.changedTouches && e.changedTouches[0]) || (e.touches && e.touches[0]) || e;
    return { x: t.clientX, y: t.clientY };
  }

  function onBoardUp(e) {
    var down = state.downCurve, at = state.downAt, up = pointerPosition(e);
    state.downCurve = null;
    if (down === null || !at || !up) { return; }
    if (Math.abs(up.x - at.x) < 8 && Math.abs(up.y - at.y) < 8) {
      post({ type: 'tapFunction', index: down });
    }
  }

  function buildCurves(scene) {
    var board = state.board;
    state.fns = [];
    state.curves = [];
    scene.functions.forEach(function (f) {
      var fn = null;
      if (f.tree) {
        try { fn = compile(f.tree); } catch (err) { post({ type: 'error', message: String(err) }); }
      }
      state.fns.push(fn);
      if (!fn) { return; }
      var curve = board.create('functiongraph', [function (x) { return fn(x, state.params); }], {
        strokeColor: f.color, strokeWidth: px(2.2), highlight: false, fixed: true, name: '', withLabel: false,
        lineCap: 'round'
      });
      curve.on('down', function (e) { state.downCurve = f.index; state.downAt = pointerPosition(e); });
      state.curves.push(curve);
    });
  }

  function escapeText(s) { return String(s == null ? '' : s); }

  function buildOverlay(scene) {
    var board = state.board, theme = scene.theme;
    if (state.overlay.length) { board.removeObject(state.overlay); }
    state.overlay = [];
    var bb = function () { return board.getBoundingBox(); };

    if (scene.options.asymptotes) {
      scene.asymptotes.forEach(function (a) {
        var color = a.color || theme.muted, p1, p2, labelPos;
        if (a.kind === 'vertical') {
          p1 = [a.value, 0]; p2 = [a.value, 1];
          labelPos = [function () { return a.value; }, function () { var b = bb(); return b[1] - (b[1] - b[3]) * 0.06; }];
        } else if (a.kind === 'horizontal') {
          p1 = [0, a.value]; p2 = [1, a.value];
          labelPos = [function () { var b = bb(); return b[2] - (b[2] - b[0]) * 0.02; }, function () { return a.value; }];
        } else {
          p1 = [0, a.value]; p2 = [1, a.value + a.slope];
          labelPos = [function () { var b = bb(); return b[2] - (b[2] - b[0]) * 0.2; },
                      function () { var b = bb(); return a.slope * (b[2] - (b[2] - b[0]) * 0.2) + a.value; }];
        }
        state.overlay.push(board.create('line', [p1, p2], {
          dash: 2, strokeColor: color, strokeOpacity: 0.85, strokeWidth: px(1.3), fixed: true, highlight: false,
          withLabel: false, name: ''
        }));
        state.overlay.push(board.create('text', [labelPos[0], labelPos[1], escapeText(a.label)], {
          fontSize: px(10), strokeColor: color, fixed: true, highlight: false,
          anchorX: a.kind === 'horizontal' ? 'right' : 'left', anchorY: 'bottom', offset: [px(4), px(3)]
        }));
      });
    }

    if (scene.options.features) {
      scene.features.forEach(function (feature) {
        var fcolor = (scene.functions[feature.function] || {}).color || theme.axis;
        var hollow = feature.kind === 'inflection';
        var p = board.create('point', [feature.x, feature.y], {
          name: escapeText(feature.label), withLabel: true, fixed: true, highlight: false, showInfobox: false,
          size: px(feature.kind === 'maximum' || feature.kind === 'minimum' ? 3.2 : 2.6),
          face: 'o', strokeColor: fcolor, strokeWidth: px(1.4), fillColor: hollow ? theme.background : fcolor,
          label: { visible: false, fontSize: px(10), strokeColor: theme.text, offset: [px(6), px(8)], highlight: false }
        });
        // Coordinates appear on tap so the card stays calm.
        p.on('down', function () { p.label.setAttribute({ visible: !p.label.evalVisProp('visible') }); board.update(); });
        state.overlay.push(p);
      });
    }
  }

  function buildPointsAndLabels(scene) {
    var board = state.board, theme = scene.theme;
    state.points = [];
    scene.points.forEach(function (pt, i) {
      var p = board.create('point', [pt.x, pt.y], {
        name: escapeText(pt.label || ''), withLabel: !!pt.label, fixed: !pt.draggable, highlight: false,
        showInfobox: false, size: px(pt.draggable ? 5 : 3.5), face: 'o',
        strokeColor: theme.background, strokeWidth: px(1.5), fillColor: theme.accent,
        label: { fontSize: px(11), strokeColor: theme.text, offset: [px(8), px(8)], highlight: false }
      });
      if (pt.draggable) {
        p.on('drag', function () { post({ type: 'point', index: i, x: p.X(), y: p.Y(), final: false }); });
        p.on('up', function () { post({ type: 'point', index: i, x: p.X(), y: p.Y(), final: true }); });
      }
      state.points.push(p);
    });
    scene.labels.forEach(function (l) {
      board.create('text', [l.x, l.y, escapeText(l.text)], {
        fontSize: px(11), strokeColor: theme.text, fixed: true, highlight: false
      });
    });
  }

  function setParams(values) {
    state.params.length = 0;
    (values || []).forEach(function (v) { state.params.push(Number(v)); });
  }

  // ---------------------------------------------------------------------------------------
  // API for Swift

  window.inkyGraph = {
    render: function (scene) {
      try {
        state.scene = scene;
        setParams(scene.params);
        var board = rebuildBoard(scene);
        board.suspendUpdate();
        buildCurves(scene);
        buildOverlay(scene);
        buildPointsAndLabels(scene);
        board.unsuspendUpdate();
        post({ type: 'rendered', curves: state.curves.length });
      } catch (err) {
        post({ type: 'error', message: String(err && err.message || err) });
      }
    },

    // Params / features changed (slider drag): redraw without rebuilding the board.
    update: function (patch) {
      if (!state.board || !state.scene) { return; }
      try {
        var board = state.board;
        board.suspendUpdate();
        setParams(patch.params);
        state.scene.asymptotes = patch.asymptotes;
        state.scene.features = patch.features;
        state.scene.options = patch.options || state.scene.options;
        buildOverlay(state.scene);
        board.unsuspendUpdate();
      } catch (err) {
        post({ type: 'error', message: String(err && err.message || err) });
      }
    },

    setView: function (v) {
      if (!state.board) { return; }
      state.board.setBoundingBox([v.xMin, v.yMax, v.xMax, v.yMin], false);
      reportView(true);
    },

    zoom: function (factor) {
      if (!state.board) { return; }
      if (factor > 1) { state.board.zoomIn(); } else { state.board.zoomOut(); }
      reportView(true);
    },

    // For tests: evaluate function i at x with the current params.
    evaluate: function (i, x) {
      var fn = state.fns[i];
      return fn ? fn(x, state.params) : null;
    },

    // For tests: interpret a tree directly.
    evaluateTree: function (tree, x, params) { return compile(tree)(x, params || []); },

    info: function () {
      var bb = state.board ? state.board.getBoundingBox() : null;
      return { curves: state.curves.length, overlay: state.overlay.length, points: state.points.length, view: bb };
    }
  };

  post({ type: 'ready' });
})();
