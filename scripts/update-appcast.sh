#!/usr/bin/env bash
set -euo pipefail

# Resolve project root from script location.
resolve_root() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    cd "$script_dir/.." && pwd
}

# Monotonic integer build from semver X.Y.Z → X*1_000_000 + Y*1000 + Z.
# Usage: compute_build_number <version> [explicit_number]
compute_build_number() {
    local version="$1"
    local explicit="${2:-}"
    if [[ -n "$explicit" ]]; then
        echo "$explicit"
        return
    fi
    local major minor patch
    IFS=. read -r major minor patch <<<"$version"
    major=${major//[^0-9]/}
    minor=${minor//[^0-9]/}
    patch=${patch//[^0-9]/}
    echo $(( 10#${major:-0} * 1000000 + 10#${minor:-0} * 1000 + 10#${patch:-0} ))
}

# Sign a DMG with Sparkle EdDSA (optional). Prints edSignature or empty.
# Usage: sparkle_ed_signature <dmg_path>
# Requires SPARKLE_PRIVATE_KEY env (base64 or raw) and sign_update in PATH or SPARKLE_SIGN_UPDATE.
sparkle_ed_signature() {
    local dmg_path="$1"
    local key="${SPARKLE_PRIVATE_KEY:-}"
    [[ -n "$key" ]] || { echo ""; return 0; }
    local sign_update="${SPARKLE_SIGN_UPDATE:-}"
    if [[ -z "$sign_update" ]]; then
        if command -v sign_update >/dev/null 2>&1; then
            sign_update="$(command -v sign_update)"
        else
            echo "WARNING: SPARKLE_PRIVATE_KEY set but sign_update not found" >&2
            echo ""
            return 0
        fi
    fi
    # sign_update prints: sparkle:edSignature="..." length="..."
    local out
    if [[ "$key" == *"="* ]] || [[ ${#key} -gt 80 ]]; then
        # likely base64 PEM/key file content
        local keyfile
        keyfile="$(mktemp)"
        if echo "$key" | base64 --decode >"$keyfile" 2>/dev/null; then
            :
        else
            printf '%s\n' "$key" >"$keyfile"
        fi
        out="$("$sign_update" "$dmg_path" -f "$keyfile" 2>/dev/null || true)"
        rm -f "$keyfile"
    else
        out="$("$sign_update" "$dmg_path" -s "$key" 2>/dev/null || true)"
    fi
    # Extract edSignature value
    if [[ "$out" =~ edSignature=\"([^\"]+)\" ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo ""
    fi
}

# Generate a Sparkle appcast <item> XML block.
# Uses build_number for sparkle:version (compared by Sparkle) and
# version string for sparkle:shortVersionString (displayed to user).
# Optional ed_sig: Sparkle 2 EdDSA signature for the enclosure.
# Usage: generate_appcast_item <version> <build_number> <url> <size> <date> [ed_sig]
generate_appcast_item() {
    local version="$1" build_number="$2" url="$3" size="$4" date="$5"
    local ed_sig="${6:-}"
    local enclosure
    if [[ -n "$ed_sig" ]]; then
        enclosure="<enclosure url=\"${url}\" length=\"${size}\" type=\"application/octet-stream\" sparkle:edSignature=\"${ed_sig}\" />"
    else
        enclosure="<enclosure url=\"${url}\" length=\"${size}\" type=\"application/octet-stream\" />"
    fi
    cat <<EOF
        <item>
            <title>Version ${version}</title>
            <pubDate>${date}</pubDate>
            <sparkle:version>${build_number}</sparkle:version>
            <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
            ${enclosure}
        </item>
EOF
}

# Insert an appcast item before the closing </channel> tag.
# Usage: insert_appcast_item <appcast_file> <item_xml>
insert_appcast_item() {
    local appcast_file="$1" item_xml="$2"
    local tmp="${appcast_file}.tmp"
    while IFS= read -r line; do
        if [[ "$line" == *"</channel>"* ]]; then
            printf '%s\n' "$item_xml"
        fi
        printf '%s\n' "$line"
    done < "$appcast_file" > "$tmp"
    mv "$tmp" "$appcast_file"
}

main() {
    local version="${1:?Usage: $0 <version> <dmg-path> [build-number]}"
    local dmg_path="${2:?Usage: $0 <version> <dmg-path> [build-number]}"
    local build_number_arg="${3:-}"

    local root
    root="$(resolve_root)"

    local build_number
    build_number="$(compute_build_number "$version" "$build_number_arg")"

    local appcast="$root/appcast.xml"
    local size date url item ed_sig

    # Prefer Sparkle zip (preserves +x, simpler install). Fall back to DMG path arg.
    local archive_path="$dmg_path"
    local archive_name="Chirp-v${version}-macOS.zip"
    local zip_candidate
    zip_candidate="$(dirname "$dmg_path")/$archive_name"
    if [[ -f "$zip_candidate" ]]; then
        archive_path="$zip_candidate"
    fi
    local ext="${archive_path##*.}"

    size=$(stat -f%z "$archive_path")
    date=$(date -R)
    url="https://github.com/stefanpenner/chirp/releases/download/v${version}/Chirp-v${version}-macOS.${ext}"
    ed_sig="$(sparkle_ed_signature "$archive_path")"

    item="$(generate_appcast_item "$version" "$build_number" "$url" "$size" "$date" "$ed_sig")"
    insert_appcast_item "$appcast" "$item"
    echo "Appcast item: v${version} build ${build_number} archive=${ext} edSig=${ed_sig:+yes}${ed_sig:-no}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
