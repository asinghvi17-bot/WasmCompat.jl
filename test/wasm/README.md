# Wasm checks

One small program per extension (`toml.jl`, `logging.jl`, `tar.jl`, `artifacts.jl`), compiled by WasmCodegen with
`trim = :safe` and run on WASI (`run.mjs`, on `node:wasi` in Node or in Bun); `check.sh NAME` diffs its output with the
same program run natively.

    WCG_JS=<WasmCodegen.jl>/js JULIA=julia NODE=node JULIA_PROJECT=<env with WasmCodegen, WasmCompat> ./check.sh toml
    ... PCRE2=1 ./check.sh tar julia_io   # Tar's error messages use a regex (PCRE2); Tar.extract sets file modes (julia_io)
    ... PCRE2=1 ./check.sh regex       # Base's Regex API, compile errors, Pkg's semver patterns, Tar's path checks
    ... PCRE2=1 ./check.sh corpus      # 69 patterns, from ordinary to PCRE-only constructs, through eachmatch, keys, replace
    ... VERIFY=error ./check.sh observables   # Observables' notifications over a closed world (Prog.prepare records it)
    ... MAKIE=before ./check.sh makie   # Makie's ispressed (WasmCompatMakieExt); MAKIE=before|after: Makie loaded before or after WasmCompat
    ... MAKIE=after ./check.sh makie_unsupported   # the ArgumentError for a collection the Wasm build can not iterate, printed in Node
    ... WASM_RUNTIME="node bun" BUN=bun PCRE2=1 ./check.sh regex   # each runtime's run diffed with the native one
    ... NO_BUILD=1 WASM_RUNTIME=bun PCRE2=1 ./check.sh regex       # the module and native output of the previous run, in Bun

`makie` and `makie_unsupported` need a Makie with `Makie._ispressed_collection_fallback` in the project, which is not
released yet: `Pkg.develop` the `Makie/` and `ComputePipeline/` directories of asinghvi17-bot/Makie.jl at branch
`trim/ispressed-typed` (388db7b2). Without Makie, or with a Makie that lacks the hook, `build.jl` exits 77 and `check.sh`
prints `makie: SKIPPED, <why>` and exits 0 (test/makie.jl, the native test, skips the same). They are not in the CI matrix
because test/Project.toml has no Makie. `makie_unsupported` does not build with 388db7b2: Makie's own `throw` in
`_ispressed` (events.jl:320) interpolates `typeof(x)`, inferred as an abstract `Type{<:BooleanOperator}` there, which
WasmCodegen refuses (`a tuple of abstract type`) as soon as a `catch` inspects the exception. It builds, and gives
`expected/makie_unsupported.diff`, with `Base.inferencebarrier(typeof(x))::DataType` in that `throw`.

`PCRE2=1` needs PCRE2_wasm_jll in the project (with its standalone module, 10.46.0+1 or later) and WasmCodegen
with `Config(foreign_functions)` and `Config(import_libraries)`.

Expected differences: `toml.jl`'s last line (a long integer literal parses as a `BigInt` natively, an overflow error
in Wasm; see the README's *Differences*); `regex.jl`'s `(?R)` line ("nested recursion at the same subject position"
from PCRE2 without a JIT, "JIT stack limit reached" from native Julia's JIT; see the README's *Regex*); `observables.jl`'s
line for a listener the closed world does not have (added natively, refused in Wasm; see the README's *Differences*); `makie_unsupported.jl`'s
three collection lines (Makie's own error for the first element natively, the extension's for the collection in Wasm); and `tar.jl`
reads an undefined value at `Tar.list`, a code generation issue (see the README's *Requirements and known limits*).
`expected/NAME.diff` is the expected `diff native wasm` of a program: `check.sh` exits 0 when each run is identical
or differs by exactly that, else 1.

**Bun** runs the same modules as Node, with the same output: Bun's `node:wasi` has no `getImportObject()` or
`initialize()`, which `js/wasi.mjs` stands in for (`wasiImportObject`, `wasiInitialize`). Bun needs no flags (it
ignores Node's), and JSPI is on by default in Bun 1.4. A trap reads differently (JavaScriptCore's messages).
