# julia test/makie_hookless_env.jl SRC_PROJECT_DIR DEST_DIR MAKIE_CHECKOUT: DEST_DIR becomes a copy of the environment in
# SRC_PROJECT_DIR (its Project.toml and manifest: WasmCodegen, WasmCompat and what they resolved to) in which Makie and
# ComputePipeline are the `Makie/` and `ComputePipeline/` directories of MAKIE_CHECKOUT (a checkout of asinghvi17-bot/Makie.jl).
# Used by test/makie.jl for the Makie without `_ispressed_collection_fallback`, which no registry has an older copy of.
using Pkg, TOML
src, dest, checkout = abspath.(ARGS)
for d in ("Makie", "ComputePipeline")
    isfile(joinpath(checkout, d, "Project.toml")) || error("$checkout is not a checkout of Makie.jl: no $d/Project.toml")
end
mkpath(dest)
cp(joinpath(src, "Project.toml"), joinpath(dest, "Project.toml"); force = true)
srcmanifest = joinpath(src, Base.manifest_names[findfirst(n -> isfile(joinpath(src, n)), Base.manifest_names)])
destmanifest = joinpath(dest, basename(srcmanifest))
# (paths in the copies are relative to where the original was: make them absolute)
function absolutize!(tbl)
    for (_, v) in tbl, e in (v isa AbstractVector ? v : [v])
        e isa AbstractDict && haskey(e, "path") && (e["path"] = abspath(src, e["path"]))
    end
end
proj = TOML.parsefile(joinpath(src, "Project.toml"))
haskey(proj, "sources") && absolutize!(proj["sources"])
open(io -> TOML.print(io, proj), joinpath(dest, "Project.toml"), "w")
man = TOML.parsefile(srcmanifest)
haskey(man, "deps") && absolutize!(man["deps"])
open(io -> TOML.print(io, man), destmanifest, "w")
Pkg.activate(dest)
Pkg.develop([PackageSpec(path = joinpath(checkout, "ComputePipeline")), PackageSpec(path = joinpath(checkout, "Makie"))])
Pkg.instantiate()
