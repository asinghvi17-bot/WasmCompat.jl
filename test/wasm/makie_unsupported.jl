# WasmCompatMakieExt: Makie's `ispressed` of a non-empty `Vector` or `Set` of an element type that is not one of
# `Makie._COLLECTION_ELTYPES` throws an `ArgumentError` in Wasm (natively Makie iterates it, and its element's own
# `ArgumentError` is the one thrown); the message is printed here, from the exception that Node runs. The other
# arguments are `Any`, as an attribute is, and throw Makie's own error in both. `expected/makie_unsupported.diff`:
# the three collections' lines.
# NOTE: this needs asinghvi17-bot/Makie.jl at 4185104f or later (branch trim/ispressed-typed), which has the upstream fix for the `throw`
# in `_ispressed`: it interpolated `typeof(x)`, which inference gives as an abstract `Type{<:BooleanOperator}`, and WasmCodegen
# does not compile a tuple of that type once an exception is inspected, as `refused` does (at 388db7b2:
# `COMPILE FAILED ... a tuple of abstract type Tuple{String, Type{<:Makie.BooleanOperator}, String}`). 4185104f makes it a concrete type.
# Build it with VERIFY=error (check.sh does by default).
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
