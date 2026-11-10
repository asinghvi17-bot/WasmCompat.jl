#!/bin/bash
# check.sh NAME [HOST_EXTENSIONS]: compile test/wasm/NAME.jl's `Prog.main` with WasmCodegen (trim = :safe), run it
# (PCRE2=1: with Base's Regex on PCRE2, see build.jl)
# on WASI in a JavaScript runtime and natively, and diff the outputs. Needs JULIA, WCG_JS (WasmCodegen's js/ directory)
# and the runtime: WASM_RUNTIME is `node` (the default, NODE), `bun` (BUN) or both (`"node bun"`; empty: none, only the build and the native run), each run diffed with the
# native output. NO_BUILD=1 reuses the module and the native output of an earlier run.
# The active project must have WasmCodegen, WasmCompat and the standard libraries the programs use.
# A program may need a package that is not in every project (makie: an unreleased Makie): its build then exits 77 and
# check.sh prints `NAME: SKIPPED, <why>` and exits 0.
# Exit status: 0 if every run is identical to the native one, or differs from it only by `expected/NAME.diff`, or is
# skipped because the engine lacks a feature the module needs (run.mjs exits 77 and names it; never silently;
# WASM_ALLOW_SKIP=0 makes a skip a failure, as in CI unless the gap is documented there).
set -u
D=$(cd "$(dirname "$0")" && pwd); n=$1; export EXT=${2:-}
O=${OUT:-$D/out}/$n; W=$O/work; mkdir -p $O
# (LIBGIT2: an empty home for both runs, so that the user's git configuration is not read natively; Julia keeps the
# depot of the real home)
if [ "${LIBGIT2:-0}" = 1 ]; then export JULIA_DEPOT_PATH=${JULIA_DEPOT_PATH:-$HOME/.julia:}; export HOME=$O/home; fi
# (makie: MAKIE=before|after, the load order of Makie and WasmCompat; after by default)
[ "$n" = makie ] && export MAKIE=${MAKIE:-after}
if [ "${NO_BUILD:-0}" != 1 ]; then
  $JULIA --startup-file=no $D/build.jl $D/$n.jl $O/$n.wasm > $O/build.log 2>&1; rc=$?
  # (build.jl exits 77 for a program whose package or version is not there: skipped, with the reason)
  if [ $rc = 77 ]; then echo "$n: SKIPPED, $(sed -n 's/^SKIP: //p' $O/build.log | head -1)"; exit 0; fi
  [ $rc = 0 ] || { tail -20 $O/build.log; exit 1; }
  rm -rf $W; mkdir -p $W
  [ "${LIBGIT2:-0}" = 1 ] && rm -rf $HOME && mkdir -p $HOME
  WORK=$W $JULIA --startup-file=no -e "include(\"$D/$n.jl\"); rc = Prog.main(); print(\"\n[main returned \$rc]\n\")" > $O/native.txt 2>&1
fi
status=0
for rt in ${WASM_RUNTIME-node}; do   # (WASM_RUNTIME= : build only)
  case $rt in
    node) js=(${NODE:-node} --no-warnings ${NODE_FLAGS:-}); out=$O/wasm.txt ;;
    bun) js=(${BUN:-bun} ${BUN_FLAGS:-}); out=$O/wasm-bun.txt ;;
    *) echo "check.sh: unknown WASM_RUNTIME $rt (node, bun)"; exit 2 ;;
  esac
  rm -rf $W; mkdir -p $W
  [ "${LIBGIT2:-0}" = 1 ] && rm -rf $HOME && mkdir -p $HOME
  "${js[@]}" $D/run.mjs $O/$n.wasm $W WORK=$W ${WASM_ENV:-} > $out 2>&1
  rc=$?
  diff $O/native.txt $out > $out.diff
  if [ $rc = 77 ]; then echo "$n ($rt): SKIPPED, an engine gap: $(sed -n 's/^SKIP: //p' $out | head -1)"
    [ "${WASM_ALLOW_SKIP:-1}" = 1 ] || { echo "$n ($rt): a skip is a failure here (WASM_ALLOW_SKIP=0)"; status=1; }
  elif [ ! -s $out.diff ]; then echo "$n ($rt): IDENTICAL"
  elif [ -f $D/expected/$n.diff ] && cmp -s $D/expected/$n.diff $out.diff; then echo "$n ($rt): IDENTICAL but for expected/$n.diff"
  else cat $out.diff; echo "$n ($rt): DIFFERENT (see above)"; status=1
  fi
done
exit $status
