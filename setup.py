#!/usr/bin/env python3
"""Install/remove only the Jellyfin Cinema user window-rule include."""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time


plugin = pathlib.Path(__file__).resolve().parent
expected = pathlib.Path.home() / ".config/omarchy/plugins/paul.jellyfin"
config = pathlib.Path.home() / ".config/hypr/hyprland.lua"
managed_line = 'dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/paul.jellyfin/window-rules.lua")'
remove = "--remove" in sys.argv


def atomic_write(path, text, mode):
    descriptor, temporary = tempfile.mkstemp(prefix=".jellyfin-cinema-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def run(command):
    return subprocess.run(command, capture_output=True, text=True)


if plugin != expected:
    sys.exit("Place this plugin at ~/.config/omarchy/plugins/paul.jellyfin before running setup.")
if not config.is_file() or config.is_symlink():
    sys.exit("The Omarchy Hyprland config is missing or unsafe; no changes were made.")
if not remove:
    result = run(["omarchy", "plugin", "validate", str(plugin)])
    if result.returncode:
        sys.exit(result.stderr.strip() or "Plugin validation failed; no changes were made.")

original = config.read_text()
original_mode = config.stat().st_mode & 0o777
backup = config.with_suffix(".lua.before-jellyfin")
lines = original.split("\n")
without_rule = [line for line in lines if line != managed_line]
if remove:
    updated = "\n".join(without_rule)
else:
    deduplicated = []
    seen_rule = False
    for line in lines:
        if line == managed_line:
            if not seen_rule:
                deduplicated.append(line)
                seen_rule = True
        else:
            deduplicated.append(line)
    updated = "\n".join(deduplicated) if seen_rule else original.rstrip() + "\n" + managed_line + "\n"
changed = updated != original

if backup.is_symlink() or (backup.exists() and not backup.is_file()):
    sys.exit("The Jellyfin config backup path is unsafe; no changes were made.")
if changed and not backup.exists():
    shutil.copy2(config, backup)

if changed:
    atomic_write(config, updated, original_mode)
    try:
        subprocess.run(["hyprctl", "reload"], check=True)
        result = subprocess.run(["hyprctl", "configerrors"], capture_output=True, text=True, check=True)
        if result.stdout.strip() not in ("", "ok"):
            raise RuntimeError(result.stdout.strip())
    except Exception as exc:
        atomic_write(config, original, original_mode)
        subprocess.run(["hyprctl", "reload"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        raise RuntimeError("Hyprland rejected the window rule; the original config was restored.") from exc

result = run(["omarchy-shell", "shell", "rescanPlugins"])
if result.returncode:
    sys.exit("The Hyprland config is valid, but Omarchy shell discovery failed. Rerun setup after the shell is ready.")

command = ["omarchy", "plugin", "disable" if remove else "enable", "paul.jellyfin"]
for attempt in range(8):
    result = run(command)
    if result.returncode == 0:
        print(result.stdout.strip() or ("Plugin disabled." if remove else "Plugin enabled."))
        break
    time.sleep(0.25)
else:
    detail = result.stderr.strip() or result.stdout.strip() or "plugin command did not succeed"
    sys.exit("Hyprland config is valid and applied, but plugin discovery/" + ("disable" if remove else "enable") + " failed: " + detail + ". Rerun setup after the shell is ready.")
