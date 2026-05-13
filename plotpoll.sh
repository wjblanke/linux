#!/usr/bin/env bash
# Loop every INTERVAL_SEC: if CHIAPLOTS_DIR exists, compare (df avail on that mount
# minus sum of all regular files under CHIAPLOTS_DIR, any depth) to a threshold; if
# greater, create either (1) Chia chiapos (-t temp, -d CHIAPLOTS_DIR) or (2) dd+mv.
# Mode is selected only by PLOTPOLL_CHIA (no fallback).
#
# Requires write access to CHIAPLOTS_DIR (default /.chiaplots).
# Uses POSIX df -Pk for available space (not GNU-only df -B1).
#
# Environment (optional):
#   CHIAPLOTS_DIR   default /.chiaplots
#   INTERVAL_SEC    default 10
#   THRESHOLD_MB    default 4096  (mebibytes: 4 GiB logical headroom; metric must exceed this)
#   FILE_MB         default 600   (mebibytes per dd file when PLOTPOLL_CHIA=0)
#   CHIA_PLOT_K     default 25
#   CHIA_BUFFER_MB  default 1024  (chiapos -b buffer MB)
#   PLOTPOLL_CHIA   default 1     (1 = only Chia; 0 = only dd+mv)
#
# On startup, if chia is on PATH and ${HOME}/.chia does not exist: chia init,
# configure -t true, configure --set-log-level INFO, keys generate_and_print.
# If chia is on PATH, chia start farmer-only is run once after that block.

# Invoked as `sh plotpoll.sh` or from a non-bash sh: re-exec so [[, ((, local work.
if [ -z "${BASH_VERSION:-}" ]; then
	exec /usr/bin/env bash "$0" "$@" || exit 1
fi

set -u

CHIAPLOTS_DIR="${CHIAPLOTS_DIR:-/.chiaplots}"
INTERVAL_SEC="${INTERVAL_SEC:-10}"
THRESHOLD_MB="${THRESHOLD_MB:-4096}"
FILE_MB="${FILE_MB:-600}"
CHIA_PLOT_K="${CHIA_PLOT_K:-25}"
CHIA_BUFFER_MB="${CHIA_BUFFER_MB:-1024}"
PLOTPOLL_CHIA="${PLOTPOLL_CHIA:-1}"

threshold_bytes=$((THRESHOLD_MB * 1024 * 1024))
create_seq=0

if command -v chia >/dev/null 2>&1; then
	if [[ -n "${HOME:-}" ]] && [[ ! -e "${HOME}/.chia" ]]; then
		echo "plotpoll: ${HOME}/.chia missing — chia init and first-time setup" >&2
		chia init
		chia configure -t true
		chia configure --set-log-level INFO
		chia keys generate --label xchlinux
	elif [[ -z "${HOME:-}" ]]; then
		echo "plotpoll: HOME unset — cannot check ~/.chia; skipping chia init" >&2
	fi
	echo "plotpoll: chia start farmer-only" >&2
	chia start farmer-only || echo "plotpoll: chia start farmer-only exited $?" >&2
fi

# Sum sizes of regular files under dir (bytes). find -print0 + stat (Linux/macOS).
sum_tree_regular_files() {
	local dir="$1"
	local sum=0 sz f
	while IFS= read -r -d '' f; do
		sz=$(stat -c '%s' "$f" 2>/dev/null || stat -f '%z' "$f" 2>/dev/null || echo 0)
		sum=$((sum + sz))
	done < <(find "$dir" -type f -print0 2>/dev/null)
	echo "$sum"
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

	chia_log="${workdir}/chia.log"
	# Piped output is not a TTY: Python buffers stdout; tqdm often draws in-place and
	# prints little when not interactive. PYTHONUNBUFFERED + GNU stdbuf line buffering
	# yields incremental lines on stderr via tee.
	_chia_run() {
		local -a args=(plotters chiapos -k "$k" "${override[@]}" -n 1 \
			-t "$workdir" -d "$dest_dir" -b "$buf")
		if command -v stdbuf >/dev/null 2>&1; then
			PYTHONUNBUFFERED=1 stdbuf -oL -eL chia "${args[@]}" 2>&1
		else
			PYTHONUNBUFFERED=1 chia "${args[@]}" 2>&1
		fi
	}
	_chia_run | tee "$chia_log" >&2
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

echo "plotpoll: starting CHIAPLOTS_DIR=${CHIAPLOTS_DIR} THRESHOLD_MB=${THRESHOLD_MB} PLOTPOLL_CHIA=${PLOTPOLL_CHIA} INTERVAL_SEC=${INTERVAL_SEC} (metric must exceed ${THRESHOLD_MB} MiB before any create)" >&2

while true; do
	if [[ ! -d "$CHIAPLOTS_DIR" ]]; then
		echo "plotpoll: ${CHIAPLOTS_DIR} does not exist — waiting" >&2
		sleep "$INTERVAL_SEC"
		continue
	fi

	avail_kb="$(df -Pk "$CHIAPLOTS_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
	if [[ -z "$avail_kb" ]] || [[ ! "$avail_kb" =~ ^[0-9]+$ ]]; then
		echo "plotpoll: df -Pk failed for $CHIAPLOTS_DIR (install coreutils or use a POSIX df)" >&2
		sleep "$INTERVAL_SEC"
		continue
	fi

	avail_bytes=$((avail_kb * 1024))
	files_sum="$(sum_tree_regular_files "$CHIAPLOTS_DIR")"
	total=$((avail_bytes - files_sum))

	if ((total > threshold_bytes)); then
		if [[ ! -w "$CHIAPLOTS_DIR" ]]; then
			echo "plotpoll: $CHIAPLOTS_DIR not writable" >&2
		elif [[ "${PLOTPOLL_CHIA}" == "1" ]]; then
			try_chia_k_plot "$CHIAPLOTS_DIR" "$avail_bytes" "$files_sum" "$total" || true
		else
			create_seq=$((create_seq + 1))
			try_dd_file "$CHIAPLOTS_DIR" "$avail_bytes" "$files_sum" "$total" "$create_seq" || true
		fi
	fi

	sleep "$INTERVAL_SEC"
done
