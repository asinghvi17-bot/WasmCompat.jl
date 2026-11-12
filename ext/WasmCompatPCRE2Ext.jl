"""
    WasmCompatPCRE2Ext

Base's `Regex` on PCRE2 itself, compiled to WebAssembly: the `pcre2_*_8` functions Base's
`pcre.jl` calls are implemented here (`WasmCodegen.Config(foreign_functions)`) over a separate
Wasm module, PCRE2_wasm_jll's `libpcre2-8.wasm`, whose exports the host gives the program as
the import module `"pcre2"` (`Config(import_libraries)`; `js/pcre2.mjs`). That module has its own
memory: PCRE2's pointers are addresses in it, which the program holds as integers, and the
program copies patterns and subjects in, and results out, through the module's `malloc`,
`free` and `mem_load*`/`mem_store*` exports.

What Base holds stays Julia objects: a compiled pattern is a `Code`, the match data a
`MatchData` (by `pointer_from_objref`); the ovector and the name table Base reads through
pointers are Julia arrays, copied from the module's memory.

Three differences from calling PCRE2 natively:

- **No JIT.** Base compiles every pattern with `PCRE2_MATCH_INVALID_UTF`, and without the JIT
  PCRE2 then checks the subject's UTF-8 on every match, from the start offset to its end, so
  `eachmatch` over a subject would be quadratic. A subject is checked once, when it is copied
  in; a valid one is matched, at a character boundary, by a twin of the pattern compiled
  without that option, told not to check (`PCRE2_NO_UTF_CHECK`). Natively the JIT refuses
  `\\C` in UTF mode, and so does `jit_compile` here (`PCRE2_ERROR_JIT_UNSUPPORTED`), so that
  Base throws the same error.
- **The subject is in the module's memory only during `pcre2_match`.** PCRE2's
  `substring_copy_bynumber` reads the subject the match data points to; here the copy is made
  from the subject Base passed to the match, which Base keeps while it uses the match data.
- **Finalizers do not run in a module,** so `Regex` never frees its pattern: compiled patterns
  are kept by (pattern, options), and each is compiled once per instance.
"""
module WasmCompatPCRE2Ext

using WasmCodegen
import PCRE2_wasm_jll
import WasmCompat

## the module's exports (the import module "pcre2"): wasm32, so addresses and sizes are UInt32

malloc(n::UInt32) = ccall((:malloc, "pcre2"), UInt32, (UInt32,), n)
free(a::UInt32) = ccall((:free, "pcre2"), Cvoid, (UInt32,), a)
load8(a::UInt32) = ccall((:mem_load8, "pcre2"), UInt32, (UInt32,), a)
load32(a::UInt32) = ccall((:mem_load32, "pcre2"), UInt32, (UInt32,), a)
load64(a::UInt32) = ccall((:mem_load64, "pcre2"), UInt64, (UInt32,), a)
store8(a::UInt32, v::UInt32) = ccall((:mem_store8, "pcre2"), Cvoid, (UInt32, UInt32), a, v)
store64(a::UInt32, v::UInt64) = ccall((:mem_store64, "pcre2"), Cvoid, (UInt32, UInt64), a, v)

pcre2_compile(pat::UInt32, len::UInt32, opts::UInt32, err::UInt32, off::UInt32) =
    ccall((:pcre2_compile_8, "pcre2"), UInt32, (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32),
          pat, len, opts, err, off, UInt32(0))
pcre2_pattern_info(code::UInt32, what::UInt32, where::UInt32) =
    ccall((:pcre2_pattern_info_8, "pcre2"), Int32, (UInt32, UInt32, UInt32), code, what, where)
pcre2_match_data_create(code::UInt32) =
    ccall((:pcre2_match_data_create_from_pattern_8, "pcre2"), UInt32, (UInt32, UInt32), code, UInt32(0))
pcre2_match_data_free(md::UInt32) = ccall((:pcre2_match_data_free_8, "pcre2"), Cvoid, (UInt32,), md)
pcre2_ovector_pointer(md::UInt32) = ccall((:pcre2_get_ovector_pointer_8, "pcre2"), UInt32, (UInt32,), md)
pcre2_ovector_count(md::UInt32) = ccall((:pcre2_get_ovector_count_8, "pcre2"), UInt32, (UInt32,), md)
pcre2_match(code::UInt32, subj::UInt32, len::UInt32, start::UInt32, opts::UInt32, md::UInt32) =
    ccall((:pcre2_match_8, "pcre2"), Int32, (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32),
          code, subj, len, start, opts, md, UInt32(0))
