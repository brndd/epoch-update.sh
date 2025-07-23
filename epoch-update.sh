#!/usr/bin/env bash
set -euo pipefail

CURL_PROGRESS=0
CURL_SILENT=0
DRY_RUN=0
GUI_MODE=""
GUI_FALLBACK=0
NOFAIL=0
NOTIFICATIONS=0
SILENT=0

WOW_DIR="${WOW_DIR:-$(pwd)}"
MANIFEST_URL="https://updater.project-epoch.net/api/v2/manifest"
TMP_PATH="" #global so we can delete it in cleanup if needed
TMP_MANIFEST=""

GUI_PIPE=""
GUI_PID=""
GUI_SUBSHELL_PID=""
GUI_FD=""
GUI_STATUS_FILE=""
CURL_PID=""

E_SUCCESS=0
E_MANIFEST_FAILED=2
E_DOWNLOAD_FAILED=3
E_HASH_MISMATCH=4

function gui_error() {
    local msg="$1"
    if [[ "$GUI_MODE" == "zenity" ]]; then
        zenity --error --title="Epoch Update error" --text="$msg" &
    fi
}

# Error, but ask the user if they want to launch anyway if there's a command
function gui_error_question() {
    local msg="$1"
    if [[ "${#CMD_ARGS[@]}" -eq 0 ]]; then
        gui_error "$msg"
        return
    fi
    if [[ "$GUI_MODE" == "zenity" ]]; then
        if zenity --question --title="Epoch Update error"\
        --text="$msg\n\nLaunch anyway?"; then
            do_launch
        fi
    fi
}

function notify_failure() {
    local msg="$1"
    if [[ "$NOTIFICATIONS" -eq 1 ]]; then
        notify-send -u critical -t 5000 "Epoch Update Failed" "$msg"
    fi
}

function notify_status() {
    local msg="$1"
    if [[ "$NOTIFICATIONS" -eq 1 ]]; then
        notify-send -u normal -t 5000 "Epoch Update" "$msg"
    fi
}

function stderr() {
    local msg="$1"
    echo "$msg" >&2
}

function stdout() {
    if [[ "$SILENT" -eq 0 ]]; then
        local msg="$1"
        echo "$msg"
    fi
}

function error() {
    local msg="$1"
    if [[ "$NOFAIL" -eq 1 ]]; then
        stderr "Error: $msg"
        notify_failure "$msg"
        gui_error "$msg"
        do_launch
    else
        stderr "Error: $msg"
        notify_failure "$msg"
        gui_error_question "$msg"
    fi
}

# Unexpected errors, not suppressed by --nofail or user confirm
function fatal() {
    local msg="$1"
    stderr "Error: $msg"
    notify_failure "$msg"
    gui_error "$msg"
}

trap 'msg="Script failed at line $LINENO: command \"$BASH_COMMAND\" exited with status $?"; fatal "$msg"; exit 1' ERR

