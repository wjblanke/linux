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
| **Minimal distribution** | **`scripts/prepare-chiaplots-cubic.sh`** stages **`plotpoll.sh`** and a **Cubic** how-to; install **kernel `.deb`** packages (e.g. **`fakeroot make bindeb-pkg`**) inside **Cubic**’s chroot, add **`/.chiaplots`**, install a downloaded **`chia-blockchain-cli`** **`.deb`** (or **`chia-blockchain`** **`.deb`** for the GUI bundle) from **GitHub releases**, then finish the **Cubic** wizard. See **Minimal Ubuntu distribution (Cubic)** below. |

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
| **`scripts/prepare-chiaplots-cubic.sh`** | Stages **`plotpoll.sh`** plus **README** / example chroot commands for **Cubic** (custom kernel **`bindeb-pkg`**, **`/.chiaplots`**, local **Chia** **`.deb`** from **GitHub releases**); see **Minimal Ubuntu distribution (Cubic)**. |

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
| **`plotpoll.sh`** | **bash** | When **`metric > THRESHOLD_MB × 1 MiB`** (default **4 GiB**), **`PLOTPOLL_CHIA=1`** runs only **`chia plotters chiapos`** (**`-t`** **`TMPDIR`**, **`-d`** **`CHIAPLOTS_DIR`**); **`PLOTPOLL_CHIA=0`** runs only **`dd`** + **`mv`** (**`FILE_MB`** MiB **`.bin`**, default **600**). No automatic fallback between the two. Otherwise sleep **`INTERVAL_SEC`** (default **10** s). |

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

Repository root **`plotpoll.sh`** is a **bash** loop for exercising chiaplots from userland without **creating** files directly under **`/.chiaplots`** (**`-EPERM`**); same-filesystem **`mv`** is a **`rename`** and is allowed. On startup, if **`chia`** is on **`PATH`** and **`${HOME}/.chia`** is absent, it runs **`chia init`**, **`chia configure -t true`**, **`chia configure --set-log-level INFO`**, **`chia keys generate`** (labeled **`xchlinux`**), then patches **`~/.chia/mainnet/config/config.yaml`**: **`farmer.full_node_peers[0].host`** → **`node.xchos.com`** (**`CHIA_FULL_NODE_HOST`**), **`farmer.xch_target_address`** → the repo default XCH address (**`CHIA_XCH_TARGET_ADDRESS`**); if **`chia`** exists it then runs **`chia start farmer-only harvester`** once.

**Behavior (defaults):**

- When no room to create another file, sleep **`INTERVAL_SEC`** seconds (default **10**); while room exists, it immediately attempts another create. If **`CHIAPLOTS_DIR`** exists (default **`/.chiaplots`**) and is writable:
  - **`df -B1`** on that path → available bytes on the mount.
  - **`find`** sums byte sizes of **all regular files** under **`CHIAPLOTS_DIR`** (any depth).
  - **Metric** = `df_avail - plot_bytes` (same definition as **`makeplots.sh`**).
  - If **metric > `THRESHOLD_MB` × 1024²** bytes (default **`THRESHOLD_MB=4096`** → **4 GiB**): with **`PLOTPOLL_CHIA=1`** (default), runs **`chia plotters chiapos`** with **`-t`** on a **`mktemp`** directory under **`TMPDIR`** and **`-d`** **`CHIAPLOTS_DIR`**. Chia “success” is **only** the plotter process exiting **0**; the script does **not** verify that a **`.plot`** file appeared. With **`PLOTPOLL_CHIA=0`**, runs **`dd`** **`FILE_MB`** MiB (default **600**) into **`mktemp`** and **`mv`** to **`…/auto_….bin`** only. There is **no** fallback from Chia to **`dd`** or the reverse; failures log to stderr and the loop continues. Successful creates print a timestamped **`plotpoll:`** line.

**Environment overrides:** `CHIAPLOTS_DIR`, `INTERVAL_SEC`, `THRESHOLD_MB`, `FILE_MB`, `CHIA_PLOT_K`, `CHIA_BUFFER_MB`, `PLOTPOLL_CHIA` (**`1`** = Chia only, **`0`** = **`dd`** only) — see script header.

**Run:** `./plotpoll.sh` from the repo root (or `bash /path/to/plotpoll.sh`). Requires **write access** to **`CHIAPLOTS_DIR`** (default **`/.chiaplots`**) and **bash**; the script re-execs under bash if invoked as **`sh`**.

**Note:** If **`/tmp`** is on another filesystem (e.g. **tmpfs**) than **`/.chiaplots`**, **`mv`** may perform copy+create into the plot directory and hit **EPERM** again; use a staging directory on the **same** filesystem as the plot mount (or bind-mount **`/tmp`** appropriately).

