# WasmCompatObservablesExt, natively: the closed-world functions the overlays call (`*_closed`) run
# the same scenario as Observables' own methods with the same listener calls, in the same order;
# what is not in the closed world throws; Observables' native methods are untouched; the overlays
# are in WasmCodegen's table. Included by runtests.jl; standalone: julia --project=<env>
# test/observables.jl (an environment with WasmCodegen, WasmCompat, Observables and Test).
using Test, WasmCodegen, WasmCompat
using Observables
using Observables: MapCallback, OnAny, SetindexCallback

const CW = WasmCompat.Observables

# an AbstractObservable of another type than Observable (its listeners are its observable's)
struct WrapObs <: AbstractObservable{Float64}
    o::Observable{Float64}
end
Observables.observe(w::WrapObs) = w.o

# a graph of every kind of listener; each listener logs its call in `log`
function build_graph(log::Vector{Any})
    a = Observable(1.0); b = Observable(2)
    m2 = map((x, y) -> (push!(log, (:m2, x, y)); x * y), a, b)               # 2 inputs, mixed types
    r = Observable{Float64}(0.0)
    map!(v -> v + 1, r, m2)                                                  # map!
    onany((x, y) -> (push!(log, (:onany, x, y)); nothing), a, b)              # onany
    c = Observable(0.0)
    on(v -> (push!(log, (:c10, v)); v > 0 ? Consume(true) : nothing), c; priority = 10)
    on(v -> (push!(log, (:c5, v)); Consume(v > 100)), c; priority = 5)
    on(v -> push!(log, (:c0, v)), c)                                         # runs only if not consumed
    e = Observable(0.0; ignore_equal_values = true)
    on(v -> push!(log, (:e, v)), e)
    pa = Observable{Any}(1.0)                                                # abstract element type
    pb = map(v -> v * 2, pa)
    on(v -> push!(log, (:pa, v)), pa)
    ea = Observable{Any}(0; ignore_equal_values = true)
    on(v -> push!(log, (:ea, v)), ea)
    xc = copy(a)                                                             # SetindexCallback
    xc2 = Observable(0.0)
    connect!(xc2, xc)                                                        # a closure that sets
    removable = on(v -> push!(log, (:removable, v)), a)
    return (; a, b, m2, r, c, e, pa, pb, ea, xc, xc2, removable)
end

function scenario(set!, nfy, off!, g, log)
    set!(g.a, 0.5); set!(g.b, 3); set!(g.a, 2.0)
    set!(g.c, -1.0); set!(g.c, 5.0); set!(g.c, 200.0)
    push!(log, (:notify_c, nfy(g.c)))
    set!(g.e, 1.0); set!(g.e, 1.0); set!(g.e, 2.0)
    set!(g.pa, 3); set!(g.pa, 0.25)                                          # Int, then Float64, in Observable{Any}
    set!(g.ea, 1); set!(g.ea, 1); set!(g.ea, 1.5)
    push!(log, (:off, off!(g.removable)))
    set!(g.a, -1.5)
    push!(log, (:values, g.m2[], g.r[], g.pb[], g.xc[], g.xc2[], length(g.a.listeners)))
    return log
end