# Support launching as a Steam shim (/path/to/script.sh -- %command%)
# What this does:
# - checks if SteamLaunch is in args
# - If yes, shift this script and all its arguments to 3 positions after SteamLaunch
# So an invocation like
# script.sh --gui -- steam-launch-wrapper -- reaper SteamLaunch AppId=123 -- game.exe --debug
# Becomes
# steam-launch-wrapper -- reaper SteamLaunch AppId=123 -- script.sh --gui -- game.exe --debug
args=("$@")
for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == "SteamLaunch" ]]; then
        for j in "${!args[@]}"; do
            if [[ "${args[$j]}" == "--" ]]; then
                script_args=("${args[@]:0:$((j + 1))}")
                other_args=("${args[@]:$((j + 1))}")                
                insert_pos=$((i + 3 - ${#script_args[@]}))
                new_args=(
                    "${other_args[@]:0:$insert_pos}"
                    "$0"
                    "${script_args[@]}"
                    "${other_args[@]:$insert_pos}"
                )
                exec "${new_args[@]}"
                exit
            fi
        done
    fi
done

function usage() {
    cat <<EOF
Usage: $0 [options] [-- command [args...]]

Options:
  --curl-progress   Enable curl command-line progress bars.
  --curl-silent     Run curl with --silent --show-error.
  --dry-run         Check files but do not download or modify anything.
  --gui             Enable GUI progress bar and errors using Zenity.
  --gui-fallback    If --gui is specified but Zenity is not installed,
                    fall back to notify-send. If notify-send is not
                    installed, work silently.
  --headless        (deprecated) Synonymous to --curl-silent.
  --nofail          Launch the command even if updates fail for a known reason.
  --notifications   Enable desktop notifications via notify-send for errors
                    and available updates.
  -s, --silent      Suppress non-error output. Implies --curl-silent.
  -h, --help        Show this help message and exit.

Environment Variables:
  WOW_DIR           Path to the World of Warcraft directory (default: current directory).
  JQ                Path to the jq binary to be used over system jq.
  
Command Execution:
  You can optionally specify a command to run after a successful update
  by using '--' followed by the command and its arguments. For example:

      $0 --gui -- wine /opt/wow/Wow.exe -console

  This will run the updater first, and then launch the given command only
  if the update completes successfully.

EOF
}

# Separate script arguments from executed command
CMD_ARGS=()
SCRIPT_ARGS=()
SEEN_DOUBLE_DASH=0
for arg in "$@"; do
    if [[ "$arg" == "--" ]]; then
        SEEN_DOUBLE_DASH=1
        continue
    fi
    if [[ "$SEEN_DOUBLE_DASH" -eq 1 ]]; then
        CMD_ARGS+=("$arg")
    else
        SCRIPT_ARGS+=("$arg")
    fi
done

# Parse script arguments
for arg in "${SCRIPT_ARGS[@]}"; do
    case "$arg" in
        --curl-progress)
            CURL_PROGRESS=1
            ;;
        --curl-silent)
            CURL_SILENT=1
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        --gui-fallback)
            GUI_FALLBACK=1
            ;;
        --gui)
            GUI_MODE="zenity"
            ;;
        --nofail)
            NOFAIL=1
            ;;
        --notifications)
            if ! command -v notify-send &>/dev/null; then
                stderr "--notifications specified but notify-send is not installed."
                exit 1
            fi
            NOTIFICATIONS=1
            ;;
        --headless)
            CURL_SILENT=1
            ;;
        -s|--silent)
            SILENT=1
            CURL_SILENT=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            stderr "Unknown argument: $arg"
            usage
            exit 1
            ;;
    esac
done

#Process interdependent flags
if [[ -n "$GUI_MODE" ]]; then
    if ! command -v zenity &>/dev/null; then
        if [[ "$GUI_FALLBACK" -eq 1 ]]; then
            if command -v notify-send &>/dev/null; then
                stdout "--gui --gui-fallback specified and Zenity not installed; falling back to notify-send"
                NOTIFICATIONS=1
                GUI_MODE=""
            else
                stdout "--gui --gui-fallback specified and neither Zenity nor notify-send installed; operating silently"
                GUI_MODE=""
            fi
        else
            stderr "--gui was specified but Zenity is not installed."
            exit 1
        fi
    fi
fi

function do_launch() {
    if [[ "${#CMD_ARGS[@]}" -gt 0 ]]; then
        cleanup
        stdout "Running post-update command: ${CMD_ARGS[*]}"
        exec "${CMD_ARGS[@]}"
        #exec replaces the shell so below only ever run
        #if launch fails in some strange way
        fatal "Failed to launch command: ${CMD_ARGS[*]}"
        exit 1
    fi
}

function gui_progress_update() {
    if [[ -z "$GUI_MODE" ]]; then
        return
    fi
    if [[ "$GUI_MODE" == "zenity" && -n "$GUI_PIPE" ]]; then
        trap '' SIGPIPE
        { echo "${1}" >&"$GUI_FD"; } 2>/dev/null || true
        trap - SIGPIPE
    fi
}

function gui_status_update() {
    if [[ -z "$GUI_MODE" ]]; then
        return
    fi
    if [[ "$GUI_MODE" == "zenity" && -n "$GUI_PIPE" ]]; then
        trap '' SIGPIPE
        { echo "#${1}" >&"$GUI_FD"; } 2>/dev/null || true
        trap - SIGPIPE
    fi
}

function check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        error "Required command '$cmd' not found. Please install it."
        exit 1
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

function create_gui() {
    if [[ "$GUI_MODE" == "zenity" ]]; then
        GUI_PIPE=$(mktemp -u --tmpdir epoch-update-fifo.XXXXXX)
        mkfifo "$GUI_PIPE"
        GUI_STATUS_FILE=$(mktemp --tmpdir epoch-gui-status.XXXXXX)
        ZENITY_PID_FILE=$(mktemp --tmpdir epoch-zenity-pid.XXXXXX)

        PARENT_SHELL=$$
        (
            set +e
            zenity --progress --title="Epoch Updater" --percentage=0 --auto-close  --time-remaining <"$GUI_PIPE" &
            ZENITY_PID=$!
            echo "$ZENITY_PID" > "$ZENITY_PID_FILE"
            wait "$ZENITY_PID"
            ZENITY_EXIT="$?"
            set -e
            echo "$ZENITY_EXIT" > "$GUI_STATUS_FILE"
            kill -s SIGUSR1 $PARENT_SHELL
        ) &
        GUI_SUBSHELL_PID=$!
        
        #gotta do this to keep the fifo open between echoes... three hours of debugging
        exec {GUI_FD}> "$GUI_PIPE"
        
        # Wait for Zenity to start and write its pid
        while [[ ! -s "$ZENITY_PID_FILE" ]]; do sleep 0.05; done
        GUI_PID=$(<"$ZENITY_PID_FILE")
        rm -f "$ZENITY_PID_FILE"
    fi
}

