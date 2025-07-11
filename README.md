# epoch-update.sh

Vibecoded updater bash script for Project Epoch to replace the stinky Electron launcher.

## Usage

1. Place in your Project Epoch installation directory (next to WoW.exe). Alternatively place anywhere and specify the WOW_DIR environment variable before running.
2. Run the script. If you're unsure about it working, you can pass `--dry-run` to just check if files need updating but not download anything.

The intended usage is to run this as a Lutris pre-launch script. When ran non-interactively, the script will try to use notify-send to pop up a desktop notification when files are updated and if updates fail. This is because Lutris doesn't support aborting launching the game if the pre-launch script fails.

## Steam shim

If you run the game through Steam as a non-Steam game, you can use steam-launch.sh
to update the game before running it:

1. Make the script executable: `chmod +x steam-launch.sh`
2. Set Steam launch options to: `/full/path/to/steam-launch.sh %command%`
