# tools/frame — on-Frame maintenance scripts

Scripts you copy to the Steam Frame headset and run there (SteamOS).

## frame-lowbatt-notif.sh — control "Controller battery low" notifications
```bash
sudo bash frame-lowbatt-notif.sh status      # what is currently applied
sudo bash frame-lowbatt-notif.sh off         # blank the popover tokens (reversible)
sudo bash frame-lowbatt-notif.sh binary      # 1-byte vrmonitor patch (hard kill)
sudo bash frame-lowbatt-notif.sh pct 30      # change the threshold to 30% instead
     bash frame-lowbatt-notif.sh dnd         # DoNotDisturb=true in steamvr.vrsettings
sudo bash frame-lowbatt-notif.sh restore     # undo off/binary/pct from backups
```

The popover is SteamVR `vrmonitor`'s status popover; it fires when a device's
battery drops below a hardcoded **15%** threshold (`battery < 0.15`, site
`vrmonitor+0x1562f8`). `pct <N>` rewrites that threshold (N in percent, half-step
values 0–100; `pct 0` = never notify, `pct 15` = stock, `pct 100` = always).
`off` blanks the `Popover_LowBattery_Controller_*` tokens in
`/opt/steamvr/content/vrmonitor/translations/vrmonitor_errors_*.txt` (UTF-16LE);
`binary` 1-byte-patches vrmonitor's `_LowBattery` state string.
`off`/`binary`/`pct` write under `/opt/steamvr` (read-only rootfs): run
`sudo steamos-readonly disable` once first, and re-apply after OS updates.
Backups: `*.lowbatt-backup` next to each patched file (`restore` undoes all).

Full mechanism + evidence (incl. the patched instructions):
`/workspace/analysis/controller-lowbatt-notif.md`.

## frame-screenshot-format.sh — screenshot output format (png/jpg)
```bash
sudo bash frame-screenshot-format.sh status   # current default format
sudo bash frame-screenshot-format.sh png      # default screenshots to .png
sudo bash frame-screenshot-format.sh jpg      # default screenshots to .jpg
sudo bash frame-screenshot-format.sh restore  # undo from backup
```

Changes the no-argument default of the dev `screenshot` helper in
`/etc/bashrc.d/vrshortcuts.sh` (ships with the OS image). That helper grabs one
frame from the SteamVR loopback (`/dev/video99`) with ffmpeg — ffmpeg picks the
encoder from the filename extension, so the default extension in `screenshot()`
(`~/screenshots/screenshot-<timestamp>.ext`) decides the saved format.
The current OS image already defaults to `.png` (older builds to `.jpg`); this
tool flips/normalizes either way. Writes to `/etc` (read-only rootfs): run
`sudo steamos-readonly disable` once first. An explicit
`screenshot /path/name.ext` argument always wins. Backup:
`vrshortcuts.sh.sshotfmt-backup`. OS updates revert (re-run after updating).

## Deploying to the Frame
```bash
scp -i /workspace/.ssh/frame_debug_key tools/frame/frame-*.sh frame@<frame_host>:
ssh -i /workspace/.ssh/frame_debug_key frame@<frame_host>
```
(hosts/keys from `/workspace/.creds`.)
