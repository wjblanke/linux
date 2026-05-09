# Root `.chiaplots` handling (ext4)

Optional behavior for a directory named **`.chiaplots`** at the **filesystem root** (child of the mount root inode). Deeper paths named `.chiaplots` are **not** treated specially.

---

## Changes since upstream (fork summary)

| Topic | Behavior |
|-------|----------|
| **statfs** | After filling `struct kstatfs`, **`ext4_chiaplots_adjust_statfs()`** adds blocks used by **regular files** directly in **`/.chiaplots`** back into **`f_bfree`** / **`f_bavail`** (capped at **`f_blocks`**). Blocks stay allocated on disk; only reporting changes. |
| **Creates under `.chiaplots`** | **`ext4_create`**, **`mknod`**, **`mkdir`**, **`symlink`**, **`link`**, **`tmpfile`** return **`-EPERM`** when the new name would live under **`/.chiaplots`**. **`rename`** is **not** blocked. **`EXT4_FC_REPLAY`**: EPERM checks skipped so fast-commit replay can recreate entries. |
| **Eviction** | **`ext4_chiaplots_try_make_space()`** runs when free clusters (accounting for dirty/reserved pools) fall below **`requested clusters + margin`**, with **`CHIAPLOTS_MARGIN_BYTES`** default **1 GiB**. Deletes the **first regular file** in **readdir order** under **`/.chiaplots`**, repeating while starved. Hooks: delayed-allocation reserve (**before** quota reserve), **`ext4_mb_new_blocks`** (non–delalloc-reserved path). **`ext4_chiaplots_force_evict()`**: single-file eviction without the starved check—used on **EDQUOT** retry and when the regular allocator still fails (**up to 3** attempts each). No separate **free-inode counter** eviction hook (**`ialloc.c`** does not call chiaplots). |
| **Credentials / DAC** | Eviction uses **`override_creds(kernel_cred())`** for **`dentry_open`** / **`vfs_unlink`** so a mode **`0700`** **`/.chiaplots`** does not fail with **EACCES** when the allocating task is unprivileged. LSM may still deny. |
| **Mount choice** | **`sb_sample_vfsmnt()`** in **`fs/namespace.c`** (exported): picks a **`vfsmount`** for **`dentry_open`** / **`mnt_want_write`**. Prefers **`mnt_root == sb->s_root`**, and among those prefers a **read-write** mount before falling back to read-only (helps **RO bind** over **RW** root). **`chiaplots.c`** calls this helper; it does **not** duplicate mount walking. |
| **Diagnostics** | **`pr_warn_ratelimited("ext4 chiaplots[%s]: …")`** around eviction / **`try_make_space`** / **`force_evict`**. Includes **`evict:`** lines for lookup, **`dentry_open`**, empty directory, no regular file, **`vfs_unlink`**, and race cases (**`.chiaplots` gone before unlink**, **victim missing before unlink**). Use **`dmesg`** / **`journalctl -k`** (grep **`chiaplots`**). Messages are **ratelimited**; bursts may be suppressed. |
| **Userland: `makeplots.sh`** | Repo root (POSIX **`sh`**): batch-fill staging; stop when **`df` avail** on the staging volume **minus** the recursive byte sum of **all regular files** under **`CHIAPLOTS`** (default **`/.chiaplots`**) is **≤ `MIN_FREE_GIB` GiB** (default **1**); then **`mv`** into **`/.chiaplots`**. See **Userland: `makeplots.sh`** below. |
| **Userland: `plotpoll.sh`** | Repo root (**bash**): loop when the same **metric** exceeds a threshold; see **Userland: `plotpoll.sh`** below. |
| **Minimal distribution** | **`scripts/create-minimal-ubuntu-iso.sh`**: **`debootstrap`** minbase Ubuntu, install this tree’s kernel + modules, **`casper`** + **`update-initramfs`**, **`plotpoll.sh`**, **`/.chiaplots`**; **`mksquashfs`** + **`grub-mkrescue`** → **hybrid `.iso`**. See **Minimal Ubuntu distribution** below. |

