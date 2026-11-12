# WasmCompatMsgPackExt: MsgPack.pack of the kind of value a dashboard sends, a Dict{String,Any} of mixed
# values (scalars, strings of each length class, arrays, nested maps, bytes, an extension), and of
# concrete containers; a value of a type the closed-world packer does not know is an error
module Prog
import MsgPack
out(s) = write(Core.stdout, s)
function hex(b::Vector{UInt8})
    io = IOBuffer()
    for x in b
        print(io, string(x; base = 16, pad = 2))
    end
    return String(take!(io))
end
show_bytes(label, b) = (out(string(label, " ", length(b), " bytes ")); out(hex(b)); out("\n"))
function main()
    d = Dict{String, Any}()
    d["id"] = 42
    d["neg"] = -7
    d["big"] = typemax(UInt64)
    d["i8"] = Int8(-3)
    d["name"] = "plot α"
    d["x"] = 1.5
    d["f32"] = Float32(0.25)
    d["ok"] = true
    d["none"] = nothing
    d["missing"] = missing
    d["sym"] = :scatter
    d["ch"] = 'é'
    d["v"] = Any[1, "two", 3.0, false, nothing]
    d["floats"] = Float64[1.0, 2.0, 3.5]
    d["specials"] = Any[-0.0, Inf, 1.0e-310, Float32(-Inf), Float32(1.0e-40)]   # (MsgPack writes hton of the float)
    d["ints"] = collect(Int32(1):Int32(20))          # 20 elements: Array16
    d["bytes"] = UInt8[0x00, 0xff, 0x10]
    d["str8"] = repeat("x", 40)
    d["str16"] = repeat("é", 200)
    inner = Dict{String, Any}(); inner["k"] = "v"; inner["n"] = Any[Dict{String, Any}("deep" => 1)]
    d["inner"] = inner
    d["ext"] = MsgPack.Extension(Int8(5), UInt8[1, 2, 3, 4])
    # (keys in a Dict's own order: the same natively and in Wasm)
    show_bytes("dict", MsgPack.pack(d))
    v = Any[]
    push!(v, d["v"]); push!(v, d["floats"]); push!(v, Dict{String, String}("a" => "b"))
    show_bytes("vector", MsgPack.pack(v))
    show_bytes("typed", MsgPack.pack(Dict{String, Float64}("x" => 1.0, "y" => -2.5)))
    show_bytes("tuple", MsgPack.pack((1, "a", 2.0)))
    # a value of a type with no mapping, in an Any-typed place: an error both ways (the message differs)
    bad = Dict{String, Any}("f" => Some(1))
    r = try
        MsgPack.pack(bad); "packed"
    catch err
        err isa ErrorException ? "ErrorException" : "other error"
    end
    out(string("no mapping: ", r, "\n"))
    return 0
end
end
