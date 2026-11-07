# WasmCompatBaseExt: `bswap`, `hton` and `ntoh` of Float16, Float32 and Float64, compared as bit patterns (integers):
# signed zeros, subnormals, Inf, NaNs with payloads (built from their bits, quiet and signaling), and values whose
# bytes differ. Each line is the swapped bits and whether they are the integer `bswap` of the bits.
# Built and checked with verify = :error (0 diagnostics, verifier clean).
module Prog
out(s) = write(Core.stdout, s)
hex(u::Unsigned) = string(u; base = 16, pad = 2sizeof(u))

function check(::Type{F}, b::U) where {F<:Base.IEEEFloat,U<:Unsigned}
    x = reinterpret(F, b)
    y = reinterpret(U, bswap(x))
    h = reinterpret(U, hton(x))
    n = reinterpret(U, ntoh(x))
    r = reinterpret(U, ntoh(hton(x)))
    ok = y == bswap(b) && h == bswap(b) && n == bswap(b) && r == b && reinterpret(U, bswap(bswap(x))) == b
    out("$(F) $(hex(b)) -> $(hex(y)) $(ok ? "ok" : "WRONG")\n")
    return ok
end

function main()
    all = true
    for b in (0x0000, 0x8000, 0x0001, 0x03ff, 0x0400, 0x3e00, 0x3c00, 0xbc00, 0x7bff, 0x7c00, 0xfc00,
              0x7e00, 0x7c01, 0x7e12, 0xfe34, 0xfdff, 0x1234)
        all &= check(Float16, b)
    end
    for b in (0x00000000, 0x80000000, 0x00000001, 0x007fffff, 0x00800000, 0x3fc00000, 0x3f800000, 0xbf800000,
              0x7f7fffff, 0x7f800000, 0xff800000, 0x7fc00000, 0x7f800001, 0x7fc01234, 0xffc0abcd, 0x7fbfffff, 0x12345678)
        all &= check(Float32, b)
    end
    for b in (0x0000000000000000, 0x8000000000000000, 0x0000000000000001, 0x000fffffffffffff, 0x0010000000000000,
              0x3ff8000000000000, 0x3ff0000000000000, 0xbff0000000000000, 0x7fefffffffffffff, 0x7ff0000000000000,
              0xfff0000000000000, 0x7ff8000000000000, 0x7ff0000000000001, 0x7ff8000012345678, 0xfff800000000abcd,
              0x0123456789abcdef)
        all &= check(Float64, b)
    end
    # (values, not bits)
    out("bswap(Float16(1.5)) = $(hex(reinterpret(UInt16, bswap(Float16(1.5)))))\n")
    out("bswap(1.0f0) = $(hex(reinterpret(UInt32, bswap(1.0f0))))\n")
    out("hton(2.5) = $(hex(reinterpret(UInt64, hton(2.5))))\n")
    out("all ok: $all\n")
    return all ? 0 : 1
end
end
