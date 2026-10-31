#!/bin/bash
# Frame (SteamOS) — control SteamVR's "Controller battery low" popover, userspace only.
#
# The popover threshold lives in vrmonitor: it reads Prop_DeviceBatteryPercentage_Float
# (0..1) and compares battery < THRESHOLD (stock THRESHOLD = 0.15, i.e. 15%).
# Machine code (aarch64, vrmonitor+0x1562f8 in the 2026-09 image):
#   fcvt d0,s0 | orr x0,#0x3333333333333333 | movk x0,#0x3fc3,lsl#48 | fmov d1,x0 |
#   ldr x19,[sp,#0x10] | fcmpe d0,d1 | ldp | cset w0,mi        (w0 = battery < threshold)
# 'pct' rewrites the orr+movk pair to encode any supported threshold (see below).
#
# Modes:
#   off        blank Popover_LowBattery_Controller_* tokens in all vrmonitor_errors_*.txt
#   binary     patch vrmonitor: _LowBattery -> _LowBatterx (state never matches)
#   pct <N>    patch the low-battery threshold in vrmonitor to N percent (0..100,
#              half-percent steps; 0 = never notify, 100 = always notify). Reversible.
#   dnd        set notifications.DoNotDisturb=true in steamvr.vrsettings
#   status     show what is currently applied
#   restore    undo off/binary/pct from the *.lowbatt-backup copies
# Run on the Frame:  sudo bash frame-lowbatt-notif.sh off
set -euo pipefail

usage() {
  cat <<'EOF'
frame-lowbatt-notif.sh — control SteamVR's "Controller battery low" popover on the
Steam Frame, userspace only (no kernel/firmware changes).

The popover is rendered by vrmonitor (status popover, tokens Popover_LowBattery_*).
It fires when a device's battery drops below a hardcoded 15% threshold.
Full mechanism: /workspace/analysis/controller-lowbatt-notif.md

Usage:
  frame-lowbatt-notif.sh off        blank the Popover_LowBattery_Controller_* tokens
                                    in every vrmonitor_errors_*.txt (UTF-16-safe,
                                    backups kept as *.lowbatt-backup)
  frame-lowbatt-notif.sh binary     hard kill: 1-byte patch of vrmonitor's _LowBattery
                                    state string -> state never matches, no popover
  frame-lowbatt-notif.sh pct <N>    change the threshold percentage instead of killing
                                    the popover. N in percent, 0..100 in half-steps
                                    (0 = never notify, 15 = stock, 100 = always).
                                    Supported N: 0 2.5 5 7.5 10 12.5 15 17.5 20 22.5 25
                                    27.5 30 32.5 35 37.5 40 42.5 45 47.5 50 52.5 55
                                    57.5 60 62.5 65 70 72.5 75 80 85 87.5 90 95 100
  frame-lowbatt-notif.sh dnd        set notifications.DoNotDisturb=true in
                                    steamvr.vrsettings (other system-layer toasts)
  frame-lowbatt-notif.sh status     report current off/binary/pct state
  frame-lowbatt-notif.sh restore    undo off/binary/pct from the .lowbatt-backup copies
  frame-lowbatt-notif.sh -h|--help  this help

Notes:
  - 'off'/'binary'/'pct' write to /opt/steamvr on the read-only rootfs:
    run 'sudo steamos-readonly disable' once first (re-enable afterwards).
  - Restart SteamVR (or reboot) after off/binary/pct; OS updates revert them.
  - pct affects HMD + controller + tracker popovers alike (same check); it does NOT
    change the battery icon colouring thresholds elsewhere.
  - off/binary/pct share the vrmonitor backup; restore undoes all of them at once.
EOF
}

STEAMVR=${STEAMVR:-/opt/steamvr}   # override for testing against extracted firmware
TRDIR=$STEAMVR/content/vrmonitor/translations
VRMON=$STEAMVR/bin/linuxarm64/vrmonitor
CFGDIR=${CFGDIR:-/home/steamos/.local/share/Steam/config}
TOKENS='Popover_LowBattery_Controller_(Header|Description|Action|ActionURL)'

