#!/usr/bin/env bash
set -euo pipefail

# Find the script under test (handles both Bazel sandbox and direct invocation)
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SELF_DIR/package.sh" ]]; then
    source "$SELF_DIR/package.sh"
else
    source "$SELF_DIR/scripts/package.sh"
fi

FAILURES=0
TESTS=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    TESTS=$((TESTS + 1))
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $label"
    else
        echo "  FAIL: $label"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAILURES=$((FAILURES + 1))
    fi
}

# --- compute_build_number ---

test_compute_build_number_explicit() {
    echo "test: compute_build_number returns explicit value when provided"
    local result
    result="$(compute_build_number "/nonexistent" "42")"
    assert_eq "explicit build number" "42" "$result"
}

test_compute_build_number_from_tags() {
    echo "test: compute_build_number counts git tags + 1"
    local tmp_repo
    tmp_repo="$(mktemp -d)"
    trap "rm -rf '$tmp_repo'" RETURN

    git -C "$tmp_repo" init -q
    git -C "$tmp_repo" commit --allow-empty -m "init" -q
    git -C "$tmp_repo" tag v0.1.0
    git -C "$tmp_repo" tag v0.2.0
    git -C "$tmp_repo" tag v0.3.0

    local result
    result="$(compute_build_number "$tmp_repo")"
    assert_eq "3 tags → build 4" "4" "$result"
}

test_compute_build_number_no_tags() {
    echo "test: compute_build_number with no tags returns 1"
    local tmp_repo
    tmp_repo="$(mktemp -d)"
    trap "rm -rf '$tmp_repo'" RETURN

    git -C "$tmp_repo" init -q

    local result
    result="$(compute_build_number "$tmp_repo")"
    assert_eq "0 tags → build 1" "1" "$result"
}

test_compute_build_number_ignores_non_v_tags() {
    echo "test: compute_build_number ignores tags not starting with v"
    local tmp_repo
    tmp_repo="$(mktemp -d)"
    trap "rm -rf '$tmp_repo'" RETURN

    git -C "$tmp_repo" init -q
    git -C "$tmp_repo" commit --allow-empty -m "init" -q
    git -C "$tmp_repo" tag v1.0.0
    git -C "$tmp_repo" tag release-2.0
    git -C "$tmp_repo" tag beta-1

    local result
    result="$(compute_build_number "$tmp_repo")"
    assert_eq "1 v-tag + 2 other → build 2" "2" "$result"
}

# --- stamp_version ---

test_stamp_version() {
    echo "test: stamp_version sets both plist keys"
    local tmp_plist
    tmp_plist="$(mktemp).plist"
    trap "rm -f '$tmp_plist'" RETURN

    # Create a minimal plist with placeholder values
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 0.0.0" "$tmp_plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "$tmp_plist"

    stamp_version "$tmp_plist" "1.2.3" "99"

    local short_version build_version
    short_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$tmp_plist")
    build_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$tmp_plist")

    assert_eq "CFBundleShortVersionString" "1.2.3" "$short_version"
    assert_eq "CFBundleVersion" "99" "$build_version"
}

# --- Run all tests ---

echo "=== package.sh tests ==="
test_compute_build_number_explicit
test_compute_build_number_from_tags
test_compute_build_number_no_tags
test_compute_build_number_ignores_non_v_tags
test_stamp_version

echo ""
echo "$TESTS tests, $FAILURES failures"
exit "$FAILURES"
