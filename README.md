# Jellyfin Cinema

An Omarchy 4 bar plugin for browsing Jellyfin movie posters inside the popup and playing a selected movie in a tiled mpv window. It also lets you explicitly save movies for local playback when you are away from the server. Browsing does not open a player window. The popup uses compact four-column poster pages, search, resume labels, and touch-friendly scrolling.

## Requirements

Omarchy 4 with the Quickshell plugin API and Lua Hyprland configuration, Python 3, mpv, and a reachable Jellyfin server for browsing or downloading. Offline playback works without a server connection. No extra Python modules, browser, daemon, or Jellyfin server modification is required. The Jellyfin account must allow media downloads for the selected movie.

## Install

Install from GitHub with `omarchy plugin add https://github.com/LLMFAO/omarchy-jellyfin-cinema.git --enable --yes`.

Run `python ~/.config/omarchy/plugins/paul.jellyfin/setup.py` to opt in to the app-specific tiled-window rule. Setup backs up `~/.config/hypr/hyprland.lua` once, adds only the plugin's managed include, validates the reload, and restores the original file if Hyprland rejects it. To remove the rule, run `python ~/.config/omarchy/plugins/paul.jellyfin/setup.py --remove` before removing the plugin. Removal also works if the plugin manifest has already disappeared, as long as `setup.py` remains. For a local copy, place the repository at `~/.config/omarchy/plugins/paul.jellyfin/`, validate it with `omarchy plugin validate ~/.config/omarchy/plugins/paul.jellyfin`, then run setup.

## Browse and play

Click the film icon. Enter your server URL, username, and password (blank passwords are supported), then Connect. The Connect button requires a separate acknowledgment before sending credentials to an `http://` server because HTTP does not encrypt the password or session token. Use HTTPS on untrusted networks.

Choose a poster to play or resume. The popup stays open until mpv confirms playback or reports a startup failure. Search with Enter, scroll through the posters, or use the page controls. The header shows this account's Jellyfin movie sessions and refreshes every five seconds. A movie playing on a TV does not block local playback; Jellyfin Cinema allows one local player on this computer at a time, even across account changes.

Local playback opens tiled on the current workspace. mpv provides pause (Space), seeking (arrows), fullscreen (f), subtitle selection (j), audio selection (#), and quit (q). Watch progress is reported to Jellyfin every ten seconds and when stopping. Pin player toggles pinning across workspaces and opts into a floating window. Small/Large also opt into floating and resize the player; use Omarchy's Super+T to tile it again.

## Offline movies

The Offline tab is available while signed out and while the Jellyfin server is unreachable. The default save folder is `~/Downloads/Jellyfin Cinema`; the Browse view shows the active location, and you can enter another absolute folder path in Offline before downloading. Jellyfin Cinema owns that folder and makes it private to your Linux account. The destination cannot be changed after downloads exist; delete the saved movies and any partial transfer first.

In Browse, use Download under a poster to save its original Jellyfin media file. One transfer runs at a time. A progress card stays at the top of the popup with Cancel, and with Resume or Remove if a transfer stops. The poster button shows Saving, a percent, or Saved. The Offline tab lists each movie in a row with Play, Sync, and Delete. Folder changes stay behind the Folder button. An interrupted transfer resumes only when Jellyfin returns a valid byte range and matching ETag or Last-Modified validator. Without range support, retry starts over. Jellyfin's download permission is enforced by the server; HTTP 403 leaves no completed offline entry. Canceled partial files are removed. Incomplete transfers never appear in the offline library.

Downloaded files remain on this computer after sign-out and plugin removal until you explicitly delete them in Offline or remove the folder yourself. While signed in, Offline shows downloads for that Jellyfin account; while signed out, it shows downloads from all accounts saved on this computer. Select a saved poster to play locally; local resume position is saved on this machine. When signed in to the same account, tap the compare icon to view both the local and server resume positions. Choose “Use server here” to save the server position on this device without changing Jellyfin, or “Send local position” to update Jellyfin. The plugin rechecks the server position before writing so a change after comparison is not silently overwritten.

Downloads contain the original media file and its embedded tracks. External subtitle files and alternate media versions are not downloaded. A file must be playable by the installed mpv build. Network loss during a download leaves a private partial file that can be resumed when the server and filesystem support it.

## Data and permissions

The server URL and Jellyfin session token are stored in `~/.config/jellyfin-cinema/config.json` with mode 600 inside a mode-700 directory. The password is passed over stdin during login and is not saved. Tokens never appear in process arguments or media URLs. Online playback uses a random per-playback localhost URL; a loopback-only proxy sends the fixed stream request to Jellyfin, forwards seek ranges, and refuses cross-origin redirects before forwarding the session token. API requests and downloads use the same-origin redirect policy.

Offline media is stored in private mode-700 account subdirectories with mode-600 movie files. The mode-600 local index contains item metadata and generated filenames, not Jellyfin URLs, server filesystem paths, or tokens. Partial files are excluded from playback and become visible only after a checked transfer, atomic rename, and index update. Poster artwork is cached under private per-server/account directories and pruned at a 300 MB total cache limit. Sign-out revokes the Jellyfin session when possible and retains offline media; if the server cannot confirm logout, the saved token is kept. If Jellyfin returns HTTP 401, the plugin clears the unusable local token and tells you remote logout was not confirmed.

This plugin runs with your normal user permissions, contacts your configured Jellyfin server, and executes local mpv/Hyprland commands. No private server address, login, token, browser profile, or media is bundled.

mpv subtitles default to a terminal look: JetBrains Mono Nerd Font in mint green on a translucent dark backdrop. While a local player is active, use A−/A+ to adjust subtitle size and Style to switch between terminal and standard subtitles. The choice and size persist per machine. Poster play, Download, progress-card Cancel/Resume/Remove, Offline row Play/Sync/Delete, Browse/Offline tabs, and the folder editor have keyboard focus and Enter/Space activation.

Online playback uses Jellyfin direct streaming. It requires permission to access and play the movie. Embedded subtitles/audio work through mpv; server transcoding and external subtitle downloads are not implemented. The first available media version is selected. Player errors are reported by desktop notification.

## Remove

Stop local playback. Run `python ~/.config/omarchy/plugins/paul.jellyfin/setup.py --remove` before `omarchy plugin remove paul.jellyfin --yes`. This removes only the managed Hyprland include and disables the widget. Account data, poster cache, and offline downloads remain; sign out before removal to revoke the session. Optional data cleanup is limited to `~/.config/jellyfin-cinema/`, `~/.cache/jellyfin-cinema/`, and `~/Downloads/Jellyfin Cinema` (or your chosen offline folder).

## Verify and share

`omarchy plugin validate .` checks the root manifest. The repository includes an MIT license, native shell components, opt-in setup/removal, and no bundled credentials. Follow <https://plugins.omarchy.org/publish.html> to submit the public repository for marketplace review. Marketplace approval applies to its recorded source snapshot and is not a general security audit.

Version 1.1.0 is installed on Omarchy 4. Marketplace verification applies only to the exact commit recorded for the listing.
