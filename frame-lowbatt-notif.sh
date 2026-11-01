#!/bin/bash
# Frame (SteamOS) — control SteamVR's "Controller battery low" popover, userspace only.
#
# Two things this script is careful about:
#  1. The ACTIVE SteamVR runtime is whatever `steamvr path` reports (the OS
#     supports a Steam-managed runtime under /home; /opt/steamvr is only the
#     immutable fallback). Patches go to the ACTIVE runtime by default; use
#     -f/--fallback to target /opt/steamvr explicitly.
#  2. The threshold site is located by machine-code signature, not offset, and
#     the CURRENT threshold is reported before patching (stock OS image = 15%).
#
# The popover threshold lives in vrmonitor: it reads Prop_DeviceBatteryPercentage_Float
# (0..1) and compares battery < THRESHOLD. Machine code (aarch64):
#   fcvt d0,s0 | orr x0,#<pattern> | movk x0,#<exp>,lsl#48 | fmov d1,x0 |
#   ldr x19,[sp,#0x10] | fcmpe d0,d1 | ldp | cset w0,mi        (w0 = battery < threshold)
# 'pct' rewrites the orr+movk pair to encode any supported threshold.
#
# Modes:
#   off        blank Popover_LowBattery_Controller_* tokens in all vrmonitor_errors_*.txt
#   binary     patch vrmonitor: _LowBattery -> _LowBatterx (state never matches)
#   pct <N>    patch the low-battery threshold in vrmonitor to N percent (0..100,
#              half-steps; 0 = never notify, 100 = always). Reversible.
#   dnd        set notifications.DoNotDisturb=true in steamvr.vrsettings
#   status     show active runtime + what is currently applied there and in /opt/steamvr
#   restore    undo off/binary/pct from the *.lowbatt-backup copies
# Run on the Frame:  sudo bash frame-lowbatt-notif.sh status
set -euo pipefail

usage() {
  cat <<'EOF'
frame-lowbatt-notif.sh — control SteamVR's "Controller battery low" popover on the
Steam Frame, userspace only (no kernel/firmware changes).

IMPORTANT: patches apply to the ACTIVE SteamVR runtime (`steamvr path`), which may
be a Steam-managed runtime under /home rather than the /opt/steamvr OS fallback.
`status` shows both. SteamVR runtime updates revert patches (re-run after updates).

Usage:
  frame-lowbatt-notif.sh status       active runtime, current threshold, applied patches
  frame-lowbatt-notif.sh pct <N>      set the low-battery threshold to N percent
                                      (half-steps 0..100; 0 = never, 100 = always)
  frame-lowbatt-notif.sh off          blank Popover_LowBattery_Controller_* tokens in
                                      every vrmonitor_errors_*.txt (UTF-16-safe)
  frame-lowbatt-notif.sh binary       1-byte vrmonitor patch: _LowBattery -> _LowBatterx
  frame-lowbatt-notif.sh dnd          notifications.DoNotDisturb=true in steamvr.vrsettings
  frame-lowbatt-notif.sh restore      undo off/binary/pct from .lowbatt-backup copies
  frame-lowbatt-notif.sh -f <mode> …  force the /opt/steamvr fallback runtime instead
  frame-lowbatt-notif.sh -h|--help    this help

Supported pct values (aarch64-encodable):
  0 2.5 5 7.5 10 12.5 15 17.5 20 22.5 25 27.5 30 32.5 35 37.5 40 42.5 45 47.5 50
  55 60 62.5 65 70 75 80 85 87.5 90 95 100

Notes:
  - /opt/steamvr sits on the read-only/verity rootfs: run
    'sudo steamos-readonly disable' once first (re-enable afterwards).
  - A Steam-managed runtime under /home is writable; no readonly dance needed.
  - Restart SteamVR (or reboot) after off/binary/pct.
  - off/binary/pct share the vrmonitor backup; restore undoes all of them at once.
EOF
}

FALLBACK_RTV=/opt/steamvr
CFGDIR=${CFGDIR:-/home/steamos/.local/share/Steam/config}
TOKENS='Popover_LowBattery_Controller_(Header|Description|Action|ActionURL)'

# pct -> orr-word top16-of-movk  (threshold double = top16<<48 | orr-pattern-low48)
# stock OS image: 15 b200e7e0 3fc3 (= double 0.15). Generated + verified against
# aarch64 ORR-bitmask encodings; see analysis/controller-lowbatt-notif.md.
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

# --- runtime selection ------------------------------------------------------

RUNTIME="$FALLBACK_RTV"
RUNTIME_TAG="fallback (/opt/steamvr)"
if [ "${1:-}" = "-f" ] || [ "${1:-}" = "--fallback" ]; then shift; fi
# (env STEAMVR overrides everything — used for testing against extracted firmware)
if [ -n "${STEAMVR:-}" ]; then
  RUNTIME="$STEAMVR"; RUNTIME_TAG="env override ($STEAMVR)"
