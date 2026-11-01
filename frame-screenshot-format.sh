#!/bin/bash
# Frame (SteamOS) — screenshot output control WITHOUT touching the read-only fs.
#
# Two separate screenshot surfaces exist on the Frame:
#
# 1. The in-VR screenshot (capture chord / dashboard). The compositor saves a
#    PNG to `../../screenshots` RELATIVE TO ITS CWD, and select_steamvr.sh sets
#    that CWD to <runtime>/bin/linuxarm64 — i.e. <runtime>/screenshots. With the
#    default /opt/steamvr runtime that directory doesn't exist and the rootfs is
#    read-only, so the PNG write fails silently and the only artifact left is
#    the JPG the Steam client encodes from the submitted frame.
#
#    Fix (no root, no ro-mounts): `shadow on` builds a *shadow runtime* under
#    $HOME — a real bin/linuxarm64 directory (files symlinked to /opt/steamvr,
#    vrmonitor copied so it stays patchable), symlinks for the rest, a real
#    writable screenshots/ dir — and points the OS at it via
#    `steamvr setpath` (the supported mechanism; steamvr.service re-applies it
#    every boot via `steamvr apply-setpath`). The compositor's PNGs then land
#    in <shadow>/screenshots. Steam's own library copy stays JPG — that
#    encoder lives in the Steam client, not SteamVR.
#
# 2. The dev `screenshot` helper in /etc/bashrc.d/vrshortcuts.sh (ffmpeg grab
#    of the /dev/video99 loopback). Its default filename extension decides the
#    format; `png` / `jpg` flip it. NOTE: /etc is on the read-only rootfs, so
#    this one mode is the only thing here that needs the readonly dance (and
#    current images already default to .png, so you likely never need it).
#
# Modes:
#   shadow on|off|status    writable shadow runtime (fixes in-VR PNG screenshots,
#                           also gives frame-lowbatt-notif.sh a patchable vrmonitor)
#   png|jpg                 default format of the dev screenshot helper (needs ro-unlock)
#   status                  show both
#   restore                 undo helper edit (shadow stays; see shadow off)
# Run on the Frame:  bash frame-screenshot-format.sh shadow on
set -euo pipefail

usage() {
  cat <<'EOF'
frame-screenshot-format.sh — control where VR screenshots land and in what format.

A. In-VR screenshots (compositor): writes PNGs to <runtime>/screenshots, which
   is missing + read-only under /opt/steamvr -> PNG silently fails, only the
   Steam-client JPG survives. Fix WITHOUT touching the read-only fs:

     frame-screenshot-format.sh shadow on      # build ~/.steamvr-shadow (symlink
                                               # farm + real bin dir + writable
                                               # screenshots/) and `steamvr setpath` it
     frame-screenshot-format.sh shadow status
     frame-screenshot-format.sh shadow off     # setpath back to /opt/steamvr
     frame-screenshot-format.sh shadow off --purge   # also delete the shadow dir

   After `shadow on`: restart SteamVR. In-VR PNGs land in
   ~/.steamvr-shadow/screenshots/. Re-run `shadow on` after OS updates to
   re-sync symlinks/refresh the vrmonitor copy.

B. Dev shell helper `screenshot` (/etc/bashrc.d/vrshortcuts.sh): ffmpeg grab of
   /dev/video99; format follows the default filename extension. /etc is on the
   read-only rootfs — this is the ONLY mode needing `steamos-readonly disable`
   (current images already default to .png).

     frame-screenshot-format.sh png             # helper defaults to .png
     frame-screenshot-format.sh jpg             # helper defaults to .jpg
     frame-screenshot-format.sh status
     frame-screenshot-format.sh restore         # undo helper edit
   -h|--help                                    # this help
EOF
}

VRSHORTCUTS=${VRSHORTCUTS:-/etc/bashrc.d/vrshortcuts.sh}    # override for testing
BACKUP="$VRSHORTCUTS.sshotfmt-backup"
SRC=${SHADOW_SRC:-/opt/steamvr}                             # runtime to shadow (override for testing)
SHADOW=${SHADOW_DIR:-$HOME/.steamvr-shadow}                 # shadow runtime (override for testing)
STEAMVR_CMD=${STEAMVR_CMD:-steamvr}

writable_note() {
  if [ ! -w "$VRSHORTCUTS" ]; then
    echo "ERROR: $VRSHORTCUTS is not writable (read-only/verity rootfs)." >&2
    echo "This mode needs:  sudo steamos-readonly disable   (re-enable afterwards)" >&2
    exit 1
  fi
}

svr() {  # call the steamvr CLI if present, quietly
  if command -v "$STEAMVR_CMD" >/dev/null 2>&1; then "$STEAMVR_CMD" "$@" 2>/dev/null || true; fi
}
current_path() { svr path | tail -1; }

default_ext() {
  grep -oE 'screenshot-\$\(date[^)]*\)\.(png|jpg)' "$VRSHORTCUTS" 2>/dev/null \
    | head -1 | sed -E 's/.*\.//' || true
}

is_shadow() { [ -e "$SHADOW/.frame-shadow" ]; }

# --- shadow runtime ---------------------------------------------------------

