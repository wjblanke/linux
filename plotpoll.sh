#!/usr/bin/env bash
# Loop every 10s: if /.chiaplots exists, compare (df avail on that mount minus sum of
# all regular files under /.chiaplots, any depth) to a threshold; if greater, add a
# file by (1) running Chia chiapos for a k25 test plot in TMPDIR, then mv the .plot
# into /.chiaplots, or (2) if that fails, dd FILE_MB MiB of zeros under /tmp then mv
# into /.chiaplots (same pattern as makeplots.sh: create outside, rename in — avoids
# EPERM on create under /.chiaplots).
# If /tmp is another filesystem (e.g. tmpfs), mv may copy+create and still hit EPERM;
# then set TMPDIR to a dir on the ext4 volume or use a same-fs staging path.
#
# Requires root (or write access to /.chiaplots) to create files there.
# Chia path: needs `chia` on PATH, a usable key (chia keys show), and enough RAM/disk
# for plotting (see CHIA_BUFFER_MB). On any failure, falls back to dd.
#
# Environment (optional):
#   CHIAPLOTS_DIR   default /.chiaplots
#   INTERVAL_SEC    default 10
#   THRESHOLD_MB    default 2048  (mebibytes: 2 GiB headroom; metric must exceed this)
#   FILE_MB         default 50    (mebibytes per dd fallback file)
#   CHIA_PLOT_K     default 25    (k size for chia plotters chiapos; use --override-k if k < 32)
#   CHIA_BUFFER_MB  default 512   (chiapos -b buffer; lower if RAM-constrained)
#   PLOTPOLL_CHIA   default 1     (set to 0 to skip Chia and only use dd)

# Invoked as `sh plotpoll.sh` or from a non-bash sh: re-exec so [[, ((, local work.
if [ -z "${BASH_VERSION:-}" ]; then
	exec /usr/bin/env bash "$0" "$@" || exit 1
fi

set -u

CHIAPLOTS_DIR="${CHIAPLOTS_DIR:-/.chiaplots}"
INTERVAL_SEC="${INTERVAL_SEC:-10}"
THRESHOLD_MB="${THRESHOLD_MB:-2048}"
FILE_MB="${FILE_MB:-50}"
CHIA_PLOT_K="${CHIA_PLOT_K:-25}"
CHIA_BUFFER_MB="${CHIA_BUFFER_MB:-512}"
PLOTPOLL_CHIA="${PLOTPOLL_CHIA:-1}"

threshold_bytes=$((THRESHOLD_MB * 1024 * 1024))
create_seq=0

sum_tree_regular_files() {
	local dir="$1"
	find "$dir" -type f -printf '%s\n' 2>/dev/null |
		awk '{s += $1} END {print s + 0}'
}

# Try Chia chiapos in a temp directory (never under CHIAPLOTS_DIR — creates there are
# EPERM). On success, mv the finished .plot into dest_dir. Returns 0 on success.
try_chia_k_plot() {
	local dest_dir="$1"
	local avail_b="$2"
	local plot_bytes="$3"
	local metric="$4"
	local workdir plotf dest k buf override chia_log chia_ec

	[[ "${PLOTPOLL_CHIA}" == "1" ]] || return 1
	command -v chia >/dev/null 2>&1 || return 1

	k="${CHIA_PLOT_K}"
	[[ "$k" =~ ^[0-9]+$ ]] || return 1
	buf="${CHIA_BUFFER_MB}"
	[[ "$buf" =~ ^[0-9]+$ ]] || buf=512

	workdir="$(mktemp -d "${TMPDIR:-/tmp}/plotpoll.chia.XXXXXX")" || return 1

	override=()
	if ((k < 32)); then
		override=(--override-k)
	fi

	# Stream chia output to stderr in real time; do not use $(...) — that buffers all
	# stdout/stderr until the plotter exits, so nothing appears for minutes.
	chia_log="${workdir}/chia.log"
	chia plotters chiapos -k "$k" "${override[@]}" -n 1 \
		-t "$workdir" -d "$workdir" -b "$buf" 2>&1 | tee "$chia_log" >&2
	chia_ec=${PIPESTATUS[0]}
	if ((chia_ec != 0)); then
		echo "plotpoll: chia plotters chiapos -k${k} failed (exit ${chia_ec}), falling back to ${FILE_MB} MiB dd" >&2
		[[ -f "$chia_log" ]] && echo "plotpoll: chia log tail (first 2KiB): $(head -c 2048 "$chia_log")" >&2
		rm -rf "$workdir"
		return 1
	fi

	plotf="$(find "$workdir" -type f -name '*.plot' 2>/dev/null | head -n1)"
	if [[ -z "${plotf}" || ! -f "${plotf}" ]]; then
		echo "plotpoll: chia finished but no .plot under $workdir, falling back to dd" >&2
		rm -rf "$workdir"
		return 1
	fi

	dest="${dest_dir}/$(basename "$plotf")"
	if ! mv_output="$(mv -- "$plotf" "$dest" 2>&1)"; then
		echo "plotpoll: mv chia plot failed: $mv_output — falling back to dd" >&2
		rm -rf "$workdir"
		return 1
	fi
	rm -rf "$workdir"
	echo "plotpoll: $(date '+%Y-%m-%d %H:%M:%S %z') created chia k${k} plot $dest (df_avail=${avail_b} plot_bytes=${plot_bytes} metric=${metric})" >&2
	return 0
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
					echo "plotpoll: $CHIAPLOTS_DIR not writable (try: sudo $0)" >&2
				else
					create_seq=$((create_seq + 1))
					if try_chia_k_plot "$CHIAPLOTS_DIR" "$avail_line" "$files_sum" "$total"; then
						:
					else
						if ! tmp="$(mktemp "${TMPDIR:-/tmp}/plotpoll.XXXXXX" 2>/dev/null)"; then
							echo "plotpoll: mktemp ${TMPDIR:-/tmp}/plotpoll.XXXXXX failed" >&2
						else
							out="${CHIAPLOTS_DIR}/auto_$(date +%s)_$$_${create_seq}_$(basename "$tmp").bin"
							if dd_output="$(
								dd if=/dev/zero of="$tmp" bs=$((1024 * 1024)) count="$FILE_MB" conv=fsync 2>&1
							)"; then
								if mv_output="$(mv -- "$tmp" "$out" 2>&1)"; then
									echo "plotpoll: $(date '+%Y-%m-%d %H:%M:%S %z') created ${FILE_MB} MiB $out (df_avail=$avail_line plot_bytes=$files_sum metric=$total)" >&2
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
			fi
		else
			echo "plotpoll: df failed for $CHIAPLOTS_DIR" >&2
		fi
	fi
	if ((room_to_create == 0)); then
		sleep "$INTERVAL_SEC"
	fi
done
