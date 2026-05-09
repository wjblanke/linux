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
| **Minimal distribution** | **`scripts/prepare-chiaplots-cubic.sh`** stages **`plotpoll.sh`** and a **Cubic** how-to; install **kernel `.deb`** packages (e.g. **`fakeroot make bindeb-pkg`**) inside **Cubic**’s chroot, add **`/.chiaplots`**, then finish the **Cubic** wizard. See **Minimal Ubuntu distribution (Cubic)** below. |

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
| **`scripts/prepare-chiaplots-cubic.sh`** | Stages **`plotpoll.sh`** plus **README** / example chroot commands for **Cubic**; see **Minimal Ubuntu distribution (Cubic)**. |

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

## Minimal Ubuntu distribution (Cubic)

**[Cubic](https://github.com/PJ-Singh-001/Cubic)** (Custom Ubuntu ISO Creator) is the supported way here to remix an official Ubuntu **`.iso`**: graphical project wizard, chroot terminal for packages and files, then regenerated ISO output.

This repository does **not** wrap Cubic in automation (upstream is GUI-first). Use **`scripts/prepare-chiaplots-cubic.sh`** to stage **`plotpoll.sh`** and a short **`README.txt`** / **`chroot-commands.example.sh`** next to your Cubic work.

### Kernel packages for the chroot

Inside Cubic’s environment, install this tree as normal **Debian kernel packages** (modules included), not a raw **`vmlinuz`** copy:

```bash
cd /path/to/linux
fakeroot make -j"$(nproc)" bindeb-pkg
```

Packages are written to the **parent directory** of the kernel source. Copy **`linux-image-*.deb`** and **`linux-modules-*.deb`** into the Cubic chroot (e.g. **`/tmp`**) and install with **`apt install -y ./linux-image-*.deb ./linux-modules-*.deb`** (or **`dpkg -i`** then **`apt -f install`**).

Optional: **`RUN_BINDEB=1 OUTPUT_BINDEB_COPY=1 ./scripts/prepare-chiaplots-cubic.sh . ./staging`** runs **`bindeb-pkg`** and copies matching **`linux-image` / `linux-modules`** **`.deb`** files into **`./staging`** (slow; requires full **`.deb`** build dependencies).

### Stage helper and Cubic install

```bash
./scripts/prepare-chiaplots-cubic.sh . /path/to/staging-dir
```

On Ubuntu, install Cubic (see **`staging-dir/README.txt`** for the current PPA pattern: **`ppa:cubic-wizard/release`**).

### What you add in the Cubic chroot

| Step | Action |
|------|--------|
| Kernel | Install **`linux-image-*.deb`** / **`linux-modules-*.deb`** from **`bindeb-pkg`**, then **`update-initramfs -u -k all`** if needed. |
| **`plotpoll.sh`** | **`install -m 0755 …/plotpoll.sh /usr/local/bin/plotpoll.sh`** |
| **`/.chiaplots`** | **`mkdir -p /.chiaplots && chmod 0777 /.chiaplots`** |

### Live session vs installed system

Ubuntu **live** images use **casper** and an **overlay**; that is not the same as a long-term **ext4** root. **chiaplots** behavior that depends on **`/`** being the real **ext4** superblock is best validated **after installing** the customized system to a disk (or on any normal **ext4** root), not only on the live desktop.

### Prerequisites

1. **Configure and build** this kernel tree enough to produce **`bindeb-pkg`** (install your distro’s kernel build dependencies, including **`fakeroot`** for **`bindeb-pkg`**).
2. **Host:** Ubuntu with **Cubic** and enough disk space for the ISO project.
3. **`plotpoll.sh`** at the repository root (same as **`LINUX_SRC`** when **`LINUX_SRC`** is **`.`**).

---

## Rationale for **`sb_sample_vfsmnt()`**

Eviction and statfs summing need a **`vfsmount`** without a user path. **`sb_sample_vfsmnt()`** returns a referenced mount for **`sb`**, preferring **`mnt_root == sb->s_root`** so **`dentry_open`** on dentries under the filesystem root works; among those it prefers **read-write** mounts so **`mnt_want_write()`** succeeds when a read-only bind shadows a writable root mount.
