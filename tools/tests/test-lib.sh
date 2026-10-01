#!/usr/bin/env bash
#
# Minimal test helpers for the release tooling tests.
#
# Sourced by the test scripts; not meant to be executed directly.

TEST_CHECKS=0
TEST_FAILURES=0

describe() {
  printf '\n=== %s ===\n' "$1"
}

check_pass() {
  TEST_CHECKS=$((TEST_CHECKS + 1))
  printf '  ok   %s\n' "$1"
}

check_fail() {
  TEST_CHECKS=$((TEST_CHECKS + 1))
  TEST_FAILURES=$((TEST_FAILURES + 1))
  printf '  FAIL %s\n' "$1" >&2
  printf '       %s\n' "$2" >&2
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if [ "$expected" = "$actual" ]; then
    check_pass "$message"
  else
    check_fail "$message" "expected '${expected}', got '${actual}'"
  fi
}

assert_not_equal() {
  local unexpected="$1"
  local actual="$2"
  local message="$3"

  if [ "$unexpected" != "$actual" ]; then
    check_pass "$message"
  else
    check_fail "$message" "did not expect '${actual}'"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    check_pass "$message"
  else
    check_fail "$message" "'${needle}' not found in: $(printf '%s' "$haystack" | head -n 5)"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    check_fail "$message" "'${needle}' unexpectedly found in: $(printf '%s' "$haystack" | head -n 5)"
  else
    check_pass "$message"
  fi
}

assert_matches() {
  local haystack="$1"
  local pattern="$2"
  local message="$3"

  if printf '%s' "$haystack" | grep -qE -- "$pattern"; then
    check_pass "$message"
  else
    check_fail "$message" "no match for /${pattern}/ in: $(printf '%s' "$haystack" | head -n 5)"
  fi
}

assert_file_exists() {
  if [ -f "$1" ]; then
    check_pass "$2"
  else
    check_fail "$2" "file '$1' does not exist"
  fi
}

assert_file_missing() {
  if [ ! -f "$1" ]; then
    check_pass "$2"
  else
    check_fail "$2" "file '$1' exists but should not"
  fi
}

# Prints a summary of the checks and exits non-zero if any of them failed.
finish_tests() {
  printf '\n----------------------------------------\n'

  if [ "$TEST_FAILURES" -gt 0 ]; then
    printf '%s: %d of %d check(s) FAILED\n' "${0##*/}" "$TEST_FAILURES" "$TEST_CHECKS" >&2
    exit 1
  fi

  printf '%s: all %d check(s) passed\n' "${0##*/}" "$TEST_CHECKS"
}
