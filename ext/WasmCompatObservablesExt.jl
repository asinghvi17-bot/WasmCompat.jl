"""
    WasmCompatObservablesExt

Observables.jl (0.5.5, unmodified) for WasmCodegen's closed world. Observables keeps listeners as
`Vector{Pair{Int,Any}}` and calls each with `invokelatest`; `MapCallback`, `OnAny` and
`SetindexCallback` hold their function, arguments and result in fields of abstract type. So every
`obs[] = v` is a dynamic call, which a trimmed program cannot compile.

In Wasm, with this extension, the observables' types, their listeners' and the values of
observables of abstract element type are a closed world, recorded natively by the build script with
`WasmCompat.Observables.close_world!` after the program has built its observables. The record is a
few methods of this module that return `Tuple` types (`cw_listener_types(::Type{Observable{Float64}})
= Tuple{MapCallback, var"#5#6"}`, ...); the code that dispatches over them is fixed: `@generated`
`isa` chains (`call_listener`, `call_mapcallback`, ...). No per-program code is generated.

Every notification goes through one entry point of argument type `Any` (`notify_any`), which
dispatches on the observable's type: inference sees `notify → listener → setindex! → notify` as a
cycle of one signature rather than a chain of growing ones, so notification stays synchronous and
depth-first, as natively.

The overlays (methods of `WasmCodegen.Runtime.WASM_METHODS`, so native code never sees them) are
one-line calls of this module's `*_closed` functions, which the native tests also run:
`setindex!(::Observable, val)`, `notify(::AbstractObservable)`, the calls of `MapCallback`, `OnAny`
and `SetindexCallback`, `on(f, ::AbstractObservable)`, the three methods of `off` and
`map(f, ::AbstractObservable, args...)`. This extension must be the only one that overlays these
signatures: of two overlays of one signature, the last one loaded is used, without a warning.

`:consistent`: no overlay here is more `:consistent` than the method it replaces (each reads or
writes the observables' mutable fields, as Observables' methods do). The record's methods are
constant by design, but they are not overlays: they are ordinary methods of this module, the same
natively and in Wasm, so when inference evaluates a call of one with the native methods it gets the
answer the module would compute.
"""
module WasmCompatObservablesExt

import Observables
import WasmCodegen
import WasmCompat
using Observables: AbstractObservable, Observable, MapCallback, OnAny, SetindexCallback,
    ObserverFunction, Consume, listeners, to_value, observe

### The record (native): types found from close_world!'s roots, or declared

"Types of a closed world (see `close_world!`)."
struct Record
    listeners::Dict{Any,Vector{Any}}   # observable type => listener types
    values::Dict{Any,Vector{Any}}      # (observable type, listener type) => value types; (O, Nothing): any listener's
    mapcallbacks::Vector{Any}          # Tuple{typeof(f), typeof(result), typeof(args)} of a MapCallback
    onanys::Vector{Any}                # Tuple{typeof(f), typeof(args)} of an OnAny
    setindexes::Vector{Any}            # typeof(obs) of a SetindexCallback
    setindex_from::Dict{Any,Vector{Any}}   # observable type => typeof(obs) of its SetindexCallbacks
end
Record() = Record(Dict{Any,Vector{Any}}(), Dict{Any,Vector{Any}}(), Any[], Any[], Any[], Dict{Any,Vector{Any}}())

# (the declarations of register_listener!/register_value!, for every close_world! until open_world!; values by
# (O, Nothing): for every listener of O)
const DECLARED = Record()

push_unique!(v::Vector{Any}, @nospecialize(x)) = (any(y -> y === x, v) || push!(v, x); nothing)
push_unique!(d::Dict{Any,Vector{Any}}, @nospecialize(k), @nospecialize(x)) = push_unique!(get!(Vector{Any}, d, k), x)

# the element type of an observable type (`eltype` of a type is that of its instances' iteration)
obs_eltype(::Type{<:AbstractObservable{T}}) where {T} = T
obs_eltype(::Type) = Any

function record!(rec::Record, @nospecialize(f), @nospecialize(observable::AbstractObservable))
    obs = observe(observable)
    for O in unique!(Any[typeof(observable), typeof(obs)])
        push_unique!(rec.listeners, O, typeof(f))
        if !isconcretetype(obs_eltype(O)) && isdefined(obs, :val)
            push_unique!(rec.values, (O, typeof(f)), typeof(obs.val))
            push_unique!(rec.values, (O, Nothing), typeof(obs.val))
        end
        f isa SetindexCallback && push_unique!(rec.setindex_from, O, typeof(f.obs))
    end
    f isa MapCallback && push_unique!(rec.mapcallbacks, Tuple{typeof(f.f),typeof(f.result),typeof(f.args)})
    f isa OnAny && push_unique!(rec.onanys, Tuple{typeof(f.f),typeof(f.args)})
    f isa SetindexCallback && push_unique!(rec.setindexes, typeof(f.obs))
    return
