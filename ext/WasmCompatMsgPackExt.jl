"""
    WasmCompatMsgPackExt

MsgPack.jl's `pack` for WasmCodegen's closed world. Overlays (methods of
`WasmCodegen.Runtime.WASM_METHODS`, used only when compiling to Wasm; native code is unchanged):

1. **`pack(io, x)` with static dispatch.** MsgPack packs a value by `pack_type(io,
   msgpack_type(typeof(x)), x)`. For a value of an abstractly typed place (an element of a
   `Dict{String,Any}` or a `Vector{Any}`, the shape of a dashboard's message), `msgpack_type`
   is called on a type known only at run time: a call that cannot be resolved in a closed
   world. Here a value of a concrete type is packed exactly as MsgPack does. A value of an
   abstract type is told apart by `isa` over the types of `VALUE_TYPES` below, then packed by
   MsgPack's own methods for its concrete type, so the bytes are the same. A value of another
   type in an abstractly typed place is an error in Wasm (natively MsgPack packs it, or
   reports that it has no mapping).

2. **`invalid_pack`'s message** names the value's type, the MsgPack type and the stream's type,
   but not the value or the stream themselves. Printing them (`show` of any object) is code
   that a closed world cannot compile. This is JuliaIO/MsgPack.jl#76's message, until it is in
   a release, with the MsgPack type printed as `T()`: the same text, without Base's default
   `show` of an object, which #76 still calls.

Only packing: `unpack` without a target type builds values of types known only at run time.
"""
module WasmCompatMsgPackExt

import MsgPack
import WasmCodegen

# The types of the values the overlay tells apart in abstractly typed places: MsgPack's scalars
# and the concrete containers messages are commonly built of. A value of a concrete type is
# packed by MsgPack directly, whatever its type.
const SCALAR_TYPES = (Nothing, Missing, Bool, Int64, Int32, Int16, Int8, UInt64, UInt32, UInt16, UInt8,
    Float64, Float32, String, SubString{String}, Symbol, Char, MsgPack.Extension)
const ARRAY_TYPES = (Vector{Any}, Vector{UInt8}, Vector{Int64}, Vector{Int32}, Vector{Float64},
    Vector{Float32}, Vector{String}, Vector{Bool}, Vector{Dict{String, Any}}, Vector{Vector{Any}})
const MAP_TYPES = (Dict{String, Any}, Dict{Symbol, Any}, Dict{String, String},
    Dict{String, Int64}, Dict{String, Float64}, Dict{String, Vector{Any}}, Dict{String, Dict{String, Any}})
const VALUE_TYPES = (SCALAR_TYPES..., ARRAY_TYPES..., MAP_TYPES...)

# a value of the concrete type T, as MsgPack's `pack(io, x)`
pack_typed(io::IO, x::T) where {T} = MsgPack.pack_type(io, MsgPack.msgpack_type(T), x)

@noinline unsupported(@nospecialize(x)) =
    error("MsgPack.pack (WasmCompat, Wasm): a value of type ", typeof(x), " in an abstractly typed place, ",
          "which the closed-world packer does not know; supported are the types of ",
          "WasmCompatMsgPackExt.VALUE_TYPES")

# `x isa T1 ? pack_typed(io, x::T1) : x isa T2 ? ... : unsupported(x)`
@eval function pack_any(io::IO, @nospecialize(x))
    return $(foldr((T, rest) -> :(x isa $T ? pack_typed(io, x::$T) : $rest), VALUE_TYPES;
                   init = :(unsupported(x))))
end

# by the static type of `x`: MsgPack's own call for a concrete one, the `isa` tests otherwise.
# (Julia expands a generated function only for concrete argument types; for an abstract one,
# such as the `Any` of an element of a `Dict{String,Any}`, it runs the `else` branch.)
function pack_value(io::IO, x)
    if @generated
        return isconcretetype(x) ? :(pack_typed(io, x)) : :(pack_any(io, x))
    else
        return pack_any(io, x)
    end
end

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function MsgPack.pack(io::IO, x)
    pack_value(io, x)
    return nothing
end

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS @noinline function MsgPack.invalid_pack(io, t, x)
    # (`$(typeof(t))()`: what `$(t)` prints for MsgPack's types, which have no fields, without
    # Base's default `show` of an object)
    error("cannot serialize Julia value with type $(typeof(x)) as MsgPack type $(typeof(t))() to $(typeof(io))")
end

end # module
