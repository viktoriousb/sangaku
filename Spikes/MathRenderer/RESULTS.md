# Math renderer spike: results

2026-10-16, macOS 26.6, Command Line Tools (Swift 6.2), release builds. Two rounds:
- Round 1 compared SwiftMath with KaTeX in a web view.
- Round 2 followed the requirement that rendering be fast and light, and added MicroTeX, MathJax in
  JavaScriptCore, and a typographic fast path.

`results/comparison.png` shows the same four proof steps set by each candidate.

Reproduce with `swift build -c release`, then:
- `.build/release/RendererSpike <mode> results [engines]`, with modes `coverage`, `images`, `perf`, `scroll`,
  `raster`, `engines`, `engines-noscroll`, `hybrid`, `hybrid-noscroll` and `compare`;
- `.build/release/RendererSpike memory results <swiftmath-compat|microtex-xits|mathjax>`.

Raw numbers are in `results/report-*.json`.

The repository leaves out the engines' bundled files and every render except `results/comparison.png`. Before
building, restore them in `Sources/RendererSpike/Resources/`:
- `katex/`: KaTeX 0.18.11's `katex.min.js`, `katex.min.css` and `fonts/`;
- `mathjax/mathjax-stix2.js`: built as described in `tools/mathjax/README.md`;
- `microtex/*.clm2`: XITS Math is `Vendor/MicroTeX/XITSMath-Regular.clm2`; STIX Two Math and Latin Modern Math
  are converted from their OpenType fonts with MicroTeX's `otf2clm.py`.

## Candidates

| | Approach | What ships |
|---|---|---|
| A | SwiftMath 1.7.3 + a compatibility layer of exact equivalents | Swift package, math fonts |
| B | KaTeX 0.18.11 rasterized in one hidden `WKWebView`, crops shown inline | 0.6 MB JS/CSS/fonts, plus a WebKit process |
| C | MicroTeX (C++17, JLaTeXMath lineage), vendored, command stream replayed in CoreGraphics | about 0.9 MB of C++, 1 MB `.clm2` font per math font |
| D | MathJax 4.1.3 + STIX Two font in JavaScriptCore, SVG output flattened to paths | 4.6 MB JS (1.5 MB gzipped) |
| E | Typographic fast path, with C for the rest | as C |
| F | Typographic fast path, with D for the rest | as D |

The typographic fast path is about 300 lines of Swift. It sets a conservative LaTeX subset as styled text, with
TeX's spacing between atoms:
- letters and digits, Greek, common relations and operators;
- `\mathbb`, `\mathcal`, `\mathfrak`, `\mathrm`, `\operatorname`;
- single sub- and superscripts, and `\pmod`.

Anything else, such as fractions, sums, accents, stacked scripts or environments, goes to the engine. Symbols
come from STIX Two Math, letters and digits from STIX Two Text; both ship with macOS.

In every candidate, formulas sit inline in SwiftUI `Text`: as text in the fast path, otherwise as template
images with a baseline offset. Rows stay native SwiftUI views.

## Results

The corpus has 79 expressions covering what mathematicians type (`results/coverage.md`). The thread test has
200 proof-step rows with 875 inline formulas. Memory and first-formula times come from a fresh process per
engine. Scrolling ran at 120 Hz (8.3 ms per frame), 2500 pt/s, every formula new, typesetting on the main thread.

| | Coverage | Per formula | First formula after launch | Memory | Scroll: missed frames · worst main-thread work |
|---|---|---|---|---|---|
| A | 62/79 exact | 0.20 ms | 113 ms | +23 MB | not run (coverage rules it out) |
| B | 79/79 | ~4.5 ms (batched, 0.5 s per batch) | ~500 ms | +75 MB WebKit process | cached rows only: 0 · 7.3 ms (30 Hz test) |
| C | 78/79 | **0.022 ms** | **16 ms** | **+13 MB** | **0 · 4.6 ms** |
| D | 79/79 | 1.05 ms | 96 ms | +36 MB | 32 of 472 (6.8%) · 15.6 ms |
| E | 78/79; 86% of formulas as text | 0.022 ms for the rest | 16 ms | +13 MB | **0 · 8.3 ms** |
| F | 79/79; 86% as text | 1.05 ms for the rest | 96 ms | +36 MB | 7 of 429 (1.6%) · 12.6 ms |

