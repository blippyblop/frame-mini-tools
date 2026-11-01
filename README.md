# tools/frame — on-Frame maintenance scripts

Scripts you copy to the Steam Frame headset and run there (SteamOS).

## frame-lowbatt-notif.sh — control "Controller battery low" notifications

**Patches the ACTIVE SteamVR runtime** (`steamvr path` — which may be a
Steam-managed runtime under `/home`; `/opt/steamvr` is only the immutable
fallback). Use `-f` to force the fallback, `status` shows both.
```bash
sudo bash frame-lowbatt-notif.sh status      # active runtime, current threshold, applied patches
sudo bash frame-lowbatt-notif.sh pct 30      # notify at 30% instead of the current threshold
sudo bash frame-lowbatt-notif.sh pct 0       # never notify (clean "off" via threshold)
sudo bash frame-lowbatt-notif.sh pct 100     # always notify (testing the popover)
sudo bash frame-lowbatt-notif.sh off         # blank the popover tokens (reversible)
sudo bash frame-lowbatt-notif.sh binary      # 1-byte vrmonitor patch (hard kill)
     bash frame-lowbatt-notif.sh dnd         # DoNotDisturb=true in steamvr.vrsettings
sudo bash frame-lowbatt-notif.sh restore     # undo off/binary/pct from backups
```

The popover threshold lives in vrmonitor as a hardcoded `battery < X` check
(machine-code signature, located and reported before patching — the stock OS
image ships X = 15%, so a device notifying at 20% is running a different
runtime/build; `status` tells you what yours uses and `pct` rewrites it).
`pct` supports half-steps 0–100 whose double is aarch64-encodable; anything
else is rejected with the supported list.
`off` blanks the `Popover_LowBattery_Controller_*` tokens in
`content/vrmonitor/translations/vrmonitor_errors_*.txt` (UTF-16LE); `binary`
1-byte-patches vrmonitor's `_LowBattery` state string.
`off`/`binary`/`pct` on `/opt/steamvr` need `sudo steamos-readonly disable`
once (re-enable after); a Steam-managed runtime under `/home` is writable.
Backups: `*.lowbatt-backup` next to each patched file (`restore` undoes all).
SteamVR runtime updates revert patches — re-run after updates.

Full mechanism + evidence (incl. the patched instructions):
`/workspace/analysis/controller-lowbatt-notif.md`.

## frame-screenshot-format.sh — screenshot output format / destination

Two surfaces:

1. **In-VR screenshots (compositor).** The compositor saves a PNG to
   `<runtime>/screenshots` (it resolves `../../screenshots` against its CWD).
   With the default `/opt/steamvr` runtime that directory is missing *and*
   read-only, so the PNG write fails silently and the only artifact left is
   the JPG the Steam client encodes from the submitted frame.
   ```bash
   sudo bash frame-screenshot-format.sh png-dir on      # one-time; see below
   sudo bash frame-screenshot-format.sh png-dir status
   sudo bash frame-screenshot-format.sh png-dir off
   ```
   `png-dir on` creates the mountpoint and bind-mounts
   `/home/steamos/screenshots/vr` (override with `SCREENSHOT_DIR=…`) onto it
   via a systemd mount unit — compositor PNGs then survive and land in your
   home. Needs `sudo steamos-readonly disable` once (to create the
   mountpoint + unit under `/etc`); `steamos-readonly enable` can be re-run
   afterwards, the mount persists across boots. Steam's own library copy
   stays JPG — that encoder lives in the Steam client, not SteamVR.
   If the active runtime is a Steam-managed one under `/home`, its
   screenshots dir is already writable (no mount needed; `status` says so).

2. **Dev `screenshot` helper** (`/etc/bashrc.d/vrshortcuts.sh`, ffmpeg grab of
   the `/dev/video99` loopback): format follows the default filename extension.
   ```bash
   sudo bash frame-screenshot-format.sh png      # helper defaults to .png
   sudo bash frame-screenshot-format.sh jpg      # ...or .jpg
   sudo bash frame-screenshot-format.sh status
   sudo bash frame-screenshot-format.sh restore  # undo helper edit + mount
   ```
   Backup: `vrshortcuts.sh.sshotfmt-backup`. An explicit
   `screenshot /path/name.ext` argument always wins. OS updates revert
   (re-run after updating).

## Deploying to the Frame
```bash
scp -i /workspace/.ssh/frame_debug_key tools/frame/frame-*.sh frame@<frame_host>:
ssh -i /workspace/.ssh/frame_debug_key frame@<frame_host>
```
(hosts/keys from `/workspace/.creds`.)
