#!/usr/bin/env bash
set -euo pipefail

# Find the script under test (handles both Bazel sandbox and direct invocation)
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SELF_DIR/update-appcast.sh" ]]; then
    source "$SELF_DIR/update-appcast.sh"
else
    source "$SELF_DIR/scripts/update-appcast.sh"
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

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    TESTS=$((TESTS + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $label"
    else
        echo "  FAIL: $label"
        echo "    expected to contain: $needle"
        echo "    actual: $haystack"
        FAILURES=$((FAILURES + 1))
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    TESTS=$((TESTS + 1))
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  PASS: $label"
    else
        echo "  FAIL: $label"
        echo "    expected NOT to contain: $needle"
        echo "    actual: $haystack"
        FAILURES=$((FAILURES + 1))
    fi
}

# --- generate_appcast_item ---

test_generate_item_uses_build_number_for_sparkle_version() {
    echo "test: generate_appcast_item uses build number for sparkle:version"
    local item
    item="$(generate_appcast_item "0.4.0" "9" "https://example.com/app.dmg" "12345" "Sat, 15 Feb 2026 00:00:00 +0000")"

    assert_contains "sparkle:version is build number" \
        "<sparkle:version>9</sparkle:version>" "$item"
}

test_generate_item_uses_semver_for_short_version() {
    echo "test: generate_appcast_item uses semver for sparkle:shortVersionString"
    local item
    item="$(generate_appcast_item "0.4.0" "9" "https://example.com/app.dmg" "12345" "Sat, 15 Feb 2026 00:00:00 +0000")"

    assert_contains "sparkle:shortVersionString is semver" \
        "<sparkle:shortVersionString>0.4.0</sparkle:shortVersionString>" "$item"
}

test_generate_item_version_fields_differ() {
    echo "test: sparkle:version and sparkle:shortVersionString are different"
    local item
    item="$(generate_appcast_item "0.4.0" "9" "https://example.com/app.dmg" "12345" "Sat, 15 Feb 2026 00:00:00 +0000")"

    assert_contains "sparkle:version is 9" \
        "<sparkle:version>9</sparkle:version>" "$item"
    assert_not_contains "sparkle:version is NOT semver" \
        "<sparkle:version>0.4.0</sparkle:version>" "$item"
}

test_generate_item_includes_enclosure() {
    echo "test: generate_appcast_item includes enclosure with url and length"
    local item
    item="$(generate_appcast_item "0.4.0" "9" "https://example.com/app.dmg" "12345" "Sat, 15 Feb 2026 00:00:00 +0000")"

    assert_contains "enclosure url" 'url="https://example.com/app.dmg"' "$item"
    assert_contains "enclosure length" 'length="12345"' "$item"
}

test_generate_item_includes_pubdate() {
    echo "test: generate_appcast_item includes pubDate"
    local item
    item="$(generate_appcast_item "0.4.0" "9" "https://example.com/app.dmg" "12345" "Sat, 15 Feb 2026 00:00:00 +0000")"

    assert_contains "pubDate" \
        "<pubDate>Sat, 15 Feb 2026 00:00:00 +0000</pubDate>" "$item"
}

test_generate_item_includes_minimum_system_version() {
    echo "test: generate_appcast_item includes minimumSystemVersion"
    local item
    item="$(generate_appcast_item "0.4.0" "9" "https://example.com/app.dmg" "12345" "Sat, 15 Feb 2026 00:00:00 +0000")"

    assert_contains "minimumSystemVersion" \
        "<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>" "$item"
}

# --- insert_appcast_item ---

test_insert_item_before_channel_close() {
    echo "test: insert_appcast_item adds item before </channel>"
    local tmp_appcast
    tmp_appcast="$(mktemp)"
    trap "rm -f '$tmp_appcast'" RETURN

    cat > "$tmp_appcast" <<'APPCAST'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Test</title>
    </channel>
</rss>
APPCAST

    local item
    item="$(generate_appcast_item "0.4.0" "9" "https://example.com/app.dmg" "12345" "Sat, 15 Feb 2026 00:00:00 +0000")"
    insert_appcast_item "$tmp_appcast" "$item"

    local result
    result="$(cat "$tmp_appcast")"

    assert_contains "item inserted" "<sparkle:version>9</sparkle:version>" "$result"
    assert_contains "channel still closed" "</channel>" "$result"
    assert_contains "rss still closed" "</rss>" "$result"
}

test_insert_item_preserves_existing_items() {
    echo "test: insert_appcast_item preserves existing items"
    local tmp_appcast
    tmp_appcast="$(mktemp)"
    trap "rm -f '$tmp_appcast'" RETURN

    cat > "$tmp_appcast" <<'APPCAST'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Test</title>
        <item>
            <sparkle:version>8</sparkle:version>
            <sparkle:shortVersionString>0.3.0</sparkle:shortVersionString>
        </item>
    </channel>
</rss>
APPCAST

    local item
    item="$(generate_appcast_item "0.4.0" "9" "https://example.com/app.dmg" "12345" "Sat, 15 Feb 2026 00:00:00 +0000")"
    insert_appcast_item "$tmp_appcast" "$item"

    local result
    result="$(cat "$tmp_appcast")"

    assert_contains "old item preserved" "<sparkle:version>8</sparkle:version>" "$result"
    assert_contains "new item added" "<sparkle:version>9</sparkle:version>" "$result"
}

test_insert_item_appears_after_existing() {
    echo "test: new item appears after existing items (before </channel>)"
    local tmp_appcast
    tmp_appcast="$(mktemp)"
    trap "rm -f '$tmp_appcast'" RETURN

    cat > "$tmp_appcast" <<'APPCAST'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Test</title>
        <item>
            <sparkle:version>8</sparkle:version>
        </item>
    </channel>
</rss>
APPCAST

    local item
    item="$(generate_appcast_item "0.4.0" "9" "https://example.com/app.dmg" "12345" "Sat, 15 Feb 2026 00:00:00 +0000")"
    insert_appcast_item "$tmp_appcast" "$item"

    # The new item (version 9) should appear after the old item (version 8)
    local pos_old pos_new
    pos_old=$(grep -n "sparkle:version>8<" "$tmp_appcast" | head -1 | cut -d: -f1)
    pos_new=$(grep -n "sparkle:version>9<" "$tmp_appcast" | head -1 | cut -d: -f1)

    TESTS=$((TESTS + 1))
    if [[ "$pos_new" -gt "$pos_old" ]]; then
        echo "  PASS: new item after old item (line $pos_new > $pos_old)"
    else
        echo "  FAIL: new item should be after old item (new=$pos_new, old=$pos_old)"
        FAILURES=$((FAILURES + 1))
    fi
}

# --- Run all tests ---

echo "=== update-appcast.sh tests ==="
test_generate_item_uses_build_number_for_sparkle_version
test_generate_item_uses_semver_for_short_version
test_generate_item_version_fields_differ
test_generate_item_includes_enclosure
test_generate_item_includes_pubdate
test_generate_item_includes_minimum_system_version
test_insert_item_before_channel_close
test_insert_item_preserves_existing_items
test_insert_item_appears_after_existing

echo ""
echo "$TESTS tests, $FAILURES failures"
exit "$FAILURES"
