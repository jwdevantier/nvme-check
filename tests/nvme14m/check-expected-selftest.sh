#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
# SPDX-License-Identifier: BSD-2-Clause
#
# Self-test for tests/nvme14m/check-expected.sh — proves the parser without a
# device. Builds three synthetic Zig test-runner logs (mirroring Zig 0.16's
# output) and checks the exit status of `check-expected.sh --parse-only`:
#
#   (a) one unknown failure           -> non-zero, and the name is reported
#   (b) that failure allow-listed     -> 0 (and not called stale)
#   (c) a fully green log             -> 0
#   (d) a log with no Zig summary     -> non-zero (build/boot failure)

set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
check="$here/check-expected.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fails=0
ok()  { printf 'ok: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }
expect_rc() { # desc want got
  if [ "$2" = "$3" ]; then ok "$1 (exit $3)"; else bad "$1: want exit $2, got $3"; fi
}

if [ ! -x "$check" ]; then
  bad "check-expected.sh is not executable"
  exit 1
fi

# --- synthetic logs --------------------------------------------------------

# A failure, plus passing tests — including one whose first diagnostic line
# rides on the `.test.` line so its `OK` is pushed to the next line.
fail_log="$tmp/fail.log"
cat > "$fail_log" <<'EOF'
1/3 inspect.test.transport registers and controller enable state...    CAP=0x4008200f0107ff
OK
2/3 inspect.test.admin Identify Controller mandatory fields...    id-ctrl: vid=0x1b36
OK
3/3 admin_errors.test.admin error completions...expected 9, found 2
FAIL (TestExpectedEqual)
/tmp/nvmecheck-build-amd64-admin-errors/batches/admin_errors.zig:143:9: 0x0 in test.admin error completions (admin_errors.zig)
2 passed; 0 skipped; 1 failed.
EOF

# (a) unknown failure -> non-zero, named correctly.
out="$(env -u NVME14M_ALLOW_LIST "$check" --parse-only "$fail_log" 2>&1)"; rc=$?
expect_rc "(a) unknown failure" 1 "$rc"
case "$out" in
  *"UNEXPECTED FAILURE: admin error completions"*) ok "(a) parsed the failing name";;
  *) bad "(a) did not report 'admin error completions'";;
esac

# (b) same failure, allow-listed -> 0, and the used entry is not called stale.
allow="$tmp/allow.txt"
printf '%s\n' 'admin error completions   # temp entry for check-expected-selftest' > "$allow"
out="$(NVME14M_ALLOW_LIST="$allow" "$check" --parse-only "$fail_log" 2>&1)"; rc=$?
expect_rc "(b) allow-listed failure" 0 "$rc"
case "$out" in
  *"stale known-failure"*) bad "(b) called the used entry stale";;
  *) ok "(b) used entry not reported stale";;
esac

# (c) green log -> 0 (this also exercises the multi-line passing record).
green_log="$tmp/green.log"
cat > "$green_log" <<'EOF'
1/2 inspect.test.transport registers and controller enable state...    CAP=0x4008200f0107ff
OK
2/2 inspect.test.admin Identify Controller mandatory fields...    id-ctrl: vid=0x1b36
OK
2 passed; 0 skipped; 0 failed.
EOF
env -u NVME14M_ALLOW_LIST "$check" --parse-only "$green_log" >/dev/null 2>&1
expect_rc "(c) green log" 0 "$?"

# (d) no Zig summary -> non-zero.
head -n 4 "$fail_log" > "$tmp/nosummary.log"
env -u NVME14M_ALLOW_LIST "$check" --parse-only "$tmp/nosummary.log" >/dev/null 2>&1
expect_rc "(d) log without a Zig summary" 1 "$?"

# (e) a stale allow-list entry only warns (still exit 0).
stale="$tmp/stale.txt"
printf '%s\n' 'some test that never ran   # temp stale entry' > "$stale"
out="$(NVME14M_ALLOW_LIST="$stale" "$check" --parse-only "$green_log" 2>&1)"; rc=$?
expect_rc "(e) stale entry only warns" 0 "$rc"
case "$out" in
  *"warning: stale known-failure: some test that never ran"*) ok "(e) stale entry warned";;
  *) bad "(e) stale entry not warned";;
esac

# --- result ----------------------------------------------------------------

if (( fails > 0 )); then
  printf '\nself-test: %d check(s) FAILED\n' "$fails" >&2
  exit 1
fi
printf 'self-test: all checks passed\n'