end

obs_types(@nospecialize(obs)) = obs isa Type ? Any[obs] : unique!(Any[typeof(obs), typeof(observe(obs))])

function WasmCompat.Observables.register_listener!(@nospecialize(obs), @nospecialize(F::Type))
    foreach(O -> push_unique!(DECLARED.listeners, O, F), obs_types(obs))
    return
end

function WasmCompat.Observables.register_value!(@nospecialize(obs), @nospecialize(V::Type))
    foreach(O -> push_unique!(DECLARED.values, (O, Nothing), V), obs_types(obs))
    return
end

## The search from the roots

# (how deep fields, elements and values are searched below a root, a listener or a value)
const SCAN_DEPTH = 3

function scan_root!(queue, seen, @nospecialize(x))
    x isa Module || return scan!(queue, seen, x, 0)
    x in seen && return
    push!(seen, x)
    for name in names(x; all = true)
        (isdefinedglobal(x, name) && !Base.isdeprecated(x, name)) || continue
        v = getglobal(x, name)
        if v isa Module   # (its submodules)
            v !== x && parentmodule(v) === x && scan_root!(queue, seen, v)
        else
            scan!(queue, seen, v, 0)
        end
    end
    return
end

function scan!(queue, seen, @nospecialize(x), depth::Int)
    (isbitstype(typeof(x)) || x isa Union{Module,Type,String,Symbol,Core.MethodInstance,Method}) && return
    if ismutable(x) || x isa AbstractObservable
        x in seen && return
        push!(seen, x)
    end
    if x isa AbstractObservable
        push!(queue, x)
        observe(x) === x || scan!(queue, seen, observe(x), 0)
        return
    end
    depth >= SCAN_DEPTH && return
    if x isa AbstractDict
        foreach(v -> scan!(queue, seen, v, depth + 1), values(x))
    elseif x isa Union{AbstractArray,Core.SimpleVector}
        isbitstype(eltype(x)) && return
        for i in eachindex(x)
            isassigned(x, i) && scan!(queue, seen, x[i], depth + 1)
        end
    else
        for i in 1:nfields(x)
            isdefined(x, i) && scan!(queue, seen, getfield(x, i), depth + 1)
        end
    end
    return
end

# the record of the observables reachable from `roots`: each one's listeners (searched in turn),
# its inputs' observables (a `map!`'s arguments) and its value
function scan_roots(roots)
    rec = Record()
    seen = Base.IdSet{Any}(); queue = Any[]
    foreach(r -> scan_root!(queue, seen, r), roots)
    while !isempty(queue)
        obs = pop!(queue)::AbstractObservable
        o = observe(obs)
        if o isa Observable
            !isconcretetype(obs_eltype(typeof(obs))) && isdefined(o, :val) &&
                push_unique!(rec.values, (typeof(obs), Nothing), typeof(o.val))
            foreach(of -> scan!(queue, seen, of.observable, 0), o.inputs)
        end
        for (_, f) in listeners(obs)
            record!(rec, f, obs)
            scan!(queue, seen, f, 0)
        end
    end
    return rec
end

### The closed world as types (methods defined by close_world!)

# (each `f()` reads `f(nothing)`: close_world! adds the more specific `f(::Nothing)` and deletes it
# again, rather than overwriting a method of this precompiled module)
cw_observable_types() = cw_observable_types(nothing)
cw_observable_types(::Any) = Tuple{}
cw_listener_types(::Type) = Tuple{}
cw_value_types(::Type, ::Type) = Tuple{}
cw_mapcallback_types() = cw_mapcallback_types(nothing)
cw_mapcallback_types(::Any) = Tuple{}
cw_onany_types() = cw_onany_types(nothing)
cw_onany_types(::Any) = Tuple{}
cw_setindex_types() = cw_setindex_types(nothing)
cw_setindex_types(::Any) = Tuple{}   # (and of an observable type: its SetindexCallbacks' observables)
cw_addhandler_types() = cw_addhandler_types(nothing)
cw_addhandler_types(::Any) = Tuple{}
cw_removehandler_types() = cw_removehandler_types(nothing)
cw_removehandler_types(::Any) = Tuple{}

