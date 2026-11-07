"""
    WasmCompat

Compatibility of Julia's standard library with WasmCodegen's closed world. The package has no code
of its own that a program calls: each standard library it covers has a package extension, loaded
when the program loads that library and WasmCodegen together, which adds methods to WasmCodegen's
overlay method table (`WasmCodegen.Runtime.WASM_METHODS`). Those methods replace the library's
own only when WasmCodegen compiles a program; native code is unchanged.

| Extension | Loaded with | What it replaces in Wasm |
|---|---|---|
| `WasmCompatTOMLExt` | TOML | `TOML.print` with static dispatch; long integer literals without GMP |
| `WasmCompatLoggingExt` | Logging | `@info`/`@warn`/`@error` printed as `ConsoleLogger` prints them, to stderr |
| `WasmCompatTarExt` | Tar | callbacks specialized on; version field check without a regex |
| `WasmCompatArgToolsExt` | ArgTools | callbacks specialized on; `open` without a keyword splat |
| `WasmCompatArtifactsExt` | Artifacts | `Overrides.toml` tables parsed without an abstract `Pair` generator |
| `WasmCompatPCRE2Ext` | PCRE2_wasm_jll | Base's `Regex` on PCRE2 compiled to Wasm ([`pcre2_config`](@ref)) |
| `WasmCompatLibGit2Ext` | LibGit2_wasm_jll, LibGit2 | `LibGit2` on libgit2 compiled to Wasm ([`libgit2_config`](@ref)) |
| `WasmCompatSIMDExt` | SIMD | SIMD.jl's LLVM intrinsics as the same operation on each lane |
| `WasmCompatBaseExt` | (WasmCodegen alone) | `Base.generating_output()` is `false` |
| `WasmCompatObservablesExt` | Observables | listeners called through `isa` chains over a closed world ([`WasmCompat.Observables`](@ref)) |

Functions here that are part of the extensions' interface with programs and builds:
[`showerror_hook`](@ref), [`pcre2_config`](@ref), [`pcre2_module`](@ref), [`libgit2_config`](@ref),
[`libgit2_module`](@ref) and the module [`WasmCompat.Observables`](@ref).

An overlay replaces the native method only where inference does not evaluate the call at compile
time: WasmCodegen's inference still evaluates calls with constant arguments using the native
methods (see `WasmCodegen.Runtime.@wasm_method`), so each overlay here reads state or performs
I/O rather than computing a constant.
"""
module WasmCompat

"""
    WasmCompat.showerror_hook(io::IO, e) -> Bool

Called in Wasm by the extensions that show exceptions of types not known at compile time (a
logged `exception = err` of a `catch`), before WasmCodegen's own `Runtime.showerror_any`, which
shows Base's exceptions. The default shows nothing and returns `false`. A program with exception
types of its own overlays it, typically with an `isa` test per type:

```julia
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function WasmCompat.showerror_hook(io::IO, @nospecialize(e))
    e isa MyError && (showerror(io, e::MyError); return true)
    return false
end
```
"""
showerror_hook(io::IO, @nospecialize(e)) = false

"""
    WasmCompat.pcre2_config(config::WasmCodegen.Config; check_version = true) -> Config

`config` with Base's `Regex` on PCRE2 compiled to WebAssembly (the extension
`WasmCompatPCRE2Ext`, loaded with WasmCodegen and PCRE2_wasm_jll): Base's PCRE2 calls are
functions of the extension (`Config(foreign_functions)`) over PCRE2_wasm_jll's standalone module,
which the host instantiates and gives the program as the import module `"pcre2"`
(`Config(import_libraries)`; `js/pcre2.mjs`, with the file [`pcre2_module`](@ref)). For
`Config(host = :wasi)`. PCRE2_wasm_jll's version must be the compiling Julia's PCRE2
(`check_version`), whose error messages and offsets differ between minor versions.
"""
function pcre2_config end

"""
    WasmCompat.pcre2_module() -> String

The path of the PCRE2 module a program compiled with [`pcre2_config`](@ref) imports as `"pcre2"`.
"""
function pcre2_module end

