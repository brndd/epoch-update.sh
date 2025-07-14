# epoch-update.sh

A simple updater bash script for Project Epoch to replace the official Electron-based updater, which can work poorly under Wine.

The script does basically the exact same thing the official launcher does, but without a GUI. It fetches the same manifest.json the official updater does, compares local file hashes to the hashes in the manifest, and downloads any files that do not match from the Project Epoch CDN URLs specified in the manifest.

## Usage


1. Make sure `jq` and `curl` are available (install them from your package manager if they aren't). If you want the script to send desktop notifications when files are updated or if updates fail, install `notify-send` too.
2. Place in your Project Epoch installation directory (next to WoW.exe). Alternatively place anywhere and specify the WOW_DIR environment variable before running.
3. Run the script. If you're unsure about it working, you can pass `--dry-run` to just check if files need updating but not download anything.

The intended usage is to run this as a Lutris pre-launch script. When ran non-interactively, the script will try to use notify-send to pop up a desktop notification when files are updated and if updates fail. This is because Lutris doesn't support aborting launching the game if the pre-launch script fails.

# steam-launch.sh

This is a launch shim that lets you update the game when launching it from Steam, if you have added the game to your library as a non-Steam game.

1. Download `epoch-update.sh` and place into the game directory (next to WoW.exe).
2. Make the script executable: `chmod +x steam-launch.sh`
3. Set Steam launch options to: `/full/path/to/steam-launch.sh %command%` (replacing the path with the actual path to the script)


# Lutris install scripts

`epoch-lutris-installer-direct.yaml` and `epoch-lutris-installer-torrent.yaml` are Lutris install scripts that set the game up with the updater script for you. The -direct one automatically downloads the game from Epoch's website, while the -torrent one asks to be pointed to the loose files downloaded from the torrent (or any other version 3.3.5 WoW client).
