#!/usr/bin/env bash

set -euo pipefail
trap 'msg="Script failed at line $LINENO: command \"$BASH_COMMAND\" exited with status $?"; echo "$msg"; notify_failure "$msg"; exit 1' ERR

NOTIFY_SEND=$(command -v notify-send || true)

HEADLESS=0
DRY_RUN=0
GUI=0
WOW_DIR="${WOW_DIR:-$(pwd)}"
MANIFEST_URL="https://updater.project-epoch.net/api/v2/manifest"
TMP_PATH="" #global so we can delete it in cleanup if needed
TMP_MANIFEST=""

E_SUCCESS=0
E_MANIFEST_FAILED=2
E_DOWNLOAD_FAILED=3
E_HASH_MISMATCH=4

GUI_PIPE=""
GUI_PID=""
CURL_PID=""

function usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --dry-run         Check files but do not download or modify anything.
  --headless        Suppress desktop notifications and progress bars.
  --gui             Use Zenity to display a graphical progress bar.
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
        --gui)
            GUI=1
            ;;
        --headless)
            HEADLESS=1
            GUI=0
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

function gui_error() {
    local msg="$1"
    if [[ "$GUI" -eq 1 ]]; then
        zenity --error --title="Epoch Update error" --text="$msg"
    fi
}

function gui_progress_update() {
    if [[ "$GUI" -eq 0 || -z "$GUI_PIPE" ]]; then
        return
    fi
    echo "${1}" >&3
}

function gui_status_update() {
    if [[ "$GUI" -eq 0 || -z "$GUI_PIPE" ]]; then
        return
    fi
    echo "#${1}" >&3
}

function error() {
    local msg="$1"
    gui_error "$msg"
    echo "Error: $msg"
}

function check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        error "Required command '$cmd' not found. Please install it."
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

function bytes_to_mb() {
    awk "BEGIN {printf \"%.2f\", $1 / 1024 / 1024 }"
}

CLEANED_UP=0
function cleanup() {
    if [[ $CLEANED_UP -eq 1 ]]; then
        return
    fi
    CLEANED_UP=1
    
    [[ -n "$CURL_PID" ]] && kill "$CURL_PID" 2>/dev/null || true
    [[ -n "$GUI_PID" ]] && kill "$GUI_PID" 2>/dev/null || true
    [[ -n "$GUI_WATCHER_PID" ]] && kill "$GUI_WATCHER_PID" 2>/dev/null || true
    [[ -n "${GUI_PIPE:-}" && -p "$GUI_PIPE" ]] && rm -f "$GUI_PIPE" || true
    [[ -f "$TMP_PATH" ]] && rm -f "$TMP_PATH" || true
    [[ -f "$TMP_MANIFEST" ]] && rm -f "$TMP_MANIFEST" || true
    
    #close fifo
    exec 3>&-
}
function on_sigint() {
    echo "Terminated by SIGINT." >&2
    cleanup
    exit 130
}
function on_sigterm() {
    echo "Terminated by SIGTERM." >&2
    cleanup
    exit 143
}
function on_sighup() {
    echo "Terminated by SIGHUP." >&2
    cleanup
    exit 129
}
trap 'cleanup' EXIT
trap 'on_sigint' SIGINT
trap 'on_sigterm' SIGTERM
trap 'on_sighup' SIGHUP


# Check available commands
check_command curl

if [[ "$GUI" -eq 1 ]] && ! command -v zenity &>/dev/null; then
    error "--gui was specified but Zenity is not installed."
    exit 1
fi

# Ensure jq exists, either as defined by the env var or in $PATH.
if [[ -n "${JQ:-}" ]]; then
    if [[ ! -x "$JQ" ]]; then
        error "JQ is set to '$JQ' but it is not executable."
        exit 1
    fi
elif command -v jq &>/dev/null; then
    JQ=$(command -v jq)
else
    error "jq not found. Please install jq or set the JQ environment variable to point to it."
    exit 1
fi


# Check for either md5sum or md5 (macOS)
MD5_CMD=""
if command -v md5sum &>/dev/null; then
    MD5_CMD="md5sum"
elif command -v md5 &>/dev/null; then
    MD5_CMD="md5"
else
    error "Neither 'md5sum' nor 'md5' command found. Please install one of them."
    exit 1
fi

# Verify Wow.exe exists in WOW_DIR (case-insensitive)
if ! find "$WOW_DIR" -maxdepth 1 -type f -iname 'Wow.exe' | grep -q .; then
    error "Wow.exe not found in $WOW_DIR"
    exit 1
fi

