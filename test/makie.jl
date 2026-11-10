# WasmCompatMakieExt, natively: the extension loads (before or after Makie, in either order of `using`), its overlay of
# `Makie._ispressed_collection_fallback` is in WasmCodegen's table and native `ispressed` is untouched by it. It needs a
# Makie with that hook (not released yet; asinghvi17-bot/Makie.jl, branch trim/ispressed-typed) in the environment, which
# test/Project.toml does not have: without it this file skips (a skipped testset, with the reason). Included by
# runtests.jl; standalone: julia --project=<env with WasmCodegen, WasmCompat, Makie and Test> test/makie.jl.
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