elif command -v steamvr >/dev/null 2>&1; then
  p=$(steamvr path 2>/dev/null || true)
  if [ -n "$p" ] && [ -f "$p/bin/linuxarm64/vrmonitor" ]; then
    RUNTIME=$(readlink -f "$p" 2>/dev/null || echo "$p")
    RUNTIME_TAG="active per 'steamvr path'"
  fi
fi
TRDIR=$RUNTIME/content/vrmonitor/translations
VRMON=$RUNTIME/bin/linuxarm64/vrmonitor

writable_root_note() {
  if [ ! -w "$RUNTIME" ]; then
    echo "ERROR: $RUNTIME is not writable (read-only/verity rootfs?)." >&2
    echo "No-root alternative: 'frame-screenshot-format.sh shadow on' builds a writable" >&2
    echo "shadow runtime under ~ (real vrmonitor copy + setpath), then re-run this." >&2
    echo "Or patch /opt/steamvr with:  sudo steamos-readonly disable   (re-enable afterwards)" >&2
    exit 1
  fi
}

# --- vrmonitor threshold site helpers ---------------------------------------

word_at() { od -An -tx4 -j "$1" -N 4 "$VRMON" | tr -d ' \n'; }

put_word() {  # $1=file-offset, $2=hex word (little-endian write)
  local off=$1 w=$2 out="" i b
  for i in 0 1 2 3; do
    b=$(( (0x$w >> (8*i)) & 0xff ))
    out+="\\x$(printf '%02x' "$b")"
  done
  printf "$out" | dd of="$VRMON" bs=1 seek="$off" conv=notrunc status=none
}

# Locate the threshold site; echoes file offset of the movk instruction.
# Layout (words relative to movk at 0):
#  -2 fcvt d0,s0 (1e22c000) | -1 orr x0,imm | 0 movk x0,imm16,lsl#48 |
#  +1 fmov d1,x0 (9e670001) | +2 ldr x19,[sp,#0x10] (f9400bf3) |
#  +3 fcmpe d0,d1 (1e612010) | +5 cset w0,mi (1a9f57e0)
find_site() {
  local cand c m
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

current_pct() {  # echoes "<pct>" when the (orr,movk) pair matches the table, else "custom"
  local site orr movk top pct_line
  site=$(find_site) || { echo "nosite"; return; }
  orr=$(word_at $((site - 4)))
  movk=$(word_at "$site")
  top=$(printf '%04x' $(( (0x$movk >> 5) & 0xffff )))
  while read -r pct_line; do
    [ -n "$pct_line" ] || continue
    set -- $pct_line
    if [ "$2" = "$orr" ] && [ "$3" = "$top" ]; then echo "$1"; return; fi
  done <<< "$PCT_TABLE"
  echo "custom"
}

pct_status_line() {  # for status: description of the threshold state of $VRMON
  case "$(current_pct)" in
    nosite) echo "threshold site NOT FOUND in this vrmonitor build" ;;
    custom) echo "threshold = custom/unknown value (patched by something else?)" ;;
    *)      echo "threshold = $(current_pct)%" ;;
  esac
}

# --- modes ------------------------------------------------------------------

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  status)
    echo "patching runtime: $RUNTIME  [$RUNTIME_TAG]"
    echo "vrmonitor:        $VRMON"
    echo "  $(pct_status_line)"
    if grep -aq '_LowBattery' "$VRMON" 2>/dev/null; then
      echo "  binary patch:     not applied (_LowBattery string present)"
    else
      echo "  binary patch:     APPLIED (_LowBattery string gone)"
    fi
    if ls "$TRDIR"/vrmonitor_errors_*.txt >/dev/null 2>&1 && \
       [ -e "$(ls "$TRDIR"/vrmonitor_errors_*.txt | head -1).lowbatt-backup" ]; then
      echo "  translation blank: applied (off mode backups present)"
    else
      echo "  translation blank: not applied"
    fi
    echo "fallback runtime: $FALLBACK_RTV"
    if [ -x "$FALLBACK_RTV/bin/linuxarm64/vrmonitor" ]; then
      VRMON=$FALLBACK_RTV/bin/linuxarm64/vrmonitor
      echo "  $(pct_status_line)"
      echo "  (use '$0 -f pct <N>' to patch the fallback explicitly)"
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
    [ -x "$VRMON" ] || { echo "ERROR: $VRMON not found" >&2; exit 1; }
    cur=$(current_pct)
    if [ "$cur" = "$want" ]; then echo "threshold already ${want}% ($VRMON)"; exit 0; fi
    site=$(find_site) || { echo "ERROR: threshold site not found in $VRMON (unexpected build)" >&2; exit 1; }
    set -- $entry
    b="$VRMON.lowbatt-backup"; [ -e "$b" ] || cp -p "$VRMON" "$b"
    put_word $((site - 4)) "$1"   # orr x0, #pattern
    put_word "$site" "$(printf 'f2e00000%x' $(( 0x$2 << 5 )))"  # movk x0,#top,lsl#48
    echo "runtime: $RUNTIME [$RUNTIME_TAG]"
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
    echo "usage: $0 [-f] status|off|binary|pct <N>|dnd|restore  (-h for details)" >&2; exit 2 ;;
esac