# Launch progress bar GUI
if [[ "$GUI" -eq 1 ]]; then
    GUI_PIPE=$(mktemp -u /tmp/epoch-update-fifo.XXXXXX)
    mkfifo "$GUI_PIPE"

    zenity --progress --title="Epoch Updater" --percentage=0 --auto-close --auto-kill --time-remaining <"$GUI_PIPE" &
    GUI_PID=$!

    #gotta do this to keep the fifo open between echoes... three hours of debugging
    exec 3> "$GUI_PIPE"
fi

TMP_MANIFEST=$(mktemp /tmp/epoch_manifest.XXXXXX.json)
echo "Downloading manifest..."
gui_status_update "Downloading manifest..."
gui_progress_update "0"
curl -sSfL "$MANIFEST_URL" -o "$TMP_MANIFEST" &
CURL_PID=$!
wait "$CURL_PID"
CURL_STATUS=$?
if [[ "$CURL_STATUS" -ne 0 ]]; then
    error "Failed to fetch manifest"
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

gui_status_update "Checking files..."
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

gui_status_update "Downloading files..."

# Second pass: Download updated files
TOTAL_DOWNLOADED=0

for FILE_PATH in "${TO_UPDATE[@]}"; do
    LOCAL_PATH="$WOW_DIR/$FILE_PATH"
    TMP_PATH="${LOCAL_PATH}.part"
    URLS=(${FILE_URLS["$FILE_PATH"]})
    EXPECTED_HASH=$("$JQ" -r ".Files[] | select(.Path == \"$FILE_PATH\") | .Hash" "$TMP_MANIFEST")
    FILE_SIZE=$("$JQ" -r ".Files[] | select(.Path == \"$FILE_PATH\") | .Size" "$TMP_MANIFEST")
    FILE_SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $FILE_SIZE / 1024 / 1024 }")

    echo "Downloading $FILE_PATH ($FILE_SIZE_MB MiB)..."

    SUCCESS=0
    CURRENT_DOWNLOADED=0
    
    if [[ "$GUI" -eq 1 ]]; then
        monitor_progress() {
            while :; do
                CURRENT_DOWNLOADED=$(stat -c%s "$TMP_PATH" 2>/dev/null || echo 0)
                NOW_DOWNLOADED=$((TOTAL_DOWNLOADED + CURRENT_DOWNLOADED))
                NOW_DOWNLOADED_MB=$(bytes_to_mb "$NOW_DOWNLOADED")
                PERCENT=$((NOW_DOWNLOADED * 100 / TOTAL_DOWNLOAD_SIZE))
                gui_progress_update "$PERCENT"
                gui_status_update "($((UPDATED + 1))/$NUM_TO_UPDATE) Downloading $FILE_PATH...\nOverall progress: $NOW_DOWNLOADED_MB / $SIZE_MB MiB"
                sleep 0.2
            done
        }
        
        monitor_progress &
        MONITOR_PID=$!
    fi
    
    for URL in "${URLS[@]}"; do
        echo "Attempting $URL..."
        if [[ "$HEADLESS" -eq 1 ]]; then
            CURL_FLAGS=(--silent --show-error --fail --location)
        else
            CURL_FLAGS=(--progress-bar --fail --location)
        fi

        
        curl "${CURL_FLAGS[@]}" "$URL" -o "$TMP_PATH" &
        CURL_PID=$!
        wait "$CURL_PID"
        CURL_STATUS=$?
        if [[ "$CURL_STATUS" -eq 0 ]]; then
            NEW_HASH=$(hash_file "$TMP_PATH")
            if [[ "$NEW_HASH" == "$EXPECTED_HASH" ]]; then
                mv -f "$TMP_PATH" "$LOCAL_PATH"
                ((UPDATED+=1))
                SUCCESS=1
                break
            else
                echo "Hash mismatch for $FILE_PATH from $URL. Expected $EXPECTED_HASH, was $NEW_HASH."
                rm -f "$TMP_PATH"
            fi
        else
            echo "Download failed from $URL"
            rm -f "$TMP_PATH"
        fi
    done
    
    if [[ "$GUI" -eq 1 ]]; then
        kill "$MONITOR_PID" 2>/dev/null || true
        TOTAL_DOWNLOADED=$((TOTAL_DOWNLOADED + FILE_SIZE))
        gui_progress_update "$((TOTAL_DOWNLOADED * 100 / TOTAL_DOWNLOAD_SIZE))"
    fi

    if [[ "$SUCCESS" -ne 1 ]]; then
        error "Failed to update $FILE_PATH"
        exit $E_DOWNLOAD_FAILED
    fi
done

echo ""
echo "$UPDATED files updated."
echo "$CURRENT files already up to date."

if [[ "$GUI" -eq 1 ]]; then
    gui_progress_update "100"
    gui_status_update "Done!"
fi

exit $E_SUCCESS