---

## Overview

### 1. statfs / free-space reporting

Disk blocks used by **regular files** directly inside **`/.chiaplots`** are added back into **`f_bfree`** and **`f_bavail`** (recalculated after reserved blocks), capped so totals never exceed **`f_blocks`**.

On Linux there is no separate **`statvfs`** syscall: libc builds **`struct statvfs`** from **`statfs`/`statfs64`**, so block counts match **`statfs`** for the same mount.

### 2. No new names via “copy” APIs

Creating a **new** inode/name under **`/.chiaplots`** via **`create`**, **`mkdir`**, **`mknod`**, **`symlink`**, **`link`**, or **`tmpfile`** returns **`-EPERM`**. Same-filesystem **`mv`** (**`rename`**) is allowed. Cross-filesystem **`mv`** uses copy+unlink in userland and hits **create** on the destination—blocked when the destination path is under **`/.chiaplots`**.

### 3. Proactive eviction (cluster headroom)

Eviction is driven only by **free-cluster** accounting (plus margin), **not** by the global free-inode counter.

- **`CHIAPLOTS_MARGIN_BYTES`** (default **1 GiB**) is converted to clusters; **`ext4_chiaplots_fs_starved()`** requires at least **`nclusters + margin_clusters`** free (via **`ext4_has_free_clusters()`**). The conversion enforces a **minimum of one cluster** of margin even if the macro were set to **`0`**.
- **Delayed allocation**: **`ext4_chiaplots_try_make_space()`** runs **before** **`dquot_reserve_block()`** so unlink can free quota-relevant space for the same uid/proj before reservation.
- **`ext4_mb_new_blocks`**: **`try_make_space`** before **`ext4_claim_free_clusters()`** when **`EXT4_MB_DELALLOC_RESERVED`** is clear; on **EDQUOT** after reservation, up to **3** **`force_evict`** + quota retry; on allocator failure, up to **3** **`force_evict`** + **`goto repeat`** before final **ENOSPC**.
- Skipped when the superblock is read-only or **`EXT4_FC_REPLAY`** is set.

To tune headroom, edit **`CHIAPLOTS_MARGIN_BYTES`** in **`fs/ext4/chiaplots.c`** and rebuild.

---

## Implementation map

| File | Role |
|------|------|
| **`fs/namespace.c`** | **`sb_sample_vfsmnt(sb)`** — referenced **`vfsmount`** for **`/.chiaplots`** paths; prefers filesystem-root mount, then RW among those. |
| **`fs/ext4/chiaplots.c`** | Path test, **`ext4_chiaplots_adjust_statfs`**, **`ext4_chiaplots_sum_fsblocks`**, **`ext4_chiaplots_try_make_space`**, **`ext4_chiaplots_force_evict`**, eviction (**`vfs_unlink`**), **`chi_dbg`** ratelimited warnings. |
| **`fs/ext4/namei.c`** | EPERM guards + **`EXT4_FC_REPLAY`** bypass on create-like ops. |
| **`fs/ext4/balloc.c`** | **`ext4_has_free_clusters()`** exported for chiaplots starvation checks. |
| **`fs/ext4/super.c`** | **`ext4_statfs`** calls **`ext4_chiaplots_adjust_statfs()`** after filling **`kstatfs`**. |
| **`fs/ext4/inode.c`** | **`ext4_da_reserve_space`**: **`try_make_space`** then **`dquot_reserve_block`**. |
| **`fs/ext4/mballoc.c`** | **`try_make_space`** / **`force_evict`** integration in **`ext4_mb_new_blocks`**. |
| **`fs/ext4/ext4.h`** | Declarations for chiaplots helpers and **`ext4_has_free_clusters()`**. |
| **`fs/ext4/Makefile`** | **`chiaplots.o`**. |
| **`makeplots.sh`** / **`plotpoll.sh`** | Repository root — batch vs periodic userland helpers; see **Userland** sections. |
| **`scripts/create-minimal-ubuntu-iso.sh`** | Builds a minimal Ubuntu **live ISO** (squashfs + casper + GRUB) with this kernel, **`plotpoll.sh`**, and **`/.chiaplots`**; see **Minimal Ubuntu distribution**. |

