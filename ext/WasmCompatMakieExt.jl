"""
    WasmCompatMakieExt

Makie's `ispressed` for WasmCodegen's closed world. `ispressed` is one method that tells the types of buttons
apart by `isa`, so a button read as `IsPressedInputType` or `Any` (an `Observable{IsPressedInputType}`, an
attribute) is a static call. A `Vector` or `Set` of such a button has an element type that is not known at
compile time, so Makie finds its concrete type by `isa` over `Makie._COLLECTION_ELTYPES` (the element types of
buttons and of operators of buttons) and iterates it with that type. Every other collection goes to
`Makie._ispressed_collection_fallback`, which iterates it as Base does: a dynamic call that WasmCodegen cannot
compile, and which fails the trim verifier.

In Wasm, with this extension, that fallback is replaced: an empty collection is `true`, as natively, and any other
collection throws an `ArgumentError` that names its type and points at `Makie._COLLECTION_ELTYPES`. Natively
(and in Wasm for the supported element types) nothing changes. The method is an overlay of
`WasmCodegen.Runtime.WASM_METHODS`, so native code never sees it. It needs a Makie that has
`_ispressed_collection_fallback` (not released yet); with any other Makie the extension loads and defines nothing.
"""
module WasmCompatMakieExt

import Makie
import WasmCodegen

# The hook is in a Makie that is not released yet (asinghvi17-bot/Makie.jl, branch trim/ispressed-typed: `ispressed`
# as one isa-based method, with `_ispressed_collection_fallback` as its one dynamic point). With a Makie that lacks it
# there is nothing to replace, and the overlay's macro would refer to a binding that does not exist (an
# `UndefVarError` when this extension loads), so the overlay is defined only when the binding is there; `@eval`
# keeps the definition from being lowered when it is not. Once a Makie release has the hook, replace the guard with a
# `[compat]` bound on Makie in Project.toml (a bound on a weak dependency applies to its extension) and define the
# overlay unconditionally.
if isdefined(Makie, :_ispressed_collection_fallback)
    @eval Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function Makie._ispressed_collection_fallback(parent, x, waspressed)::Bool
        isempty(x) && return true
        # (`x` is an abstract `Vector` or `Set` here, so `typeof(x)` is inferred as `Type{Vector{T}} where T`, and
        # WasmCodegen does not compile a tuple of that abstract type, as `string` builds from the pieces of the message:
        # the barrier makes it the `DataType` it is at run time)
        T = Base.inferencebarrier(typeof(x))::DataType
        throw(
            ArgumentError(
                "`ispressed` can not evaluate a $T in a Wasm build: the element type is not one of " *
                    "`Makie._COLLECTION_ELTYPES`. Use a collection of buttons or operators of buttons of those types."
            )
        )
    end
end

end
