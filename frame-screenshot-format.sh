#!/bin/bash
# Frame (SteamOS) — screenshot output control, userspace only.
#
# Two separate screenshot surfaces exist on the Frame:
#
# 1. The in-VR screenshot (capture chord / dashboard). The compositor saves a
#    PNG to `<steamvr-runtime>/screenshots` (it builds "../../screenshots"
#    relative to its CWD, which select_steamvr.sh sets to
#    <runtime>/bin/linuxarm64). With the default /opt/steamvr runtime that
#    directory doesn't exist and sits on the READ-ONLY rootfs, so the PNG write
#    fails silently — the only artifact left is the JPG the Steam client encodes
#    from the submitted frame. `png-dir on` fixes this: it creates the
#    directory and bind-mounts a writable folder (default
#    /home/steamos/screenshots/vr) onto it, so compositor PNGs survive and land
#    in the user's home. (Steam's own library copy stays JPG — that encoding
#    lives in the Steam client, not in SteamVR.)
#
# 2. The dev `screenshot` helper in /etc/bashrc.d/vrshortcuts.sh (ffmpeg grab
#    of the /dev/video99 loopback). Its default filename extension decides the
#    format; `png` / `jpg` flip it.
#
# Modes:
#   png-dir on|off|status   compositor PNG rescue (bind mount)
#   png|jpg                 default format of the dev screenshot helper
#   status                  show both
#   restore                 undo png/jpg and png-dir from backups
# Run on the Frame:  sudo bash frame-screenshot-format.sh png-dir on
set -euo pipefail

usage() {
  cat <<'EOF'
frame-screenshot-format.sh — control where VR screenshots land and in what format.

A. In-VR screenshots (compositor): the compositor writes PNGs to
   <runtime>/screenshots. With /opt/steamvr that path is missing + read-only, so
   the PNG silently fails and only the Steam-client JPG survives.
   `png-dir on` bind-mounts a writable folder onto it (one-time
   'sudo steamos-readonly disable' needed to create the mountpoint+unit,
   'steamos-readonly enable' can be re-run afterwards; the mount persists).

     frame-screenshot-format.sh png-dir on      # PNGs land in $SCREENSHOT_DIR
                                                # (default /home/steamos/screenshots/vr)
     frame-screenshot-format.sh png-dir off
     frame-screenshot-format.sh png-dir status

B. Dev shell helper `screenshot` (/etc/bashrc.d/vrshortcuts.sh): ffmpeg grab of
   /dev/video99; format follows the default filename extension.

     frame-screenshot-format.sh png             # helper defaults to .png
     frame-screenshot-format.sh jpg             # helper defaults to .jpg
     frame-screenshot-format.sh status
     frame-screenshot-format.sh restore         # undo helper edit + mount from backups
   -h|--help                                    # this help
EOF
}

VRSHORTCUTS=${VRSHORTCUTS:-/etc/bashrc.d/vrshortcuts.sh}    # override for testing
BACKUP="$VRSHORTCUTS.sshotfmt-backup"
FALLBACK_RTV=${FALLBACK_RTV:-/opt/steamvr}                  # override for testing
UNIT_NAME=opt-steamvr-screenshots.mount
UNIT_PATH=${SCREENSHOT_UNIT_DIR:-/etc/systemd/system}/$UNIT_NAME   # override for testing
PNGDIR_TARGET=${SCREENSHOT_DIR:-/home/steamos/screenshots/vr}

# resolve the active SteamVR runtime (same logic as frame-lowbatt-notif.sh)
RUNTIME="$FALLBACK_RTV"
if [ -n "${STEAMVR:-}" ]; then RUNTIME="$STEAMVR"
elif command -v steamvr >/dev/null 2>&1; then
  p=$(steamvr path 2>/dev/null || true)
  [ -n "$p" ] && [ -d "$p" ] && RUNTIME=$(readlink -f "$p" 2>/dev/null || echo "$p")
fi
SSDIR="$RUNTIME/screenshots"

writable_note() {
  if [ ! -w "$VRSHORTCUTS" ]; then
    echo "ERROR: $VRSHORTCUTS is not writable (read-only/verity rootfs)." >&2
    echo "Run once first:  sudo steamos-readonly disable   (re-enable afterwards)" >&2
    exit 1
  fi
}

default_ext() {
  grep -oE 'screenshot-\$\(date[^)]*\)\.(png|jpg)' "$VRSHORTCUTS" 2>/dev/null \
    | head -1 | sed -E 's/.*\.//' || true
}

