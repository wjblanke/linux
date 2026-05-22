#!/usr/bin/env bash
# Stage files and notes for customizing an Ubuntu ISO with Cubic (Custom Ubuntu ISO
# Creator). Cubic is a graphical wizard; this script does not invoke it.
#
# Usage:
#   ./scripts/prepare-chiaplots-cubic.sh [LINUX_SRC] [OUTPUT_DIR]
#
# Optional:
#   RUN_BINDEB=1   Run "fakeroot make bindeb-pkg" in LINUX_SRC (slow; needs kernel
#                  package build deps). Debian packages are written to the parent
#                  of LINUX_SRC; copy linux-image-*.deb (and optionally headers) into
#                  OUTPUT_DIR yourself, or use OUTPUT_BINDEB_COPY=1 to copy matches.
#   OUTPUT_BINDEB_COPY=1   After bindeb-pkg, copy linux-image-*.deb and linux-modules-*.deb
#                  from LINUX_SRC/.. into OUTPUT_DIR (requires RUN_BINDEB=1).
#
set -euo pipefail

abspath() {
	if command -v realpath >/dev/null 2>&1; then
		realpath "$1"
	else
		(cd "$1" && pwd)
	fi
}

LINUX_SRC="$(abspath "${1:-.}")"
OUT_ARG="${2:-./chiaplots-cubic-staging}"
mkdir -p "$OUT_ARG"
OUT="$(abspath "$OUT_ARG")"
RUN_BINDEB="${RUN_BINDEB:-0}"
OUTPUT_BINDEB_COPY="${OUTPUT_BINDEB_COPY:-0}"

if [[ ! -f "${LINUX_SRC}/Makefile" ]]; then
	echo "LINUX_SRC is not a kernel tree: ${LINUX_SRC}" >&2
	exit 1
fi
if [[ ! -f "${LINUX_SRC}/scripts/xchos" ]]; then
	echo "Missing ${LINUX_SRC}/scripts/xchos" >&2
	exit 1
fi

mkdir -p "$OUT"
cp -a -- "${LINUX_SRC}/scripts/xchos" "${OUT}/xchos"
chmod a+rX "${OUT}/xchos"

if [[ "$RUN_BINDEB" == "1" ]]; then
	if ! command -v fakeroot >/dev/null 2>&1; then
		echo "RUN_BINDEB=1 needs fakeroot (and full kernel .deb build dependencies)." >&2
		exit 1
	fi
	echo "==> fakeroot make bindeb-pkg (writes .deb files under parent of ${LINUX_SRC})"
	make -C "${LINUX_SRC}" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" bindeb-pkg
	if [[ "$OUTPUT_BINDEB_COPY" == "1" ]]; then
		parent="$(dirname "${LINUX_SRC}")"
		shopt -s nullglob
		for f in "${parent}"/linux-image-*.deb "${parent}"/linux-modules-*.deb; do
			cp -a -- "$f" "${OUT}/"
		done
		shopt -u nullglob
	fi
fi

cat >"${OUT}/README.txt" <<EOF
Chiaplots + Cubic (Custom Ubuntu ISO Creator)
=============================================

This directory was created by:
  scripts/prepare-chiaplots-cubic.sh ${LINUX_SRC} ${OUT}

Contents of this directory:
  xchos                  Copy into the Cubic chroot with your linux-*.deb files.
  chroot-commands.example.sh   Mirrors section 3 below (kernel, xchos, Chia .deb; adjust STAGING).
  README.txt                   This file (aligned with README.md).

Also copy a Chia release .deb into this directory before syncing to the chroot (see
section 1 below). The script does not download it.

Cubic remixes an official Ubuntu .iso: extract filesystem, customize as root inside
that tree, regenerate .iso. Upstream is GUI-first (no stable CLI):
  https://github.com/PJ-Singh-001/Cubic

Prerequisites
-------------
- Ubuntu (or derivative) host for Cubic, with disk/RAM for extract + ISO build.
- Kernel tree configured so: fakeroot make bindeb-pkg succeeds (build deps + fakeroot).
- Base .iso arch matches your kernel (amd64 vs arm64). Prefer same release family
  as the chroot (e.g. Noble ISO for noble userspace).
- xchos is staged here from: ${LINUX_SRC}/scripts/xchos
- Network in the Cubic chroot: apt still reaches Ubuntu mirrors for dependencies when
  installing local .deb files (kernel + Chia).

Install Cubic
-------------
  sudo apt-add-repository universe
  sudo apt-add-repository ppa:cubic-wizard/release
  sudo apt update
  sudo apt install cubic

1. Build kernel Debian packages (kernel build host)
---------------------------------------------------
From your linux source tree (chiaplots fork):

  cd ${LINUX_SRC}
  # Tree must be configured. bindeb-pkg builds kernel/modules if needed, then writes:
  fakeroot make -j"\$(nproc)" bindeb-pkg

.deb files are written to the parent of this source tree, e.g.:
  $(dirname "${LINUX_SRC}")
(not inside the checkout that contains the top-level Makefile).

You need linux-image-*.deb and linux-modules-*.deb for a bootable image.
linux-headers-*.deb is optional (tooling / out-of-tree modules).

Copy them next to this staging copy of xchos (this directory):

  cp -v /path/to/parent-of-linux/linux-image-*.deb /path/to/parent-of-linux/linux-modules-*.deb ${OUT}/

