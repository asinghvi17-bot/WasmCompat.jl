"""
    WasmCompatLoggingExt

Logging for WasmCodegen's closed world. The logging macros find the current logger in a scoped
value (an `AbstractLogger`, so every call on it is dynamic) and pass the message and the key-value
pairs to `handle_message` unspecialized. juliac's trim patches, which WasmCodegen applies, make
`current_logger_for_env` return `nothing`, so a trimmed program compiles its log calls but prints
nothing.

In Wasm, with this extension, `current_logger_for_env` returns a `WasmStderrLogger` instead: a
concrete logger, so the macros' calls on it are static. It prints what Base's default
`ConsoleLogger(stderr)` prints for a stream without color: the box, the level, the message's lines,
the `key = value` lines (values shown as `text/plain`, exceptions with `showerror`) and, for
warnings and errors, `@ Module file:line`. `maxlog` is counted per log call as `ConsoleLogger`
counts it.

Differences from the native default logger, by design:
- the logger is fixed: `with_logger` and `global_logger` are not consulted, the minimum level is
  `Info` and `JULIA_DEBUG` is ignored (`@debug` prints nothing);
- an exception logged with its backtrace (`exception = (err, bt)`) is shown without the backtrace;
- every value is shown as a value of a type not known at compile time (the macros pass them as
  `Any`): of one of the types of `show_any` below (strings, symbols, numbers, versions, UUIDs),
  or an exception (`WasmCompat.showerror_hook`, then WasmCodegen's `Runtime.showerror_any`);
  another, vectors included, is shown as `(a value of type T)`. The methods of this module only
  run in Wasm (natively the logger is never current).
- a log call whose key-value pairs include a value of a type not known at compile time (a
  caught `err` without a type assertion) doesn't compile: its keyword pairs, `Base.Pairs{Symbol}`
  of a `NamedTuple` with an abstract field type, are made by a call on a type known only at run
  time (a limit of the code generator; native trim compiles it). Assert the type at the call
  (`exception = err::MyError`) or pass a value of a concrete type.
"""
module WasmCompatLoggingExt

import Logging
import WasmCodegen
import WasmCompat
using Base.CoreLogging: AbstractLogger, LogLevel, Info, Warn

"The logger of a program compiled to Wasm (see the module's documentation)."
struct WasmStderrLogger <: AbstractLogger
    min_level::LogLevel
end

# (the logger is read from a global, of a type with a field: the overlay must not be a
# constant, or inference evaluates the call at compile time with the native method, which
# juliac's trim patches make return `nothing`; see `WasmCodegen.Runtime.@wasm_method`)
const LOGGER = Ref(WasmStderrLogger(Info))
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function Base.CoreLogging.current_logger_for_env(
        std_level::LogLevel, group, _module)
    # (the level against a constant: a call below it compiles to nothing, its values unbuilt)
    return std_level >= Info ? LOGGER[] : nothing
end

Base.CoreLogging.shouldlog(::WasmStderrLogger, level, _module, group, id) = true
Base.CoreLogging.min_enabled_level(logger::WasmStderrLogger) = logger.min_level
Base.CoreLogging.catch_exceptions(::WasmStderrLogger) = true

const MAXLOG = Dict{Symbol, Int}()

# (the macros call this; its arguments are specialized on, unlike `handle_message`'s)
function Base.CoreLogging.handle_message_nothrow(::WasmStderrLogger, level::LogLevel, message, _module, group, id,
        file, line; kwargs...)
    try
        buf = IOBuffer()
        log_record(buf, level, message, _module, id, file, line, values(kwargs)) || return nothing
        write(Core.stderr, take!(buf))
    catch err
        # (as Base's `logging_error`, without the backtrace)
        write(Core.stderr, string("Error: Exception while generating log record in module ", string_any(_module),
            " at ", string_any(file), ":", string_any(line), "\n"))
    end
    return nothing
end

# (the macros call this when building the message or its values throws: Base's method calls
# `handle_message` on an unspecialized logger)
function Base.CoreLogging.logging_error(::WasmStderrLogger, level, _module, group, id, filepath, line,
        @nospecialize(err), real::Bool)
    buf = IOBuffer()
    msg = string("Exception while generating log record in module ", string_any(_module), " at ",
        string_any(filepath), ":", string_any(line))
    # (not `(; exception = err)`: a tuple of an `Any` value is not compiled; the exception
    # shown directly instead)
    log_record(buf, Base.CoreLogging.Error, msg, _module, id, filepath, line, (; exception = ErrorShown(err)))
    write(Core.stderr, take!(buf))
    return nothing
end

