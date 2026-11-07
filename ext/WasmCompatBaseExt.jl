"""
    WasmCompatBaseExt

Base for WasmCodegen's closed world: constructs of Base's own code that a program reaches without
asking for them, and that WasmCodegen does not compile. Loaded with WasmCodegen alone.

- **`Base.generating_output()`** asks the runtime whether the process is writing a code cache
  (`ccall(:jl_generating_output)`, which WasmCodegen does not compile). A compiled program never
  is: `false`. Among others, `Base.OncePerProcess`'s initializer reaches it through
  `__precompile__(false)`, so every first call of a `OncePerProcess` value trapped.
- **`Base.bswap(x::Base.IEEEFloat)`** (so `hton`, `ntoh`, `htol`, `ltoh` of a float) swaps the bytes of
  the bits, as `Base.uinttype(typeof(x))`. Base's method is `bswap_int(x)` on the float itself, which
  WasmCodegen emits as integer shifts and masks on an `f32`/`f64` (invalid Wasm), and which, for a
  `Float16`, it did in `Float32` (`bswap(1.5f16)` was `0x0000`). Fixed in WasmCodegen by
  asinghvi17-bot/WasmCodegen.jl `fix/float-bswap`; this overlay is for the WasmCodegen without it.
  It is no more `:consistent` than Base's method, which is: it calls only `reinterpret` and
  `bswap` of an unsigned integer, with no `Base.@assume_effects` of its own.
"""
module WasmCompatBaseExt

import WasmCodegen

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Base.generating_output(
    incremental::Union{Bool,Nothing} = nothing) = false

# (a function of its own, which test/base.jl compares the effects of with Base's)
@inline function bswap_float(x::F) where {F<:Base.IEEEFloat}
    U = Base.uinttype(F)
    return reinterpret(F, bswap(reinterpret(U, x)))
end

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Base.bswap(x::Base.IEEEFloat) = bswap_float(x)

end # module