mount_active() { mount 2>/dev/null | grep -q " $FALLBACK_RTV/screenshots "; }

png_dir_status() {
  echo "active runtime:      $RUNTIME"
  echo "compositor PNG dir:  $SSDIR"
  if [ -d "$SSDIR" ] && [ -w "$SSDIR" ]; then
    echo "  status:            writable as-is (PNGs land here)"
  elif mount_active; then
    echo "  status:            bind-mounted (writable via mount unit)"
  elif [ "$RUNTIME" != "$FALLBACK_RTV" ]; then
    echo "  status:            NOT writable (home runtimes are normally writable — odd)"
  else
    echo "  status:            NOT writable -> compositor PNG write FAILS silently,"
    echo "                     only the Steam-client JPG survives. Fix: png-dir on"
  fi
  [ -e "$UNIT_PATH" ] && echo "  mount unit:        $UNIT_PATH (installed)" || true
}

png_dir_on() {
  if mount_active; then echo "already mounted"; return 0; fi
  # 1. writable target in the user's home
  mkdir -p "$PNGDIR_TARGET"
  if [ "$(id -u)" = "0" ] && id steamos >/dev/null 2>&1; then
    chown steamos:steamos "$PNGDIR_TARGET" || true
  fi
  # 2. mountpoint on the (possibly read-only) rootfs
  if [ ! -d "$FALLBACK_RTV/screenshots" ]; then
    mkdir -p "$FALLBACK_RTV/screenshots" 2>/dev/null || {
      echo "ERROR: cannot create $FALLBACK_RTV/screenshots (read-only rootfs)." >&2
      echo "Run once first:  sudo steamos-readonly disable   (re-enable afterwards)" >&2
      exit 1
    }
  fi
  # 3. mount unit (system-level; /etc is on the rootfs too)
  if [ ! -e "$UNIT_PATH" ]; then
    mkdir -p "$(dirname "$UNIT_PATH")" 2>/dev/null || true
    cat > "$UNIT_PATH" <<EOF || {
[Unit]
Description=Writable backing dir for SteamVR compositor screenshots
[Mount]
What=$PNGDIR_TARGET
Where=$FALLBACK_RTV/screenshots
Type=none
Options=bind
[Install]
WantedBy=multi-user.target
EOF
      echo "ERROR: cannot write $UNIT_PATH (read-only rootfs)." >&2
      echo "Run once first:  sudo steamos-readonly disable   (re-enable afterwards)" >&2
      exit 1; }
    echo "installed $UNIT_PATH"
  fi
  # 4. activate now + at boot (skip gracefully when not on a systemd host / testing)
  if command -v systemctl >/dev/null 2>&1 && [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]; then
    systemctl daemon-reload
    systemctl enable --now "$UNIT_NAME"
  else
    echo "systemd not active here; apply manually with:  mount --bind $PNGDIR_TARGET $FALLBACK_RTV/screenshots"
  fi
  echo "compositor PNGs will land in $PNGDIR_TARGET (Steam's library copy stays JPG — that encoder lives in the Steam client)."
}

png_dir_off() {
  if command -v systemctl >/dev/null 2>&1 && [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]; then
    systemctl disable --now "$UNIT_NAME" 2>/dev/null || true
  fi
  if mount_active; then umount "$FALLBACK_RTV/screenshots" || true; fi
  if [ -e "$UNIT_PATH" ]; then cp -p "$UNIT_PATH" "$UNIT_PATH.sshotfmt-backup" 2>/dev/null || true; rm -f "$UNIT_PATH"; echo "removed $UNIT_PATH (backup kept)"; fi
  echo "png-dir disabled. (mkdir the dir yourself if you want raw writes on a writable rootfs)"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  status)
    echo "== compositor (in-VR screenshots)"; png_dir_status
    echo; echo "== dev helper (vrshortcuts.sh)"
    echo "vrshortcuts: $VRSHORTCUTS"
    case "$(default_ext)" in
      png) echo "default screenshot format: png" ;;
      jpg) echo "default screenshot format: jpg" ;;
      *)   echo "default screenshot format: not found (no screenshot-\\$\(date...\) default line?)" ;;
    esac
    ;;
  png-dir)
    case "${2:-}" in
      on)  png_dir_on ;;
      off) png_dir_off ;;
      status) png_dir_status ;;
      *) echo "usage: $0 png-dir on|off|status" >&2; exit 2 ;;
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
    echo "usage: $0 status|png|jpg|restore|png-dir on|off|status  (-h for details)" >&2; exit 2 ;;
esac