# pct -> orr-word top16-of-movk  (threshold double = top16<<48 | orr-pattern-low48)
# stock: 15 b200e7e0 3fc3  (= double 0.15). Generated + verified against aarch64
# ORR-bitmask encodings; see analysis/controller-lowbatt-notif.md.
PCT_TABLE='
0 aa1f03e0 0000
2.5 b201e7e0 3f99
5 b201e7e0 3fa9
7.5 b200e7e0 3fb3
10 b201e7e0 3fb9
12.5 aa1f03e0 3fc0
15 b200e7e0 3fc3
17.5 b203e7e0 3fc6
20 b201e7e0 3fc9
22.5 b202e7e0 3fcc
25 aa1f03e0 3fd0
27.5 b201e7e0 3fd1
30 b200e7e0 3fd3
32.5 b202e7e0 3fd4
35 b203e7e0 3fd6
37.5 aa1f03e0 3fd8
40 b201e7e0 3fd9
42.5 b200e7e0 3fdb
45 b202e7e0 3fdc
47.5 b203e7e0 3fde
50 aa1f03e0 3fe0
55 b201e7e0 3fe1
60 b200e7e0 3fe3
62.5 aa1f03e0 3fe4
65 b202e7e0 3fe4
70 b203e7e0 3fe6
75 aa1f03e0 3fe8
80 b201e7e0 3fe9
85 b200e7e0 3feb
87.5 aa1f03e0 3fec
90 b202e7e0 3fec
95 b203e7e0 3fee
100 aa1f03e0 3ff0
'

writable_root_note() {
  if [ ! -w "$STEAMVR" ]; then
    echo "ERROR: $STEAMVR is not writable (read-only/verity rootfs)." >&2
    echo "Run once first:  sudo steamos-readonly disable" >&2
    exit 1
  fi
}

# --- vrmonitor threshold site helpers -------------------------------------

word_at() {  # $1=file-offset (bytes) -> 8 lowercase hex chars
  od -An -tx4 -j "$1" -N 4 "$VRMON" | tr -d ' \n'
}

put_word() {  # $1=file-offset, $2=hex word (little-endian write)
  local off=$1 w=$2 out="" i b
  for i in 0 1 2 3; do
    b=$(( (0x$w >> (8*i)) & 0xff ))
    out+="\\x$(printf '%02x' "$b")"
  done
  printf "$out" | dd of="$VRMON" bs=1 seek="$off" conv=notrunc status=none
}

# Locate the threshold site; echoes the file offset of the movk instruction.
# Site layout (word offsets relative to movk at 0):
#  -2 fcvt d0,s0 (1e22c000) | -1 orr x0,imm | 0 movk x0,imm16,lsl#48 |
#  +1 fmov d1,x0 (9e670001) | +2 ldr x19,[sp,#0x10] (f9400bf3) |
#  +3 fcmpe d0,d1 (1e612010) | +5 cset w0,mi (1a9f57e0)
find_site() {
  local cand c m
  # fcmpe d0,d1 has no NUL bytes -> greppable; anchor the site on it.
  while read -r cand; do
    [ -n "$cand" ] || continue
    m=$(( cand - 12 ))
    [ "$m" -ge 8 ] || continue
    [ "$(word_at $((m - 8)))" = "1e22c000" ] || continue   # fcvt d0,s0
    [ "$(word_at $((m + 4)))" = "9e670001" ] || continue   # fmov d1,x0
    [ "$(word_at $((m + 8)))" = "f9400bf3" ] || continue   # ldr x19,[sp,#0x10]
    [ "$(word_at $((m + 12)))" = "1e612010" ] || continue  # fcmpe d0,d1
    [ "$(word_at $((m + 20)))" = "1a9f57e0" ] || continue  # cset w0,mi
    echo "$m"
    return 0
  done < <(grep -abo -e $'\x10\x20\x61\x1e' "$VRMON" | cut -d: -f1 || true)
  return 1
}

current_pct() {  # echoes "<pct>" if the (orr,movk) pair matches the table, else "custom"/"stock-unknown"
  local site orr movk top
  site=$(find_site) || { echo "nosite"; return; }
  orr=$(word_at $((site - 4)))
  movk=$(word_at "$site")
  top=$(printf '%04x' $(( (0x$movk >> 5) & 0xffff )))
  local pct_line
  while read -r pct_line; do
    [ -n "$pct_line" ] || continue
    set -- $pct_line
    if [ "$2" = "$orr" ] && [ "$3" = "$top" ]; then echo "$1"; return; fi
  done <<< "$PCT_TABLE"
  if [ "$orr" = "b200e7e0" ]; then echo "custom"; else echo "custom"; fi
}

