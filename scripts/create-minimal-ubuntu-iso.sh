#!/usr/bin/env bash
# Create a minimal Ubuntu live-style ISO with the kernel built from this tree.
#
# The root filesystem is still assembled under OUTPUT_DIR/rootfs (debootstrap,
# your modules, plotpoll, /.chiaplots), then squashed into casper/filesystem.squashfs
# and wrapped with grub-mkrescue (BIOS + EFI hybrid on amd64).
#
# Intended host: Ubuntu or Debian (debootstrap, chroot). On macOS, run inside
# Docker with the repo bind-mounted (privileged). See fs/ext4/CHIAPLOTS.md.
#
# Usage:
#   sudo ./scripts/create-minimal-ubuntu-iso.sh [LINUX_SRC] [OUTPUT_DIR]
#
# Environment:
#   RELEASE        Ubuntu codename (default: noble)
#   ARCH           debootstrap arch (default: host; x86_64 -> amd64, aarch64 -> arm64)
#   APT_MIRROR     archive base URL (defaults by arch)
#   EXTRA_PKGS     space-separated apt packages (optional)
#   SKIP_DEBOOTSTRAP  set to 1 to reuse existing OUTPUT_DIR/rootfs (still rebuilds squashfs+ISO)
#
# Build the kernel first for the same ARCH as the rootfs (e.g. make bzImage modules).
#
# Bundles repository root plotpoll.sh as /usr/local/bin/plotpoll.sh (required file).
# Pre-creates /.chiaplots (mode 0777) for ext4 chiaplots testing; tighten in production.
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
OUT="$(abspath "${2:-./minimal-ubuntu-iso}")"
RELEASE="${RELEASE:-noble}"
HOST_ARCH="$(uname -m)"
ARCH="${ARCH:-$HOST_ARCH}"
SKIP_DEBOOTSTRAP="${SKIP_DEBOOTSTRAP:-0}"
EXTRA_PKGS="${EXTRA_PKGS:-}"

map_debian_arch() {
	case "$1" in
	x86_64) echo amd64 ;;
	aarch64) echo arm64 ;;
	armv7l) echo armhf ;;
	*) echo "$1" ;;
	esac
}

DEB_ARCH="$(map_debian_arch "$ARCH")"
ROOTFS="${OUT}/rootfs"
ISOSTAGE="${OUT}/isostage"
CHROOT_MOUNTS=0

cleanup_chroot_mounts() {
	if [[ "$CHROOT_MOUNTS" -eq 1 ]]; then
		umount -l "${ROOTFS}/sys" 2>/dev/null || true
		umount -l "${ROOTFS}/proc" 2>/dev/null || true
		umount -l "${ROOTFS}/dev/pts" 2>/dev/null || true
		umount -l "${ROOTFS}/dev" 2>/dev/null || true
		CHROOT_MOUNTS=0
	fi
}

mount_for_chroot() {
	cleanup_chroot_mounts
	mount --bind /dev "${ROOTFS}/dev"
	mount --bind /dev/pts "${ROOTFS}/dev/pts" 2>/dev/null || true
	mount -t proc proc "${ROOTFS}/proc"
	mount -t sysfs sysfs "${ROOTFS}/sys"
	CHROOT_MOUNTS=1
}

run_in_chroot() {
	mount_for_chroot
	# shellcheck disable=SC2068
	chroot "${ROOTFS}" "$@"
	local ec=$?
	cleanup_chroot_mounts
	return "$ec"
}

if [[ "$(id -u)" -ne 0 ]]; then
	echo "Run as root (sudo); debootstrap and chroot need privileges." >&2
	exit 1
fi

if ! command -v debootstrap >/dev/null 2>&1; then
	echo "Install debootstrap: apt-get install -y debootstrap" >&2
	exit 1
fi

trap cleanup_chroot_mounts EXIT

APT_MIRROR="${APT_MIRROR:-}"
if [[ -z "$APT_MIRROR" ]]; then
	if [[ "$DEB_ARCH" == "amd64" || "$DEB_ARCH" == "i386" ]]; then
		APT_MIRROR="http://archive.ubuntu.com/ubuntu"
	else
		APT_MIRROR="http://ports.ubuntu.com/ubuntu-ports"
	fi
fi

mkdir -p "$OUT"

if [[ ! -f "${LINUX_SRC}/Makefile" ]]; then
	echo "LINUX_SRC does not look like a kernel tree: ${LINUX_SRC}" >&2
	exit 1
fi

KREL="$(make -s -C "${LINUX_SRC}" kernelrelease 2>/dev/null || true)"
if [[ -z "$KREL" ]]; then
	echo "Cannot read kernelrelease; configure the tree in ${LINUX_SRC} (e.g. make defconfig)." >&2
	exit 1
fi

