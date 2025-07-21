#!/usr/bin/env bash

set -euo pipefail
trap 'msg="Script failed at line $LINENO"; echo "$msg"; notify_failure "$msg"; exit 1' ERR

NOTIFY_SEND=$(command -v notify-send || true)

HEADLESS=0
DRY_RUN=0
WOW_DIR="${WOW_DIR:-$(pwd)}"
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
  JQ                Path to the jq binary to be used over system jq.
EOF
}

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

function check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Required command '$cmd' not found. Please install it."
        exit 1
    fi
}

function notify_failure() {
    local msg="$1"
    if [[ "$HEADLESS" -eq 0 && -n "$NOTIFY_SEND" && ! -t 0 ]]; then
        "$NOTIFY_SEND" -u critical -t 5000 "Epoch Update Failed" "$msg"
    fi
}

function notify_status() {
    local msg="$1"
    if [[ "$HEADLESS" -eq 0 && -n "$NOTIFY_SEND" && ! -t 1 ]]; then
        "$NOTIFY_SEND" -u normal -t 5000 "Epoch Update" "$msg"
    fi
}

function hash_file() {
    local file="$1"
    if [[ "$MD5_CMD" == "md5sum" ]]; then
        md5sum "$file" | awk '{ print $1 }'
    else
        md5 -q "$file"
    fi
}

check_command curl

# Ensure jq exists, either as defined by the env var or in $PATH.
if [[ -n "${JQ:-}" ]]; then
    if [[ ! -x "$JQ" ]]; then
        echo "Error: JQ is set to '$JQ' but it is not executable."
        exit 1
    fi
elif command -v jq &>/dev/null; then
    JQ=$(command -v jq)
else
    echo "Error: jq not found. Please install jq or set the JQ environment variable to point to it."
    exit 1
fi


# Check for either md5sum or md5 (macOS)
MD5_CMD=""
if command -v md5sum &>/dev/null; then
    MD5_CMD="md5sum"
elif command -v md5 &>/dev/null; then
    MD5_CMD="md5"
else
    echo "Error: Neither 'md5sum' nor 'md5' command found. Please install one of them."
    exit 1
fi

# Verify Wow.exe exists in WOW_DIR (case-insensitive)
if ! find "$WOW_DIR" -maxdepth 1 -type f -iname 'Wow.exe' | grep -q .; then
    echo "Error: Wow.exe not found in $WOW_DIR"
    notify_failure "Wow.exe not found in $WOW_DIR"
    exit 1
fi

TMP_MANIFEST="/tmp/epoch_manifest.json"

echo "Downloading manifest..."
if ! curl -sSfL "$MANIFEST_URL" -o "$TMP_MANIFEST"; then
    echo "Failed to fetch manifest"
    notify_failure "Failed to fetch manifest"
    exit $E_MANIFEST_FAILED
fi
# Normalize manifest paths to use forward slashes
"$JQ" '.Files |= map(.Path |= gsub("\\\\"; "/"))' "$TMP_MANIFEST" > "${TMP_MANIFEST}.tmp" && mv "${TMP_MANIFEST}.tmp" "$TMP_MANIFEST"

FILE_COUNT=$("$JQ" '.Files | length' "$TMP_MANIFEST")
echo "Found $FILE_COUNT files in manifest."

UPDATED=0
CURRENT=0
TOTAL_DOWNLOAD_SIZE=0
declare -a TO_UPDATE=()
declare -A FILE_URLS

# First pass: Determine which files need to be updated
for i in $(seq 0 $((FILE_COUNT - 1))); do
    FILE_PATH=$("$JQ" -r ".Files[$i].Path" "$TMP_MANIFEST")
    EXPECTED_HASH=$("$JQ" -r ".Files[$i].Hash" "$TMP_MANIFEST")
    URLS=($("$JQ" -r ".Files[$i].Urls | .cloudflare, .digitalocean, .none" "$TMP_MANIFEST"))

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
    TO_UPDATE+=("$FILE_PATH")
    FILE_URLS["$FILE_PATH"]="${URLS[*]}"
    FILE_SIZE=$("$JQ" -r ".Files[$i].Size" "$TMP_MANIFEST")
    TOTAL_DOWNLOAD_SIZE=$((TOTAL_DOWNLOAD_SIZE + FILE_SIZE))
done

NUM_TO_UPDATE="${#TO_UPDATE[@]}"

SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_DOWNLOAD_SIZE / 1024 / 1024 }")

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo ""
    echo "Dry run complete. $NUM_TO_UPDATE files would be updated. Download size: $SIZE_MB MiB."
    exit $E_SUCCESS
fi

if [[ "$NUM_TO_UPDATE" -gt 0 ]]; then
    echo ""
    echo "$NUM_TO_UPDATE files need to be updated. Total download size: ${SIZE_MB} MiB."
    
    notify_status "$NUM_TO_UPDATE file updates (size: $SIZE_MB MiB) are being downloaded."
fi

# Second pass: Download updated files
for FILE_PATH in "${TO_UPDATE[@]}"; do
    LOCAL_PATH="$WOW_DIR/$FILE_PATH"
    URLS=(${FILE_URLS["$FILE_PATH"]})
    EXPECTED_HASH=$("$JQ" -r ".Files[] | select(.Path == \"$FILE_PATH\") | .Hash" "$TMP_MANIFEST")
    FILE_SIZE=$("$JQ" -r ".Files[] | select(.Path == \"$FILE_PATH\") | .Size" "$TMP_MANIFEST")
    FILE_SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $FILE_SIZE / 1024 / 1024 }")

    echo "Downloading $FILE_PATH ($FILE_SIZE_MB MiB)..."

    SUCCESS=0
    for URL in "${URLS[@]}"; do
        echo "Attempting $URL..."
        if [[ "$HEADLESS" -eq 1 ]]; then
            CURL_FLAGS=(--silent --show-error --fail --location)
        else
            CURL_FLAGS=(--progress-bar --fail --location)
        fi

        if curl "${CURL_FLAGS[@]}" "$URL" -o "$LOCAL_PATH"; then
            NEW_HASH=$(hash_file "$LOCAL_PATH")
            if [[ "$NEW_HASH" == "$EXPECTED_HASH" ]]; then
                ((UPDATED+=1))
                SUCCESS=1
                break
            else
                echo "Hash mismatch for $FILE_PATH from $URL. Expected $EXPECTED_HASH, was $NEW_HASH."
            fi
        else
            echo "Download failed from $URL"
        fi
    done

    if [[ "$SUCCESS" -ne 1 ]]; then
        echo "Failed to update $FILE_PATH"
        notify_failure "Failed to update $FILE_PATH"
        exit $E_DOWNLOAD_FAILED
    fi
done

echo ""
echo "$UPDATED files updated."
echo "$CURRENT files already up to date."

exit $E_SUCCESS
