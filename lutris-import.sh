#!/usr/bin/env bash
set -euo pipefail

SRC="$1"
DEST="$2"

# Normalize SRC to directory containing Wow.exe
if [[ -f "$SRC" && "$(basename "$SRC" | tr '[:upper:]' '[:lower:]')" == "wow.exe" ]]; then
    SRC_DIR="$(dirname "$SRC")"
elif [[ -d "$SRC" ]]; then
    # Check for Wow.exe (case-insensitive) in directory
    if ! find "$SRC" -maxdepth 1 -type f -iname 'Wow.exe' | grep -q .; then
        echo "Error: Directory '$SRC' does not contain Wow.exe"
        exit 1
    fi
    SRC_DIR="$SRC"
else
    echo "Error: '$SRC' is not a Wow.exe file or a valid directory"
    exit 1
fi

echo "Copying contents of '$SRC_DIR' to '$DEST'..."
mkdir -p "$DEST"
cp -rv "$SRC_DIR/." "$DEST/"

echo "Import complete."
