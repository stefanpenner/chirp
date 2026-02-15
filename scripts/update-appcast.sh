#!/usr/bin/env bash
set -euo pipefail

# Resolve project root from script location.
resolve_root() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    cd "$script_dir/.." && pwd
}

# Compute an integer build number from the count of v* git tags in the repo.
# Usage: compute_build_number <repo_dir> [explicit_number]
compute_build_number() {
    local repo_dir="$1"
    local explicit="${2:-}"
    if [[ -n "$explicit" ]]; then
        echo "$explicit"
    else
        echo $(( $(git -C "$repo_dir" tag -l 'v*' | wc -l) + 1 ))
    fi
}

# Generate a Sparkle appcast <item> XML block.
# Uses build_number for sparkle:version (compared by Sparkle) and
# version string for sparkle:shortVersionString (displayed to user).
# Usage: generate_appcast_item <version> <build_number> <url> <size> <date>
generate_appcast_item() {
    local version="$1" build_number="$2" url="$3" size="$4" date="$5"
    cat <<EOF
        <item>
            <title>Version ${version}</title>
            <pubDate>${date}</pubDate>
            <sparkle:version>${build_number}</sparkle:version>
            <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
            <enclosure url="${url}" length="${size}" type="application/octet-stream" />
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
    build_number="$(compute_build_number "$root" "$build_number_arg")"

    local appcast="$root/appcast.xml"
    local size date url item

    size=$(stat -f%z "$dmg_path")
    date=$(date -R)
    url="https://github.com/stefanpenner/chirp/releases/download/v${version}/Chirp-v${version}-macOS.dmg"

    item="$(generate_appcast_item "$version" "$build_number" "$url" "$size" "$date")"
    insert_appcast_item "$appcast" "$item"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
