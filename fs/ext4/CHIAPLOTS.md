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
| **Diagnostics** | **`pr_warn_ratelimited("ext4 chiaplots[%s]: …")`** around eviction / **`try_make_space`** / **`force_evict`**. Use **`dmesg`** / **`journalctl -k`** (grep **`chiaplots`**). |
| **Userland helper** | Repo root **`makeplots.sh`**: fills **`./plots`** with fixed-size files until ENOSPC, then **`mv`** into **`/.chiaplots`**—does **not** **`mkdir`** the destination; it must already exist. |

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

Messages are **ratelimited**; bursts may be suppressed.

---

## Build Linux from GitHub source

Use this flow to build and boot a kernel from this fork (or any Linux GitHub tree).

### 1. Install build dependencies (Debian/Ubuntu example)

```bash
sudo apt update
sudo apt install git build-essential libncurses-dev bison flex libssl-dev libelf-dev libdw-dev
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

## Rationale for **`sb_sample_vfsmnt()`**

Eviction and statfs summing need a **`vfsmount`** without a user path. **`sb_sample_vfsmnt()`** returns a referenced mount for **`sb`**, preferring **`mnt_root == sb->s_root`** so **`dentry_open`** on dentries under the filesystem root works; among those it prefers **read-write** mounts so **`mnt_want_write()`** succeeds when a read-only bind shadows a writable root mount.