CLEANED_UP=0
function cleanup() {
    if [[ $CLEANED_UP -eq 1 ]]; then
        return
    fi
    CLEANED_UP=1
    
    [[ -n "$CURL_PID" ]] && kill "$CURL_PID" 2>/dev/null || true
    [[ -n "$GUI_SUBSHELL_PID" ]] && kill "$GUI_SUBSHELL_PID" 2>/dev/null || true
    [[ -n "$GUI_PID" ]] && kill "$GUI_PID" 2>/dev/null || true
    [[ -f "$GUI_STATUS_FILE" ]] && rm -f "$GUI_STATUS_FILE" || true
    [[ -n "${GUI_PIPE:-}" && -p "$GUI_PIPE" ]] && rm -f "$GUI_PIPE" || true
    [[ -f "$TMP_PATH" ]] && rm -f "$TMP_PATH" || true
    [[ -f "$TMP_MANIFEST" ]] && rm -f "$TMP_MANIFEST" || true
    
    if [[ "$GUI_MODE" == "zenity" && -n "$GUI_FD" ]]; then
        #close fifo
        exec {GUI_FD}>&-
    fi
}
function on_sigint() {
    stderr "Terminated by SIGINT."
    cleanup
    exit 130
}
function on_sigterm() {
    stderr "Terminated by SIGTERM."
    cleanup
    exit 143
}
function on_sighup() {
    stderr "Terminated by SIGHUP."
    cleanup
    exit 129
}
#Called by Zenity subshell when Zenity is closed
function on_sigusr1() {
    if [[ "$GUI_MODE" == "zenity" && -f "$GUI_STATUS_FILE" ]]; then
        ZENITY_EXIT_CODE=$(<"$GUI_STATUS_FILE")
        if [[ "ZENITY_EXIT_CODE" -eq 1 ]]; then
            stderr "User clicked Cancel."
            cleanup
            exit 1
        fi
    fi
}
trap 'cleanup' EXIT
trap 'on_sigint' SIGINT
trap 'on_sigterm' SIGTERM
trap 'on_sighup' SIGHUP
trap 'on_sigusr1' SIGUSR1


# Check available commands
check_command curl

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
if [[ -n "$GUI_MODE" ]]; then
    create_gui
fi

# Download manifest
TMP_MANIFEST=$(mktemp --tmpdir epoch_manifest.XXXXXX.json)
stdout "Downloading manifest..."
gui_status_update "Downloading manifest..."
gui_progress_update "0"
curl -sSfL "$MANIFEST_URL" -o "$TMP_MANIFEST" &
CURL_PID=$!
if ! wait "$CURL_PID"; then
    error "Failed to fetch manifest."
    exit $E_MANIFEST_FAILED
fi
# Normalize manifest paths to use forward slashes
"$JQ" '.Files |= map(.Path |= gsub("\\\\"; "/"))' "$TMP_MANIFEST" > "${TMP_MANIFEST}.tmp" && mv "${TMP_MANIFEST}.tmp" "$TMP_MANIFEST"

FILE_COUNT=$("$JQ" '.Files | length' "$TMP_MANIFEST")
stdout "Found $FILE_COUNT files in manifest."


# Determine which files need to be updated
UPDATED=0
CURRENT=0
TOTAL_DOWNLOAD_SIZE=0
declare -a TO_UPDATE=()
declare -A FILE_URLS

gui_status_update "Checking files..."
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
            stdout "[OK] $FILE_PATH"
            ((CURRENT+=1))
            continue
        fi
    fi

    stdout "[UPDATE NEEDED] $FILE_PATH"
    TO_UPDATE+=("$FILE_PATH")
    FILE_URLS["$FILE_PATH"]="${URLS[*]}"
    FILE_SIZE=$("$JQ" -r ".Files[$i].Size" "$TMP_MANIFEST")
    TOTAL_DOWNLOAD_SIZE=$((TOTAL_DOWNLOAD_SIZE + FILE_SIZE))