---

## Limits and semantics

- Recognition walks dentry parents and matches the root-level name **`.chiaplots`** (**case-sensitive**). Casefold / encryption may prevent a match.
- Only **`/<mount-root>/.chiaplots`** and its subtree are affected.
- The kernel **never creates** **`/.chiaplots`**. Create it once in userland if you want eviction/statfs adjustment (e.g. **`mkdir /.chiaplots`** as root). Creating that directory as a child of the **mount root** is **not** blocked by the EPERM rules (those apply **inside** **`/.chiaplots`**).
- Eviction collects at most **128** directory entries per scan pass (**`CHIAPLOTS_MAX_NAMES`**).
- Eviction uses normal **`vfs_unlink`**; errors stop the loop for that allocation attempt.
- **`/.chiaplots`** must live on the **same** mounted volume as the workload expecting eviction; otherwise freeing plots does not help writers on another mount.

---

## Debugging

Kernel warnings:

```bash
sudo dmesg --ctime | grep -i chiaplots
# or: sudo journalctl -k -g chiaplots
```

Messages are **ratelimited**; bursts may be suppressed (see fork summary table).

---

## Userland scripts (repository root)

Scripts **`makeplots.sh`** and **`plotpoll.sh`** live at the **repository root** (alongside the top-level **`Makefile`**).

**Shared metric** (both scripts):

**`metric`** = **`df` available bytes** on the chosen path’s filesystem **minus** the total size of **all regular files** under **`CHIAPLOTS`** / **`CHIAPLOTS_DIR`** (recursive sum via **`find`**).

That matches how **`chiaplots`** adjusts **`statfs`**: **`df`** reports inflated free space for plot blocks; subtracting measured plot file sizes approximates **logical** headroom for workload scripts. Compare **`df`** and the plot tree on the **same mount** as **`/.chiaplots`**.

| Script | Interpreter | Role |
|--------|-------------|------|
| **`makeplots.sh`** | POSIX **`sh`** | One-shot: fill staging until **`metric ≤ MIN_FREE_GIB` GiB**, then **`mv`** into **`/.chiaplots`**. |
| **`plotpoll.sh`** | **bash** | When **`metric > THRESHOLD_MB × 1 MiB`**, **`dd`** in **`/tmp`** then **`mv`** into **`/.chiaplots`** (tight loop while room exists); otherwise sleep **`INTERVAL_SEC`** (default **10** s). |

---

## Userland: `makeplots.sh`

**Path:** `<repository-root>/makeplots.sh`

**Purpose:** Batch-create **`SIZE_MB`** MiB files (default **50**) under a staging directory, then move them into **`/.chiaplots`** with same-filesystem **`rename`** (avoid **EPERM** on **create** under **`/.chiaplots`**).

**Stop condition:** Before each file, compute **`metric`** as above using **`df -B1 "$STAGING_DIR"`** and recursive **`find "$CHIAPLOTS" … -printf '%s\n'`** (GNU **find**). Stop when **`metric ≤ MIN_FREE_GIB × 1024³`** (default **`MIN_FREE_GIB=1`** → **1 GiB**). If **`dd`** fails (**ENOSPC**, etc.), stop early.

**Arguments & environment:**

| Variable / arg | Meaning |
|----------------|---------|
| **`$1`** | Staging directory (default **`./plots`**). |
| **`CHIAPLOTS`** | Directory whose tree is summed and destination for **`mv`** (default **`/.chiaplots`**). Must already exist; script does **not** **`mkdir`** it. |
| **`SIZE_MB`** | **`dd`** file size in **MiB** per file (default **50**). |
| **`MIN_FREE_GIB`** | Stop when **`metric`** is at or below this many **GiB** (**1024³** bytes) (default **1**). |

**Requirements:** GNU **coreutils** **`df -B1`** and GNU **`find -printf`**. Intended for **Linux** test hosts.