pcre2_substring_length(md::UInt32, n::UInt32, len::UInt32) =
    ccall((:pcre2_substring_length_bynumber_8, "pcre2"), Int32, (UInt32, UInt32, UInt32), md, n, len)
pcre2_substring_number_from_name(code::UInt32, name::UInt32) =
    ccall((:pcre2_substring_number_from_name_8, "pcre2"), Int32, (UInt32, UInt32), code, name)
pcre2_get_error_message(err::Int32, buf::UInt32, len::UInt32) =
    ccall((:pcre2_get_error_message_8, "pcre2"), Int32, (Int32, UInt32, UInt32), err, buf, len)

const UTF = 0x00080000
const MATCH_INVALID_UTF = 0x04000000
const NO_UTF_CHECK = 0x40000000
const INFO_ALLOPTIONS = UInt32(0)
const INFO_JITSIZE = UInt32(10)
const INFO_NAMECOUNT = UInt32(17)
const INFO_NAMEENTRYSIZE = UInt32(18)
const INFO_NAMETABLE = UInt32(19)
const INFO_SIZE = UInt32(22)
const INFO_HASBACKSLASHC = UInt32(23)
const INFO_FRAMESIZE = UInt32(24)
const ERROR_NOMEMORY = Int32(-48)
const ERROR_JIT_BADOPTION = Int32(-45)
const ERROR_JIT_UNSUPPORTED = Int32(-68)
const UNSET32 = typemax(UInt32)

# 64 bytes of the module's memory for out-parameters, allocated on first use
const SCRATCH = Ref{UInt32}(0)
function scratch()
    SCRATCH[] == 0 && (SCRATCH[] = malloc(UInt32(64)))
    return SCRATCH[]
end

"Copies `n` bytes from `p` (Julia's memory) to `a` (the module's), 8 at a time; whether they are ASCII."
function copyin!(a::UInt32, p::Ptr{UInt8}, n::Int)
    i = 0
    high = UInt64(0)
    while i + 8 <= n
        v = UInt64(0)
        for k in 1:8
            v |= UInt64(unsafe_load(p, i + k)) << (8 * (k - 1))
        end
        high |= v
        store64(a + UInt32(i), v)
        i += 8
    end
    while i < n
        b = unsafe_load(p, i + 1)
        high |= b
        store8(a + UInt32(i), UInt32(b))
        i += 1
    end
    return high & 0x8080808080808080 == 0
end

"`s` NUL-terminated in the module's memory, which the caller frees."
function cstring(s::String)
    n = ncodeunits(s)
    a = malloc(UInt32(n + 1))
    GC.@preserve s copyin!(a, pointer(s), n)
    store8(a + UInt32(n), UInt32(0))
    return a
end

## compiled patterns

mutable struct Code
    addr::UInt32           # the pcre2_code
    pattern::String
    options::UInt32
    twin::UInt32           # the pattern compiled without MATCH_INVALID_UTF, once needed
    twin_state::Int8       # 0: not compiled, 1: compiled, -1: none
    jit::Int32             # what pcre2_jit_compile returns natively, as far as it is known here
    nametable::Vector{UInt8}
    names_copied::Bool
end

const CODES = Dict{Tuple{String,UInt32},Code}()

code_of(p::Ptr{Cvoid}) = unsafe_pointer_to_objref(p)::Code

function info32(addr::UInt32, what::UInt32)
    s = scratch()
    store64(s, UInt64(0))
    rc = pcre2_pattern_info(addr, what, s)
    return rc == 0 ? load32(s) : UInt32(0)
end

