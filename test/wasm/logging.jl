# WasmCompatLoggingExt: the logging macros print as ConsoleLogger(stderr) does
module Prog
using Logging
@noinline f(x) = x > 1 ? error("boom $x") : x
function main()
    @info "plain info"
    @info "info with values" n = 3 s = "str" sym = :abc ver = v"1.2.3"
    @warn "a warning" key = :sym
    try
        f(2)
    catch err
        # (asserted: a caught `err` as it is is an `Any`, whose keyword pairs WasmCodegen does not compile)
        e = err::ErrorException
        @error "caught an error" exception = e
        @warn "caught, as a value" e
    end
    for i in 1:3
        @warn "only once" maxlog = 1 i
    end
    @debug "hidden"
    @info "multi\nline\nmessage" x = 1.5
    @warn "interpolated $(1 + 2) message"
    return 0
end
end