## Notes per candidate

**A, SwiftMath.**
- The compatibility layer registers missing symbols and operators through SwiftMath's public API and rewrites
  `\pmod`, `\bmod`, `\tfrac`, `\not\equiv` and `gathered` exactly.
- Still missing, and only fixable by changing the typesetter: `\xrightarrow`, `\overset`, `\stackrel`,
  `\underbrace`, `\overbrace`, `\substack`, `\boxed`, `\phantom`, `\varprojlim`, `\varinjlim`, `\mathscr`,
  `\boldsymbol`, `\left\lvert`, `\hline`, `smallmatrix`, `CD`.
- Lossy stand-ins, such as dropping an arrow's label, were rejected: they would show wrong math that looks right.

**B, KaTeX images.** Full coverage and good output. But it needs an extra 75 MB WebKit process and half a second
per batch on a cold start. Its Computer Modern-style math looks heavier than the STIX Two prose. Rejected by the
user as not fast or light enough.

**C, MicroTeX.**
- Fastest and lightest by a wide margin. Output matches STIX-style prose closely (XITS Math is a STIX derivative).
- Changes made for the spike:
  - Strict parsing. By default MicroTeX renders unknown commands as raw text; strict mode makes them errors, a
    one-line patch in `core/parser.h`.
  - TeX-faithful rewrites for `\pmod`, `\bmod` and `/`, which MicroTeX spaced differently from amsmath.
  - `\operatorname*{X}` rewritten to `\mathop{\mathrm{X}}\limits`.
  - A C++ shim so parse errors, thrown as C++ exceptions, come back as error strings.
- `CD` (commutative diagrams) is unsupported and now reported as an error.
- Matching STIX Two Math exactly needs converting the font to `.clm2` once with MicroTeX's `otf2clm.py`, which
  requires FontForge.
- Risks:
  - Upstream's last commit is from August 2024, so we would own a vendored copy and its patches.
  - It keeps global state, so it must be used from one thread.
  - The corpus is small. Adopting it should come with a regression corpus of a thousand or more real formulas,
    checked against MathJax as the reference.

**D, MathJax.**
- Broadest coverage, including `CD`, and the exact STIX Two font. Runs without WebKit.
- 45× slower than MicroTeX per formula, and visibly stutters at 120 Hz when typesetting on the main thread. It
  would need background typesetting with placeholders.
- The 4.6 MB bundle is built from `tools/mathjax/entry.js`.

**E and F, fast path.**
- 86% of inline formulas in proof steps are simple enough to be text. That text is selectable, searchable,
  readable by VoiceOver, inherits colour and dark mode, and stays crisp at any zoom.
- Next to engine output in the same font family, the seam is not visible.
- The mockups already draw inline math this way.

## Recommendation

Use E: the typographic fast path for simple inline math, MicroTeX for everything structural, and a clearly marked
LaTeX-source chip for anything neither can render, never a silent approximation.

Optionally, load MathJax lazily as a third tier for the rare constructs MicroTeX lacks, such as `CD`. It costs
about 100 ms and 30 MB, only once such a formula appears.

Design changes this suggests:
1. Inline math is text by default. Only structural formulas become drawn images.
2. One math family: STIX Two Math for engine output (convert to `.clm2` once), STIX Two Text for prose.
3. Long or structural formulas in proof steps go on their own display line.
4. Unrenderable formulas show their source in a monospace chip with a warning. The model's raw LaTeX stays
   visible and editable.
5. The composer previews on every keystroke; MicroTeX is fast enough to typeset synchronously.

## Environment notes

- The Command Line Tools on this Mac carry a stale `usr/include/c++/v1` that shadows the SDK's libc++. The spike
  works around it in `Package.swift`. Xcode's own toolchain is unaffected.
- The live scroll tests used a 120 Hz display. The round-1 scroll tests ran on a 30 Hz external display with Low
  Power Mode on.
