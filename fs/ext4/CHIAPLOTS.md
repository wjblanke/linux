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

3. **Automatic eviction on allocation failure**  
   When the allocator would fail with **ENOSPC** because not enough clusters are free, *or* there are no free inodes left, the filesystem tries to delete **regular files** in `/.chiaplots`, removing the **first regular file** encountered in each directory scan (readdir order), until either enough space/inodes are available for the pending reservation/allocation or nothing removable remains.  
   Delayed allocation reserves quota **after** this eviction so deleting plot files can satisfy `dquot_reserve_block` for the same user.  
   If **mballoc** still cannot place blocks while counters show free space (fragmentation), up to three **forced** evictions (ignoring the global “starved” check) run before final **ENOSPC**.  
   **EDQUOT** after cluster reservation retries up to three forced evictions before failing.  
   Read-only mounts and fast-commit replay skip eviction.

## Implementation map

| Area | Change |
|------|--------|
| `fs/namespace.c` | Adds `sb_sample_vfsmnt()` for eviction paths that need a `vfsmount`. |
| `fs/ext4/chiaplots.c` | `ext4_is_parent_in_chiaplots_subtree()`, statfs adjustment, eviction. |
| `fs/ext4/namei.c` | Deny create-like operations under `.chiaplots` (`-EPERM`). |
| `fs/ext4/balloc.c` | `ext4_has_free_clusters()` is not `static` so eviction can re-check free space. |
| `fs/ext4/super.c` | After filling `kstatfs`, calls `ext4_chiaplots_adjust_statfs()`. |
| `fs/ext4/inode.c` | Runs `ext4_chiaplots_try_make_space()` **before** `dquot_reserve_block()` for delayed allocation. |
| `fs/ext4/ialloc.c` | At the start of inode allocation, calls `ext4_chiaplots_try_make_space(sbi, 0, 0)` (no cluster reservation); eviction runs only if the free-inode counter is zero. |
| `fs/ext4/mballoc.c` | Before `ext4_claim_free_clusters()`, calls `ext4_chiaplots_try_make_space()`; `ext4_chiaplots_force_evict()` on quota failure and when the regular allocator returns no space despite reservation. |
| `fs/ext4/Makefile` | Builds `chiaplots.o`. |
| `fs/ext4/ext4.h` | Declarations for chiaplots helpers and `ext4_has_free_clusters()`. |

## Limits and semantics

- Path recognition walks dentry parents and matches the root-level name **`.chiaplots`** (case-sensitive). Encrypted or casefolded directory names may not match.
- Only **`/<mount-root>/.chiaplots`** and its subtree are affected.
- Eviction scans at most **128** directory entries per pass.
- Eviction uses normal `vfs_unlink`; failures stop the eviction loop for that allocation attempt.

## Rationale for `sb_sample_vfsmnt`

Eviction needs to open `/.chiaplots` without a user-supplied path. `sb_sample_vfsmnt()` returns a referenced `vfsmount`, preferring `mnt_root == sb->s_root` so `dentry_open()` works for dentries under the filesystem root.
