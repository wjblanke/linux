# Root `.chiaplots` handling (ext4)

This note describes optional behavior for a directory named `.chiaplots` at the **filesystem root** (the root inode’s child `.chiaplots`, not deeper paths).

## Overview

1. **statfs / free-space reporting**  
   Disk blocks used by **regular files** directly inside `/.chiaplots` are added back into the reported free block counts (`f_bfree`, `f_bavail`), capped so totals never exceed `f_blocks`.  
   Physically those blocks remain allocated; this only affects what `statfs()` (and thus tools like `df`) report.

2. **No new entries via “copy” APIs**  
   Creating a **new** name inside `/.chiaplots` or any subdirectory (`create`, `mkdir`, `mknod`, `symlink`, `link`, `tmpfile`) returns **-EPERM**.  
   **`rename`** (same-filesystem `mv`) is unchanged: existing inodes can be moved into or within `.chiaplots` without creating a new inode.  
   Cross-filesystem “mv” is implemented as copy+unlink in userland and still hits **create** on the destination — blocked when the destination path is under `.chiaplots`.

3. **Proactive eviction with a 1 GiB headroom**  
   Eviction does **not** wait for ENOSPC. On every allocation hook the filesystem checks whether free clusters fall below the request **plus a 1 GiB margin** (`CHIAPLOTS_MARGIN_BYTES` in `fs/ext4/chiaplots.c`). When they do, regular files in `/.chiaplots` are unlinked **first regular file in readdir order**, repeating until the headroom is restored or nothing removable remains. The same path also fires when the free-inode counter hits zero.  
   Delayed allocation reserves quota **after** this eviction so deleting plot files can satisfy `dquot_reserve_block` for the same user.  
   If **mballoc** still cannot place blocks while counters show free space (fragmentation), up to three **forced** evictions (one file each, ignoring the headroom check) run before final **ENOSPC**.  
   **EDQUOT** after cluster reservation retries up to three forced evictions before failing.  
   Read-only mounts and fast-commit replay skip eviction.

   To change the headroom edit `CHIAPLOTS_MARGIN_BYTES` and rebuild; setting it to `0` reverts to the previous “evict only on real ENOSPC” behaviour.

## Implementation map

| Area | Change |
|------|--------|
| `fs/namespace.c` | Adds `sb_sample_vfsmnt()` for eviction paths that need a `vfsmount`. |
| `fs/ext4/chiaplots.c` | `ext4_is_parent_in_chiaplots_subtree()`, statfs adjustment, eviction. |
| `fs/ext4/namei.c` | Deny create-like operations under `.chiaplots` (`-EPERM`). |
| `fs/ext4/balloc.c` | `ext4_has_free_clusters()` is not `static` so eviction can re-check free space. |
| `fs/ext4/super.c` | After filling `kstatfs`, calls `ext4_chiaplots_adjust_statfs()`. |
| `fs/ext4/inode.c` | Runs `ext4_chiaplots_try_make_space()` **before** `dquot_reserve_block()` for delayed allocation. |
| `fs/ext4/ialloc.c` | At the start of inode allocation, calls `ext4_chiaplots_try_make_space(sbi, 1, 0)` so low cluster pressure can trigger eviction before inode-group placement heuristics fail. |
| `fs/ext4/mballoc.c` | Before `ext4_claim_free_clusters()`, calls `ext4_chiaplots_try_make_space()`; `ext4_chiaplots_force_evict()` on quota failure and when the regular allocator returns no space despite reservation. |
| `fs/ext4/Makefile` | Builds `chiaplots.o`. |
| `fs/ext4/ext4.h` | Declarations for chiaplots helpers and `ext4_has_free_clusters()`. |

## Limits and semantics

- Path recognition walks dentry parents and matches the root-level name **`.chiaplots`** (case-sensitive). Encrypted or casefolded directory names may not match.
- Only **`/<mount-root>/.chiaplots`** and its subtree are affected.
- Eviction scans at most **128** directory entries per pass.
- Eviction runs **enumerate + unlink** under **`kernel_cred()`** (`init_task`’s subjective cred) so a mode **`0700`** `/.chiaplots` does not block eviction when the allocating task is unprivileged (DAC would otherwise return **EACCES** from `dentry_open`). LSM (SELinux/AppArmor) may still deny.
- Eviction uses normal `vfs_unlink`; failures stop the eviction loop for that allocation attempt.

## Rationale for `sb_sample_vfsmnt`

Eviction needs to open `/.chiaplots` without a user-supplied path. `sb_sample_vfsmnt()` returns a referenced `vfsmount`, preferring `mnt_root == sb->s_root` so `dentry_open()` works for dentries under the filesystem root; among those it prefers a mount that is **not** read-only so `mnt_want_write()` succeeds when multiple mounts exist (e.g. RO bind over RW root).
