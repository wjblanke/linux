# Root `.chiaplots` handling (ext4)

This note describes optional behavior added for a directory named `.chiaplots` at the **filesystem root** (i.e. the root inode’s child `.chiaplots`, not deeper paths).

## Overview

1. **statfs / free-space reporting**  
   Disk blocks used by **regular files** directly inside `/.chiaplots` are added back into the reported free block counts (`f_bfree`, `f_bavail`), capped so totals never exceed `f_blocks`.  
   Physically those blocks remain allocated; this only affects what `statfs()` (and thus tools like `df`) report.

2. **Automatic eviction on allocation failure**  
   When the allocator would fail with **ENOSPC** because not enough clusters are free, the filesystem tries to delete **regular files** in `/.chiaplots`, removing the **first regular file** encountered in each directory scan (readdir order), until either enough space is available for the pending reservation/allocation or nothing removable remains.  
   Read-only mounts skip eviction.

## Implementation map

| Area | Change |
|------|--------|
| `fs/namespace.c` | Adds `sb_sample_vfsmnt()` — returns any `vfsmount` referencing the given `super_block` so kernel code can open paths without a user pathname. |
| `fs/ext4/chiaplots.c` | Implements scanning `/.chiaplots`, statfs adjustment, and eviction (`vfs_unlink`). |
| `fs/ext4/balloc.c` | `ext4_has_free_clusters()` is no longer `static` so eviction can re-check free space. |
| `fs/ext4/super.c` | After filling `kstatfs`, calls `ext4_chiaplots_adjust_statfs()`. |
| `fs/ext4/inode.c` | Before reserving clusters for delayed allocation, calls `ext4_chiaplots_try_make_space()` (must run **before** taking `i_block_reservation_lock`; eviction may sleep). |
| `fs/ext4/mballoc.c` | Before the existing `ext4_claim_free_clusters()` loop, calls `ext4_chiaplots_try_make_space()`. |
| `fs/ext4/Makefile` | Builds `chiaplots.o`. |
| `fs/ext4/ext4.h` | Declarations for the helpers above and `ext4_has_free_clusters()`. |

## Limits and semantics

- Only the directory **`/<mount-root>/.chiaplots`** is considered (single path segment `.chiaplots` under the ext4 root dentry).
- Eviction scans at most **128** directory entries per pass; if there are more files, only that subset is visible to each eviction pass, so the “first” file is the first regular file among those entries in readdir order.
- Statfs aggregation walks directory entries and uses `ext4_iget()` per inode number; large directories may make `statfs` heavier than usual.
- Eviction uses the same permission and unlink paths as normal `unlink`; failures (permissions, immutable attributes, etc.) stop the eviction loop for that allocation attempt.

## Rationale for `sb_sample_vfsmnt`

`statfs` and allocation helpers only receive a `super_block` or `ext4_sb_info`, not a `vfsmount`. Opening a directory with `dentry_open()` requires a valid `struct path` including a mount. `sb_sample_vfsmnt()` walks the superblock’s mount list (VFS-internal) and returns one referenced mount, which is enough to open `/.chiaplots` for iteration and unlink.
