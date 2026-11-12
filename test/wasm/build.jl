# julia --project=env build.jl PROG.jl OUT.wasm   compile PROG.jl's `Prog.main` for WASI with WasmCodegen.
# ENV: COMPAT=0 builds without WasmCompat loaded; TRIM (safe), VERIFY (warn here; check.sh makes it error for makie and makie_unsupported), EXT (comma-separated host extensions);
# PCRE2=1 builds with Base's Regex on PCRE2 (`WasmCompat.pcre2_config`), and copies the PCRE2 module next to OUT.wasm;
# LIBGIT2=1 builds with LibGit2 on libgit2 (`WasmCompat.libgit2_config`), and copies the libgit2 module next to OUT.wasm;
# MAKIE=before|after loads Makie before or after WasmCompat (makie.jl). It needs a Makie with
# `Makie._ispressed_collection_fallback`, an unreleased one: without Makie or that hook this exits 77 (`SKIP: <why>`),
# which check.sh reports as a skip.
# A program may define `Prog.prepare()`, called natively after loading it and before compiling (observables.jl records
# its closed world there), and `Prog.CONFIG`, keywords of `WasmCodegen.Config`.
using WasmCodegen, TOML, Logging, Tar, ArgTools, Artifacts, Dates, MsgPack, Observables
compat = get(ENV, "COMPAT", "1") == "1"
pcre2 = get(ENV, "PCRE2", "0") == "1"
pcre2 && @eval using PCRE2_wasm_jll
libgit2 = get(ENV, "LIBGIT2", "0") == "1"
libgit2 && @eval using LibGit2, LibGit2_wasm_jll
makie = get(ENV, "MAKIE", "0")
makie in ("0", "before", "after") || error("build.jl: MAKIE is 0, before or after")
if makie != "0"
    makie_error = try
        makie == "before" && @eval using Makie
        compat && @eval using WasmCompat
        makie == "after" && @eval using Makie
        isdefined(Main.Makie, :_ispressed_collection_fallback) ? nothing : "this Makie $(pkgversion(Main.Makie)) has no `_ispressed_collection_fallback` (the ispressed hook is unreleased)"
    catch err
        err isa ArgumentError || rethrow()   # (Makie is not in the project)
        "Makie is not available: $(first(split(sprint(showerror, err), '\n')))"
    end
    if makie_error !== nothing
        println("SKIP: ", makie_error)
        exit(77)
    end
    println("Makie ", pkgversion(Main.Makie), " loaded ", makie, " WasmCompat")
else
    compat && @eval using WasmCompat
end
if compat
    for e in (:WasmCompatCoreExt, :WasmCompatTOMLExt, :WasmCompatLoggingExt, :WasmCompatTarExt, :WasmCompatArgToolsExt, :WasmCompatArtifactsExt, :WasmCompatMsgPackExt,
              :WasmCompatPCRE2Ext, :WasmCompatLibGit2Ext, :WasmCompatBaseExt, :WasmCompatSIMDExt, :WasmCompatObservablesExt, :WasmCompatMakieExt)
        println("extension ", e, ": ", Base.get_extension(WasmCompat, e) !== nothing)
    end
end
include(abspath(ARGS[1]))
isdefined(Prog, :prepare) && Prog.prepare()
trim = Symbol(get(ENV, "TRIM", "safe")); verify = Symbol(get(ENV, "VERIFY", "warn"))
exts = Symbol[Symbol(x) for x in split(get(ENV, "EXT", ""), ',') if !isempty(x)]
cfg = WasmCodegen.Config(; host = :wasi, host_extensions = exts, trim, verify, on_unsupported = trim === :safe ? :error : :trap,
                         (isdefined(Prog, :CONFIG) ? Prog.CONFIG : (;))...)
if pcre2
    cfg = WasmCompat.pcre2_config(cfg)
    cp(WasmCompat.pcre2_module(), joinpath(dirname(abspath(ARGS[2])), "libpcre2-8.wasm"); force = true)
end
if libgit2
    cfg = WasmCompat.libgit2_config(cfg)
    cp(WasmCompat.libgit2_module(), joinpath(dirname(abspath(ARGS[2])), "libgit2.wasm"); force = true)
end
# (tests run on optimized modules only: wasm-opt -O3, WasmCodegen's default)
cfg.optimize === nothing && error("build.jl: Config(optimize = nothing): the checks run on modules optimized by wasm-opt only")
println("verify: ", cfg.verify, ", optimize: wasm-opt ", join(cfg.optimize.exec, ' '))
t = time()
c = try
    WasmCodegen.compile([WasmCodegen.Entry(Prog.main, (); name = "main")]; config = cfg)
catch err
    println("COMPILE FAILED after ", round(time() - t; digits = 1), " s:")
    showerror(stdout, err); println(); exit(2)
end
println("compiled in ", round(time() - t; digits = 1), " s, ", length(c.bytes), " bytes, ", length(c.cgm.diagnostics), " diagnostics")
for (mi, u) in c.cgm.diagnostics
    println("  DIAG ", mi, ": ", first(sprint(show, u), 600))
end
rep = isassigned(c.world.trim_report) ? c.world.trim_report[] : ""
println("verifier: ", isempty(rep) ? "clean" : string(count("\nError", "\n" * rep) + count("\nWarning", "\n" * rep), " entries"))
isempty(rep) || write(ARGS[2] * ".verifier.txt", rep)
write(ARGS[2], c.bytes)