const CW_FUNCTIONS = (cw_observable_types, cw_listener_types, cw_value_types, cw_mapcallback_types,
                      cw_onany_types, cw_setindex_types, cw_addhandler_types, cw_removehandler_types)
const CLOSED_WORLD_METHODS = Method[]

# (through an inference barrier: Julia 1.12 and 1.13 fold `Tuple{v...}` of a constant global vector
# with its contents at inference time, even after it changed)
tuple_type(v) = Tuple{Base.inferencebarrier(v)...}

function applicable_types(@nospecialize(F), @nospecialize(V))
    ms = Base._methods_by_ftype(Tuple{F,V}, -1, Base.get_world_counter())
    return ms isa Vector && !isempty(ms)
end

function WasmCompat.Observables.open_world!()
    foreach(Base.delete_method, CLOSED_WORLD_METHODS)
    empty!(CLOSED_WORLD_METHODS)
    foreach(empty!, (DECLARED.listeners, DECLARED.values))
    return
end

function WasmCompat.Observables.close_world!(roots...; exclude = ())
    rec = scan_roots(roots)
    for (O, Fs) in DECLARED.listeners, F in Fs
        push_unique!(rec.listeners, O, F)
    end
    for ((O, _), Vs) in DECLARED.values, V in Vs   # (for every listener of O)
        push_unique!(rec.values, (O, Nothing), V)
        foreach(F -> push_unique!(rec.values, (O, F), V), get(rec.listeners, O, Any[]))
    end
    defs = Expr[]
    obstypes = sort!(collect(Any, keys(rec.listeners)); by = string)
    push!(defs, :(cw_observable_types(::Nothing) = $(tuple_type(obstypes))))
    for O in obstypes
        Fs = Any[F for F in rec.listeners[O] if !any(E -> F <: E, exclude)]
        push!(defs, :(cw_listener_types(::Type{$O}) = $(tuple_type(Fs))))
        isconcretetype(obs_eltype(O)) && continue
        for F in Fs
            F <: Union{MapCallback,OnAny} && continue   # (they do not use the value)
            Vs = Any[V for V in get(rec.values, (O, F), Any[]) if applicable_types(F, V)]
            push!(defs, :(cw_value_types(::Type{$O}, ::Type{$F}) = $(tuple_type(Vs))))
        end
    end
    for ((O, F), Vs) in rec.values
        F === Nothing && push!(defs, :(cw_value_types(::Type{$O}, ::Type{Nothing}) = $(tuple_type(Vs))))
    end
    push!(defs, :(cw_mapcallback_types(::Nothing) = $(tuple_type(rec.mapcallbacks))))
    push!(defs, :(cw_onany_types(::Nothing) = $(tuple_type(rec.onanys))))
    push!(defs, :(cw_setindex_types(::Nothing) = $(tuple_type(rec.setindexes))))
    for (O, Ts) in rec.setindex_from
        push!(defs, :(cw_setindex_types(::Type{$O}) = $(tuple_type(Ts))))
    end
    hooks(v) = tuple_type(unique!(Any[typeof(g) for g in v]))
    push!(defs, :(cw_addhandler_types(::Nothing) = $(hooks(Observables.addhandler_callbacks))))
    push!(defs, :(cw_removehandler_types(::Nothing) = $(hooks(Observables.removehandler_callbacks))))
    # (the previous record's methods deleted, the new ones defined: the methods defined after `w`)
    foreach(Base.delete_method, CLOSED_WORLD_METHODS)
    empty!(CLOSED_WORLD_METHODS)
    w = Base.get_world_counter()
    foreach(def -> Core.eval(@__MODULE__, def), defs)
    for f in CW_FUNCTIONS, m in methods(f)
        m.primary_world > w && push!(CLOSED_WORLD_METHODS, m)
    end
    return
end

### Statically dispatched Observables (what the overlays call)

@noinline unregistered_listener() =
    throw(ErrorException("WasmCompat.Observables: a listener of a type not in the closed world (see close_world!)"))
@noinline unregistered_value() =
    throw(ErrorException("WasmCompat.Observables: a value of a type not in the closed world (see close_world!)"))

# `g(v)`, split over the value types `Vs` (none: `v` as it is). The generator does not read `v`'s type,
# which is abstract where splitting matters: inference runs a generator for an abstract signature only
# if it does not need to (and Julia does not `invoke` an optionally generated function there). Where `v`
# is concrete, inference folds the chain to the one call.
@generated function split_call(g, v, ::Type{Vs}) where {Vs<:Tuple}
    Ts = fieldtypes(Vs)
    isempty(Ts) && return :(g(v))
    ex = :(unregistered_value())
    for V in reverse(Ts)
        ex = :(v isa $V ? g(v::$V) : $ex)
    end
    return ex