"""
    WasmCompat.libgit2_config(config::WasmCodegen.Config; check_version = true) -> Config

`config` with Julia's `LibGit2` on libgit2 compiled to WebAssembly (the extension
`WasmCompatLibGit2Ext`, loaded with WasmCodegen, LibGit2_wasm_jll and LibGit2): `LibGit2`'s calls
of libgit2 are functions of the extension (`Config(foreign_functions)`) over LibGit2_wasm_jll's
standalone module, which the host instantiates, with a WASI instance of its own over the program's
preopens, and gives the program as the import module `"libgit2"` (`Config(import_libraries)`;
`js/libgit2.mjs`, with the file [`libgit2_module`](@ref)). For `Config(host = :wasi)`.
LibGit2_wasm_jll's version must be the compiling Julia's libgit2 (`check_version`).
"""
function libgit2_config end

"""
    WasmCompat.libgit2_module() -> String

The path of the libgit2 module a program compiled with [`libgit2_config`](@ref) imports as `"libgit2"`.
"""
function libgit2_module end

"""
    WasmCompat.Observables

The closed world of `WasmCompatObservablesExt` (loaded with WasmCodegen and Observables). In Wasm,
Observables calls its listeners through `isa` chains over the types they have in the build
process, which the build script records with [`close_world!`](@ref WasmCompat.Observables.close_world!)
after building the program's observables and before compiling. Natively nothing changes: the
record is only read by the extension's overlays.

- [`close_world!`](@ref WasmCompat.Observables.close_world!)`(roots...; exclude = ())`: record the
  types of the observables reachable from `roots`, their listeners and values; the extension's
  overlays dispatch over them in Wasm.
- [`register_listener!`](@ref WasmCompat.Observables.register_listener!)`(obs, F)` and
  [`register_value!`](@ref WasmCompat.Observables.register_value!)`(obs, V)`: types the program
  only makes at run time (a listener added in Wasm, a value of an `Observable{Any}`), for the next
  `close_world!`.
- [`open_world!`](@ref WasmCompat.Observables.open_world!)`()`: forget the record and the declarations.
"""
module Observables

"""
    WasmCompat.Observables.close_world!(roots...; exclude = ()) -> Nothing

Record, for the overlays of `WasmCompatObservablesExt`, the types of the observables reachable from
`roots`, of their listeners and of their values, and the types declared with
[`register_listener!`](@ref WasmCompat.Observables.register_listener!) and
[`register_value!`](@ref WasmCompat.Observables.register_value!). Call it in the build script after
the program has built its observables and before `WasmCodegen.compile`; calling it again replaces
the record.

A root is a module (its globals, and its submodules'), an observable, or any other object, whose
fields, elements and values are searched to a small depth. From each observable found, its listeners
are searched too (a closure's captured observables, a `map`'s result). `exclude`: listener types (or
`UnionAll`s) to leave out, for listeners the program never calls in Wasm.

In Wasm, after this call:
- a listener whose type was not recorded for its observable's type throws an `ErrorException` when
  it is added (`on`) or called; so does a value of a type not recorded for an observable whose
  element type is abstract (`Observable{Any}`), when its listeners are called;
- listeners are called directly, without `invokelatest` (a trimmed program has one world).

Natively nothing changes: Observables' own methods run, with every listener and value.
"""
function close_world! end

"""
    WasmCompat.Observables.register_listener!(obs, F::Type)

Declare that the program adds a listener of type `F` to `obs` (an observable, or an observable type)
at run time, for the next [`close_world!`](@ref WasmCompat.Observables.close_world!). For a `map`,
`onany` or `copy` made at run time, whose listener's fields have types too, build one like it
natively instead and pass it to `close_world!` as a root.
"""
function register_listener! end

"""
    WasmCompat.Observables.register_value!(obs, V::Type)

Declare that the program sets `obs` (an observable of abstract element type, or its type) to a value
of type `V` at run time, for the next [`close_world!`](@ref WasmCompat.Observables.close_world!).
"""
function register_value! end

"""
    WasmCompat.Observables.open_world!() -> Nothing

Forget the record of [`close_world!`](@ref WasmCompat.Observables.close_world!) and the declarations:
in Wasm, a notification then calls no listener (and throws if there is one).
"""
function open_world! end

end # module Observables

end # module
