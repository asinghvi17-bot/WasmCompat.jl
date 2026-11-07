# WasmCompatBaseExt, natively: the `bswap` overlay of the IEEE floats (`bswap_float`, the method of the overlay)
# against Base's `bswap`, as bit patterns, and its presence in WasmCodegen's table. Included by runtests.jl;
# standalone: julia --project=<env> test/base.jl (an environment with WasmCodegen, WasmCompat and Test).
using Test, WasmCodegen, WasmCompat

@testset "Base: bswap of the IEEE floats" begin
    BaseExt = Base.get_extension(WasmCompat, :WasmCompatBaseExt)
    @test BaseExt isa Module
    bits(x) = reinterpret(Base.uinttype(typeof(x)), x)
    # (values built from their bits: NaN payloads, quiet and signaling, and the infinities, zeros and subnormals)
    patterns = Dict(
        Float16 => UInt16[0x0000, 0x8000, 0x0001, 0x03ff, 0x0400, 0x3e00, 0x3c00, 0xbc00, 0x7bff, 0x7c00, 0xfc00,
                          0x7e00, 0x7c01, 0x7e12, 0xfe34, 0xfdff, 0x1234],
        Float32 => UInt32[0x00000000, 0x80000000, 0x00000001, 0x007fffff, 0x00800000, 0x3fc00000, 0x3f800000, 0xbf800000,
                          0x7f7fffff, 0x7f800000, 0xff800000, 0x7fc00000, 0x7f800001, 0x7fc01234, 0xffc0abcd, 0x7fbfffff,
                          0x12345678],
        Float64 => UInt64[0x0000000000000000, 0x8000000000000000, 0x0000000000000001, 0x000fffffffffffff,
                          0x0010000000000000, 0x3ff8000000000000, 0x3ff0000000000000, 0xbff0000000000000,
                          0x7fefffffffffffff, 0x7ff0000000000000, 0xfff0000000000000, 0x7ff8000000000000,
                          0x7ff0000000000001, 0x7ff8000012345678, 0xfff800000000abcd, 0x0123456789abcdef])
    for (F, bs) in patterns, b in bs
        x = reinterpret(F, b)
        y = BaseExt.bswap_float(x)
        @test y isa F
        @test bits(y) == bswap(b)               # the bytes of the bits, reversed
        @test bits(y) == bits(bswap(x))         # = Base's bswap
        @test bits(BaseExt.bswap_float(y)) == b # an involution, down to the payload
        if Base.ENDIAN_BOM == 0x04030201        # (hton and ntoh are bswap on a little-endian host)
            @test bits(hton(x)) == bits(y) && bits(ntoh(x)) == bits(y)
        end
    end
    @test bits(BaseExt.bswap_float(Float16(1.5))) == 0x003e
    @test BaseExt.bswap_float(1.0f0) === reinterpret(Float32, 0x0000803f)
    @test BaseExt.bswap_float(2.5) === reinterpret(Float64, 0x0000000000000440)

    @testset "no more :consistent than Base's method" begin
        # (the overlay asserts no effects: they are inferred from its body, `bswap_float`)
        for F in (Float16, Float32, Float64)
            native = Base.infer_effects(bswap, (F,))
            overlay = Base.infer_effects(BaseExt.bswap_float, (F,))
            @test !Core.Compiler.is_consistent(overlay) || Core.Compiler.is_consistent(native)
        end
    end

    @testset "present in WasmCodegen's overlay table" begin
        ms = Method[]
        Base.visit(m -> m.module === BaseExt && push!(ms, m), WasmCodegen.Runtime.WASM_METHODS)
        @test any(m -> m.name === :bswap && m.sig == Tuple{typeof(Base.bswap), Base.IEEEFloat}, ms)
        @test any(m -> m.name === :generating_output, ms)
    end
end