shadow_on() {
  [ -d "$SRC/bin/linuxarm64" ] || { echo "ERROR: $SRC/bin/linuxarm64 not found" >&2; exit 1; }
  mkdir -p "$SHADOW/bin/linuxarm64" "$SHADOW/screenshots"

  # real (writable) bin/linuxarm64 dir; every file/dir inside = symlink
  local entry
  find "$SRC/bin/linuxarm64" -mindepth 1 -maxdepth 1 | while read -r entry; do
    ln -sfn "$entry" "$SHADOW/bin/linuxarm64/$(basename "$entry")"
  done
  # vrmonitor as a real file so it can be patched (frame-lowbatt-notif.sh pct)
  rm -f "$SHADOW/bin/linuxarm64/vrmonitor"
  cp -p "$SRC/bin/linuxarm64/vrmonitor" "$SHADOW/bin/linuxarm64/vrmonitor"
  chmod u+w "$SHADOW/bin/linuxarm64/vrmonitor"

  # everything else at runtime root = symlink (content/drivers/resources/…)
  find "$SRC" -mindepth 1 -maxdepth 1 ! -name bin | while read -r entry; do
    ln -sfn "$entry" "$SHADOW/$(basename "$entry")"
  done
  touch "$SHADOW/.frame-shadow"

  # point the OS at the shadow (supported mechanism; re-applied every boot)
  if command -v "$STEAMVR_CMD" >/dev/null 2>&1; then
    "$STEAMVR_CMD" setpath "$SHADOW" 2>/dev/null || true
    echo "steamvr path -> $(current_path)"
  else
    echo "NOTE: '$STEAMVR_CMD' CLI not found; run manually:  steamvr setpath $SHADOW"
  fi

  echo "shadow runtime ready: $SHADOW"
  echo "  - in-VR PNG screenshots will land in $SHADOW/screenshots/"
  echo "  - vrmonitor here is a writable copy (frame-lowbatt-notif.sh pct can patch it)"
  echo "  - restart SteamVR (or reboot) to activate"
  echo "  - re-run 'shadow on' after OS updates to re-sync symlinks"
}

shadow_status() {
  echo "OS runtime (fallback): $SRC"
  echo "shadow runtime:        $SHADOW"
  if is_shadow; then
    echo "  built:               yes ($(find "$SHADOW/bin/linuxarm64" -maxdepth 1 | wc -l) entries in bin/linuxarm64)"
    if cmp -s "$SRC/bin/linuxarm64/vrmonitor" "$SHADOW/bin/linuxarm64/vrmonitor"; then
      echo "  vrmonitor copy:      identical to OS copy"
    else
      echo "  vrmonitor copy:      DIFFERS from OS copy (patched, or OS updated -> re-run 'shadow on')"
    fi
    local n; n=$(find "$SHADOW/screenshots" -name '*.png' 2>/dev/null | wc -l)
    echo "  screenshots so far:  $n png in $SHADOW/screenshots"
  else
    echo "  built:               no"
  fi
  local p; p=$(current_path)
  [ -n "$p" ] && echo "active ('steamvr path'): $p"
  if is_shadow && [ "$p" != "$SHADOW" ]; then
    echo "  NOTE: shadow is not the active runtime yet (restart SteamVR or re-run setpath)"
  fi
}

shadow_off() {
  if command -v "$STEAMVR_CMD" >/dev/null 2>&1; then
    "$STEAMVR_CMD" setpath "$SRC" 2>/dev/null || true
    echo "steamvr path -> $(current_path)"
  fi
  if [ "${2:-}" = "--purge" ]; then
    [ -d "$SHADOW" ] && { cp -a "$SHADOW/screenshots" "$HOME/steamvr-shadow-screenshots" 2>/dev/null || true; rm -rf "$SHADOW"; echo "shadow dir removed (screenshots kept in ~/steamvr-shadow-screenshots)"; }
  else
    echo "shadow kept at $SHADOW (screenshots inside). Remove later with: $0 shadow off --purge"
  fi
}

# --- dev helper -------------------------------------------------------------

helper_mode() {  # $1 = png|jpg
  writable_note
  local cur new
  cur=$(default_ext)
  [ "$cur" = "png" ] || [ "$cur" = "jpg" ] || { echo "ERROR: could not find the screenshot() default in $VRSHORTCUTS" >&2; exit 1; }
  if [ "$cur" = "$1" ]; then echo "default screenshot format already $1"; exit 0; fi
  [ -e "$BACKUP" ] || cp -p "$VRSHORTCUTS" "$BACKUP"
  sed -E -i "s/(screenshot-\\\$\\(date[^)]*\\)\\.)${cur}/\\1${1}/" "$VRSHORTCUTS"
  new=$(default_ext)
  [ "$new" = "$1" ] || { echo "ERROR: edit did not apply (still $new)" >&2; exit 1; }
  echo "default screenshot format: ${cur} -> ${1}  (backup: $BACKUP)"
  echo "New shells only (open a fresh terminal or: source $VRSHORTCUTS)."
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  status)
    echo "== compositor (in-VR screenshots)"; shadow_status
    echo; echo "== dev helper (vrshortcuts.sh)"
    echo "vrshortcuts: $VRSHORTCUTS"
    case "$(default_ext)" in
      png) echo "default screenshot format: png" ;;
      jpg) echo "default screenshot format: jpg" ;;
      *)   echo "default screenshot format: not found" ;;
    esac
    ;;
  shadow)
    case "${2:-}" in
      on)  shadow_on ;;
      off) shadow_off "${@:2:2}" ;;
      status) shadow_status ;;
      *) echo "usage: $0 shadow on|off [--purge]|status" >&2; exit 2 ;;
    esac
    ;;
  png|jpg) helper_mode "$1" ;;
  restore)
    [ -e "$BACKUP" ] || { echo "no backup at $BACKUP (nothing to restore)" >&2; exit 1; }
    cp -p "$BACKUP" "$VRSHORTCUTS"
    echo "restored $VRSHORTCUTS from $BACKUP"
    ;;
  *)
    echo "usage: $0 status|shadow on|off [--purge]|status|png|jpg|restore  (-h for details)" >&2; exit 2 ;;
esac
