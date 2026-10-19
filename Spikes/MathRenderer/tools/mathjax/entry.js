// MathJax 4 for JavaScriptCore: TeX in, flattened vector drawing out. No DOM, no module loader.
import { mathjax } from '@mathjax/src/mjs/mathjax.js';
import { TeX } from '@mathjax/src/mjs/input/tex.js';
import { SVG } from '@mathjax/src/mjs/output/svg.js';
import { liteAdaptor } from '@mathjax/src/mjs/adaptors/liteAdaptor.js';
import { RegisterHTMLHandler } from '@mathjax/src/mjs/handlers/html.js';
import '@mathjax/src/mjs/input/tex/base/BaseConfiguration.js';
import '@mathjax/src/mjs/input/tex/ams/AmsConfiguration.js';
import '@mathjax/src/mjs/input/tex/newcommand/NewcommandConfiguration.js';
import '@mathjax/src/mjs/input/tex/amscd/AmsCdConfiguration.js';
import '@mathjax/src/mjs/input/tex/boldsymbol/BoldsymbolConfiguration.js';
import '@mathjax/src/mjs/input/tex/mathtools/MathtoolsConfiguration.js';
import '@mathjax/src/mjs/input/tex/color/ColorConfiguration.js';
import '@mathjax/src/mjs/input/tex/configmacros/ConfigMacrosConfiguration.js';
import { MathJaxStix2Font } from '@mathjax/mathjax-stix2-font/mjs/svg.js';
import './stix2-dynamic.js';

// Every glyph range is bundled above, so "loading" one is a no-op that completes synchronously.
mathjax.asyncLoad = () => null;
mathjax.asyncIsSynchronous = true;

const adaptor = liteAdaptor();
RegisterHTMLHandler(adaptor);
let doc = null;

globalThis.mjInit = function (macrosJSON) {
  const tex = new TeX({
    packages: ['base', 'ams', 'newcommand', 'amscd', 'boldsymbol', 'mathtools', 'color', 'configmacros'],
    macros: JSON.parse(macrosJSON),
    formatError: (jax, err) => { throw err; },
  });
  const svg = new SVG({ fontCache: 'none', fontData: MathJaxStix2Font, linebreaks: { inline: false } });
  doc = mathjax.document('', { InputJax: tex, OutputJax: svg });
};

function multiply(m, n) {
  return [
    m[0] * n[0] + m[2] * n[1], m[1] * n[0] + m[3] * n[1],
    m[0] * n[2] + m[2] * n[3], m[1] * n[2] + m[3] * n[3],
    m[0] * n[4] + m[2] * n[5] + m[4], m[1] * n[4] + m[3] * n[5] + m[5],
  ];
}

function parseTransform(s, m) {
  if (!s) return m;
  const re = /(translate|scale|matrix)\(([^)]*)\)/g;
  let match;
  while ((match = re.exec(s))) {
    const v = match[2].split(/[\s,]+/).filter((x) => x.length).map(Number);
    if (match[1] === 'translate') m = multiply(m, [1, 0, 0, 1, v[0] || 0, v[1] || 0]);
    else if (match[1] === 'scale') m = multiply(m, [v[0], 0, 0, v.length > 1 ? v[1] : v[0], 0, 0]);
    else m = multiply(m, v);
  }
  return m;
}

function num(node, name) {
  const v = adaptor.getAttribute(node, name);
  return v ? parseFloat(v) : 0;
}

// Flattens the SVG into [kind, ..., matrix] ops in the outer viewBox's coordinates.
function walk(node, m, ops) {
  const kind = adaptor.kind(node);
  if (kind === '#text' || kind === '#comment') return;
  m = parseTransform(adaptor.getAttribute(node, 'transform'), m);
  if (kind === 'svg' && ops.length + 1 > 0 && node !== walk.root) {
    // Nested svg: position by x/y and map its viewBox onto width/height.
    m = multiply(m, [1, 0, 0, 1, num(node, 'x'), num(node, 'y')]);
    const vb = adaptor.getAttribute(node, 'viewBox');
    if (vb) {
      const [vx, vy, vw, vh] = vb.split(/[\s,]+/).map(Number);
      const w = num(node, 'width') || vw, h = num(node, 'height') || vh;
      m = multiply(m, [w / vw, 0, 0, h / vh, -vx * w / vw, -vy * h / vh]);
    }
  } else if (kind === 'path') {
    const d = adaptor.getAttribute(node, 'd');
    if (d) ops.push(['p', d, ...m]);
  } else if (kind === 'rect') {
    ops.push(['r', num(node, 'x'), num(node, 'y'), num(node, 'width'), num(node, 'height'), ...m]);
  } else if (kind === 'line') {
    ops.push(['l', num(node, 'x1'), num(node, 'y1'), num(node, 'x2'), num(node, 'y2'),
              num(node, 'stroke-width') || 1, ...m]);
  } else if (kind === 'text') {
    ops.push(['t', adaptor.textContent(node), num(node, 'font-size') || 1000,
              adaptor.getAttribute(node, 'font-family') || '', adaptor.getAttribute(node, 'font-style') || '',
              adaptor.getAttribute(node, 'font-weight') || '', ...m]);
    return;
  }
  for (const child of adaptor.childNodes(node)) walk(child, m, ops);
}

globalThis.mjRender = function (src, display) {
  try {
    const container = doc.convert(src, { display: display, em: 16, ex: 8, containerWidth: 100000 });
    const svg = adaptor.firstChild(container);
    const vb = adaptor.getAttribute(svg, 'viewBox').split(/[\s,]+/).map(Number);
    const ops = [];
    walk.root = svg;
    walk(svg, [1, 0, 0, 1, 0, 0], ops);
    return JSON.stringify({ vb: vb, ops: ops });
  } catch (e) {
    return JSON.stringify({ error: String((e && e.message) || e) });
  }
};
