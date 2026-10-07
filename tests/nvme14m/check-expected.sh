#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
# SPDX-License-Identifier: BSD-2-Clause
#
# check-expected.sh — acceptance check for the nvme14m (NVMe 1.4 mandatory
# baseline) suite.
#
# The device under test (QEMU's NVMe controller) is not 1.4(c)-conformant, so
# some spec-correct assertions fail on it. Those failures are *not* weakened;
# they are recorded, one Zig test name per line, in
# tests/nvme14m/known-qemu-failures.txt with a 1.4(c) citation. This script
# proves that no other test fails.
#
# Usage:
#   tests/nvme14m/check-expected.sh                 # run host tests + 6 batches
#   tests/nvme14m/check-expected.sh --parse-only F  # parse a captured log
#
# Exit status:
#   0  every failing Zig test is allow-listed (and host spec tests are green)
#   1  an unexpected failure, or a batch that never got as far as running
#      tests (build/boot failure), or a missing Zig summary in --parse-only
#   2  usage / environment error
#
# Environment:
#   NVME14M_ALLOW_LIST  allow-list path (default: <this dir>/known-qemu-failures.txt)
#   NVME14M_RUN_LOG     combined run log (default: /tmp/nvme14m-run.log)

set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
allow_list="${NVME14M_ALLOW_LIST:-$script_dir/known-qemu-failures.txt}"
run_log="${NVME14M_RUN_LOG:-/tmp/nvme14m-run.log}"

# The six batch programs, i.e. the `:` filter keys of workflow.lua.
batches="inspect features admin_errors io reset shutdown"

usage() {
  cat >&2 <<'EOF'
usage: check-expected.sh [--parse-only FILE]

  (no args)        run `zig build test`, then each of the six nvme14m batches,
                   and check that every failing Zig test is allow-listed.
  --parse-only F   skip the run; parse the already-captured log F instead.

environment:
  NVME14M_ALLOW_LIST  allow-list path (default: tests/nvme14m/known-qemu-failures.txt)
  NVME14M_RUN_LOG     combined log (default: /tmp/nvme14m-run.log)

exit 0 iff no unexpected failure; stale allow-list entries only warn.
EOF
}

# --- parsing ---------------------------------------------------------------

# has_zig_summary: stdin -> exit 0 iff it contains the Zig test summary line.
has_zig_summary() {
  grep -Eq '[0-9]+ passed; [0-9]+ skipped; [0-9]+ failed\.'
}

# failing_names: stdin -> stdout the names of failing Zig tests, one per line
# (sorted, deduplicated).
#
# Zig 0.16's test runner writes one record per test:
#
#     N/M <program>.test.<name>...<first diagnostic or error>
#     ...                 (further diagnostics, for passing tests)
#     OK                  (pass)  -- or --  FAIL (...), then a stack trace (fail)
#
# A passing test that printed nothing leaves `OK` on the `.test.` line; one
# that printed diagnostics leaves it on a later line. So a test's outcome
# cannot be read off the `.test.` line alone (the task brief's "does not end in
# OK" rule would call every chatty passing test a failure): classify the whole
# record instead. The `N/M ` prefix anchors the start and keeps source lines /
# stack-trace frames from matching.
failing_names() {
  awk '
    function flush() { if (start && failed) print name }
    /^[0-9]+\/[0-9]+ [^ ]*\.test\./ {
      flush()
      start = 1; failed = 0
      name = $0
      sub(/^[0-9]+\/[0-9]+ [^ ]*\.test\./, "", name)
      sub(/\.\.\..*$/, "", name)
      next
    }
    start && /^FAIL/ { failed = 1 }
    END { flush() }
  ' | sort -u
}

# allow_names: stdout = the allow-list entries (comments and blanks stripped).
allow_names() {
  sed -e 's/#.*//' "$allow_list" \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -v '^$' || true
}

# check_against_allow_list <failures>: report unexpected failures and stale
# entries; return 0 iff every failing name is in the allow-list.
check_against_allow_list() {
  local failures="$1"
  local allowed name unexpected=0
  allowed="$(allow_names)"

  while IFS= read -r name; do
    [ -z "$name" ] && continue
    if printf '%s\n' "$allowed" | grep -qxF -- "$name"; then
      :
    else
      echo "UNEXPECTED FAILURE: $name" >&2
      unexpected=1
    fi
  done <<< "$failures"

  while IFS= read -r name; do
    [ -z "$name" ] && continue
    if [ -z "$failures" ] || ! printf '%s\n' "$failures" | grep -qxF -- "$name"; then
      echo "warning: stale known-failure: $name" >&2
    fi
  done <<< "$allowed"

  return "$unexpected"
}

# --- run mode --------------------------------------------------------------

run_suite() {
  cd "$repo_root" || { echo "check-expected: cannot cd to $repo_root" >&2; return 2; }

  echo "== host spec tests: zig build test ==" >&2
  if ! zig build test; then
    echo "check-expected: FAIL: 'zig build test' (host spec tests) is not green" >&2
    return 1
  fi

  : > "$run_log" || { echo "check-expected: cannot write $run_log" >&2; return 2; }

  local infra=0 b rc tmp
  tmp="$(mktemp)" || return 2
  for b in $batches; do
    printf '\n=== nvme14m:%s ===\n' "$b" >> "$run_log"
    ./nvme-check.lua "nvme14m:$b" -a amd64 >"$tmp" 2>&1
    rc=$?
    cat "$tmp" >> "$run_log"

    # On success makac does not surface the test program's stdout/stderr (see
    # nvmecheck:libvfn-simple in testlib/lib/libvfn_simple.lua), so a green
    # batch has no Zig summary at all. Only a *non-zero* batch is expected to
    # carry one; if it does not, the batch died before its tests ran.
    if (( rc != 0 )) && ! has_zig_summary < "$tmp"; then
      echo "ERROR: nvme14m:$b exited $rc with no Zig test summary (build/boot failure?)" >&2
      infra=1
    fi
  done
  rm -f "$tmp"

  local failures; failures="$(failing_names < "$run_log")"
  local final=0
  check_against_allow_list "$failures" || final=1
  (( infra != 0 )) && final=1

  if (( final == 0 )); then
    echo "check-expected: OK (combined log: $run_log)" >&2
  else
    echo "check-expected: FAIL (combined log: $run_log)" >&2
  fi
  return "$final"
}

# --- parse-only mode -------------------------------------------------------

parse_only() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "check-expected: --parse-only needs an existing FILE (got '$file')" >&2
    return 2
  fi
  if ! has_zig_summary < "$file"; then
    echo "check-expected: $file has no Zig test summary line" >&2
    return 1
  fi
  local failures; failures="$(failing_names < "$file")"
  check_against_allow_list "$failures" || return 1
  return 0
}

# --- entry point -----------------------------------------------------------

main() {
  case "${1:-}" in
    "")
      run_suite || return $?
      ;;
    --parse-only)
      parse_only "${2:-}" || return $?
      ;;
    -h | --help)
      usage; return 0
      ;;
    *)
      echo "check-expected: unknown argument: $1" >&2
      usage; return 2
      ;;
  esac
  return 0
}

main "$@"
exit $?
