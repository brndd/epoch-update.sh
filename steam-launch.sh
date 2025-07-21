#!/usr/bin/env bash
# epoch-update.sh Steam launch shim adapted from BepInEx's launch shim
#
# HOW TO USE:
# 1. Make this script executable: `chmod +x steam-launch.sh`
# 2. Set Steam launch options to: `/full/path/to/steam-launch.sh %command%`

SCRIPT_PATH="$(readlink -f "$0")"
BASEDIR="$(dirname "$SCRIPT_PATH")"
UPDATER="$BASEDIR/epoch-update.sh"

# Ensure the updater is executable
if [ ! -x "$UPDATER" ]; then
    echo "Error: epoch-update.sh not found or not executable in $BASEDIR"
    exit 1
fi

args=("$@")
for i in "${!args[@]}"; do
    if [ "${args[$i]}" = "SteamLaunch" ]; then
        # Insert $0 at position i+3 (two after SteamLaunch)
        insert_pos=$((i + 3))
        new_args=("${args[@]:0:$insert_pos}" "$0" "${args[@]:$insert_pos}")
        exec "${new_args[@]}"
        exit
    fi
done

# Run the updater
"$UPDATER"
UPDATE_EXIT=$?

# Commented out so we launch the game even if update fails, to mirror Lutris behaviour.
# The updater spits out notify-send notifications so the user should be aware

#if [ $UPDATE_EXIT -ne 0 ]; then
#    echo "Epoch updater failed with exit code $UPDATE_EXIT"
#    exit $UPDATE_EXIT
#fi

# If we got here, the update succeeded.
# Now launch the game using the arguments passed to this shim
if [ -z "$1" ]; then
    echo "No game launch command provided to shim."
    exit 1
fi

exec "$@"