# --- modes -----------------------------------------------------------------

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  status)
    echo "vrmonitor:        $VRMON"
    if grep -aq '_LowBattery' "$VRMON" 2>/dev/null; then
      echo "binary patch:     not applied (_LowBattery string present)"
    else
      echo "binary patch:     APPLIED (_LowBattery string gone)"
    fi
    case "$(current_pct)" in
      nosite)  echo "pct patch:        threshold site not found (unexpected build?)" ;;
      custom)  echo "pct patch:        threshold = custom/unknown value" ;;
      *)       echo "pct patch:        threshold = $(current_pct)% (stock is 15%)" ;;
    esac
    if ls "$TRDIR"/vrmonitor_errors_*.txt >/dev/null 2>&1 && \
       [ -e "$(ls "$TRDIR"/vrmonitor_errors_*.txt | head -1).lowbatt-backup" ]; then
      echo "translation blank: applied (off mode backups present)"
    else
      echo "translation blank: not applied"
    fi
    ;;
  off)
    writable_root_note
    command -v iconv >/dev/null || { echo "iconv missing" >&2; exit 1; }
    for f in "$TRDIR"/vrmonitor_errors_*.txt; do
      [ -e "$f" ] || continue
      b="$f.lowbatt-backup"; [ -e "$b" ] || cp -p "$f" "$b"
      iconv -f UTF-16LE -t UTF-8 "$b" \
        | sed -E "s/^\"(${TOKENS})\".*/\"\\1\" \"\"/" \
        | iconv -f UTF-8 -t UTF-16 > "$f.tmp" && mv "$f.tmp" "$f"
      echo "blanked tokens in $f"
    done
    echo "Done. Restart SteamVR (or reboot) to take effect."
    ;;
  binary)
    writable_root_note
    b="$VRMON.lowbatt-backup"; [ -e "$b" ] || cp -p "$VRMON" "$b"
    if grep -aq '_LowBattery' "$VRMON"; then
      printf 'x' | dd of="$VRMON" bs=1 seek=$(grep -abo '_LowBatter' "$VRMON" | head -1 | cut -d: -f1) conv=notrunc status=none
      echo "patched $VRMON (backup: $b). Restart SteamVR."
    else
      echo "already patched (no _LowBattery string found)"
    fi
    ;;
  pct)
    writable_root_note
    want=${2:-}
    [ -n "$want" ] || { echo "usage: $0 pct <0|2.5|5|...|100>" >&2; exit 2; }
    want=${want%\%}; want=${want%.0}
    entry=$(awk -v p="$want" '$1==p {print $2, $3}' <<< "$PCT_TABLE")
    if [ -z "$entry" ]; then
      echo "unsupported threshold '$2'." >&2
      echo "supported:$(awk '{printf " %s", $1}' <<< "$PCT_TABLE")" >&2
      exit 2
    fi
    site=$(find_site) || { echo "ERROR: threshold site not found in $VRMON (unexpected build)" >&2; exit 1; }
    set -- $entry
    b="$VRMON.lowbatt-backup"; [ -e "$b" ] || cp -p "$VRMON" "$b"
    cur=$(current_pct)
    if [ "$cur" = "$want" ]; then echo "threshold already ${want}%"; exit 0; fi
    put_word $((site - 4)) "$1"   # orr x0, #pattern
    put_word "$site" "$(printf 'f2e00000%x' $(( 0x$2 << 5 )))"  # movk x0,#top,lsl#48
    echo "threshold: ${cur:-?}% -> ${want}%  (patched $VRMON, backup: $b). Restart SteamVR."
    if [ "$want" = "0" ]; then
      echo "  (0% = battery < 0 never true -> notification effectively off)"
    elif [ "$want" = "100" ]; then
      echo "  (100% = threshold 1.0 -> popover always shows while battery < full; good for testing)"
    fi
    ;;
  dnd)
    command -v jq >/dev/null || { echo "jq missing (present on-device at /usr/bin/jq)" >&2; exit 1; }
    mkdir -p "$CFGDIR"; f="$CFGDIR/steamvr.vrsettings"
    [ -e "$f" ] || echo '{}' > "$f"
    tmp=$(mktemp); jq '.notifications = ((.notifications // {}) + {DoNotDisturb: true})' "$f" > "$tmp" \
      && { cp -p "$f" "$f.lowbatt-backup" 2>/dev/null || true; mv "$tmp" "$f"; }
    echo "DoNotDisturb=true in $f"
    ;;
  restore)
    for b in "$TRDIR"/vrmonitor_errors_*.txt.lowbatt-backup "$VRMON.lowbatt-backup"; do
      [ -e "$b" ] || continue
      cp -p "$b" "${b%.lowbatt-backup}"; echo "restored ${b%.lowbatt-backup}"
    done
    ;;
  *)
    echo "usage: $0 off|binary|pct <N>|dnd|status|restore  (-h for details)" >&2; exit 2 ;;
esac