Download a Chia release .deb matching your ISO architecture (amd64, arm64, ...) from:
  https://github.com/Chia-Network/chia-blockchain/releases
Typical names: chia-blockchain-cli_<ver>-1_<arch>.deb (CLI) or
chia-blockchain_<ver>_<arch>.deb (GUI installer). Copy ONE into:
  ${OUT}/

Or re-run this script with:
  RUN_BINDEB=1 OUTPUT_BINDEB_COPY=1 ./scripts/prepare-chiaplots-cubic.sh ${LINUX_SRC} ${OUT}

2. Cubic wizard (graphical)
---------------------------
1) Original ISO   — Official Ubuntu .iso you are customizing.
2) Project dir    — Empty dedicated folder (avoid names like 20.04.3-4; some Cubic
                    versions mishandle version-like directory names).
3) Extract        — Wait until finished.
4) Terminal       — Root shell in the extracted system; no sudo. Run section 3 here.
5) Boot / Compression / etc. — Defaults are fine unless you have a reason to change.
6) Generate       — Write the final .iso.

Getting files into the chroot: from the host, copy everything in this directory
(including linux-image-*.deb, linux-modules-*.deb, xchos, chia-blockchain*.deb)
into a path inside
the custom root. Cubic's UI shows the project path; open it in a file manager or a
second host terminal. Common convention: copy into /tmp/chiaplots-staging/ inside
the chroot, then run section 3 from there.

3. Inside Cubic's root shell (kernel, xchos, /.chiaplots, Chia)
----------------------------------------------------------------
Run after linux-image-*.deb, linux-modules-*.deb, xchos, and your Chia .deb
are in one place (example: /tmp/chiaplots-staging):

  STAGING=/tmp/chiaplots-staging
  cd "\$STAGING"

  # 3a — Kernel packages
  apt update
  apt install -y ./linux-image-*.deb ./linux-modules-*.deb
  # If apt complains about dependencies:
  #   apt-get install -f -y

  # 3b — xchos helper
  install -m 0755 ./xchos /usr/local/bin/xchos

  # 3c — Kernel never creates this; userland must.
  mkdir -p /.chiaplots
  chmod 0777 /.chiaplots

  # 3d — Initramfs (often already done by postinst; safe to repeat)
  update-initramfs -u -k all

  # 3e — Chia from local .deb (copied into STAGING). Use ONE line matching your file:
  apt install -y ./chia-blockchain-cli_*.deb
  # or: apt install -y ./chia-blockchain_*.deb
  # If apt reports unmet dependencies: apt-get install -f -y  then repeat apt install.

Order: install .deb packages before assuming /lib/modules matches anything from
uname -r in this shell (uname -r may still reflect the host kernel Cubic used).

Verify:

  ls /boot/vmlinuz-*
  ls /lib/modules/
  dpkg -l | grep -E '^ii\\s+linux-(image|modules)-'
  dpkg -l | grep -E '^ii\\s+chia-blockchain(-cli)?'

4. After leaving the chroot
---------------------------
Finish Cubic and generate the .iso. On first boot, pick the custom kernel in GRUB if
needed; uname -r should match the bindeb-pkg version.

Live session vs installed disk
------------------------------
Ubuntu live uses casper + overlay; / is not the same as a long-lived ext4 root after
a normal install. Chiaplots behavior tied to ext4 on / is best validated on installed
disk (or any normal ext4 root), not only on the live desktop.

Full narrative: see README.md (section "Minimal Ubuntu distribution (Cubic)").
EOF

cat >"${OUT}/chroot-commands.example.sh" <<'EOF'
#!/bin/bash
# Run inside Cubic's chroot as root, after copying linux-image-*.deb,
# linux-modules-*.deb, xchos, and chia-blockchain*.deb into STAGING
# (default /tmp/chiaplots-staging).
set -euo pipefail
STAGING="${1:-/tmp/chiaplots-staging}"
cd "$STAGING"

# 3a — Install kernel packages
apt update
if ! apt install -y ./linux-image-*.deb ./linux-modules-*.deb; then
	apt-get install -f -y
	apt install -y ./linux-image-*.deb ./linux-modules-*.deb
fi

# 3b — xchos
install -m 0755 ./xchos /usr/local/bin/xchos

# 3c — /.chiaplots
mkdir -p /.chiaplots
chmod 0777 /.chiaplots

# 3d — initramfs
update-initramfs -u -k all

# 3e — Chia from local .deb in STAGING (edit glob if you use chia-blockchain_*.deb GUI package)
if ! apt install -y ./chia-blockchain-cli_*.deb; then
	apt-get install -f -y
	apt install -y ./chia-blockchain-cli_*.deb
fi

echo "Done. Verify: ls /boot/vmlinuz-* /lib/modules/ ; dpkg -l | grep chia-blockchain ; exit chroot and finish Cubic."
EOF
chmod a+rX "${OUT}/chroot-commands.example.sh"

echo "Staged: ${OUT}/xchos"
echo "Read:   ${OUT}/README.txt"
if [[ "$RUN_BINDEB" != "1" ]]; then
	echo "Tip: build kernel .deb packages with:  (cd ${LINUX_SRC} && fakeroot make -j\$(nproc) bindeb-pkg)"
fi