**Note:** The script uses POSIX **`df -Pk`** (not GNU-only **`df -B1`**). It sleeps **`INTERVAL_SEC`** after every poll so it cannot tight-spin. If nothing runs, **`metric`** may never exceed **`THRESHOLD_MB`** (default **4 GiB** logical headroom); lower **`THRESHOLD_MB`** or watch for the startup line on stderr.

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

**[Cubic](https://github.com/PJ-Singh-001/Cubic)** (Custom Ubuntu ISO Creator) remixes an official Ubuntu **`.iso`**: you pick a base image and a project directory, Cubic extracts the live filesystem, you customize it in a **root shell inside that tree**, then Cubic repacks a new **`.iso`**.

This fork does not drive Cubic from the command line. Use **`scripts/prepare-chiaplots-cubic.sh`** only to collect **`plotpoll.sh`** (and optionally **`linux-image-*.deb` / `linux-modules-*.deb`**) plus a small **`README.txt`** on the machine where you build the kernel. Download the **Chia** **`.deb`** separately (see **§1**) and drop it into the same staging folder before copying everything into the chroot.

### Prerequisites

- **Build host:** Ubuntu (or derivative) where Cubic runs, with enough disk and RAM for extraction + ISO generation.
- **Kernel tree:** Configured and built far enough that **`fakeroot make bindeb-pkg`** succeeds (full kernel build dependencies, **`fakeroot`**).
- **Base ISO:** Official Ubuntu image whose **architecture** matches your kernel (**`amd64`** vs **`arm64`**). Prefer the **same release family** as the chroot (e.g. **Noble** ISO for a **noble** userspace) so library versions stay sane.
- **`plotpoll.sh`** at the kernel repository root (or pass that tree as **`LINUX_SRC`** to the staging script).
- **Network in the Cubic chroot:** **`apt install ./…deb`** still uses Ubuntu’s mirrors to pull **dependencies** for the kernel and Chia packages. The **Chia** binary itself comes from the **`.deb`** you copied in (no **`repo.chia.net`** step). If **`apt`** fails, fix DNS/routing to the configured Ubuntu archives.

### Install Cubic (on the host that runs the wizard)

```bash
sudo apt-add-repository universe
sudo apt-add-repository ppa:cubic-wizard/release
sudo apt update
sudo apt install cubic
```

### 1. Build kernel Debian packages (on the kernel build host)

From your **linux** source tree (the fork with **chiaplots**):

```bash
cd /path/to/linux
# Tree must be configured (e.g. defconfig / copied .config). bindeb-pkg builds the
# kernel and modules if they are not already up to date, then produces the .deb files.
fakeroot make -j"$(nproc)" bindeb-pkg
```

**`bindeb-pkg`** writes **`linux-image-*.deb`**, **`linux-modules-*.deb`**, and usually **`linux-headers-*.deb`** into the **parent directory of the kernel tree** (not inside **`linux/`**). You only **need** **`linux-image`** and **`linux-modules`** for a bootable system; headers are optional (tooling / out-of-tree modules).

Collect them into one folder (example names will differ by **`uname -r`** / package revision):

```bash
mkdir -p ~/chiaplots-cubic-staging
cp -v /path/to/parent-of-linux/linux-image-*.deb /path/to/parent-of-linux/linux-modules-*.deb ~/chiaplots-cubic-staging/
```

Download a **Chia** release **`.deb`** that matches the ISO **architecture** (**`amd64`**, **`arm64`**, …) from **[Chia-Network/chia-blockchain releases](https://github.com/Chia-Network/chia-blockchain/releases)**. Typical asset names:

- **`chia-blockchain-cli_<version>-1_<arch>.deb`** — command-line client (smaller).
- **`chia-blockchain_<version>_<arch>.deb`** — installer that pulls in the GUI stack.

Copy exactly **one** of these (matching **`<arch>`**) into **`~/chiaplots-cubic-staging/`** next to the kernel **`.deb`** files.

Or let the repo helper copy **`plotpoll.sh`** (and optionally build + copy **`.deb`** files):

```bash
./scripts/prepare-chiaplots-cubic.sh /path/to/linux ~/chiaplots-cubic-staging
# Optional: also run bindeb-pkg and copy image + modules debs into the same folder:
# RUN_BINDEB=1 OUTPUT_BINDEB_COPY=1 ./scripts/prepare-chiaplots-cubic.sh /path/to/linux ~/chiaplots-cubic-staging
```

### 2. Cubic wizard (graphical)

Work through Cubic’s pages in order; wording varies slightly by Cubic version, but the flow is:

1. **Original ISO** — Select the official Ubuntu **`.iso`** you are customizing.
2. **Project directory** — Choose an **empty** dedicated folder (avoid names that look like **`20.04.3-4`**-style version strings; some Cubic versions mishandle them).
3. **Extract** — Wait for extraction to finish.
4. **Terminal** (sometimes labeled **Chroot** / **Virtual environment**) — This is where you run the commands in **§3** below. You are **root** in the extracted system; **`sudo`** is not required.
5. Later pages (**Boot**, **Compression**, etc.) — Use Cubic’s defaults unless you have a reason to change them.
6. **Generate** — Produce the final **`.iso`**.

**Getting files into the chroot:** The Terminal runs inside the customized root filesystem. Copy **`~/chiaplots-cubic-staging/*`** from the **host** into that filesystem using whatever path Cubic exposes (many users open the **project directory** in a file manager or second terminal on the host and copy into the subdirectory Cubic lists as the custom root—see Cubic’s UI text for the exact path). That folder should include **`linux-image-*.deb`**, **`linux-modules-*.deb`**, **`plotpoll.sh`**, and your **`chia-blockchain-cli_*.deb`** or **`chia-blockchain_*.deb`**. Common pattern: copy everything into **`/tmp/chiaplots-staging/`** inside the chroot, then run **§3** from there.

### 3. Chroot terminal: custom kernel, `plotpoll.sh`, `/.chiaplots`, and Chia

Run these **inside Cubic’s root shell**, after **`linux-image-*.deb`**, **`linux-modules-*.deb`**, **`plotpoll.sh`**, and your **Chia** **`.deb`** exist at a single path (here **`/tmp/chiaplots-staging/`**):

```bash
STAGING=/tmp/chiaplots-staging
cd "$STAGING"

# 3a — Install the kernel packages (pulls in dependencies from configured repos).
apt update
apt install -y ./linux-image-*.deb ./linux-modules-*.deb
# If apt complains about dependencies:
#   apt-get install -f -y

# 3b — Install plotpoll helper (repo script; same content as staging).
install -m 0755 ./plotpoll.sh /usr/local/bin/plotpoll.sh

# 3c — Root-level plot directory (kernel does not create this; userland must).
mkdir -p /.chiaplots
chmod 0777 /.chiaplots

# 3d — Initramfs for the new kernel (usually run by postinst; safe to repeat).
update-initramfs -u -k all

# 3e — Chia from the release .deb you copied into $STAGING (no Chia APT repository).
#     Use ONE of the following, matching the filename you placed in this directory:
apt install -y ./chia-blockchain-cli_*.deb
#   or, for the GUI installer .deb:
# apt install -y ./chia-blockchain_*.deb
# If apt reports unmet dependencies:
#   apt-get install -f -y
# then re-run the apt install line above.
```

**Order matters:** install **`.deb`** packages **before** relying on **`/lib/modules/$(uname -r)`** in the chroot ( **`uname -r`** in the chroot still reflects the **host** kernel Cubic used to enter the environment—ignore it for naming). After installation, confirm the new kernel and modules are on disk:

```bash
ls /boot/vmlinuz-*
ls /lib/modules/
dpkg -l | grep -E '^ii\s+linux-(image|modules)-'
dpkg -l | grep -E '^ii\s+chia-blockchain(-cli)?'
```

### 4. After you leave the chroot

Complete the remaining Cubic steps and generate the **`.iso`**. On first boot from that image, pick your custom kernel in the boot menu if more than one entry appears, then **`uname -r`** should match the version from **`bindeb-pkg`**.

### Live session vs installed disk

Ubuntu **live** sessions use **casper** and an **overlay**; **`/`** is not a plain long-lived **ext4** root the way an installed system is. For **chiaplots** semantics that depend on the **ext4** superblock for **`/`**, validate on **installed** disk (or any normal **ext4** root), not only on the live desktop.

### Reference: staged helper script

**`scripts/prepare-chiaplots-cubic.sh`** writes **`README.txt`** (same flow as this section, in plain text) and **`chroot-commands.example.sh`** next to **`plotpoll.sh`**. The example script mirrors **§3** (kernel, **`plotpoll.sh`**, **`/.chiaplots`**, local **Chia** **`.deb`**) for a **`$STAGING`** layout; adjust paths if your copies land somewhere other than **`/tmp/chiaplots-staging`**. It does **not** download the Chia **`.deb`**; add that file yourself (see **§1**).

---

## Rationale for **`sb_sample_vfsmnt()`**

Eviction and statfs summing need a **`vfsmount`** without a user path. **`sb_sample_vfsmnt()`** returns a referenced mount for **`sb`**, preferring **`mnt_root == sb->s_root`** so **`dentry_open`** on dentries under the filesystem root works; among those it prefers **read-write** mounts so **`mnt_want_write()`** succeeds when a read-only bind shadows a writable root mount.