**Run:** From a directory on the target volume, e.g. **`./makeplots.sh`** or **`sudo ./makeplots.sh ./plots`**.

---

## Userland: `plotpoll.sh`

Repository root **`plotpoll.sh`** is a **bash** loop for exercising chiaplots from userland without **creating** files directly under **`/.chiaplots`** (**`-EPERM`**); same-filesystem **`mv`** is a **`rename`** and is allowed.

**Behavior (defaults):**

- When no room to create another file, sleep **`INTERVAL_SEC`** seconds (default **10**); while room exists, it immediately attempts another create. If **`CHIAPLOTS_DIR`** exists (default **`/.chiaplots`**) and is writable:
  - **`df -B1`** on that path → available bytes on the mount.
  - **`find`** sums byte sizes of **all regular files** under **`CHIAPLOTS_DIR`** (any depth).
  - **Metric** = `df_avail - plot_bytes` (same definition as **`makeplots.sh`**).
  - If **metric > `THRESHOLD_MB` × 1024²** bytes (default **`THRESHOLD_MB=1100`** → **1100 MiB**), allocates **`FILE_MB`** MiB (default **50**) with **`dd`** into **`mktemp /tmp/plotpoll.XXXXXX`**, then **`mv`** to **`CHIAPLOTS_DIR/auto_<epoch>_<pid>.bin`**. Successful creates print a timestamped `plotpoll:` line; **`dd`/`mv`** failures go to stderr.

**Environment overrides:** `CHIAPLOTS_DIR`, `INTERVAL_SEC`, `THRESHOLD_MB`, `FILE_MB` (see script header).

**Run:** `sudo ./plotpoll.sh` from the repo root (or `bash /path/to/plotpoll.sh`). Requires **bash**; the script re-execs under bash if invoked as **`sh`**.

**Note:** If **`/tmp`** is on another filesystem (e.g. **tmpfs**) than **`/.chiaplots`**, **`mv`** may perform copy+create into the plot directory and hit **EPERM** again; use a staging directory on the **same** filesystem as the plot mount (or bind-mount **`/tmp`** appropriately).

---

## Build Linux from GitHub source

Use this flow to build and boot a kernel from this fork (or any Linux GitHub tree).

### 1. Install build dependencies (Debian/Ubuntu example)

```bash
sudo apt update
sudo apt install git build-essential libncurses-dev bison flex libssl-dev libelf-dev libdw-dev gawk
```

### 2. Clone source (if needed) and enter tree

```bash
git clone --depth 1 https://github.com/wjblanke/linux.git
cd linux
```

### 3. Seed `.config`

```bash
cp /boot/config-$(uname -r) .config
make olddefconfig
scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
scripts/config --set-str SYSTEM_REVOCATION_KEYS ""
```
### 4. Build kernel and modules

```bash
make -j"$(nproc)"
```

### 5. Install modules and kernel

```bash
sudo make modules_install
sudo make install
```

### 6. Create /.chiaplots folder

```bash
sudo mkdir /.chiaplots
sudo chmod 777 /.chiaplots
```

### 7. Reboot and verify running kernel

```bash
uname -r
```

Confirm it matches the kernel you built before testing chiaplots behavior.

---

## Minimal Ubuntu distribution

The script **`scripts/create-minimal-ubuntu-iso.sh`** builds a **small Ubuntu live ISO** ( **`debootstrap --variant=minbase`**, **`main`** only), installs **your built kernel** and modules into a staging rootfs, adds **`casper`** so the initramfs can pivot into a **squashfs** live image, copies **`plotpoll.sh`** and creates **`/.chiaplots`**, then runs **`mksquashfs`** and **`grub-mkrescue`** to emit a **BIOS + UEFI hybrid** **`.iso`** ( **`amd64`** / **`i386`** ) or an EFI-oriented ISO on **arm64**.

After boot, the live root is typically an **overlay** on top of the squashfs; use an **ext4** disk or loop device for workloads where **chiaplots** must own the real root mount.

### What ends up in the build output

