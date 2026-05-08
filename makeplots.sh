#!/bin/sh
# Fill a staging directory with fixed-size files until (df avail on the staging
# volume minus total bytes of all regular files under CHIAPLOTS_DIR, recursive)
# is at or below MIN_FREE_GIB (default 1 GiB), then move everything into
# /.chiaplots (same-fs rename). Matches the "effective headroom" idea used by
# plotpoll.sh on chiaplots-adjusted statfs semantics.
#
# Usage:
#   ./makeplots.sh [staging_dir]
#
# Environment:
#   CHIAPLOTS   plot directory to measure (default: /.chiaplots)
#   SIZE_MB     file size in mebibytes (default: 50)
#   MIN_FREE_GIB  stop when (df_avail - chiaplots_tree_bytes) <= this many GiB
#                 (default: 1; 1 GiB = 1024^3 bytes).
#
# Requires GNU find (-printf) for the recursive sum; df uses -B1 (GNU coreutils).
#
# Run from a directory on the ext4 volume you want to fill. For a meaningful
# metric, CHIAPLOTS_DIR should be on the same mounted filesystem as STAGING_DIR.
# The destination directory must already exist (this script does not create
# /.chiaplots). Moving into it typically requires appropriate permissions (e.g. root).

set -u

STAGING_DIR="${1:-./plots}"
CHIAPLOTS_DIR="${CHIAPLOTS:-/.chiaplots}"
SIZE_MB="${SIZE_MB:-50}"
MIN_FREE_GIB="${MIN_FREE_GIB:-1}"
min_free_bytes=$((MIN_FREE_GIB * 1024 * 1024 * 1024))

mkdir -p -- "$STAGING_DIR" || exit 1

echo "Writing ${SIZE_MB} MiB files into: $STAGING_DIR"
echo "Stopping when (df_avail on this volume - bytes under ${CHIAPLOTS_DIR}) <= ${MIN_FREE_GIB} GiB (${min_free_bytes} bytes)."

i=0
while :; do
	avail="$(df -B1 "$STAGING_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
	case "$avail" in
	'' | *[!0-9]*)
		echo "makeplots: df failed for $STAGING_DIR" >&2
		exit 1
		;;
	esac

	plots_sum=0
	if [ -d "$CHIAPLOTS_DIR" ]; then
		plots_sum="$(find "$CHIAPLOTS_DIR" -type f -printf '%s\n' 2>/dev/null |
			awk '{s += $1} END {print s + 0}')"
	fi
	case "$plots_sum" in
	'' | *[!0-9]*) plots_sum=0 ;;
	esac

	if awk -v a="$avail" -v p="$plots_sum" -v m="$min_free_bytes" \
		'BEGIN { exit !((a - p) <= m) }' </dev/null; then
		echo "Metric (df_avail - chiaplots_bytes) = $((avail - plots_sum)) <= ${min_free_bytes}; stopping fill."
		echo "  df_avail=${avail} chiaplots_sum=${plots_sum}"
		break
	fi

	out="$STAGING_DIR/plot_${i}.bin"
	if ! dd if=/dev/zero of="$out" bs=1048576 count="$SIZE_MB" conv=fsync 2>/dev/null; then
		rm -f -- "$out" 2>/dev/null || true
		echo "makeplots: dd failed (ENOSPC or error); stopping at $i file(s)." >&2
		break
	fi
	i=$((i + 1))
	rem=$((i % 10))
	if [ "$rem" -eq 0 ]; then
		metric=$((avail - plots_sum))
		echo "  ... $i files (df_avail=$avail chiaplots_sum=$plots_sum metric=$metric)"
	fi
done

echo "Created $i file(s). Moving to: $CHIAPLOTS_DIR"

if [ ! -d "$CHIAPLOTS_DIR" ]; then
	echo "Destination does not exist or is not a directory: $CHIAPLOTS_DIR" >&2
	echo "Create it once (e.g. mkdir -m 755 /.chiaplots) and rerun." >&2
	exit 1
fi

set -- "$STAGING_DIR"/*
if [ "$#" -eq 1 ] && [ ! -e "$1" ]; then
	echo "No files to move (staging empty or fill skipped)." >&2
	exit 1
fi

for f do
	mv -- "$f" "$CHIAPLOTS_DIR"/
done

echo "Done."