end

@generated is_registered(::Type{O}, ::Type{Os}) where {O,Os<:Tuple} = O in fieldtypes(Os)

# the one notification entry point, of argument type Any (see the module's documentation)
notify_any(@nospecialize(obs))::Bool = dispatch_notify(obs, cw_observable_types())

@generated function dispatch_notify(obs, ::Type{Os}) where {Os<:Tuple}
    ex = :(notify_unregistered(obs))
    for O in reverse(fieldtypes(Os))
        ex = :(obs isa $O ? notify_typed(obs::$O) : $ex)
    end
    return ex
end

# (an observable of a type with no listener in the closed world: nothing to call, unless it has one. Another
# `AbstractObservable` throws: its listeners are those of `observe(obs)`, a dynamic call for a type not known
# here, and recording listener-less types of Observables' other subtypes, `ObservablePair` and `Flatten`, would
# compile their code, which is not trim-safe)
function notify_unregistered(@nospecialize(obs))::Bool
    obs isa Observable && isempty((obs::Observable).listeners) && return false
    return unregistered_listener()
end

notify_closed(obs::AbstractObservable)::Bool = notify_any(Base.inferencebarrier(obs))

function notify_typed(obs::AbstractObservable)::Bool
    val = obs[]
    for (_, f) in listeners(obs)::Vector{Pair{Int,Any}}
        result = call_listener(obs, f, val, cw_listener_types(typeof(obs)))
        result isa Consume && result.x && return true   # (consumed: the next listeners are not called)
    end
    return false
end

@generated function call_listener(obs, f, val, ::Type{Fs}) where {Fs<:Tuple}
    ex = :(unregistered_listener())
    for F in reverse(fieldtypes(Fs))
        g = F === SetindexCallback ? :(SetindexFrom(f::$F, cw_setindex_types($obs))) : :(f::$F)
        ex = :(f isa $F ? split_call($g, val, cw_value_types($obs, $F)) : $ex)
    end
    return ex
end

# A SetindexCallback called by a notification of an observable of type O: an isa chain over the observables
# of O's SetindexCallbacks only (`SetindexCallback` is one type for every target, and a value of O stored into
# the target of another observable's copy would be a conversion that does not exist)
struct SetindexFrom{Ts<:Tuple}
    sc::SetindexCallback
end
SetindexFrom(sc::SetindexCallback, ::Type{Ts}) where {Ts<:Tuple} = SetindexFrom{Ts}(sc)
(s::SetindexFrom{Ts})(x) where {Ts} = call_setindex(s.sc, x, Ts)

function setindex_closed!(observable::Observable, val)
    if observable.ignore_equal_values
        isequal_closed(observable, val) && return
    end
    observable.val = val
    return notify_closed(observable)
end

function isequal_closed(observable::Observable{T}, val) where {T}
    isconcretetype(T) && return isequal(observable.val, val)
    Vs = cw_value_types(typeof(observable), Nothing)
    return split_call(v -> split_call(old -> isequal(old, v), observable.val, Vs), val, Vs)
end

# `f` of the values of `args` (observables, or values as they are), split over the value types of
# the observables of abstract element type
apply_closed(f, args::Tuple) = apply_split(f, args, arg_value_types(args))
arg_value_types(args::Tuple) = Tuple{map(arg_value_type, args)...}
arg_value_type(a::AbstractObservable) = cw_value_types(typeof(a), Nothing)
arg_value_type(@nospecialize(a)) = Tuple{}

@generated function apply_split(f, args::Tuple, ::Type{VTs}) where {VTs<:Tuple}
    n = fieldcount(args)
    vals = [Symbol(:a, i) for i in 1:n]
    body = :(f($(vals...)))
    for i in n:-1:1
        Ts = fieldtypes(fieldtype(VTs, i))
        isempty(Ts) && continue
        v = vals[i]
        ex = :(unregistered_value())
        for V in reverse(Ts)
            ex = :($v isa $V ? (let $v = $v::$V; $body; end) : $ex)
        end
        body = ex
    end
    return Expr(:block, [:($(vals[i]) = to_value(args[$i])) for i in 1:n]..., body)
end

# the listeners whose fields Observables does not type: an isa chain over the recorded field types
@generated function call_mapcallback(mc::MapCallback, ::Type{Ts}) where {Ts<:Tuple}
    ex = :(unregistered_listener())
    for T in reverse(fieldtypes(Ts))
        F, R, A = fieldtypes(T)
        ex = :(mc.f isa $F && mc.result isa $R && mc.args isa $A ?
               (setindex_closed!(mc.result::$R, apply_closed(mc.f::$F, mc.args::$A)); nothing) : $ex)
    end
    return ex