"`pcre2_compile_8(pattern, length, options, errorcode, erroroffset, ccontext)`"
function compile(pattern::Ptr{UInt8}, len::UInt, options::UInt32, errorcode::Ptr{Cint},
                 erroroffset::Ptr{UInt}, ccontext::Ptr{Cvoid})
    text = unsafe_string(pattern, len)
    c = get(CODES, (text, options), nothing)
    c === nothing || return pointer_from_objref(c)
    n = Int(len)
    pat = malloc(UInt32(max(n, 1)))
    copyin!(pat, pattern, n)
    s = scratch()
    addr = pcre2_compile(pat, UInt32(n), options, s, s + UInt32(4))
    free(pat)
    if addr == 0
        (unsafe_pointer_to_objref(errorcode)::Base.RefValue{Cint})[] = reinterpret(Int32, load32(s))
        (unsafe_pointer_to_objref(erroroffset)::Base.RefValue{UInt})[] = UInt(load32(s + UInt32(4)))
        return C_NULL
    end
    # (the JIT does not support \C in UTF mode)
    utf = info32(addr, INFO_ALLOPTIONS) & UTF != 0
    jit = utf && info32(addr, INFO_HASBACKSLASHC) != 0 ? ERROR_JIT_UNSUPPORTED : ERROR_JIT_BADOPTION
    c = Code(addr, text, options, UInt32(0), Int8(0), jit, UInt8[], false)
    CODES[(text, options)] = c
    return pointer_from_objref(c)
end

"`pcre2_jit_compile_8(code, options)`: there is no JIT."
jit_compile(code::Ptr{Cvoid}, options::UInt32) = code_of(code).jit

"`pcre2_code_free_8(code)`: compiled patterns are kept (see `CODES`)."
code_free(code::Ptr{Cvoid}) = nothing

function twin(c::Code)
    if c.twin_state == 0
        n = ncodeunits(c.pattern)
        pat = malloc(UInt32(max(n, 1)))
        GC.@preserve c copyin!(pat, pointer(c.pattern), n)
        s = scratch()
        c.twin = pcre2_compile(pat, UInt32(n), c.options & ~MATCH_INVALID_UTF, s, s + UInt32(4))
        free(pat)
        c.twin_state = c.twin == 0 ? Int8(-1) : Int8(1)
    end
    return c.twin
end

function nametable(c::Code)
    if !c.names_copied
        count = info32(c.addr, INFO_NAMECOUNT)
        size = info32(c.addr, INFO_NAMEENTRYSIZE)
        s = scratch()
        pcre2_pattern_info(c.addr, INFO_NAMETABLE, s)
        table = load32(s)
        n = Int(count) * Int(size)
        v = Vector{UInt8}(undef, n)
        for i in 1:n
            v[i] = load8(table + UInt32(i - 1)) % UInt8
        end
        c.nametable = v
        c.names_copied = true
    end
    return c.nametable
end

"`pcre2_pattern_info_8(code, what, where)`, for the results Base reads: integers and the name table."
function pattern_info(code::Ptr{Cvoid}, what::UInt32, where::Ptr{Cvoid})
    c = code_of(code)
    if what == INFO_NAMETABLE
        (unsafe_pointer_to_objref(where)::Base.RefValue{Ptr{UInt8}})[] = pointer(nametable(c))
        return Cint(0)
    end
    s = scratch()
    store64(s, UInt64(0))
    rc = pcre2_pattern_info(c.addr, what, s)
    rc == 0 || return rc
    if what == INFO_SIZE || what == INFO_FRAMESIZE || what == INFO_JITSIZE
        (unsafe_pointer_to_objref(where)::Base.RefValue{UInt})[] = UInt(load32(s))
    else
        (unsafe_pointer_to_objref(where)::Base.RefValue{UInt32})[] = load32(s)
    end
    return Cint(0)
end

"`pcre2_substring_number_from_name_8(code, name)`"
function substring_number_from_name(code::Ptr{Cvoid}, name::Cstring)
    a = cstring(unsafe_string(convert(Ptr{UInt8}, name)))
    rc = pcre2_substring_number_from_name(code_of(code).addr, a)
    free(a)
    return rc
end

## subjects

# The subject in the module's memory: the last one matched, kept for the next match of the
# same pointer and length (a string's bytes do not change, and a pointer's address names its
# string), and whether it is valid UTF-8.
mutable struct Staged
    key::UInt64
    len::UInt
    addr::UInt32
    cap::UInt32
    valid::Bool
end

