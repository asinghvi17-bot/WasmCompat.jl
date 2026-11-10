# WasmCompatMakieExt: Makie's `ispressed` (one method of `isa` branches) over a closed world. A button read as `Any`
# (an attribute) or as `IsPressedInputType` (an `Observable{IsPressedInputType}`), operators, tuples, and a `Vector` or
# `Set` of the supported element types (also a mixed `Set{Any}`) are static calls and give what they give natively; an
# empty collection of another element type is `true`. (makie_unsupported.jl: a non-empty one throws.)
# Needs a Makie with `Makie._ispressed_collection_fallback` (build.jl exits 77, and check.sh reports a skip, without it).
# `Prog.prepare` records the closed world of `OBS`, as in observables.jl. MAKIE=before|after (build.jl) loads Makie
# before or after WasmCompat: the extension must load, and work, in both.
module Prog
using Makie
using Makie: Keyboard, Mouse, Events, IsPressedInputType, Exclusively, ispressed
out(s) = write(Core.stdout, s)

const EV = Events()
const OBS = Observable{IsPressedInputType}(Keyboard.a)
# (read as Any: an attribute)
const ANYS = Any[Keyboard.a, Keyboard.b, Mouse.left, Mouse.right, true, false, Keyboard.a & Mouse.left, Keyboard.a | Keyboard.b,
                 !Keyboard.b, Exclusively(Keyboard.a & Mouse.left), (Keyboard.a, Mouse.left), (Keyboard.a, Keyboard.b),
                 [Keyboard.a, Keyboard.c], Set([Keyboard.a, Mouse.left]), Set([Keyboard.a, Mouse.right])]
# (read as IsPressedInputType)
const ISPS = IsPressedInputType[Keyboard.b, Keyboard.a, Mouse.left, [Keyboard.a], Set([Keyboard.b]), Keyboard.a | Keyboard.c]
const OBS_VALUES = IsPressedInputType[Keyboard.a, Mouse.left, Keyboard.b & Keyboard.a, [Keyboard.a, Keyboard.c], true]
const MIXED = Set{Any}([Keyboard.a, Mouse.left, Keyboard.a & Mouse.left])
const MIXED_VEC = Any[Keyboard.a, Mouse.left, Keyboard.a | Keyboard.b]

b2s(b::Bool) = b ? "1" : "0"
state() = string("keyboard = ", sort!(string.(collect(EV.keyboardstate))), ", mouse = ", sort!(string.(collect(EV.mousebuttonstate))))

function main()
    out("start: $(state())\n")
    for round in 1:4
        if round == 2
            push!(EV.keyboardstate, Keyboard.a)
        elseif round == 3
            push!(EV.mousebuttonstate, Mouse.left)
        elseif round == 4
            push!(EV.keyboardstate, Keyboard.c)
            delete!(EV.keyboardstate, Keyboard.a)
        end
        out("round $round: $(state())\n")
        s = ""
        for b in ANYS
            s *= b2s(ispressed(EV, b))
        end
        out("  as Any: $s\n")
        s = ""
        for b in ISPS
            s *= b2s(ispressed(EV, b))
        end
        out("  as IsPressedInputType: $s\n")
        s = ""
        for v in OBS_VALUES
            OBS[] = v
            s *= b2s(ispressed(EV, OBS[]))
        end
        out("  Observable{IsPressedInputType}: $s\n")
        out("  Set{Any}: $(b2s(ispressed(EV, MIXED))), Vector{Any}: $(b2s(ispressed(EV, MIXED_VEC)))\n")
        # a Vector and a Set of an element type that is not known: empty is true, as natively
        out("  empty: $(b2s(ispressed(EV, Int[]))) $(b2s(ispressed(EV, Set{String}()))) $(b2s(ispressed(EV, Float64[])))\n")
    end
    return 0
end

# (build.jl, natively, before compiling: the types OBS holds at run time, for the Observables extension's closed world)
function prepare()
    isdefined(Main, :WasmCompat) || return   # (COMPAT=0: the baseline, without the extensions)
    CW = Main.WasmCompat.Observables
    for v in OBS_VALUES
        CW.register_value!(OBS, typeof(v))
    end
    CW.close_world!(@__MODULE__)
end

# (build.jl: Events holds Observables that refer to each other)
const CONFIG = (; shell_first_mutables = true)
end
