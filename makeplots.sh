#!/usr/bin/env bash
# Fill a staging directory with 50 MiB files until the filesystem refuses
# writes, then move everything into /.chiaplots (same-fs rename).
#
# Usage:
#   ./chiaplots-fill-and-move.sh [staging_dir]
#
# Environment:
#   CHIAPLOTS   destination directory (default: /.chiaplots)
#   SIZE_MB     file size in mebibytes (default: 50)
#
# Run from a directory on the ext4 volume you want to fill (or pass full path
# to staging_dir). Creating /.chiaplots and moving into it typically requires
# appropriate permissions (e.g. root).

set -u

STAGING_DIR="${1:-./plots}"
CHIAPLOTS_DIR="${CHIAPLOTS:-/.chiaplots}"
SIZE_MB="${SIZE_MB:-50}"

if ! [[ "$SIZE_MB" =~ ^[0-9]+$ ]] || [[ "$SIZE_MB" -lt 1 ]]; then
	echo "SIZE_MB must be a positive integer" >&2
	exit 1
fi

mkdir -p -- "$STAGING_DIR" || exit 1

echo "Writing ${SIZE_MB} MiB files into: $STAGING_DIR"
i=0
while true; do
	out="$STAGING_DIR/plot_${i}.bin"
	# Stop when we can no longer allocate a full file (ENOSPC, etc.).
	if ! dd if=/dev/zero of="$out" bs=1M count="$SIZE_MB" conv=fsync 2>/dev/null; then
		rm -f -- "$out" 2>/dev/null || true
		break
	fi
	i=$((i + 1))
	if (( i % 10 == 0 )); then
		echo "  ... $i files"
	fi
done

echo "Created $i file(s). Moving to: $CHIAPLOTS_DIR"

mkdir -p -- "$CHIAPLOTS_DIR" || exit 1

shopt -s nullglob
files=("$STAGING_DIR"/*)
if ((${#files[@]} == 0)); then
	echo "No files to move (staging empty or fill failed immediately)." >&2
	exit 1
fi

for f in "${files[@]}"; do
	mv -- "$f" "$CHIAPLOTS_DIR"/
done

echo "Done."