const STAGED = Staged(UInt64(0), UInt(0), UInt32(0), UInt32(0), false)

function stage!(subject::Ptr{UInt8}, len::UInt)
    st = STAGED
    key = UInt64(UInt(subject))
    st.cap != 0 && st.key == key && st.len == len && return st
    if st.cap < len || st.cap == 0
        st.cap == 0 || free(st.addr)
        st.cap = UInt32(max(len, UInt(64)))
        st.addr = malloc(st.cap)
    end
    ascii = copyin!(st.addr, subject, Int(len))
    st.valid = ascii || isvalid(String, unsafe_string(subject, len))
    st.key = key
    st.len = len
    return st
end

## match data

mutable struct MatchData
    addr::UInt32           # the pcre2_match_data
    ovaddr::UInt32         # its ovector
    ovector::Vector{UInt}  # a copy, for Base's pointer
    subject::Ptr{UInt8}    # of the last match, which Base keeps while it uses this
end

data_of(p::Ptr{Cvoid}) = unsafe_pointer_to_objref(p)::MatchData

"`pcre2_match_data_create_from_pattern_8(code, gcontext)`"
function match_data_create(code::Ptr{Cvoid}, gcontext::Ptr{Cvoid})
    md = pcre2_match_data_create(code_of(code).addr)
    md == 0 && return C_NULL
    n = 2 * Int(pcre2_ovector_count(md))
    d = MatchData(md, pcre2_ovector_pointer(md), Vector{UInt}(undef, n), Ptr{UInt8}(0))
    return pointer_from_objref(d)
end

"`pcre2_match_data_free_8(match_data)`"
function match_data_free(md::Ptr{Cvoid})
    d = data_of(md)
    d.addr == 0 || pcre2_match_data_free(d.addr)
    d.addr = UInt32(0)
    return nothing
end

"`pcre2_get_ovector_count_8(match_data)`"
ovector_count(md::Ptr{Cvoid}) = UInt32(length(data_of(md).ovector) ÷ 2)

"`pcre2_get_ovector_pointer_8(match_data)`: the ovector, copied, and `PCRE2_UNSET` widened."
function ovector_pointer(md::Ptr{Cvoid})
    d = data_of(md)
    v = d.ovector
    for k in 1:length(v)÷2
        w = load64(d.ovaddr + UInt32(8 * (k - 1)))
        a, b = w % UInt32, (w >> 32) % UInt32
        @inbounds v[2k-1] = a == UNSET32 ? typemax(UInt) : UInt(a)
        @inbounds v[2k] = b == UNSET32 ? typemax(UInt) : UInt(b)
    end
    return pointer(v)
end

"`pcre2_match_8(code, subject, length, startoffset, options, match_data, mcontext)`"
function match(code::Ptr{Cvoid}, subject::Ptr{UInt8}, len::UInt, start::UInt, options::UInt32,
               md::Ptr{Cvoid}, mcontext::Ptr{Cvoid})
    c = code_of(code)
    d = data_of(md)
    st = stage!(subject, len)
    addr, opts = c.addr, options
    if st.valid && c.options & MATCH_INVALID_UTF != 0 &&
       (start >= len || unsafe_load(subject, start + 1) & 0xc0 != 0x80)
        t = twin(c)
        t == 0 || ((addr, opts) = (t, options | NO_UTF_CHECK))
    end
    d.subject = subject
    return pcre2_match(addr, st.addr, UInt32(len), UInt32(min(start, UInt(typemax(UInt32)))), opts, d.addr)
end

"`pcre2_substring_length_bynumber_8(match_data, number, length)`"
function substring_length_bynumber(md::Ptr{Cvoid}, number::Cint, len::Ptr{UInt})
    s = scratch()
    rc = pcre2_substring_length(data_of(md).addr, reinterpret(UInt32, number), s)
    rc == 0 && ((unsafe_pointer_to_objref(len)::Base.RefValue{UInt})[] = UInt(load32(s)))
    return rc
end

