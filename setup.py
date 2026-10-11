#!/usr/bin/env python3
"""Install/remove only the Jellyfin Cinema user window-rule include."""
import pathlib, shutil, subprocess, sys, time
p=pathlib.Path(__file__).resolve().parent
config=pathlib.Path.home()/".config/hypr/hyprland.lua"
line='dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/paul.jellyfin/window-rules.lua")'
remove="--remove" in sys.argv
if p != pathlib.Path.home()/".config/omarchy/plugins/paul.jellyfin":
    sys.exit("Place this plugin at ~/.config/omarchy/plugins/paul.jellyfin before running setup.")
subprocess.run(["omarchy","plugin","validate",str(p)],check=True)
original=config.read_text()
backup=config.with_suffix(".lua.before-jellyfin")
if not backup.exists(): shutil.copy2(config,backup)
text="\n".join(x for x in original.split("\n") if x!=line)
if not remove: text=text.rstrip()+"\n"+line+"\n"
config.write_text(text)
try:
    subprocess.run(["hyprctl","reload"],check=True)
    result=subprocess.run(["hyprctl","configerrors"],capture_output=True,text=True,check=True)
    if result.stdout.strip() not in ("", "ok"): raise RuntimeError(result.stdout)
except Exception:
    config.write_text(original)
    subprocess.run(["hyprctl","reload"],check=False)
    raise
subprocess.run(["omarchy-shell","shell","rescanPlugins"],check=True)
for attempt in range(8):
    result=subprocess.run(["omarchy","plugin","disable" if remove else "enable","paul.jellyfin"],capture_output=True,text=True)
    if result.returncode==0:
        print(result.stdout.strip()); break
    time.sleep(.25)
else: sys.exit(result.stderr.strip() or "Plugin discovery failed; retry setup when the shell is ready.")