| Item | Location / notes |
|------|-------------------|
| **ISO** | **`OUTPUT_DIR/minimal-ubuntu-<release>-<kernelrelease>-<arch>.iso`** |
| **Staging rootfs** | **`OUTPUT_DIR/rootfs/`** (same tree that was squashed; useful for inspection) |
| **ISO build tree** | **`OUTPUT_DIR/isostage/`** (**`casper/`**, **`boot/grub/`**, **`.disk/`**) |
| Inside squashfs | **`/boot/vmlinuz-*`**, **`/lib/modules/`**, **`/usr/local/bin/plotpoll.sh`**, **`/.chiaplots`** (**0777**) |

The script writes **`OUTPUT_DIR/README.txt`**. It runs **`apt-get`** on the **build host** to install **`squashfs-tools`**, **`xorriso`**, and **GRUB** packages needed for **`grub-mkrescue`**.

### Prerequisites

1. **Configure and build** this kernel for the target architecture (e.g. **`make -j"$(nproc)"`** so **`arch/.../bzImage`** or **`Image`** exists, and modules build).
2. **Host:** Ubuntu (**`noble`** or similar) with **`debootstrap`**, run as **root**. The script will **`apt-get install`** **ISO** tools on that host (requires network on first run).
3. Repository root must contain **`plotpoll.sh`**.

### Create the distribution

```bash
sudo apt-get install -y debootstrap   # if needed
sudo ./scripts/create-minimal-ubuntu-iso.sh . /path/to/output-dir
```

Arguments: **`[LINUX_SRC]`** (default **`.`**), **`[OUTPUT_DIR]`** (default **`./minimal-ubuntu-iso`**). **`LINUX_SRC`** must contain **`Makefile`**, **`plotpoll.sh`**, and the built kernel image.

**Environment (optional):**

| Variable | Meaning |
|----------|---------|
| **`RELEASE`** | Ubuntu codename (default **`noble`**) |
| **`ARCH`** | **`debootstrap`** arch (**`amd64`** / **`arm64`** / …) |
| **`APT_MIRROR`** | Override archive URL |
| **`EXTRA_PKGS`** | Extra **`apt`** packages in the chroot (space-separated) |
| **`SKIP_DEBOOTSTRAP=1`** | Reuse existing **`OUTPUT_DIR/rootfs`**; still reinstalls kernel, **casper**, squashfs, and ISO |

### Docker on macOS

Use **Docker Desktop** or **Colima**, **privileged** container, and bind-mount the repo plus an output directory. The container must reach the network for **`debootstrap`**, **`apt`** (including **`casper`**), and host **`apt-get`** for **xorriso** / **GRUB**.

```bash
mkdir -p docker-out
docker run --rm -it --privileged \
  -v "$PWD":/src -v "$PWD/docker-out":/out \
  ubuntu:noble bash
apt-get update
apt-get install -y debootstrap build-essential libncurses-dev bison flex \
  libssl-dev libelf-dev libdw-dev gawk bc cpio
cd /src && test -f .config || make defconfig && make -j"$(nproc)"
./scripts/create-minimal-ubuntu-iso.sh /src /out
```

The **`.iso`** appears under **`./docker-out/`** on the Mac. **Apple Silicon** builds an **arm64** ISO; **Intel** builds **amd64**.

### Booting

**QEMU (amd64):**

```bash
qemu-system-x86_64 -m 2G -cdrom minimal-ubuntu-*.iso -boot d
```

**chiaplots** applies when the workload’s root (or test data) is on **ext4** with this kernel; the **live overlay** root may differ from a bare **ext4** install—use a dedicated **ext4** disk or image for strict filesystem-level tests if needed.

---

## Rationale for **`sb_sample_vfsmnt()`**

Eviction and statfs summing need a **`vfsmount`** without a user path. **`sb_sample_vfsmnt()`** returns a referenced mount for **`sb`**, preferring **`mnt_root == sb->s_root`** so **`dentry_open`** on dentries under the filesystem root works; among those it prefers **read-write** mounts so **`mnt_want_write()`** succeeds when a read-only bind shadows a writable root mount.