"`pcre2_substring_copy_bynumber_8(match_data, number, buffer, bufflen)`, from the subject of the match."
function substring_copy_bynumber(md::Ptr{Cvoid}, number::UInt32, buffer::Ptr{UInt8}, bufflen::Ptr{UInt})
    d = data_of(md)
    s = scratch()
    rc = pcre2_substring_length(d.addr, number, s)
    rc < 0 && return rc
    size = UInt(load32(s))
    ref = unsafe_pointer_to_objref(bufflen)::Base.RefValue{UInt}
    size + 1 > ref[] && return ERROR_NOMEMORY
    left = UInt(load32(d.ovaddr + UInt32(8) * number))
    for k in UInt(1):size
        unsafe_store!(buffer, unsafe_load(d.subject, left + k), k)
    end
    unsafe_store!(buffer, 0x00, size + 1)
    ref[] = size
    return Cint(0)
end

"`pcre2_get_error_message_8(errorcode, buffer, bufflen)`"
function get_error_message(errorcode::Cint, buffer::Ptr{UInt8}, bufflen::UInt)
    n = UInt32(min(bufflen, UInt(typemax(UInt32))))
    buf = malloc(max(n, UInt32(1)))
    rc = pcre2_get_error_message(errorcode, buf, n)
    # (the message and its NUL; truncated to the buffer if it does not fit)
    m = rc >= 0 ? Int(rc) + 1 : rc == ERROR_NOMEMORY ? Int(n) : 0
    for k in 1:m
        unsafe_store!(buffer, load8(buf + UInt32(k - 1)) % UInt8, k)
    end
    free(buf)
    return rc
end

const FUNCTIONS = Pair{Tuple{Symbol,String},Any}[
    (Symbol(:pcre2_, name, :_8), "libpcre2-8") => f for (name, f) in (
        :compile => compile, :jit_compile => jit_compile, :code_free => code_free,
        :pattern_info => pattern_info, :substring_number_from_name => substring_number_from_name,
        :match_data_create_from_pattern => match_data_create, :match_data_free => match_data_free,
        :get_ovector_count => ovector_count, :get_ovector_pointer => ovector_pointer, :match => match,
        :substring_length_bynumber => substring_length_bynumber,
        :substring_copy_bynumber => substring_copy_bynumber, :get_error_message => get_error_message)]

## the build's side

const PCRE2_CONFIG_VERSION = UInt32(11)

"The version of the PCRE2 the compiling Julia runs, as `major.minor`."
function native_pcre2_version()
    buf = Vector{UInt8}(undef, 64)
    n = ccall((:pcre2_config_8, Base.PCRE.PCRE_LIB), Cint, (UInt32, Ptr{UInt8}), PCRE2_CONFIG_VERSION, buf)
    n > 0 || error("WasmCompat: could not read the native PCRE2's version")
    s = GC.@preserve buf unsafe_string(pointer(buf))
    return VersionNumber(first(split(s)))
end

function WasmCompat.pcre2_module()
    isdefined(PCRE2_wasm_jll, :libpcre2_8_wasm32_wasm) ||
        error("WasmCompat: this PCRE2_wasm_jll has no standalone module (`libpcre2_8_wasm32_wasm`)")
    return getglobal(PCRE2_wasm_jll, :libpcre2_8_wasm32_wasm)::String
end

function WasmCompat.pcre2_config(config::WasmCodegen.Config; check_version::Bool = true)
    config.host === :wasi ||
        throw(ArgumentError("WasmCompat.pcre2_config: the PCRE2 module is a host import, for Config(host = :wasi)"))
    if check_version
        native = native_pcre2_version()
        wasm = pkgversion(PCRE2_wasm_jll)
        (native.major, native.minor) == (wasm.major, wasm.minor) ||
            error("WasmCompat: PCRE2_wasm_jll is PCRE2 $(wasm.major).$(wasm.minor), the compiling Julia's PCRE2 is ",
                  "$(native.major).$(native.minor): install the PCRE2_wasm_jll of the same version, whose ",
                  "error messages and offsets are the native ones (or pass check_version = false)")
    end
    kw = Dict{Symbol,Any}(k => getfield(config, k) for k in fieldnames(WasmCodegen.Config))
    kw[:foreign_functions] = [config.foreign_functions; FUNCTIONS]
    kw[:import_libraries] = unique!([config.import_libraries; "pcre2"])
    return WasmCodegen.Config(; kw...)
end

end # module
