# WasmCompatMakieExt, natively: the extension loads (before or after Makie, in either order of `using`), its overlay of
# `Makie._ispressed_collection_fallback` is in WasmCodegen's table and native `ispressed` is untouched by it. It needs a
# Makie with that hook (not released yet; asinghvi17-bot/Makie.jl, branch trim/ispressed-typed) in the environment, which
# test/Project.toml does not have: without it the first testset skips (a skipped testset, with the reason). The second
# testset is the other side of the guard in the extension, against a Makie *without* the hook: it runs when
# WASMCOMPAT_MAKIE_HOOKLESS is the path of a checkout of asinghvi17-bot/Makie.jl at a commit before the hook (for example
# 1c6d51c65, on branch trim/ispressed-typed), and skips with a message otherwise. It builds an environment with that Makie
# from the active one (test/makie_hookless_env.jl: needs the registry, and the depot to precompile Makie, a few minutes)
# and loads WasmCompat and Makie in both orders in a process each. Included by runtests.jl; standalone:
# [WASMCOMPAT_MAKIE_HOOKLESS=<checkout>] julia --project=<env with WasmCodegen, WasmCompat, Makie and Test> test/makie.jl.
using Test, WasmCodegen, WasmCompat

# (the same Makie as the wasm check's: loaded here, or the reason why not)
const MAKIE_SKIP = try
    @eval using Makie
    isdefined(Makie, :_ispressed_collection_fallback) ? nothing :
        "this Makie ($(pkgversion(Makie))) has no `_ispressed_collection_fallback`, the ispressed hook that is not released yet"
catch err
    err isa ArgumentError || rethrow()
    "Makie is not in the environment"
end

@testset "Makie: ispressed fallback (WasmCompatMakieExt)" begin
    if MAKIE_SKIP !== nothing
        @info "WasmCompatMakieExt: skipped, $MAKIE_SKIP"
        @test_skip false
    else
        MakieExt = Base.get_extension(WasmCompat, :WasmCompatMakieExt)
        @test MakieExt isa Module
        overlays = Method[]
        Base.visit(WasmCodegen.Runtime.WASM_METHODS) do m
            m.module === MakieExt && push!(overlays, m)
        end
        @test length(overlays) == 1 && only(overlays).name === :_ispressed_collection_fallback

        # natively nothing changes: the stock fallback iterates any collection, as Base does
        using Makie: Keyboard, Mouse, Events, ispressed, IsPressedInputType
        ev = Events()
        push!(ev.keyboardstate, Keyboard.a); push!(ev.mousebuttonstate, Mouse.left)
        for b in Any[Keyboard.a, Mouse.left, Keyboard.a & Mouse.left, Keyboard.b | Keyboard.a, [Keyboard.a], Set{Any}([Keyboard.a, Mouse.left]),
                     IsPressedInputType[Keyboard.a][1]]
            @test ispressed(ev, b)
        end
        @test !ispressed(ev, Keyboard.b) && !ispressed(ev, Any[Keyboard.a, Keyboard.b])
        @test ispressed(ev, Int[]) && ispressed(ev, Set{String}())      # an empty collection of an unsupported type
        @test_throws ArgumentError ispressed(ev, Any[[1, 2]][1])        # Makie's own error for an element it does not know
        e = try; ispressed(ev, [1, 2]); catch err; err; end
        @test e isa ArgumentError && !occursin("Wasm build", e.msg)

        # the load order: Makie before WasmCompat, and after (a process each)
        proj = Base.active_project()
        for order in ("using Makie; using WasmCodegen; using WasmCompat", "using WasmCodegen; using WasmCompat; using Makie")
            code = """
                $order
                ext = Base.get_extension(WasmCompat, :WasmCompatMakieExt)
                ext === nothing && error("WasmCompatMakieExt not loaded")
                n = 0
                Base.visit(WasmCodegen.Runtime.WASM_METHODS) do m
                    m.module === ext && (global n += 1)
                end
                n == 1 || error("\$n overlays")
                print("ok")
                """
            out = IOBuffer()
            ok = success(pipeline(`$(Base.julia_cmd()) --startup-file=no --project=$proj -e $code`; stdout = out, stderr = stderr))
            @test ok && String(take!(out)) == "ok"
        end
    end
end

# the guard in the extension, against a Makie that lacks the hook: the extension loads, in either order, and defines nothing
@testset "Makie: no ispressed hook (WasmCompatMakieExt defines no overlay)" begin
    hookless = get(ENV, "WASMCOMPAT_MAKIE_HOOKLESS", "")
    if isempty(hookless)
        @info "WasmCompatMakieExt, hookless Makie: skipped, WASMCOMPAT_MAKIE_HOOKLESS is not set (a checkout of asinghvi17-bot/Makie.jl before the ispressed hook, e.g. 1c6d51c65)"
        @test_skip false
    else
        @test isdir(hookless)
        mktempdir() do env
            active = dirname(Base.active_project())
            made = success(pipeline(`$(Base.julia_cmd()) --startup-file=no $(joinpath(@__DIR__, "makie_hookless_env.jl")) $active $env $hookless`;
                                    stdout = stderr, stderr = stderr))
            @test made
            made || return
            for order in ("using Makie; using WasmCodegen; using WasmCompat", "using WasmCodegen; using WasmCompat; using Makie")
                code = """
                    $order
                    isdefined(Makie, :_ispressed_collection_fallback) && error("not a hookless Makie: \$(pkgversion(Makie))")
                    ext = Base.get_extension(WasmCompat, :WasmCompatMakieExt)
                    ext === nothing && error("WasmCompatMakieExt not loaded")
                    n = 0
                    Base.visit(WasmCodegen.Runtime.WASM_METHODS) do m
                        m.module === ext && (global n += 1)
                    end
                    n == 0 || error("\$n overlays")
                    # (and native ispressed is untouched)
                    using Makie: Events, Keyboard, ispressed
                    ev = Events(); push!(ev.keyboardstate, Keyboard.a)
                    ispressed(ev, Keyboard.a) && ispressed(ev, [Keyboard.a]) && !ispressed(ev, Keyboard.b) || error("ispressed")
                    print("ok ", pkgversion(Makie))
                    """
                out = IOBuffer()
                ok = success(pipeline(`$(Base.julia_cmd()) --startup-file=no --project=$env -e $code`; stdout = out, stderr = stderr))
                @test ok && startswith(String(take!(out)), "ok ")
            end
        end
    end
end
