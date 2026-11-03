# Important:

None of this shit is tested

# tools/frame — on-Frame maintenance scripts

Scripts you copy to the Steam Frame headset and run there (SteamOS).

## frame-screenshot-format.sh — screenshot destination/format (no root, no ro-writes)

**Why your in-VR screenshots are JPG:** the compositor saves a PNG to
`../../screenshots` relative to its CWD; `select_steamvr.sh` sets that CWD to
`<runtime>/bin/linuxarm64`, i.e. `<runtime>/screenshots`. With `/opt/steamvr`
that directory doesn't exist and the rootfs is read-only — the PNG write fails
silently and only the JPG the Steam client encodes survives.

**The fix never touches the read-only fs.** `shadow on` builds a shadow runtime
under `$HOME` — real `bin/linuxarm64` dir (per-file symlinks to `/opt/steamvr`,
plus a real writable copy of `vrmonitor`), symlinks for the rest, and a real
`screenshots/` dir — then points the OS at it with the supported
`steamvr setpath` (steamvr.service re-applies it every boot):
```bash
bash frame-screenshot-format.sh shadow on       # build + setpath
bash frame-screenshot-format.sh shadow status   # active runtime, PNG count, drift
bash frame-screenshot-format.sh shadow off      # setpath back to /opt/steamvr
bash frame-screenshot-format.sh shadow off --purge   # also delete the shadow dir
```
After `shadow on`, restart SteamVR. In-VR PNGs land in
`~/.steamvr-shadow/screenshots/`. Steam's own library copy stays JPG — that
encoder lives in the Steam client, not SteamVR. Re-run `shadow on` after OS
updates to re-sync symlinks / refresh the vrmonitor copy.
Because the shadow's `vrmonitor` is a real writable copy, this also unblocks
`frame-lowbatt-notif.sh pct` with **no root and no verity changes**.

Dev helper `screenshot` (`/etc/bashrc.d/vrshortcuts.sh`, ffmpeg grab of
`/dev/video99`): `png` / `jpg` flip its default extension. NOTE: `/etc` is on
the read-only rootfs — this is the only mode needing
`sudo steamos-readonly disable`, and current images already ship `.png`, so you
likely never need it. `restore` undoes the helper edit.
```bash
sudo bash frame-screenshot-format.sh png|jpg
bash frame-screenshot-format.sh status
sudo bash frame-screenshot-format.sh restore
```

## frame-lowbatt-notif.sh — control "Controller battery low" notifications

**Patches the ACTIVE SteamVR runtime** (`steamvr path`). Default = `/opt/steamvr`
(read-only: needs `sudo steamos-readonly disable`, or use the shadow runtime
above and it just works without root). `-f` forces the fallback; `status` shows
both and reports the *current* threshold.
```bash
bash frame-lowbatt-notif.sh status           # active runtime, current threshold, patches
sudo bash frame-lowbatt-notif.sh pct 30      # notify at 30% instead of current
sudo bash frame-lowbatt-notif.sh pct 0       # never notify (clean "off" via threshold)
sudo bash frame-lowbatt-notif.sh pct 100     # always notify (testing the popover)
sudo bash frame-lowbatt-notif.sh off         # blank the popover tokens (reversible)
sudo bash frame-lowbatt-notif.sh binary      # 1-byte vrmonitor patch (hard kill)
     bash frame-lowbatt-notif.sh dnd         # DoNotDisturb=true in steamvr.vrsettings
sudo bash frame-lowbatt-notif.sh restore     # undo off/binary/pct from backups
```

The threshold is a hardcoded `battery < X` check in vrmonitor, located by
machine-code signature; the OS image ships X = 15% (the script reports what
*your* build uses before patching). `pct` supports half-steps 0–100 whose
double is aarch64-encodable; anything else is rejected with the supported list.
`off` blanks the `Popover_LowBattery_Controller_*` tokens in
`content/vrmonitor/translations/vrmonitor_errors_*.txt` (UTF-16LE); `binary`
1-byte-patches vrmonitor's `_LowBattery` state string. Backups:
`*.lowbatt-backup` next to each patched file (`restore` undoes all).
SteamVR updates revert patches — re-run after updates.

Full mechanism + evidence (incl. the patched instructions):
`/workspace/analysis/controller-lowbatt-notif.md`.

## Deploying to the Frame
```bash
scp -i /workspace/.ssh/frame_debug_key tools/frame/frame-*.sh frame@<frame_host>:
ssh -i /workspace/.ssh/frame_debug_key frame@<frame_host>
```
(hosts/keys from `/workspace/.creds`.)