@testset "Observables: closed world" begin
    ObsExt = Base.get_extension(WasmCompat, :WasmCompatObservablesExt)
    @test ObsExt isa Module

    native_log = Any[]
    g_native = build_graph(native_log)
    closed_log = Any[]
    g = build_graph(closed_log)
    CW.open_world!()
    # (the scenario sets `pa` to an Int and `ea` to a Float64: types their listeners did not see at closing)
    CW.register_value!(Observable{Any}, Int)
    CW.register_value!(Observable{Any}, Float64)
    CW.close_world!(g)
    @test Set(fieldtypes(ObsExt.cw_value_types(Observable{Any}, Nothing))) == Set([Float64, Int])
    @test MapCallback in fieldtypes(ObsExt.cw_listener_types(Observable{Float64}))
    @test OnAny in fieldtypes(ObsExt.cw_listener_types(Observable{Int}))
    @test SetindexCallback in fieldtypes(ObsExt.cw_listener_types(Observable{Float64}))
    @test length(fieldtypes(ObsExt.cw_mapcallback_types())) == 3         # m2, r, pb

    @testset "the closed functions do what Observables does" begin
        scenario((o, v) -> o[] = v, notify, off, g_native, native_log)
        scenario(ObsExt.setindex_closed!, ObsExt.notify_closed, ObsExt.off_closed, g, closed_log)
        @test closed_log == native_log
        @test length(closed_log) > 20
        # (a map made by the closed `map`, and `on` with update, of a recorded listener type)
        m = ObsExt.map_closed(v -> v * 2, g.pa, (), false, 0)
        @test m[] == 0.5 && m isa Observable{Float64}
    end

    @testset "what is not in the closed world throws" begin
        newlistener = v -> nothing
        @test_throws ErrorException ObsExt.on_closed(newlistener, g.a, false, 0, false)
        @test_throws ErrorException ObsExt.setindex_closed!(g.pa, Int32(3))   # (a value type not recorded)
        CW.register_listener!(g.a, typeof(newlistener))
        CW.register_value!(g.pa, Int32)
        CW.close_world!(g)
        of = ObsExt.on_closed(newlistener, g.a, false, 0, true)
        @test of isa ObserverFunction && of.f === newlistener
        @test ObsExt.off_closed(of)
        n = length(closed_log)
        ObsExt.setindex_closed!(g.pa, Int32(3))                               # declared now: the listener logs it
        @test closed_log[n + 1] == (:pa, Int32(3)) && g.pb[] === 6.0
        # an observable type with no listener at closing: setting it calls nothing, adding one throws
        lonely = Observable(0x01)
        @test ObsExt.setindex_closed!(lonely, 0x02) == false
        @test_throws ErrorException ObsExt.on_closed(newlistener, lonely, false, 0, false)
    end

    @testset "modules as roots, exclude" begin
        m = Module(:ObsRoots)
        Core.eval(m, quote
            using Observables
            const X = Observable(1.0f0)
            const BUF = Float32[]
            on(v -> push!(BUF, v), X)
            const HELD = Ref(map(v -> [v], X))                                # found through a Ref
        end)
        CW.open_world!()
        CW.close_world!(m)
        Fs = fieldtypes(ObsExt.cw_listener_types(Observable{Float32}))
        @test length(Fs) == 2 && MapCallback in Fs
        @test Observable{Vector{Float32}} in fieldtypes(ObsExt.cw_observable_types()) ||
              isempty(m.HELD[].listeners)                                     # (no listener: not needed)
        CW.close_world!(m; exclude = (MapCallback,))
        @test fieldtypes(ObsExt.cw_listener_types(Observable{Float32})) == (typeof(only(filter(f -> !(f isa MapCallback), last.(m.X.listeners)))),)
        CW.open_world!()
        @test ObsExt.cw_listener_types(Observable{Float32}) == Tuple{}
        @test ObsExt.cw_observable_types() == Tuple{}
    end

    @testset "declarations stay until open_world!" begin
        CW.open_world!()
        f = v -> nothing
        CW.register_listener!(Observable(0.0), typeof(f))
        CW.register_value!(Observable{Any}, Int16)
        CW.close_world!()
        @test typeof(f) in fieldtypes(ObsExt.cw_listener_types(Observable{Float64}))
        CW.close_world!(Observable(1))                                        # again, another root: they stay
        @test typeof(f) in fieldtypes(ObsExt.cw_listener_types(Observable{Float64}))
        @test Int16 in fieldtypes(ObsExt.cw_value_types(Observable{Any}, Nothing))
        CW.open_world!(); CW.close_world!()
        @test ObsExt.cw_listener_types(Observable{Float64}) == Tuple{}
        @test ObsExt.cw_value_types(Observable{Any}, Nothing) == Tuple{}
    end

    @testset "SetindexCallback returns its value, as natively" begin
        src = Observable(1.5); dst = copy(src)
        sc = only(last.(src.listeners))::SetindexCallback
        CW.close_world!(src)
        @test sc(2.5) === 2.5                                                 # native
        @test ObsExt.call_setindex(sc, 3.5, ObsExt.cw_setindex_types()) === 3.5 && dst[] == 3.5
        # (from a notification: the observables of the source type's SetindexCallbacks only)
        anysrc = Observable{Any}(1); copy(anysrc)
        CW.close_world!(src, anysrc)
        @test ObsExt.cw_setindex_types(Observable{Float64}) == Tuple{Observable{Float64}}
        @test ObsExt.cw_setindex_types(Observable{Any}) == Tuple{Observable{Any}}
        @test Set(fieldtypes(ObsExt.cw_setindex_types())) == Set([Observable{Float64}, Observable{Any}])
        @test ObsExt.SetindexFrom(sc, ObsExt.cw_setindex_types(Observable{Float64}))(4.5) === 4.5 && dst[] == 4.5
        # (the value is the listener's result: a Consume stops the notification, as natively)
        csrc = Observable{Any}(Consume(false)); copy(csrc)
        after = Any[]; on(v -> push!(after, v), csrc)
        csrc2 = Observable{Any}(Consume(false)); copy(csrc2)
        after2 = Any[]; on(v -> push!(after2, v), csrc2)
        CW.close_world!(csrc)
        @test ObsExt.setindex_closed!(csrc, Consume(true)) == true == (csrc2[] = Consume(true); notify(csrc2))
        @test after == after2 == Any[]
        CW.open_world!()
    end

    @testset "notify of an observable of a type not in the closed world" begin
        CW.open_world!(); CW.close_world!()
        @test ObsExt.notify_closed(Observable(0x01)) == false                # an Observable without listeners
        w = WrapObs(Observable(1.0))
        @test notify(w) == false                                              # natively
        @test_throws ErrorException ObsExt.notify_closed(w)                   # another AbstractObservable type
        hits = Float64[]
        on(v -> push!(hits, v), w)
        CW.close_world!(w)                                                    # recorded: dispatched
        @test ObsExt.notify_closed(w) == false && hits == [1.0]
        CW.open_world!()
    end

    @testset "native Observables untouched" begin
        CW.close_world!(g)
        @test parentmodule(which(notify, (Observable{Float64},))) === Observables
        @test parentmodule(which(setindex!, (Observable{Float64}, Float64))) === Observables
        hits = Float64[]
        on(v -> push!(hits, v), g.a)                                          # a listener type never recorded
        g.a[] = 7.0
        @test hits == [7.0]
        @test isempty(Observables.addhandler_callbacks)                       # (no hook: nothing records natively)
        CW.open_world!()
    end

    @testset "overlays are in WasmCodegen's table" begin
        sigs = Any[]
        Base.visit(WasmCodegen.Runtime.WASM_METHODS) do m
            m.module === ObsExt && push!(sigs, m.sig)
        end
        for sig in (Tuple{typeof(setindex!),Observable,Any}, Tuple{typeof(notify),AbstractObservable},
                    Tuple{MapCallback,Any}, Tuple{OnAny,Any}, Tuple{SetindexCallback,Any},
                    Tuple{typeof(on),Any,AbstractObservable}, Tuple{typeof(off),AbstractObservable,Any},
                    Tuple{typeof(off),AbstractObservable,ObserverFunction}, Tuple{typeof(off),ObserverFunction})
            @test sig in sigs
        end
        @test any(s -> s <: Tuple{typeof(map),Any,AbstractObservable,Vararg}, sigs)
        # (each overlay has the signature of a native method: it replaces it, and covers no other)
        for sig in sigs
            occursin('#', string(Base.unwrap_unionall(sig).parameters[1])) && continue   # (the keyword bodies)
            @test Base._which(sig).method.sig == sig
        end
    end
end
