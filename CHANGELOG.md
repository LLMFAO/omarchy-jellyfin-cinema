# Changelog

## 1.0.1 — 2026-10-11

- Refuse Jellyfin API redirects to a different origin before forwarding the session token.
- Keep account and poster-cache directories private and enforce mode `600` on saved session data.
- Add local regression tests for redirect handling and credential-file permissions.
