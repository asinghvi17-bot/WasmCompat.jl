# WasmCompatObservablesExt: Observables.jl's notifications, over the closed world that `prepare` (called by
# build.jl before compiling) records. One submodule per case: the Observables MWE; a `map(sin)` chain (P1); two-input
# `map`, `map!`, `onany`, priorities with `Consume`, `ignore_equal_values`, `@map`, a direct `notify` (P2); listeners
# added and removed at run time, `copy`, `connect!` (P3); `Observable{Any}`/`Observable{Real}` changing type at run
# time (P4); a synchronous notify → listener → setindex! cycle through nested value types (P5); one generic `link!`
# re-entered along a chain with growing signatures (P6). `expected/observables.diff`: a listener of a type not in the
# closed world is refused in Wasm, and added natively (see the README's *Differences*).
module Prog
using Observables
out(s) = write(Core.stdout, s)

module MWE
using Observables
const x = Observable(1.0)
const y = map(v -> 2v, x)
const SEEN = Float64[]
on(v -> push!(SEEN, v), y)
function run(out)
    out("mwe: y = $(y[])\n")
    x[] = 0.5; out("mwe: y = $(y[])\n")
    x[] = -3.25; out("mwe: y = $(y[])\n")
    out("mwe: seen = $(join(SEEN, ", "))\n")
end
end

module P1
using Observables
const X = Observable(1.0)
const Y = map(v -> sin(v), X)
const BUF = Float64[]
on(v -> push!(BUF, v), Y)
function run(out)
    out("p1: y = $(Y[]), buf = $(length(BUF))\n")
    for v in (0.5, 2.0, -3.25)
        X[] = v
        out("p1: x = $v, y = $(Y[]), buf = $(length(BUF))\n")
    end
    out("p1: buf = $(join(BUF, ", "))\n")
end
end

module P2
using Observables
const A = Observable(1.0)
const B = Observable(2)
const M2 = map((a, b) -> a * b, A, B)                       # 2 inputs, mixed types
const R = Observable{Float64}(0.0)
map!(v -> v + 1, R, M2)                                     # map! (update = true)
const BUF2 = Float64[]
onany((a, b) -> (push!(BUF2, a + b); nothing), A, B)        # onany
const C = Observable(0.0)
const LOG = Float64[]
on(v -> v > 0 ? Consume(true) : nothing, C; priority = 10)  # Union{Consume,Nothing}
on(v -> Consume(v > 100), C; priority = 5)                  # Consume
on(v -> push!(LOG, v), C)                                   # runs only if not consumed
const E = Observable(0.0; ignore_equal_values = true)
const ECOUNT = Ref(0)
on(_ -> (ECOUNT[] += 1), E)
const Z = Observables.@map &A + 2.0 * &M2                   # @map
const W1 = map(sin, Z)
const W2 = map(x -> x^2, W1; ignore_equal_values = true)
const V = map(v -> [v, 2v, 4v], A)                          # Observable{Vector{Float64}}
const VSUM = Ref(0.0)
on(v -> (VSUM[] = sum(v)), V)
const EI = Observable(0; ignore_equal_values = true)        # Int, ignore_equal_values
const EIDER = map(i -> Float64(i) / 2, EI)
state() = "m2 = $(M2[]), r = $(R[]), z = $(Z[]), w1 = $(W1[]), w2 = $(W2[]), vsum = $(VSUM[]), " *
          "ecount = $(ECOUNT[]), eider = $(EIDER[]), buf2 = $(length(BUF2)), log = $(length(LOG))"
function run(out)
    out("p2: $(state())\n")
    for (name, v) in (("a", 0.5), ("b", 3.0), ("a", 2.0), ("c", -1.0), ("c", 5.0), ("c", 200.0), ("c", -2.0),
                      ("notify c", 0.0), ("notify a", 0.0), ("e", 1.0), ("e", 1.0), ("e", 2.0), ("ei", 3.0),
                      ("ei", 3.0), ("ei", 4.0), ("a", -1.5), ("b", -7.0))
        r = ""
        name == "a" ? (A[] = v) : name == "b" ? (B[] = round(Int, v)) : name == "c" ? (C[] = v) :
        name == "e" ? (E[] = v) : name == "ei" ? (EI[] = round(Int, v)) :
        name == "notify c" ? (r = string(notify(C))) : (r = string(notify(A)))
        out("p2: $name $v $r: $(state())\n")
    end
    out("p2: buf2 = $(join(BUF2, ", ")); log = $(join(LOG, ", "))\n")
end
end

