#!/usr/bin/env bash
# Loop every 5s: if /.chiaplots exists, compare (df avail on that mount minus sum of
# all regular files under /.chiaplots, any depth) to a threshold; if greater, add a
# 50 MiB file. Writes under /tmp then mv into /.chiaplots (same pattern as
# makeplots.sh: create outside, rename in — avoids EPERM on create under /.chiaplots).
# If /tmp is another filesystem (e.g. tmpfs), mv may copy+create and still hit EPERM;
# then set TMPDIR to a dir on the ext4 volume or use a same-fs staging path.
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
				if [[ ! -w "$CHIAPLOTS_DIR" ]]; then
					echo "plotpoll: $CHIAPLOTS_DIR not writable (try: sudo $0)" >&2
				else
					if ! tmp="$(mktemp /tmp/plotpoll.XXXXXX 2>/dev/null)"; then
						echo "plotpoll: mktemp /tmp/plotpoll.XXXXXX failed" >&2
					else
						out="${CHIAPLOTS_DIR}/auto_$(date +%s)_$$.bin"
						if dd_output="$(
							dd if=/dev/zero of="$tmp" bs=$((1024 * 1024)) count="$FILE_MB" conv=fsync 2>&1
						)"; then
							if mv_output="$(mv -- "$tmp" "$out" 2>&1)"; then
								echo "plotpoll: created ${FILE_MB} MiB $out (df_avail=$avail_line plot_bytes=$files_sum metric=$total)" >&2
							else
								rm -f -- "$tmp" 2>/dev/null || true
								echo "plotpoll: mv $tmp -> $out failed" >&2
								echo "plotpoll: mv said: $mv_output" >&2
							fi
						else
							rm -f -- "$tmp" 2>/dev/null || true
							echo "plotpoll: failed dd to $tmp" >&2
							echo "plotpoll: dd said: $dd_output" >&2
						fi
					fi
				fi
			fi
		else
			echo "plotpoll: df failed for $CHIAPLOTS_DIR" >&2
		fi
	fi
	sleep "$INTERVAL_SEC"
done
