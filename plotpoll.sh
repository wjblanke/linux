#!/usr/bin/env bash
# Loop every 10s: if /.chiaplots exists, compare (df avail on that mount minus sum of
# all regular files under /.chiaplots, any depth) to a threshold; if greater, create
# either (1) a Chia chiapos plot with -t temp under TMPDIR and -d CHIAPLOTS_DIR, or
# (2) a FILE_MB MiB zero-filled file via dd under TMPDIR then mv into CHIAPLOTS_DIR.
# Mode is selected only by PLOTPOLL_CHIA (no fallback from one to the other).
# If /tmp is another filesystem (e.g. tmpfs), mv may copy+create and still hit EPERM;
# then set TMPDIR to a dir on the ext4 volume or use a same-fs staging path.
#
# Requires write access to CHIAPLOTS_DIR (default /.chiaplots) to create files there.
# Chia path: needs `chia` on PATH, a usable key (chia keys show), and enough RAM/disk
# for plotting (see CHIA_BUFFER_MB).
#
# Environment (optional):
#   CHIAPLOTS_DIR   default /.chiaplots
#   INTERVAL_SEC    default 10
#   THRESHOLD_MB    default 4096  (mebibytes: 4 GiB headroom; metric must exceed this)
#   FILE_MB         default 50    (mebibytes per dd file when PLOTPOLL_CHIA=0)
#   CHIA_PLOT_K     default 25    (k size for chia plotters chiapos; use --override-k if k < 32)
#   CHIA_BUFFER_MB  default 1024  (chiapos -b buffer MB; ~1 GiB; lower if RAM-constrained)
#   PLOTPOLL_CHIA   default 1     (1 = only Chia chiapos; 0 = only dd+mv)

# Invoked as `sh plotpoll.sh` or from a non-bash sh: re-exec so [[, ((, local work.
if [ -z "${BASH_VERSION:-}" ]; then
	exec /usr/bin/env bash "$0" "$@" || exit 1
fi

set -u

CHIAPLOTS_DIR="${CHIAPLOTS_DIR:-/.chiaplots}"
INTERVAL_SEC="${INTERVAL_SEC:-10}"
THRESHOLD_MB="${THRESHOLD_MB:-4096}"
FILE_MB="${FILE_MB:-50}"
CHIA_PLOT_K="${CHIA_PLOT_K:-25}"
CHIA_BUFFER_MB="${CHIA_BUFFER_MB:-1024}"
PLOTPOLL_CHIA="${PLOTPOLL_CHIA:-1}"

threshold_bytes=$((THRESHOLD_MB * 1024 * 1024))
create_seq=0

sum_tree_regular_files() {
	local dir="$1"
	find "$dir" -type f -printf '%s\n' 2>/dev/null |
		awk '{s += $1} END {print s + 0}'
}

# Run Chia chiapos with -t temp dir (working files) and -d dest_dir (final .plot path).
# Success is chia exit 0 only — no check for a .plot file in dest_dir.
try_chia_k_plot() {
	local dest_dir="$1"
	local avail_b="$2"
	local plot_bytes="$3"
	local metric="$4"
	local workdir k buf override chia_log chia_ec

	command -v chia >/dev/null 2>&1 || {
		echo "plotpoll: chia not on PATH" >&2
		return 1
	}

	k="${CHIA_PLOT_K}"
	[[ "$k" =~ ^[0-9]+$ ]] || return 1
	buf="${CHIA_BUFFER_MB}"
	[[ "$buf" =~ ^[0-9]+$ ]] || buf=1024

	workdir="$(mktemp -d "${TMPDIR:-/tmp}/plotpoll.chia.XXXXXX")" || return 1

	override=()
	if ((k < 32)); then
		override=(--override-k)
	fi

	# Stream chia output to stderr in real time; do not use $(...) — that buffers all
	# stdout/stderr until the plotter exits, so nothing appears for minutes.
	chia_log="${workdir}/chia.log"
	chia plotters chiapos -k "$k" "${override[@]}" -n 1 \
		-t "$workdir" -d "$dest_dir" -b "$buf" 2>&1 | tee "$chia_log" >&2
	chia_ec=${PIPESTATUS[0]}
	if ((chia_ec != 0)); then
		echo "plotpoll: chia plotters chiapos -k${k} failed (exit ${chia_ec})" >&2
		[[ -f "$chia_log" ]] && echo "plotpoll: chia log tail (first 2KiB): $(head -c 2048 "$chia_log")" >&2
		rm -rf "$workdir"
		return 1
	fi

	rm -rf "$workdir"
	echo "plotpoll: $(date '+%Y-%m-%d %H:%M:%S %z') chia k${k} finished (exit 0; final dir $dest_dir) (df_avail=${avail_b} plot_bytes=${plot_bytes} metric=${metric})" >&2
	return 0
}

try_dd_file() {
	local dest_dir="$1"
	local avail_line="$2"
	local files_sum="$3"
	local total="$4"
	local seq="$5"
	local tmp out dd_output mv_output

	if ! tmp="$(mktemp "${TMPDIR:-/tmp}/plotpoll.XXXXXX" 2>/dev/null)"; then
		echo "plotpoll: mktemp ${TMPDIR:-/tmp}/plotpoll.XXXXXX failed" >&2
		return 1
	fi
	out="${dest_dir}/auto_$(date +%s)_$$_${seq}_$(basename "$tmp").bin"
	if dd_output="$(
		dd if=/dev/zero of="$tmp" bs=$((1024 * 1024)) count="$FILE_MB" conv=fsync 2>&1
	)"; then
		if mv_output="$(mv -- "$tmp" "$out" 2>&1)"; then
			echo "plotpoll: $(date '+%Y-%m-%d %H:%M:%S %z') created ${FILE_MB} MiB $out (df_avail=$avail_line plot_bytes=$files_sum metric=$total)" >&2
			return 0
		fi
		rm -f -- "$tmp" 2>/dev/null || true
		echo "plotpoll: mv $tmp -> $out failed" >&2
		echo "plotpoll: mv said: $mv_output" >&2
		return 1
	fi
	rm -f -- "$tmp" 2>/dev/null || true
	echo "plotpoll: failed dd to $tmp" >&2
	echo "plotpoll: dd said: $dd_output" >&2
	return 1
}

while true; do
	room_to_create=0
	if [[ -d "$CHIAPLOTS_DIR" ]]; then
		avail_line="$(df -B1 "$CHIAPLOTS_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
		if [[ -n "$avail_line" ]] && [[ "$avail_line" =~ ^[0-9]+$ ]]; then
			files_sum="$(sum_tree_regular_files "$CHIAPLOTS_DIR")"
			total=$((avail_line - files_sum))
			if ((total > threshold_bytes)); then
				room_to_create=1
				if [[ ! -w "$CHIAPLOTS_DIR" ]]; then
					echo "plotpoll: $CHIAPLOTS_DIR not writable" >&2
				else
					if [[ "${PLOTPOLL_CHIA}" == "1" ]]; then
						try_chia_k_plot "$CHIAPLOTS_DIR" "$avail_line" "$files_sum" "$total" || true
					else
						create_seq=$((create_seq + 1))
						try_dd_file "$CHIAPLOTS_DIR" "$avail_line" "$files_sum" "$total" "$create_seq" || true
					fi
				fi
			fi
		else
			echo "plotpoll: df failed for $CHIAPLOTS_DIR" >&2
		fi
	fi
	if ((room_to_create == 0)); then
		sleep "$INTERVAL_SEC"
	fi
done