module P3
using Observables
const X3 = Observable(1.0)
const BUF3 = Float64[]
dbl(v) = (push!(BUF3, 2v); nothing)
scaler(k) = v -> (push!(BUF3, k * v); nothing)
const XC = copy(X3)                                         # SetindexCallback
const XC2 = Observable(0.0)
connect!(XC2, XC)                                           # a closure listener: o1[] = x
const OF = on(v -> push!(BUF3, -v), X3)                     # removed at run time
const DYN = Ref{Observable{Float64}}(Observable(0.0))
const XU = Observable(0.0)
function run(out)
    X3[] = 0.5
    out("p3: xc2 = $(XC2[]), listeners = $(length(X3.listeners))\n")
    on(dbl, X3)                                             # declared (prepare)
    X3[] = 1.5
    out("p3: on(dbl): listeners = $(length(X3.listeners)), buf3 = $(join(BUF3, ", "))\n")
    DYN[] = map(sin, X3)                                    # one like it is a root (prepare)
    out("p3: map: dyn = $(DYN[][])\n")
    X3[] = 2.5
    out("p3: dyn = $(DYN[][])\n")
    out("p3: off = $(off(OF)), listeners = $(length(X3.listeners))\n")
    on(scaler(10.0), X3)                                    # declared (prepare)
    X3[] = 3.5
    out("p3: xc2 = $(XC2[]), buf3 = $(join(BUF3, ", "))\n")
    # (not declared: the closed world refuses it in Wasm, see expected/observables.diff)
    added = try
        on(v -> nothing, XU)
        "added"
    catch e
        e isa ErrorException ? "ErrorException" : "another error"
    end
    out("p3: an undeclared listener: $added\n")
end
end

module P4
using Observables
const PA = Observable{Any}(1.0)
const PB = map(v -> v * 2, PA)                              # a MapCallback of an Observable{Any}
const BUFA = Float64[]
on(v -> push!(BUFA, Float64(v)), PA)                        # a listener of ::Any
const PC = Observable{Real}(1)
const PD = map((a, c) -> a + c, PA, PC)
num(x) = x isa Float64 ? string(x) : x isa Int ? string(x, " (Int)") : "?"
function run(out)
    out("p4: pb = $(num(PB[])), pd = $(num(PD[]))\n")
    PA[] = 0.25; out("p4: pb = $(num(PB[])), pd = $(num(PD[]))\n")
    PC[] = 3; out("p4: pd = $(num(PD[]))\n")
    PA[] = 4; out("p4: pb = $(num(PB[])), pd = $(num(PD[]))\n")    # an Int (declared: prepare)
    PC[] = -2; out("p4: pd = $(num(PD[]))\n")
    out("p4: bufa = $(join(BUFA, ", "))\n")
end
end

module P5
using Observables
const A = Observable(1.0)
const V = map(a -> fill(a, 3), A)                           # Vector{Float64}
const T = map(v -> (v[1], length(v)), V)                    # Tuple{Float64,Int}
const S = map(t -> t[1] * t[2], T)                          # Float64
const N = Observable(0)
on(s -> (N[] = round(Int, s); nothing), S)                  # Int
const M = map(n -> [n, 2n], N)                              # Vector{Int}
const B = Observable(0.0)
on(m -> (B[] = Float64(sum(m)); nothing), M)                # Float64 again
const BV = map(b -> [b, b / 2], B)                          # Vector{Float64} again
const LOG = Float64[]
on(v -> (push!(LOG, v[2]); v[2] < 100 && (A[] = v[2]); nothing), BV)   # back to A (bounded)
function run(out)
    for v in (0.5, 2.0, 7.25, 40.0)
        A[] = v
        out("p5: a = $v: s = $(S[]), b = $(B[]), n = $(N[]), log = $(length(LOG))\n")
    end
    out("p5: log = $(join(LOG, ", "))\n")
end
end

module P6
using Observables
setv!(dst, x) = (dst[] = x; nothing)
link!(f, src, dst) = on(v -> setv!(dst, f(v)), src)
const A = Observable(1.0)
const V = Observable([0.0])
const T = Observable((0.0, 0))
const W = Observable([[0.0]])
const S = Observable(0.0)
const NT = Observable((a = 0.0, b = [0.0]))
link!(a -> [a, 2a], A, V)
link!(v -> (sum(v), length(v)), V, T)
link!(t -> [[t[1]], [Float64(t[2])]], T, W)
link!(w -> sum(sum, w), W, S)
link!(s -> (a = s, b = [s, s]), S, NT)
const OUT = Ref(0.0)
on(nt -> (OUT[] = nt.a + sum(nt.b); nothing), NT)
function run(out)
    for v in (0.5, 2.0, -3.25)
        A[] = v
        out("p6: a = $v: out = $(OUT[]), s = $(S[]), t1 = $(T[][1])\n")
    end
end
end

function main()
    MWE.run(out); P1.run(out); P2.run(out); P3.run(out); P4.run(out); P5.run(out); P6.run(out)
    return 0
end

# (build.jl: the observable graphs, cycles included, as objects created before their fields are set)
const CONFIG = (; shell_first_mutables = true)

# (build.jl, natively, before compiling: the closed world of this program's observables, and the types it only
# makes at run time)
function prepare()
    isdefined(Main, :WasmCompat) || return   # (COMPAT=0: the baseline, without the extension)
    CW = Main.WasmCompat.Observables
    CW.register_listener!(P3.X3, typeof(P3.dbl))
    CW.register_listener!(P3.X3, typeof(P3.scaler(1.0)))
    CW.register_value!(P4.PA, Int)
    CW.close_world!(@__MODULE__, map(sin, Observable(0.0)))   # (and a map like P3's run-time one)
end
end
