# Wasm checks

One small program per extension (`toml.jl`, `logging.jl`, `tar.jl`, `artifacts.jl`, `msgpack.jl`), compiled by WasmCodegen with
`trim = :safe` and run on WASI (`run.mjs`, on `node:wasi` in Node or in Bun); `check.sh NAME` diffs its output with the
same program run natively.

    WCG_JS=<WasmCodegen.jl>/js JULIA=julia NODE=node JULIA_PROJECT=<env with WasmCodegen, WasmCompat> ./check.sh toml
    ... PCRE2=1 ./check.sh tar julia_io   # Tar's error messages use a regex (PCRE2); Tar.extract sets file modes (julia_io)
    ... PCRE2=1 ./check.sh regex       # Base's Regex API, compile errors, Pkg's semver patterns, Tar's path checks
    ... PCRE2=1 ./check.sh corpus      # 69 patterns, from ordinary to PCRE-only constructs, through eachmatch, keys, replace
    ... WASM_RUNTIME="node bun" BUN=bun PCRE2=1 ./check.sh regex   # each runtime's run diffed with the native one
    ... NO_BUILD=1 WASM_RUNTIME=bun PCRE2=1 ./check.sh regex       # the module and native output of the previous run, in Bun

`PCRE2=1` needs PCRE2_wasm_jll in the project (with its standalone module, 10.46.0+1 or later) and WasmCodegen
with `Config(foreign_functions)` and `Config(import_libraries)`.

Expected differences: `toml.jl`'s last line (a long integer literal parses as a `BigInt` natively, an overflow error
in Wasm; see the README's *Differences*); `regex.jl`'s `(?R)` line ("nested recursion at the same subject position"
from PCRE2 without a JIT, "JIT stack limit reached" from native Julia's JIT; see the README's *Regex*).
`expected/NAME.diff` is the expected `diff native wasm` of a program: `check.sh` exits 0 when each run is identical
or differs by exactly that, else 1.

**Bun** runs the same modules as Node, with the same output: Bun's `node:wasi` has no `getImportObject()` or
`initialize()`, which `js/wasi.mjs` stands in for (`wasiImportObject`, `wasiInitialize`). Bun needs no flags (it
ignores Node's), and JSPI is on by default in Bun 1.4. A trap reads differently (JavaScriptCore's messages).
