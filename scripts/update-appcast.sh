#!/usr/bin/env bash
set -euo pipefail
VERSION="${1:?Usage: $0 <version> <dmg-path>}"
DMG_PATH="${2:?Usage: $0 <version> <dmg-path>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPCAST="$ROOT/docs/appcast.xml"

SIZE=$(stat -f%z "$DMG_PATH")
DATE=$(date -R)
URL="https://github.com/stefanpenner/chirp/releases/download/v${VERSION}/Chirp-v${VERSION}-macOS.dmg"

ITEM="        <item>\n            <title>Version ${VERSION}<\/title>\n            <pubDate>${DATE}<\/pubDate>\n            <sparkle:version>${VERSION}<\/sparkle:version>\n            <sparkle:shortVersionString>${VERSION}<\/sparkle:shortVersionString>\n            <sparkle:minimumSystemVersion>15.0<\/sparkle:minimumSystemVersion>\n            <enclosure url=\"${URL}\" length=\"${SIZE}\" type=\"application\/octet-stream\" \/>\n        <\/item>"

# Insert before </channel>
sed -i '' "s|</channel>|${ITEM}\n    </channel>|" "$APPCAST"
