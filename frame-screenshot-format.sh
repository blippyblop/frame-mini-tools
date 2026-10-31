#!/bin/bash
# Frame (SteamOS) — change the screenshot output format of the dev `screenshot`
# helper in /etc/bashrc.d/vrshortcuts.sh, userspace only.
#
# The helper captures one frame from the SteamVR loopback device (/dev/video99)
# with ffmpeg and writes to ~/screenshots/screenshot-<timestamp>.EXT. ffmpeg
# picks the encoder from the file extension, so the saved format is simply the
# default extension in the script (stock image ships .png; older builds .jpg).
#
# Modes:
#   status    show the current default screenshot format
#   png       default screenshots to .png
#   jpg       default screenshots to .jpg
#   restore   undo png/jpg from the .sshotfmt-backup copy
# Run on the Frame:  sudo bash frame-screenshot-format.sh png
set -euo pipefail

usage() {
  cat <<'EOF'
frame-screenshot-format.sh — set the default output format (png/jpg) of the
`screenshot` helper (/etc/bashrc.d/vrshortcuts.sh) on the Steam Frame.

The helper grabs a frame from the SteamVR loopback (/dev/video99) via ffmpeg;
ffmpeg chooses the encoder from the filename extension, so the default
extension in `screenshot()` decides the saved format.

Usage:
  frame-screenshot-format.sh status    show current default format
  frame-screenshot-format.sh png       save screenshots as .png by default
  frame-screenshot-format.sh jpg       save screenshots as .jpg by default
  frame-screenshot-format.sh restore   undo from the .sshotfmt-backup copy
  frame-screenshot-format.sh -h        this help

Notes:
  - Writes to /etc on the read-only/verity rootfs:
    run 'sudo steamos-readonly disable' once first (re-enable afterwards).
  - An explicit `screenshot /path/name.ext` argument always wins; this only
    changes the no-argument default.
  - OS updates revert the change (re-run after updating).
EOF
}

VRSHORTCUTS=${VRSHORTCUTS:-/etc/bashrc.d/vrshortcuts.sh}   # override for testing
BACKUP="$VRSHORTCUTS.sshotfmt-backup"

writable_note() {
  if [ ! -w "$VRSHORTCUTS" ]; then
    echo "ERROR: $VRSHORTCUTS is not writable (read-only/verity rootfs)." >&2
    echo "Run once first:  sudo steamos-readonly disable" >&2
    exit 1
  fi
}

default_ext() {  # echoes png|jpg|none (extension of the screenshot() default filename)
  grep -oE 'screenshot-\$\(date[^)]*\)\.(png|jpg)' "$VRSHORTCUTS" 2>/dev/null \
    | head -1 | sed -E 's/.*\.//' || true
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  status)
    echo "vrshortcuts: $VRSHORTCUTS"
    case "$(default_ext)" in
      png) echo "default screenshot format: png" ;;
      jpg) echo "default screenshot format: jpg" ;;
      *)   echo "default screenshot format: not found (no screenshot-\\$\(date...\) default line?)" ;;
    esac
    ;;
  png|jpg)
    writable_note
    cur=$(default_ext)
    [ "$cur" = "png" ] || [ "$cur" = "jpg" ] || { echo "ERROR: could not find the screenshot() default in $VRSHORTCUTS" >&2; exit 1; }
    if [ "$cur" = "$1" ]; then echo "default screenshot format already $1"; exit 0; fi
    [ -e "$BACKUP" ] || cp -p "$VRSHORTCUTS" "$BACKUP"
    sed -E -i "s/(screenshot-\\\$\\(date[^)]*\\)\\.)${cur}/\\1${1}/" "$VRSHORTCUTS"
    new=$(default_ext)
    [ "$new" = "$1" ] || { echo "ERROR: edit did not apply (still $new)" >&2; exit 1; }
    echo "default screenshot format: ${cur} -> ${1}  (backup: $BACKUP)"
    echo "New shells only (open a fresh terminal or: source $VRSHORTCUTS)."
    ;;
  restore)
    [ -e "$BACKUP" ] || { echo "no backup at $BACKUP (nothing to restore)" >&2; exit 1; }
    cp -p "$BACKUP" "$VRSHORTCUTS"
    echo "restored $VRSHORTCUTS from $BACKUP"
    ;;
  *)
    echo "usage: $0 status|png|jpg|restore  (-h for details)" >&2; exit 2 ;;
esac
