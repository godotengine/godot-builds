#!/usr/bin/env bash
#
# Runs the static checks and the test suites of the release tooling.
#
# Usage: ./tools/tests/run-tests.sh

set -uo pipefail

tests_dir=$(dirname "$(readlink -f "$0")")
repo_root=$(git -C "$tests_dir" rev-parse --show-toplevel)

failures=0

section() {
  printf '\n############################################\n# %s\n############################################\n' "$1"
}

section "Shell syntax"

while IFS= read -r script; do
  if bash -n "$script"; then
    printf '  ok   %s\n' "${script#"$repo_root"/}"
  else
    printf '  FAIL %s\n' "${script#"$repo_root"/}" >&2
    failures=$((failures + 1))
  fi
done < <(find "$repo_root/tools" -name '*.sh' -type f | LC_ALL=C sort)

section "ShellCheck"

if command -v shellcheck > /dev/null 2>&1; then
  while IFS= read -r script; do
    if shellcheck --shell=bash "$script"; then
      printf '  ok   %s\n' "${script#"$repo_root"/}"
    else
      printf '  FAIL %s\n' "${script#"$repo_root"/}" >&2
      failures=$((failures + 1))
    fi
  done < <(find "$repo_root/tools" -name '*.sh' -type f | LC_ALL=C sort)
else
  printf '  skip shellcheck is not installed\n'
fi

section "Test suites"

while IFS= read -r test_script; do
  printf '\n---- %s ----\n' "${test_script#"$repo_root"/}"
  if bash "$test_script"; then
    printf '  ok   %s\n' "${test_script#"$repo_root"/}"
  else
    printf '  FAIL %s\n' "${test_script#"$repo_root"/}" >&2
    failures=$((failures + 1))
  fi
done < <(find "$tests_dir" -name 'test-*.sh' -type f -not -name 'test-lib.sh' | LC_ALL=C sort)

printf '\n========================================\n'
if [ "$failures" -gt 0 ]; then
  printf '%d check group(s) FAILED\n' "$failures" >&2
  exit 1
fi
printf 'All checks passed\n'
