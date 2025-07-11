# epoch-update.sh

Vibecoded updater bash script for Project Epoch to replace the stinky Electron launcher.

## Usage


1. Make sure `jq` and `curl` are available (install them from your package manager if they aren't). If you want the script to send desktop notifications when files are updated or if updates fail, install `notify-send` too.
2. Place in your Project Epoch installation directory (next to WoW.exe). Alternatively place anywhere and specify the WOW_DIR environment variable before running.
3. Run the script. If you're unsure about it working, you can pass `--dry-run` to just check if files need updating but not download anything.

The intended usage is to run this as a Lutris pre-launch script. When ran non-interactively, the script will try to use notify-send to pop up a desktop notification when files are updated and if updates fail. This is because Lutris doesn't support aborting launching the game if the pre-launch script fails.

## Steam shim

If you run the game through Steam as a non-Steam game, you can use steam-launch.sh
to update the game before running it:

1. Make the script executable: `chmod +x steam-launch.sh`
2. Set Steam launch options to: `/full/path/to/steam-launch.sh %command%` (replacing the path with the actual path to the script)

Note that you still need epoch-update.sh in the WoW installation directory for steam-launch.sh to work.