pick_kernel_image() {
	local src="$1" arch="$2"
	case "$arch" in
	amd64 | i386)
		if [[ -f "${src}/arch/x86/boot/bzImage" ]]; then
			echo "${src}/arch/x86/boot/bzImage"
			return
		fi
		;;
	arm64)
		if [[ -f "${src}/arch/arm64/boot/Image.gz" ]]; then
			echo "${src}/arch/arm64/boot/Image.gz"
			return
		fi
		if [[ -f "${src}/arch/arm64/boot/Image" ]]; then
			echo "${src}/arch/arm64/boot/Image"
			return
		fi
		;;
	esac
	echo ""
}

KERNEL_BIN="$(pick_kernel_image "${LINUX_SRC}" "${DEB_ARCH}")"
if [[ -z "$KERNEL_BIN" ]]; then
	echo "No built kernel image found for ${DEB_ARCH} under ${LINUX_SRC}." >&2
	echo "Build first (e.g. make -j\"\$(nproc)\" bzImage modules for amd64)." >&2
	exit 1
fi

if [[ "$SKIP_DEBOOTSTRAP" != "1" ]]; then
	echo "==> debootstrap --variant=minbase ${RELEASE} (${DEB_ARCH}) -> ${ROOTFS}"
	rm -rf "${ROOTFS}"
	debootstrap --variant=minbase --arch="${DEB_ARCH}" \
		--components=main \
		"${RELEASE}" "${ROOTFS}" "${APT_MIRROR}"

	cp /etc/resolv.conf "${ROOTFS}/etc/resolv.conf" 2>/dev/null || true

	run_in_chroot /bin/bash -c "
		set -e
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -qq
		apt-get install -y --no-install-recommends \
			initramfs-tools kmod ca-certificates bash coreutils findutils ${EXTRA_PKGS}
		apt-get clean
		rm -rf /var/lib/apt/lists/*
	"
else
	if [[ ! -d "${ROOTFS}/bin" ]]; then
		echo "SKIP_DEBOOTSTRAP=1 but ${ROOTFS} is missing; run without SKIP first." >&2
		exit 1
	fi
fi

echo "==> Install modules (${KREL}) into ${ROOTFS}"
make -C "${LINUX_SRC}" INSTALL_MOD_PATH="${ROOTFS}" INSTALL_MOD_STRIP=1 modules_install

mkdir -p "${ROOTFS}/boot"
BOOT_DST="${ROOTFS}/boot/vmlinuz-${KREL}"
if [[ "$KERNEL_BIN" == *.gz ]]; then
	cp -a -- "${KERNEL_BIN}" "${ROOTFS}/boot/vmlinuz-${KREL}.gz"
	BOOT_DST="${ROOTFS}/boot/vmlinuz-${KREL}.gz"
else
	cp -a -- "${KERNEL_BIN}" "${BOOT_DST}"
fi

PLOTPOLL_SRC="${LINUX_SRC}/plotpoll.sh"
if [[ ! -f "$PLOTPOLL_SRC" ]]; then
	echo "Expected ${PLOTPOLL_SRC} (repo root plotpoll.sh) for the distribution." >&2
	exit 1
fi
echo "==> Install plotpoll.sh -> /usr/local/bin/plotpoll.sh"
mkdir -p "${ROOTFS}/usr/local/bin"
cp -a -- "$PLOTPOLL_SRC" "${ROOTFS}/usr/local/bin/plotpoll.sh"
chmod 0755 "${ROOTFS}/usr/local/bin/plotpoll.sh"

echo "==> Create /.chiaplots (chiaplots directory at filesystem root)"
mkdir -p "${ROOTFS}/.chiaplots"
chmod 0777 "${ROOTFS}/.chiaplots"

echo "==> Install casper + initramfs (live boot from squashfs)"
cp /etc/resolv.conf "${ROOTFS}/etc/resolv.conf" 2>/dev/null || true
run_in_chroot /bin/bash -c "
	set -e
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y casper
	apt-get clean
	rm -rf /var/lib/apt/lists/*
	depmod -a '${KREL}'
	update-initramfs -c -k '${KREL}'
"

INITRD="${ROOTFS}/boot/initrd.img-${KREL}"
if [[ ! -f "$INITRD" ]]; then
	INITRD="$(ls "${ROOTFS}/boot"/initrd.img* 2>/dev/null | head -1 || true)"
fi
if [[ -z "$INITRD" || ! -f "$INITRD" ]]; then
	echo "No initrd.img-* under ${ROOTFS}/boot after update-initramfs." >&2
	exit 1
fi

echo "==> Host tools for squashfs + ISO (xorriso, grub-mkrescue, mtools)"
# grub-mkrescue runs mformat(1) from the mtools package for the BIOS boot floppy image.
if command -v apt-get >/dev/null 2>&1; then
	apt-get update -qq
	case "$DEB_ARCH" in
	amd64 | i386)
		DEBIAN_FRONTEND=noninteractive apt-get install -y \
			squashfs-tools xorriso mtools grub-common grub-pc-bin grub-efi-amd64-bin
		;;
	arm64)
		DEBIAN_FRONTEND=noninteractive apt-get install -y \
			squashfs-tools xorriso mtools grub-common grub-efi-arm64-bin
		;;
	*)
		echo "Install squashfs-tools xorriso mtools grub packages for arch ${DEB_ARCH} manually." >&2
		exit 1
		;;
	esac
else
	for c in mksquashfs xorriso mformat grub-mkrescue; do
		command -v "$c" >/dev/null 2>&1 || {
			echo "Missing host command: $c (e.g. apt-get install -y squashfs-tools xorriso mtools grub-common ...)" >&2
			exit 1
		}
	done
fi

echo "==> Squash rootfs -> casper/filesystem.squashfs"
rm -rf "${ISOSTAGE}"
mkdir -p "${ISOSTAGE}/casper" "${ISOSTAGE}/boot/grub" "${ISOSTAGE}/.disk"
mksquashfs "${ROOTFS}" "${ISOSTAGE}/casper/filesystem.squashfs" \
	-comp xz -b 1M -noappend -no-recovery

# Bootloader-visible kernel + initrd (casper expects a plain vmlinuz on the ISO)
if [[ "$BOOT_DST" == *.gz ]]; then
	gzip -dc -- "$BOOT_DST" >"${ISOSTAGE}/casper/vmlinuz"
else
	cp -a -- "$BOOT_DST" "${ISOSTAGE}/casper/vmlinuz"
fi
cp -a -- "$INITRD" "${ISOSTAGE}/casper/initrd"

cat >"${ISOSTAGE}/boot/grub/grub.cfg" <<GRUBEOF
set default=0
set timeout=5
menuentry "Minimal Ubuntu chiaplots (${KREL})" {
	linux /casper/vmlinuz boot=casper quiet splash noprompt --
	initrd /casper/initrd
}
GRUBEOF

echo "Ubuntu chiaplots minimal ${RELEASE} ${KREL}" >"${ISOSTAGE}/.disk/info"
echo "full_cd/single" >"${ISOSTAGE}/.disk/cd_type"
touch "${ISOSTAGE}/.disk/base_installable"

ISO_PATH="${OUT}/minimal-ubuntu-${RELEASE}-${KREL}-${DEB_ARCH}.iso"
echo "==> grub-mkrescue -> ${ISO_PATH}"
rm -f -- "${ISO_PATH}"
# Trailing args after -- go to xorriso: -as mkisofs so -V / -appid are valid.
#
# arm64: default grub-mkrescue still embeds i386-pc (x86) BIOS boot metadata; guests
# such as VirtualBox on Apple Silicon then report "x86 instead of arm". Force GRUB
# modules from arm64-efi only (UEFI AArch64 ISO, no legacy PC floppy image).
mkrescue=(grub-mkrescue --compress=xz -o "${ISO_PATH}")
case "$DEB_ARCH" in
arm64)
	GRUB_ARM64_EFI=/usr/lib/grub/arm64-efi
	if [[ ! -d "$GRUB_ARM64_EFI" ]]; then
		echo "Missing ${GRUB_ARM64_EFI} (install grub-efi-arm64-bin on the build host)." >&2
		exit 1
	fi
	mkrescue+=(-d "$GRUB_ARM64_EFI")
	;;
armhf)
	GRUB_ARM_EFI=/usr/lib/grub/arm-efi
	if [[ -d "$GRUB_ARM_EFI" ]]; then
		mkrescue+=(-d "$GRUB_ARM_EFI")
	fi
	;;
esac
mkrescue+=("${ISOSTAGE}" -- -as mkisofs -V "CHIAPLOTS_${KREL}" -appid "chiaplots-minimal")
"${mkrescue[@]}"

trap - EXIT
cleanup_chroot_mounts

cat >"${OUT}/README.txt" <<EOF
Minimal Ubuntu (${RELEASE}, ${DEB_ARCH}) live ISO with custom kernel ${KREL}

ISO:
  ${ISO_PATH}

Boot:
  amd64/i386: hybrid BIOS + UEFI (default grub-mkrescue).
  arm64: UEFI AArch64 only (grub-mkrescue -d /usr/lib/grub/arm64-efi). Use an arm64
  build environment (e.g. Docker linux/arm64 on Apple Silicon, not --platform linux/amd64)
  so debootstrap, kernel, and ISO targets match the guest.

Live session uses casper + filesystem.squashfs (plotpoll, /.chiaplots).
Unpacked rootfs (for inspection / SKIP rebuilds):
  ${ROOTFS}

Source tree: ${LINUX_SRC}

Reinstall kernel + ISO only (reuse debootstrap tree):
  SKIP_DEBOOTSTRAP=1 $0 ${LINUX_SRC} ${OUT}
EOF

echo "Done."
echo "  ISO:      ${ISO_PATH}"
echo "  Rootfs:   ${ROOTFS}"
echo "  README:   ${OUT}/README.txt"
