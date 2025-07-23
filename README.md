# epoch-update.sh

A ~~simple~~ updater bash script for Project Epoch to replace the official Electron-based updater, which can work poorly under Wine.

The script does basically the exact same thing the official launcher does. It fetches the same manifest.json the official updater does, compares local file hashes to the hashes in the manifest, and downloads any files that do not match from the Project Epoch CDN URLs specified in the manifest.

## Quickstart

1. Make sure `jq` and `curl` are available (install them from your package manager if they aren't).
  - If you want a graphical progress bar, install `zenity` and pass the `--gui` parameter.
  - If you want the script to send desktop notifications when files are updated or if updates fail, install `notify-send` and pass the `--notifications` parameter.
  - Alternatively you can download a static jq binary from https://github.com/jqlang/jq/releases and specify its path using the `JQ=/path/to/jq` before running the script.
2. Download [epoch-update.sh](https://github.com/brndd/epoch-update.sh/raw/refs/heads/master/epoch-update.sh) (right click > Save as) and place it anywhere.
3. `chmod +x epoch-update.sh` to make the script executable.
4. Run the script in the same directory as your WoW.exe -- it expects the working directory to contain the game (alternatively run anywhere and specify the WOW_DIR environment variable before running). If you're unsure about it working, you can pass `--dry-run` to just check if files need updating but not download anything. You can also pass `--help` to see the options.

The script can work both as a standalone updater (default), for launching a command, and as a Steam launch shim. Read below for more details.

## Usage

```
Usage: ./epoch-update.sh [options] [-- command [args...]]

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

      ./epoch-update.sh --gui -- wine /opt/wow/Wow.exe -console

  This will run the updater first, and then launch the given command only
  if the update completes successfully.

```

## With Lutris

The best way to use the script with Lutris is to set it as the "Command prefix" under the "System options" of the game configuration, like so:

`/path/to/epoch-update.sh --gui --gui --gui-fallback --`

This way Lutris will first start the script, which will handle any updates and display its GUI and then launch the game seamlessly.

You may have to specify the `WOW_DIR` environment variable under the "System options" of the game configuration in Lutris if the script has trouble finding Wow.exe (Lutris sometimes gives it a strange working directory).

## With Steam

The script can work as a Steam launch shim by setting the game's launch options to run the script. To do this, right-click the game, select Properties, and insert the command into the Launch Options box, and insert (replacing the path with the actual path of the script):

`/path/to/epoch-update.sh --gui --gui-fallback -- %command%`

An advanced example that also uses Gamemode and Gamescope, enables update GUI, and passes -console as a command line parameter to the game:

`gamemoderun gamescope -w 2560 -h 1440 -W 2560 -H 1440 -f -- /path/to/epoch-update.sh --gui -- %command% -console`


# Lutris install scripts

`epoch-lutris-installer-direct.yaml` and `epoch-lutris-installer-torrent.yaml` are Lutris install scripts that set the game up with the updater script for you. The -direct one automatically downloads the game from Epoch's website, while the -torrent one asks to be pointed to the loose files downloaded from the torrent (or any other version 3.3.5 WoW client).

A slightly modified version of the direct installer is also available on [the Lutris website](https://lutris.net/games/project-epoch/). This version downloads a prebuilt jq binary to make it more portable across distributions, as not all distros ship jq.
