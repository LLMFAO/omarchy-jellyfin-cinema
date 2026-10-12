# Changelog

## 1.1.0 — 2026-10-11

- Show download progress in a card at the top of the popup, with labeled Download, Saved, Cancel, Resume, and Remove controls.
- Keep Previous, Next, and the player actions in full-width bars at the bottom of the popup.
- List offline movies as rows with Play, Sync, and Delete, and hide the folder editor until Folder is opened.
- Add a private offline library with explicit downloads, progress, cancel, validated resume, local playback, and retained files after sign-out.
- Serialize offline index pruning and final media rename so refreshes cannot orphan a completed download.
- Hold the transfer lock through sign-out and download-folder changes to prevent account/root races.
- Scope the signed-in Offline view to its account while retaining all saved files in the signed-out view.
- Let users adopt the compared Jellyfin resume point locally; restrict generated files to known video containers.
- Add keyboard focus and Enter/Space activation to the offline tabs, folder button, and cancel/remove controls.
- Save offline movies by generated filenames under `~/Downloads/Jellyfin Cinema` by default, with an editable destination before the first download.
- Keep partial downloads out of the offline library; check Jellyfin's download permission, free space, range responses, validators, and completion size before commit.
- Save offline resume position locally and add a deliberate compare/choose flow before updating Jellyfin progress.
- Let a local movie start while a Jellyfin movie continues on a TV or another remote client; enforce one local player per computer across accounts.
- Keep browsing available when playback status cannot be fetched, return results before artwork downloads, and isolate session/artwork workers.
- Scope playback sessions and poster caches to the signed-in account; prune poster cache storage at a fixed total limit.
- Require an explicit acknowledgment before sending passwords or tokens to an HTTP server.
- Make setup/removal writes atomic and repeatable; allow safe window-rule removal if the plugin manifest has disappeared.
- Keep sign-out honest about server revocation and prevent account changes during playback/download startup.
- Retain the launch readiness handshake, subtitle controls, player cleanup, and expired-login recovery.

## 1.0.2 — 2026-10-11

- Keep Jellyfin authorization out of mpv and FFmpeg by streaming through a loopback-only proxy.
- Block cross-origin stream redirects and preserve byte-range seeking through the proxy.
- Add regression tests for redirected playback and range forwarding.

## 1.0.1 — 2026-10-11

- Refuse Jellyfin API redirects to a different origin before forwarding the session token.
- Keep account and poster-cache directories private and enforce mode `600` on saved session data.
- Add local regression tests for redirect handling and credential-file permissions.