"""
    log_record(io, level, message, _module, id, file, line, kwargs::NamedTuple) -> Bool

Write to `io` what `ConsoleLogger` writes for the record (a stream without color, `right_justify
= 0`). `false` if `maxlog` suppresses it.
"""
function log_record(io::IO, level::LogLevel, @nospecialize(message), @nospecialize(_module), @nospecialize(id),
        @nospecialize(file), @nospecialize(line), kwargs::NamedTuple)
    if haskey(kwargs, :maxlog)
        maxlog = kwargs.maxlog
        if maxlog isa Core.BuiltinInts && id isa Symbol
            remaining = get!(MAXLOG, id, Int(maxlog))
            remaining == 0 && return false
            MAXLOG[id] = remaining - 1
        end
    end
    msglines = Tuple{Int, String}[(0, String(l)) for l in split(chomp(message_text(message)), '\n')]
    names = keys(kwargs)
    # (as ConsoleLogger: each value shown limited, in its share of the stream's rows)
    hasmaxlog = haskey(kwargs, :maxlog) ? 1 : 0
    dsize = displaysize()
    rows_per_value = max(1, dsize[1] ÷ (length(kwargs) + 1 - hasmaxlog))
    for i in 1:length(kwargs)
        key = names[i]
        key === :maxlog && continue
        vbuf = IOBuffer()
        valio = IOContext(vbuf, :displaysize => (rows_per_value, dsize[2] - 5), :limit => true)
        show_any(valio, getfield(kwargs, i))
        vallines = split(String(take!(vbuf)), '\n')
        if length(vallines) == 1
            push!(msglines, (2, string(key, " = ", vallines[1])))
        else
            push!(msglines, (2, string(key, " =")))
            append!(msglines, ((3, String(l)) for l in vallines))
        end
    end
    prefix = string(level == Warn ? "Warning" : string(level), ':')
    suffix = Info <= level < Warn ? "" : record_suffix(_module, file, line)
    # (`right_justify = 0`: a suffix goes on a line of its own)
    isempty(suffix) || push!(msglines, (0, ""))
    for (i, (indent, msg)) in enumerate(msglines)
        boxstr = length(msglines) == 1 ? "[ " : i == 1 ? "┌ " : i < length(msglines) ? "│ " : "└ "
        print(io, boxstr)
        i == 1 && !isempty(prefix) && print(io, prefix, " ")
        print(io, " "^indent, msg)
        i == length(msglines) && !isempty(suffix) && print(io, suffix)
        println(io)
    end
    return true
end

# `default_metafmt`'s suffix
function record_suffix(@nospecialize(_module), @nospecialize(file), @nospecialize(line))
    suffix = ""
    _module !== nothing && (suffix *= module_text(_module))
    if file !== nothing
        _module !== nothing && (suffix *= " ")
        suffix *= contractuser(file isa String ? file : string_any(file))
        if line !== nothing
            suffix *= ":" * (line isa Int ? string(line) : line isa UnitRange{Int} ? string(first(line), "-", last(line)) : string_any(line))
        end
    end
    return isempty(suffix) ? suffix : "@ " * suffix
end
# `Base.contractuser(path)` without a regex (Base's goes through `relpath`): the home directory
# as `~`, for the normalized absolute paths of log calls
function contractuser(path::String)
    home = try
        rstrip(homedir(), '/')
    catch
        return path
    end
    isempty(home) && return path
    path == home && return "~"
    return startswith(path, string(home, '/')) ? string("~", SubString(path, ncodeunits(home) + 1)) : path
end
module_text(@nospecialize(m)) = m isa Module ? string(m::Module) : string_any(m)

# the message as `string(message)` gives it
message_text(@nospecialize(m)) =
    m isa String ? m :
    m isa SubString{String} ? String(m) :
    m isa LazyString ? String(m::LazyString) :
    string_any(m)

function string_any(@nospecialize(x))
    io = IOBuffer()
    print_any(io, x)
    return String(take!(io))
end
# `print(io, x)` of a value of a type not known at compile time
function print_any(io::IO, @nospecialize(x))
    x isa AbstractString ? print(io, x isa String ? x : String(x)) :
    x isa Symbol ? print(io, x) :
    show_any(io, x)
end

"An exception of a type not known at compile time, as a value of a known type (see `logging_error`)."
struct ErrorShown
    err::Any
end

"""
    show_any(io, x)

`ConsoleLogger`'s `showvalue(io, x)` (`show(io, "text/plain", x)`; `showerror` of an exception)
of a value of a type not known at compile time: by `isa` over common types; natively for any.
"""
function show_any(io::IO, @nospecialize(x))
    if x isa ErrorShown
        showerror_any(io, x.err)
    elseif x isa Tuple{Exception, Any}
        showerror_any(io, x[1])
    elseif x isa Exception
        showerror_any(io, x)
    elseif x isa String
        show(io, MIME"text/plain"(), x::String)
    elseif x isa SubString{String}
        show(io, MIME"text/plain"(), x::SubString{String})
    elseif x isa Symbol
        show(io, MIME"text/plain"(), x::Symbol)
    elseif x isa Char
        show(io, MIME"text/plain"(), x::Char)
    elseif x isa Bool
        show(io, MIME"text/plain"(), x::Bool)
    elseif x isa Int64
        show(io, MIME"text/plain"(), x::Int64)
    elseif x isa Int32
        show(io, MIME"text/plain"(), x::Int32)
    elseif x isa UInt64
        show(io, MIME"text/plain"(), x::UInt64)
    elseif x isa UInt32
        show(io, MIME"text/plain"(), x::UInt32)
    elseif x isa UInt8
        show(io, MIME"text/plain"(), x::UInt8)
    elseif x isa Float64
        show(io, MIME"text/plain"(), x::Float64)
    elseif x isa Nothing
        show(io, MIME"text/plain"(), x::Nothing)
    elseif x isa VersionNumber
        show(io, MIME"text/plain"(), x::VersionNumber)
    elseif x isa Base.UUID
        show(io, MIME"text/plain"(), x::Base.UUID)
    elseif x isa Base.SHA1
        show(io, MIME"text/plain"(), x::Base.SHA1)
    else
        print(io, "(a value of type ", typeof(x), ")")
    end
    return nothing
end

# `showerror(io, e)` of an exception of a type not known at compile time: the program's
# (`WasmCompat.showerror_hook`), then WasmCodegen's `Runtime.showerror_any`
function showerror_any(io::IO, @nospecialize(e))
    WasmCompat.showerror_hook(io, e) && return nothing
    WasmCodegen.Runtime.showerror_any(io, e)
    return nothing
end

end # module