end

@generated function call_onany(onany::OnAny, ::Type{Ts}) where {Ts<:Tuple}
    ex = :(unregistered_listener())
    for T in reverse(fieldtypes(Ts))
        F, A = fieldtypes(T)
        ex = :(onany.f isa $F && onany.args isa $A ? apply_closed(onany.f::$F, onany.args::$A) : $ex)
    end
    return ex
end

@generated function call_setindex(sc::SetindexCallback, x, ::Type{Ts}) where {Ts<:Tuple}
    ex = :(unregistered_listener())
    for O in reverse(fieldtypes(Ts))
        ex = :(sc.obs isa $O ? (setindex_closed!(sc.obs::$O, x); x) : $ex)   # (`x`, as Observables' `sc.obs[] = x`)
    end
    return ex
end

# the hooks of Observables.addhandler_callbacks/removehandler_callbacks, of the types present at closing
@generated function call_hooks(hooks::Vector{Any}, ::Type{Gs}, args...) where {Gs<:Tuple}
    ex = :(unregistered_listener())
    for G in reverse(fieldtypes(Gs))
        ex = :(g isa $G ? (g::$G)(args...) : $ex)
    end
    return quote
        for g in hooks
            $ex
        end
    end
end

function check_registered(@nospecialize(observable::AbstractObservable), @nospecialize(f))
    is_registered(typeof(f), cw_listener_types(typeof(observable))) || unregistered_listener()
    return
end

# (Observables' `on`, `off` and `map`, with the dynamic calls replaced)
function on_closed(f, observable::AbstractObservable, weak::Bool, priority::Int, update::Bool)
    check_registered(observable, f)
    Observables.register_callback(observable, priority, f)
    call_hooks(Observables.addhandler_callbacks, cw_addhandler_types(), f, observable)
    update && split_call(f, observable[], cw_value_types(typeof(observable), typeof(f)))
    return ObserverFunction(f, observable, weak)
end

function off_closed(observable::AbstractObservable, f)
    callbacks = listeners(observable)
    for (i, (prio, f2)) in enumerate(callbacks)
        if f === f2
            deleteat!(callbacks, i)
            call_hooks(Observables.removehandler_callbacks, cw_removehandler_types(), observable, f)
            return true
        end
    end
    return false
end

@generated function dispatch_off(obs, f, ::Type{Os}) where {Os<:Tuple}
    ex = :(unregistered_listener())
    for O in reverse(fieldtypes(Os))
        ex = :(obs isa $O ? off_closed(obs::$O, f) : $ex)
    end
    return ex
end

off_closed(obsfunc::ObserverFunction) =
    dispatch_off(Base.inferencebarrier(obsfunc.observable), obsfunc.f, cw_observable_types())

function map_closed(f::F, arg1::AbstractObservable, args::Tuple, ignore_equal_values::Bool, priority::Int) where {F}
    obs = Observable(apply_closed(f, (arg1, args...)); ignore_equal_values)
    map!(f, obs, arg1, args...; update = false, priority)
    return obs
end

### The overlays (the signatures of Observables 0.5.5's methods)

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Base.setindex!(observable::Observable, val) =
    setindex_closed!(observable, val)

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Base.notify(observable::AbstractObservable) =
    notify_closed(observable)

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS (mc::MapCallback)(value) =
    call_mapcallback(mc, cw_mapcallback_types())

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS (onany::OnAny)(value) =
    call_onany(onany, cw_onany_types())

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS (sc::SetindexCallback)(x) =
    call_setindex(sc, x, cw_setindex_types())

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Observables.on(f, observable::AbstractObservable;
        weak::Bool = false, priority::Int = 0, update::Bool = false) =
    on_closed(f, observable, weak, priority, update)

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Observables.off(observable::AbstractObservable, f) =
    off_closed(observable, f)

# (Observables' more specific method of the same function, which the one above would otherwise cover in Wasm:
# of the overlay table and the native one, the first that covers a call is used)
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Observables.off(observable::AbstractObservable,
        obsfunc::ObserverFunction) =
    off_closed(observable, obsfunc.f)

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Observables.off(obsfunc::ObserverFunction) =
    off_closed(obsfunc)

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Base.map(f::F, arg1::AbstractObservable, args...;
        ignore_equal_values::Bool = false, priority::Int = 0) where {F} =
    map_closed(f, arg1, args, ignore_equal_values, priority)

end # module
