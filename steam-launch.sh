#!/usr/bin/env sh
# epoch-update.sh Steam launch shim adapted from BepInEx's launch shim
#
# HOW TO USE:
# 1. Make this script executable: `chmod +x steam-launch.sh`
# 2. Set Steam launch options to: `/full/path/to/steam-launch.sh %command%`

SCRIPT_PATH="$(readlink -f "$0")"
BASEDIR="$(dirname "$SCRIPT_PATH")"

# Special case: launched via Steam
if [ "$2" = "SteamLaunch" ]; then
    cmd="$1 $2 $3 $4 $0"
    shift 4
    exec $cmd "$@"
    exit
fi

# Path to updater script (assumed in same dir as this shim)
UPDATER="$BASEDIR/epoch-update.sh"

# Ensure the updater is executable
if [ ! -x "$UPDATER" ]; then
    echo "Error: epoch-update.sh not found or not executable in $BASEDIR"
    exit 1
fi

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
