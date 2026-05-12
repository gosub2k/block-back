#!/usr/bin/env bash
set -uo pipefail

MNT=/mnt/_src_$$
USE_UNIQUE=0
DDRESCUE_ONLY=0

usage() {
    echo "Usage: $0 [-u] [-d] <destination_dir_base>" >&2; exit 1
}

while getopts ':ud' opt; do
  case $opt in
    u) USE_UNIQUE=1 ;;
    d) DDRESCUE_ONLY=1 ;;
    *) usage ;;
  esac
done
shift $(( OPTIND - 1 ))

if [[ $# != 1 ]]; then usage; fi
DISKS_BASE=$1

run() {
  echo "+ $*"
  "$@"
}

# Find USB- and MMC-attached block disks
mapfile -t USB_DEVS < <(lsblk -ndo NAME,TRAN,TYPE 2>/dev/null \
  | awk '($2=="usb" || $2=="mmc") && $3=="disk" {print "/dev/" $1}')

if [ ${#USB_DEVS[@]} -eq 0 ]; then
  echo "No USB/MMC block devices found." >&2
  echo "Available block devices:" >&2
  lsblk -o NAME,TRAN,TYPE,SIZE,MODEL >&2
  exit 1
fi

echo "USB/MMC block devices found:"
for i in "${!USB_DEVS[@]}"; do
  dev="${USB_DEVS[$i]}"
  tran=$(lsblk -ndo TRAN "$dev" 2>/dev/null)
  size=$(lsblk -ndo SIZE "$dev" 2>/dev/null || echo "?")
  model=$(lsblk -ndo MODEL "$dev" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  vendor=$(lsblk -ndo VENDOR "$dev" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  echo "  [$i] $dev  ${size}  tran=${tran}  vendor=${vendor}  model=${model}"
done

read -rp "Select device [0-$((${#USB_DEVS[@]}-1))]: " sel
if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -ge "${#USB_DEVS[@]}" ]; then
  echo "Invalid selection." >&2
  exit 1
fi

SRC="${USB_DEVS[$sel]}"

# Build a clean directory name: prefer vendor+model, fall back to kernel device name
# (MMC cards often expose no MODEL/VENDOR via lsblk)
VENDOR=$(lsblk -ndo VENDOR "$SRC" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
MODEL=$(lsblk -ndo MODEL  "$SRC" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
if [ -z "$VENDOR" ] && [ -z "$MODEL" ]; then
  RAW_LABEL=$(basename "$SRC")
else
  RAW_LABEL="${VENDOR:+${VENDOR}_}${MODEL:-UNKNOWN}"
fi
DEVICE_DIR=$(echo "$RAW_LABEL" | tr -s ' /' '_' | tr -dc 'A-Za-z0-9_-')

if [ "$USE_UNIQUE" -eq 1 ]; then
  SERIAL=$(lsblk -ndo SERIAL "$SRC" 2>/dev/null | tr -dc 'A-Za-z0-9_-')
  if [ -n "$SERIAL" ]; then
    DEVICE_DIR="${DEVICE_DIR}_${SERIAL}"
    echo "Serial : $SERIAL  (appended to path)"
  elif [ -d "$DISKS_BASE/$DEVICE_DIR" ]; then
    n=1
    while [ -d "$DISKS_BASE/${DEVICE_DIR}_${n}" ]; do (( n++ )) || true; done
    DEVICE_DIR="${DEVICE_DIR}_${n}"
    echo "No serial found — rotating to $DEVICE_DIR"
  fi
fi

DEST="$DISKS_BASE/$DEVICE_DIR"

echo ""
echo "Device : $SRC"
echo "Label  : $RAW_LABEL"
echo "Dest   : $DEST"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$SRC"
echo ""
read -rp "Proceed? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

[ -d "$DISKS_BASE" ] || { echo "$DISKS_BASE not accessible." >&2; exit 1; }
mkdir -p "$DEST" || { echo "Cannot create $DEST — check NFS write permissions." >&2; exit 1; }

sudo mkdir -p "$MNT"
trap 'sudo umount "$MNT" 2>/dev/null; sudo rmdir "$MNT" 2>/dev/null' EXIT

mapfile -t PARTS < <(lsblk -nrpo NAME,TYPE "$SRC" | awk '$2=="part"{print $1}')
[ ${#PARTS[@]} -gt 0 ] || { echo "No partitions found on $SRC." >&2; exit 1; }

# Rename any old device-name subdirs (sda1, sdb2, nvme0n1p1, …) to partition_N
idx=1
for existing in "$DEST"/*/; do
  base=$(basename "$existing")
  if [[ "$base" =~ ^(sd|hd|vd|nvme|mmcblk)[a-z0-9]+$ ]]; then
    newname="partition_${idx}"
    echo "Renaming existing $base -> $newname"
    run mv "$existing" "$DEST/$newname"
  fi
  (( idx++ )) || true
done

echo ""
echo "Partitions to back up: ${PARTS[*]}"
echo ""

part_idx=1
for p in "${PARTS[@]}"; do
  label="partition_${part_idx}"
  d="$DEST/$label"
  img_base="$DEST/${label}"
  echo "========================================================"
  echo "=== Partition $part_idx: $p  ->  $d"
  echo "========================================================"
  run mkdir -p "$d"

  if [ "$DDRESCUE_ONLY" -eq 1 ]; then
    if ! command -v ddrescue &>/dev/null; then
      echo "  ddrescue not found — installing gddrescue..."
      run sudo apt-get install -y gddrescue
    fi
    img="${img_base}.img"
    log="${img_base}.ddrescue.log"
    echo "=== ddrescue $p -> $img (log: $log) ==="
    run sudo ddrescue -d -r3 --force "$p" "$img" "$log"
  else
    cur=$(findmnt -nro TARGET "$p" 2>/dev/null | head -1 || true)
    if [ -n "$cur" ]; then
      src="$cur"
      unmnt=0
      echo "=== $p is already mounted at $cur — using live mount ==="
    else
      echo "=== Mounting $p read-only at $MNT ==="
      if ! run sudo mount -o ro "$p" "$MNT" 2>&1; then
        echo "  Skipping $p (mount failed — unsupported filesystem?)"
        (( part_idx++ )) || true
        continue
      fi
      src="$MNT"
      unmnt=1
    fi

    echo "=== rsync $src/ -> $d/ ==="
    rsync_ok=0
    run rsync -rlt --info=progress2 --human-readable --timeout=600 \
      "$src/" "$d/" && rsync_ok=1 || true

    if [ "$rsync_ok" -eq 0 ]; then
      echo ""
      echo "  rsync failed on $p — falling back to ddrescue raw image"

      if ! command -v ddrescue &>/dev/null; then
        echo "  ddrescue not found — installing gddrescue..."
        run sudo apt-get install -y gddrescue
      fi

      img="${img_base}.img"
      log="${img_base}.ddrescue.log"
      echo "=== ddrescue $p -> $img (log: $log) ==="
      run sudo ddrescue -d -r3 --force "$p" "$img" "$log"
    fi

    [ "$unmnt" = 1 ] && run sudo umount "$MNT"
  fi
  (( part_idx++ )) || true
  echo ""
done

echo "All done. Files written to $DEST"
