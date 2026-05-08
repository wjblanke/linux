#!/usr/bin/env bash
# Loop every 5s: if /.chiaplots exists, compare (df avail on that mount minus sum of
# all regular files under /.chiaplots, any depth) to a threshold; if greater, add a
# 50 MiB file. Intended for ext4 chiaplots testing (statfs treats plot blocks
# specially; this difference mirrors "effective" headroom in rough terms).
#
# Requires root (or write access to /.chiaplots) to create files there.
#
# Environment (optional):
#   CHIAPLOTS_DIR   default /.chiaplots
#   INTERVAL_SEC    default 5
#   THRESHOLD_MB    default 1100  (mebibytes: threshold * 1024*1024 bytes)
#   FILE_MB         default 50    (mebibytes per new file)

# Invoked as `sh plotpoll.sh` or from a non-bash sh: re-exec so [[, ((, local work.
if [ -z "${BASH_VERSION:-}" ]; then
	exec /usr/bin/env bash "$0" "$@" || exit 1
fi

set -u

CHIAPLOTS_DIR="${CHIAPLOTS_DIR:-/.chiaplots}"
INTERVAL_SEC="${INTERVAL_SEC:-5}"
THRESHOLD_MB="${THRESHOLD_MB:-1100}"
FILE_MB="${FILE_MB:-50}"

threshold_bytes=$((THRESHOLD_MB * 1024 * 1024))

sum_tree_regular_files() {
	local dir="$1"
	find "$dir" -type f -printf '%s\n' 2>/dev/null |
		awk '{s += $1} END {print s + 0}'
}

while true; do
	if [[ -d "$CHIAPLOTS_DIR" ]]; then
		avail_line="$(df -B1 "$CHIAPLOTS_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
		if [[ -n "$avail_line" ]] && [[ "$avail_line" =~ ^[0-9]+$ ]]; then
			files_sum="$(sum_tree_regular_files "$CHIAPLOTS_DIR")"
			total=$((avail_line - files_sum))
			if (( total > threshold_bytes )); then
				out="${CHIAPLOTS_DIR}/auto_$(date +%s)_$$.bin"
				if ! dd if=/dev/zero of="$out" bs=1M count="$FILE_MB" conv=fsync \
					status=none 2>/dev/null; then
					rm -f -- "$out" 2>/dev/null || true
					echo "plotpoll: failed to create $out" >&2
				fi
			fi
		else
			echo "plotpoll: df failed for $CHIAPLOTS_DIR" >&2
		fi
	fi
	sleep "$INTERVAL_SEC"
done
