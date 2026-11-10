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
`WasmCodegen.Runtime.WASM_METHODS`, so native code never sees it.
"""
module WasmCompatMakieExt

import Makie
import WasmCodegen

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function Makie._ispressed_collection_fallback(parent, x, waspressed)::Bool
    isempty(x) && return true
    throw(
        ArgumentError(
            "`ispressed` can not evaluate a $(typeof(x)) in a Wasm build: the element type is not one of " *
                "`Makie._COLLECTION_ELTYPES`. Use a collection of buttons or operators of buttons of those types."
        )
    )
end

end
