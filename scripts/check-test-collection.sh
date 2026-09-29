#!/usr/bin/env bash
# Test-collection gate — the wiring half.
#
# The gate itself lives where the facts are, inside the test artifacts:
# `src/test/TestCollection.zig` compares each file's `test` declarations with the
# tests the compiler actually collected for that artifact (`builtin.test_functions`),
# and `tools/zmodu/src/main.zig` / (framework) `src/tests.zig` call it from a test
# named `test-collection gate: …`. It runs whenever that artifact runs, so CI's
# `Run tests` step is what normally executes it.
#
# This script adds the two things a test cannot check about itself:
#
#   1. **The exclusion claims are true.** A file listed in `other_artifacts` is
#      skipped by the gate on the claim that a *different* build step compiles its
#      tests. Here every entry must appear as a compile root in that package's
#      build.zig (`b.path("…")`), so the list cannot be used to silence a file
#      whose tests nothing runs.
#   2. **The gate has actually executed.** `zig build test` replays Zig's cached
#      run result when nothing the *compiler* read changed — and the gate reads
#      files the compiler never saw. A new source file that nothing imports
#      changes no artifact, so a cached replay would report success without ever
#      looking at it. The run below is forced (`-Dtest-force-run=true`), which is
#      the whole point of this script existing rather than a documented command.
#
# Rows in GATES are a ratchet, in the same spirit as check-production.sh's
# FUZZ_ROOTS: a package whose gate is added gets a row here, and a row whose gate
# call site has been deleted fails the check instead of skipping silently.
#
#   <package build.zig>|<gate call site>|<source path prefix in build.zig>|<test filter or ->
#
# The framework row (`build.zig|src/tests.zig|src`) is listed too. Its gate can
# only run inside the library artifact — a 2000+ test binary whose full
# execution takes minutes — so its forced run passes `-Dtest-filter=` and
# executes just the gate test. That is sound because the filter is applied at
# *runtime* by scripts/test-runner.zig: the binary still carries the complete
# `builtin.test_functions` list the gate compares against the tree, and the
# gate itself does the tree walk when it runs. The CLI row runs its whole
# suite instead: it costs seconds, and tools/zmodu/build.zig has no
# test-filter option. CI's `Run tests` step executes the same gate on a cold
# cache; this script is what forces it to look at the tree *now* instead of
# replaying a cached verdict.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ROOT/.zig-global-cache}"

GATES=(
  "tools/zmodu/build.zig|tools/zmodu/src/main.zig|src|-"
  "build.zig|src/tests.zig|src|test-collection gate"
)

fail=0

# The exclusion list of a gate call site: the strings of `tests_in_other_artifacts`.
exclusions_of() {
  awk '
    /const tests_in_other_artifacts = \[_\]\[\]const u8\{/ { in_list = 1; next }
    in_list {
      if (/:? *= *\[_\]\[\]const u8 &\.\{\}/) { in_list = 0; next }
      if ($0 ~ /^};/) { in_list = 0; next }
      # one "path.zig" per line, with a trailing comma and maybe a comment
      if (match($0, /"[^"]+\.zig"/)) {
        s = substr($0, RSTART + 1, RLENGTH - 2)
        print s
      }
    }
  ' "$1"
}

for row in "${GATES[@]}"; do
  IFS='|' read -r build_zig call_site prefix filter <<<"$row"
  if [[ ! -f "$call_site" ]]; then
    echo "check-test-collection: gate call site is missing: $call_site" >&2
    fail=1
    continue
  fi
  if ! grep -q 'test-collection gate:' "$call_site"; then
    echo "check-test-collection: no test named 'test-collection gate:' in $call_site — the gate was removed or renamed" >&2
    fail=1
  fi

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    if ! grep -qF "b.path(\"${prefix}/${entry}\")" "$build_zig"; then
      echo "check-test-collection: $call_site excludes '$entry', but ${build_zig} never compiles it (no b.path(\"${prefix}/${entry}\"))" >&2
      echo "check-test-collection: an exclusion must name a file another build step really compiles — otherwise its tests run nowhere" >&2
      fail=1
    fi
  done < <(exclusions_of "$call_site")

  # Forced run: the gate must look at the tree *now*, not at a cached verdict.
  # A row with a filter executes only the gate test — the filter is applied at
  # runtime (scripts/test-runner.zig), so the binary's `builtin.test_functions`
  # still lists every collected test and the comparison is unchanged.
  log="$(mktemp -t zm-test-collection.XXXXXX)"
  pkg_dir="$(dirname "$build_zig")"
  # Two spelled-out commands rather than an args array: the macOS bash is 3.2,
  # where `"${arr[@]}"` on an empty array trips `set -u`.
  if [[ "$filter" != "-" ]]; then
    (cd "$pkg_dir" && zig build test -Dtest-force-run=true "-Dtest-filter=$filter" --summary all) >"$log" 2>&1 && run_ok=1 || run_ok=0
  else
    (cd "$pkg_dir" && zig build test -Dtest-force-run=true --summary all) >"$log" 2>&1 && run_ok=1 || run_ok=0
  fi
  if [[ "$run_ok" -eq 1 ]]; then
    grep -E 'Build Summary:' "$log" | tail -1 | sed "s|^|check-test-collection: ${pkg_dir}: |"
    grep -E 'test-collection gate:' "$log" | sed 's/^/check-test-collection: /' || true
  else
    echo "check-test-collection: the test-collection gate failed in ${pkg_dir}:" >&2
    cat "$log" >&2
    fail=1
  fi
  rm -f "$log"
done

if [[ "$fail" -ne 0 ]]; then
  echo "check-test-collection: FAILED — see src/test/TestCollection.zig for what the gate checks" >&2
  exit 1
fi

echo "check-test-collection: OK"
