# WasmCompatMakieExt: Makie's `ispressed` of a non-empty `Vector` or `Set` of an element type that is not one of
# `Makie._COLLECTION_ELTYPES` throws an `ArgumentError` in Wasm (natively Makie iterates it, and its element's own
# `ArgumentError` is the one thrown); the message is printed here, from the exception that Node runs. The other
# arguments are `Any`, as an attribute is, and throw Makie's own error in both. `expected/makie_unsupported.diff`:
# the three collections' lines.
# NOTE: Makie's own `throw` in `_ispressed` interpolates `typeof(x)`, which inference gives as an abstract
# `Type{<:BooleanOperator}` there, and WasmCodegen does not compile a tuple of that type. It is compiled when an exception is
# inspected, as `refused` does, so this program does not build with Makie 0.25.0 at 388db7b2 of
# asinghvi17-bot/Makie.jl (trim/ispressed-typed): `COMPILE FAILED ... a tuple of abstract type
# Tuple{String, Type{<:Makie.BooleanOperator}, String}`. It builds, with the same results, when that `throw` takes
# `Base.inferencebarrier(typeof(x))::DataType` (see the README).
# Same requirements and MAKIE=before|after as makie.jl.
module Prog
using Makie
using Makie: Events, ispressed
out(s) = write(Core.stdout, s)

const EV = Events()
# (read as Any: an attribute)
const UNSUPPORTED = Any[[1, 2], Set(["a"]), Float64[2.5], 3, "text", Int[]]

# the message of the ArgumentError that `ispressed(parent, x)` throws
function refused(parent, @nospecialize(x))
    try
        return string("no error: ", ispressed(parent, x))
    catch e
        e isa ArgumentError || return "another error"
        msg = e.msg   # (an Any: narrowed to String here)
        return msg isa String ? string("ArgumentError: ", msg) : "an ArgumentError"
    end
end

function main()
    for x in UNSUPPORTED
        out("unsupported: $(refused(EV, x))\n")
    end
    return 0
end

# (build.jl: Events holds Observables that refer to each other)
const CONFIG = (; shell_first_mutables = true)
end