done

NUM_TO_UPDATE="${#TO_UPDATE[@]}"

SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_DOWNLOAD_SIZE / 1024 / 1024 }")

if [[ "$DRY_RUN" -eq 1 ]]; then
    stdout ""
    stdout "Dry run complete. $NUM_TO_UPDATE files would be updated. Download size: $SIZE_MB MiB."
    exit $E_SUCCESS
fi

if [[ "$NUM_TO_UPDATE" -gt 0 ]]; then
    stdout ""
    stdout "$NUM_TO_UPDATE files need to be updated. Total download size: ${SIZE_MB} MiB."
    
    notify_status "$NUM_TO_UPDATE file updates (size: $SIZE_MB MiB) are being downloaded."
fi


# Download updated files
gui_status_update "Downloading files..."
TOTAL_DOWNLOADED=0
for FILE_PATH in "${TO_UPDATE[@]}"; do
    LOCAL_PATH="$WOW_DIR/$FILE_PATH"
    TMP_PATH=$(mktemp "${LOCAL_PATH}.XXXXXX.part")
    URLS=(${FILE_URLS["$FILE_PATH"]})
    EXPECTED_HASH=$("$JQ" -r ".Files[] | select(.Path == \"$FILE_PATH\") | .Hash" "$TMP_MANIFEST")
    FILE_SIZE=$("$JQ" -r ".Files[] | select(.Path == \"$FILE_PATH\") | .Size" "$TMP_MANIFEST")
    FILE_SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $FILE_SIZE / 1024 / 1024 }")

    stdout "Downloading $FILE_PATH ($FILE_SIZE_MB MiB)..."

    SUCCESS=0
    CURRENT_DOWNLOADED=0
    
    if [[ -n "$GUI_MODE" ]]; then
        (
            while :; do
                CURRENT_DOWNLOADED=$(stat -c%s "$TMP_PATH" 2>/dev/null || echo 0)
                NOW_DOWNLOADED=$((TOTAL_DOWNLOADED + CURRENT_DOWNLOADED))
                NOW_DOWNLOADED_MB=$(bytes_to_mb "$NOW_DOWNLOADED")
                PERCENT=$((NOW_DOWNLOADED * 99 / TOTAL_DOWNLOAD_SIZE))
                gui_progress_update "$PERCENT"
                gui_status_update "($((UPDATED + 1))/$NUM_TO_UPDATE) Downloading $FILE_PATH...\nOverall progress: $NOW_DOWNLOADED_MB / $SIZE_MB MiB"
                sleep 0.2
            done
        ) &
        MONITOR_PID=$!
    fi
    
    for URL in "${URLS[@]}"; do
        stdout "Attempting $URL..."
        
        CURL_FLAGS=(--fail --location)
        if [[ "$CURL_PROGRESS" -eq 1 ]]; then
            CURL_FLAGS+=(--progress-bar)
        fi
        if [[ "$CURL_SILENT" -eq 1 ]]; then
            CURL_FLAGS+=(--silent --show-error)
        fi
        
        curl "${CURL_FLAGS[@]}" "$URL" -o "$TMP_PATH" &
        CURL_PID=$!
        if wait "$CURL_PID"; then
            NEW_HASH=$(hash_file "$TMP_PATH")
            if [[ "$NEW_HASH" == "$EXPECTED_HASH" ]]; then
                mv -f "$TMP_PATH" "$LOCAL_PATH"
                ((UPDATED+=1))
                SUCCESS=1
                break
            else
                stdout "Hash mismatch for $FILE_PATH from $URL. Expected $EXPECTED_HASH, was $NEW_HASH."
                rm -f "$TMP_PATH"
            fi
        else
            stdout "Download failed from $URL"
            rm -f "$TMP_PATH"
        fi
    done

    if [[ "$SUCCESS" -ne 1 ]]; then
        error "Failed to update $FILE_PATH."
        exit $E_DOWNLOAD_FAILED
    fi
    
    if [[ -n "$GUI_MODE" ]]; then
        kill "$MONITOR_PID" 2>/dev/null || true
        TOTAL_DOWNLOADED=$((TOTAL_DOWNLOADED + FILE_SIZE))
        gui_progress_update "$((TOTAL_DOWNLOADED * 99 / TOTAL_DOWNLOAD_SIZE))"
    fi
done

stdout ""
stdout "$UPDATED files updated."
stdout "$CURRENT files already up to date."

if [[ -n "$GUI_MODE" ]]; then
    gui_progress_update "100"
    gui_status_update "Done!"
fi

cleanup
do_launch

trap '' EXIT
exit $E_SUCCESS
