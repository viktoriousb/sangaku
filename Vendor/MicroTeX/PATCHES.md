# Changes to upstream MicroTeX

Upstream: https://github.com/NanoMichael/MicroTeX, branch `openmath`, commit
`086f4eb740270b28bd0c61a0a359aea9300d61ae` (2024-08-06). Licence: MIT (`LICENSE`).

`Sources/CMicroTeX/lib` is upstream `lib/` without its CMake and Meson files, plus the changes below. Each change
has a test in `sangakuTests`.

1. **Strict parsing** (`lib/core/parser.h`, the two default `Parser` constructors: `init(true, …)` →
   `init(false, …)`). Upstream parses leniently and typesets unknown commands and environments as raw source
   text. Strict mode makes them errors, so sangaku can show a source chip instead of wrong-looking math.
2. **`lib/microtexconfig.h`** written by hand (upstream generates it with CMake); automatic font search is off.
3. **`safe_parse.cpp`** (new): `microtex_tryInit`, `microtex_tryParse` and `microtex_tryDrawingData` wrap the
   throwing entry points (`microtex_init`, `microtex_parseRender`, `microtex_getDrawingData`) and turn C++
   exceptions into an error string, since exceptions must not cross into Swift.
4. **`include/CMicroTeX.h`** (new): the subset of the C API sangaku calls, declared without upstream's include
   paths.

TeX-faithful input rewrites (`\pmod`, `\bmod`, `/`, `\operatorname*`) live in the Swift bridge
(`sangaku/Services/Rendering/Tier2/MicroTeXCompat.swift`), not here.
