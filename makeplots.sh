#!/usr/bin/env bash
# Fill a staging directory with fixed-size files until free space on that
# volume is at or below MIN_FREE_GIB (default 1 GiB), then move everything into
# /.chiaplots (same-fs rename).
#
# Usage:
#   ./makeplots.sh [staging_dir]
#
# Environment:
#   CHIAPLOTS   destination directory (default: /.chiaplots)
#   SIZE_MB     file size in mebibytes (default: 50)
#   MIN_FREE_GIB  stop filling when df "Avail" is <= this many GiB (default: 1)
#                 (1 GiB = 1024^3 bytes; uses df on the staging path).
#
# Run from a directory on the ext4 volume you want to fill.
# The destination directory must already exist (this script does not create
# /.chiaplots). Moving into it typically requires appropriate permissions (e.g. root).

if [ -z "${BASH_VERSION:-}" ]; then
	exec /usr/bin/env bash "$0" "$@" || exit 1
fi

set -u

STAGING_DIR="${1:-./plots}"
CHIAPLOTS_DIR="${CHIAPLOTS:-/.chiaplots}"
SIZE_MB="${SIZE_MB:-50}"
MIN_FREE_GIB="${MIN_FREE_GIB:-1}"
min_free_bytes=$((MIN_FREE_GIB * 1024 * 1024 * 1024))

mkdir -p -- "$STAGING_DIR" || exit 1

avail_bytes() {
	df -B1 "$STAGING_DIR" 2>/dev/null | awk 'NR==2 {print $4}'
}

echo "Writing ${SIZE_MB} MiB files into: $STAGING_DIR"
echo "Stopping when available space on this volume is <= ${MIN_FREE_GIB} GiB (${min_free_bytes} bytes)."

i=0
while true; do
	avail="$(avail_bytes)"
	if [[ -z "$avail" ]] || [[ ! "$avail" =~ ^[0-9]+$ ]]; then
		echo "makeplots: df failed for $STAGING_DIR" >&2
		exit 1
	fi
	if (( avail <= min_free_bytes )); then
		echo "Available bytes ${avail} <= limit ${min_free_bytes}; stopping fill."
		break
	fi

	out="$STAGING_DIR/plot_${i}.bin"
	if ! dd if=/dev/zero of="$out" bs=1M count="$SIZE_MB" conv=fsync 2>/dev/null; then
		rm -f -- "$out" 2>/dev/null || true
		echo "makeplots: dd failed (ENOSPC or error); stopping at $i file(s)." >&2
		break
	fi
	i=$((i + 1))
	if (( i % 10 == 0 )); then
		echo "  ... $i files (avail_bytes=$avail)"
	fi
done

echo "Created $i file(s). Moving to: $CHIAPLOTS_DIR"

if [[ ! -d "$CHIAPLOTS_DIR" ]]; then
	echo "Destination does not exist or is not a directory: $CHIAPLOTS_DIR" >&2
	echo "Create it once (e.g. mkdir -m 755 /.chiaplots) and rerun." >&2
	exit 1
fi

shopt -s nullglob
files=("$STAGING_DIR"/*)
if ((${#files[@]} == 0)); then
	echo "No files to move (staging empty or fill skipped)." >&2
	exit 1
fi

for f in "${files[@]}"; do
	mv -- "$f" "$CHIAPLOTS_DIR"/
done

echo "Done."
