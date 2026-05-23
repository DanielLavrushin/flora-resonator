#!/usr/bin/env bash
# Builds FloraResonator-${VERSION}.zip from Scripts/ + enabled.txt, where VERSION
# is read out of Scripts/config.lua so the filename can't drift from what the
# running mod reports.

set -euo pipefail

cd "$(dirname "$0")"

VERSION=$(grep -oP 'VERSION\s*=\s*"\K[^"]+' Scripts/config.lua)
if [[ -z "$VERSION" ]]; then
    echo "could not parse VERSION from Scripts/config.lua" >&2
    exit 1
fi

OUT="FloraResonator-${VERSION}.zip"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/FloraResonator"
cp -r Scripts "$STAGE/FloraResonator/"
cp enabled.txt "$STAGE/FloraResonator/"

rm -f "$OUT"
(cd "$STAGE" && zip -qr "$OLDPWD/$OUT" FloraResonator)

echo "built $OUT"
unzip -l "$OUT"
