#!/bin/bash

set -euo pipefail

NOTIFY_SEND=$(command -v notify-send || true)

HEADLESS=0
DRY_RUN=0
WOW_DIR="${WOW_DIR:-}"
MANIFEST_URL="https://updater.project-epoch.net/api/v2/manifest"

E_SUCCESS=0
E_MANIFEST_FAILED=2
E_DOWNLOAD_FAILED=3
E_HASH_MISMATCH=4

function usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --dry-run         Check files but do not download or modify anything.
  --headless        Suppress desktop notifications and progress bars.
  -h, --help        Show this help message and exit.

Environment Variables:
  WOW_DIR           Path to the World of Warcraft directory (default: current directory).
EOF
}

function check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        echo "Required command '$cmd' not found. Please install it."
        exit 1
    fi
}

check_command jq
check_command curl

# Check for either md5sum or md5 (macOS)
MD5_CMD=""
if command -v md5sum &>/dev/null; then
    MD5_CMD="md5sum"
elif command -v md5 &>/dev/null; then
    MD5_CMD="md5"
else
    echo "Neither 'md5sum' nor 'md5' command found. Please install one of them."
    exit 1
fi

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=1
            ;;
        --headless)
            HEADLESS=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            usage
            exit 1
            ;;
    esac
done

function notify_failure() {
    local msg="$1"
    if [[ "$HEADLESS" -eq 0 && -n "$NOTIFY_SEND" && ! -t 0 ]]; then
        "$NOTIFY_SEND" -u critical -t 5000 "Epoch Update Failed" "$msg"
    fi
}

function notify_success() {
    local msg="$1"
    if [[ "$HEADLESS" -eq 0 && -n "$NOTIFY_SEND" && ! -t 1 ]]; then
        "$NOTIFY_SEND" -u normal -t 5000 "Epoch Update Complete" "$msg"
    fi
}

trap 'msg="Script failed at line $LINENO"; echo "$msg"; notify_failure "$msg"; exit 1' ERR

# Use current directory if WOW_DIR is unset or empty
if [[ -z "$WOW_DIR" ]]; then
    WOW_DIR="$(pwd)"
fi

# Verify Wow.exe exists in WOW_DIR (case-insensitive)
if ! find "$WOW_DIR" -maxdepth 1 -type f -iname 'Wow.exe' | grep -q .; then
    echo "Error: Wow.exe not found in $WOW_DIR"
    notify_failure "Wow.exe not found in $WOW_DIR"
    exit 1
fi

TMP_MANIFEST="/tmp/epoch_manifest.json"

function hash_file() {
    local file="$1"
    if [[ "$MD5_CMD" == "md5sum" ]]; then
        md5sum "$file" | awk '{ print $1 }'
    else
        md5 -q "$file"
    fi
}

# Fetch the manifest
echo "Downloading manifest..."
if ! curl -sSfL "$MANIFEST_URL" -o "$TMP_MANIFEST"; then
    echo "Failed to fetch manifest"
    notify_failure "Failed to fetch manifest"
    exit $E_MANIFEST_FAILED
fi

# Read file count
FILE_COUNT=$(jq '.Files | length' "$TMP_MANIFEST")
echo "Found $FILE_COUNT files in manifest."

UPDATED=0
CURRENT=0

for i in $(seq 0 $((FILE_COUNT - 1))); do
    FILE_PATH=$(jq -r ".Files[$i].Path" "$TMP_MANIFEST" | sed 's|\\|/|g')
    EXPECTED_HASH=$(jq -r ".Files[$i].Hash" "$TMP_MANIFEST")
    URLS=($(jq -r ".Files[$i].Urls | .cloudflare, .digitalocean, .none" "$TMP_MANIFEST"))

    LOCAL_PATH="$WOW_DIR/$FILE_PATH"
    LOCAL_DIR=$(dirname "$LOCAL_PATH")
    mkdir -p "$LOCAL_DIR"

    if [[ -f "$LOCAL_PATH" ]]; then
        LOCAL_HASH=$(hash_file "$LOCAL_PATH")
        if [[ "$LOCAL_HASH" == "$EXPECTED_HASH" ]]; then
            echo "[OK] $FILE_PATH"
            ((CURRENT+=1))
            continue
        fi
    fi

    echo "[UPDATE NEEDED] $FILE_PATH"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        continue
    fi

    SUCCESS=0
    for URL in "${URLS[@]}"; do
        echo "Downloading $FILE_PATH from $URL ..."
        if [[ "$HEADLESS" -eq 1 ]]; then
            CURL_FLAGS=(--silent --show-error --fail --location)
        else
            CURL_FLAGS=(--progress-bar --fail --location)
        fi

        if curl "${CURL_FLAGS[@]}" "$URL" -o "$LOCAL_PATH"; then
            NEW_HASH=$(hash_file "$LOCAL_PATH")
            if [[ "$NEW_HASH" == "$EXPECTED_HASH" ]]; then
                SUCCESS=1
                ((UPDATED+=1))
                break
            else
                echo "Hash mismatch for $FILE_PATH from $URL"
            fi
        else
            echo "Download failed from $URL"
        fi
    done

    if [[ $SUCCESS -ne 1 ]]; then
        echo "Failed to update $FILE_PATH"
        notify_failure "Failed to update $FILE_PATH"
        exit $E_DOWNLOAD_FAILED
    fi
done

echo ""
echo "$UPDATED files updated."
echo "$CURRENT files already up to date."

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Dry run completed. No files were modified."
else
    if [[ "$UPDATED" -gt 0 && "$HEADLESS" -eq 0 && ! -t 1 ]]; then
        notify_success "$UPDATED files updated successfully."
    fi
fi

exit $E_SUCCESS
