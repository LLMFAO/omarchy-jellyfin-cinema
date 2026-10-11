# Jellyfin Cinema

An Omarchy 4 bar plugin: browse small movie posters directly in the popup, search your Jellyfin library, and choose a poster to launch a movie in a **tiled mpv window**. Browsing never opens a separate window. Four poster columns, 24 movies per page, resume labels, next/previous controls, and faster wheel/touch scrolling with recycled poster tiles.

## Requirements
Omarchy 4 with its Quickshell plugin API and Lua Hyprland configuration, Python 3, mpv, and a reachable Jellyfin server. No extra Python modules, browser, daemon, or Jellyfin server modifications are required.

## Install
Install from GitHub with `omarchy plugin add https://github.com/LLMFAO/omarchy-jellyfin-cinema.git --enable --yes`.
Run `python ~/.config/omarchy/plugins/paul.jellyfin/setup.py` to opt in to the app-specific tiled-window rule. This makes a one-time backup of `~/.config/hypr/hyprland.lua`, adds only the plugin's managed include, validates the reload, and rolls back if validation fails. To remove the rule, run `python ~/.config/omarchy/plugins/paul.jellyfin/setup.py --remove` before removing the plugin. For a local copy, place the repository at `~/.config/omarchy/plugins/paul.jellyfin/`, validate with `omarchy plugin validate ~/.config/omarchy/plugins/paul.jellyfin`, then run setup.

Click the film icon. Enter server URL (including any reverse-proxy base path), username, and password (blank is supported), then Connect. Click a poster to play/resume. Search with Enter; scroll for more posters or use page controls. The header shows the current movie poster while playback is active on any Jellyfin screen for this account, with the device and paused state; it refreshes every five seconds. While another screen is playing, poster play buttons are disabled. Playback is guarded to allow one mpv movie at a time per machine; the server-wide status check also blocks starting while another device is playing. Account edits the connection or signs out.

Playback opens tiled on the current workspace. mpv provides pause (Space), seeking (arrows), fullscreen (f), subtitle selection (j), audio selection (#), and quit (q). Watch progress is reported to Jellyfin every ten seconds and when stopping. Pin player toggles pinning across workspaces and opts into a floating window. Small/Large also opt into floating and resize the player; use Omarchy's Super+T to tile it again.

## Data and permissions
The server URL and Jellyfin session token are stored outside the repository in `~/.config/jellyfin-cinema/config.json` with mode 600 inside a mode-700 directory. The password goes over stdin during login and is not saved. Tokens never appear in process arguments or stream URLs; mpv gets its authorization header from a mode-600 config in a private temporary directory that is removed after playback. API requests refuse redirects to a different origin so the session token is not forwarded to another host. Posters are cached in a mode-700 directory at `~/.cache/jellyfin-cinema/posters/`. The local device ID identifies each machine separately. Sign out revokes the local session.

This plugin runs with your normal user permissions, contacts your configured Jellyfin server, and executes local mpv/Hyprland commands. HTTP is supported for trusted local/tailnet connections; use HTTPS on untrusted networks. No private server address, login, token, browser profile, or media is bundled.

mpv subtitles default to a terminal look: JetBrains Mono Nerd Font in mint green on a translucent dark backdrop. While your local player is active, use A−/A+ to adjust subtitle size and Style to switch between terminal and standard subtitles. The choice and size persist per machine.

Playback uses Jellyfin direct streaming and mpv decoding. Requires permission to access and play the movie. Embedded subtitles/audio work through mpv; server transcoding and external subtitle downloads are not implemented. The first available media version is selected. Player errors are reported by desktop notification.

## Remove
Close playing movies. Run `python ~/.config/omarchy/plugins/paul.jellyfin/setup.py --remove` **before** `omarchy plugin remove paul.jellyfin --yes`. This removes only the managed include and disables the widget. Account and poster cache remain; sign out before removal to revoke the session. Optional data cleanup is limited to the two paths above. If an earlier Chromium version was used, its separate `~/.local/share/jellyfin-cinema/browser/` profile may also be removed.

## Verify and share
`omarchy plugin validate .` checks the root manifest. The repository includes an MIT license, native shell components, opt-in setup/removal, and no bundled credentials. Follow https://plugins.omarchy.org/publish.html to submit the public repository for marketplace review. Marketplace validation checks listing requirements; maintainers explicitly do not perform a security review.

Verified on Omarchy 4: Jellyfin authentication and library browsing, poster pages and search, plugin manifest validation, tiled mpv launch and playback controls, subtitles, and clean Hyprland reload/rollback behavior.
