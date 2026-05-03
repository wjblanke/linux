// SPDX-License-Identifier: GPL-2.0
/*
 * Optional Chia plot directory handling: root /.chiaplots
 */

#include <linux/dcache.h>
#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/mount.h>
#include <linux/mnt_idmapping.h>
#include <linux/namei.h>
#include <linux/readdir.h>
#include "ext4.h"

#define CHIAPLOTS_DIR ".chiaplots"
#define CHIAPLOTS_MAX_NAMES 128

struct vfsmount *sb_sample_vfsmnt(struct super_block *sb);

struct chi_sum_ctx {
	struct dir_context ctx;
	struct super_block *sb;
	u64 sum_fsblocks;
};

static bool chi_sum_actor(struct dir_context *ctx, const char *name, int namlen,
			  loff_t offset, u64 ino, unsigned int dtype)
{
	struct chi_sum_ctx *s = container_of(ctx, struct chi_sum_ctx, ctx);
	struct inode *inode;

	(void)offset;
	(void)dtype;

	if (namlen <= 2 && name[0] == '.' &&
	    (namlen == 1 || (namlen == 2 && name[1] == '.')))
		return true;
	if (namlen > EXT4_NAME_LEN)
		return true;

	inode = ext4_iget(s->sb, ino, EXT4_IGET_NORMAL);
	if (IS_ERR(inode))
		return true;
	if (S_ISREG(inode->i_mode))
		s->sum_fsblocks += (u64)inode->i_blocks >>
				   (inode->i_sb->s_blocksize_bits - 9);
	iput(inode);
	return true;
}

static u64 ext4_chiaplots_sum_fsblocks(struct super_block *sb)
{
	struct vfsmount *mnt;
	struct dentry *chi;
	struct path path;
	struct file *dirf;
	struct chi_sum_ctx sctx;
	int err;

	mnt = sb_sample_vfsmnt(sb);
	if (IS_ERR(mnt))
		return 0;

	chi = lookup_one_unlocked(&nop_mnt_idmap,
				  &QSTR_LEN(CHIAPLOTS_DIR, sizeof(CHIAPLOTS_DIR) - 1),
				  sb->s_root);
	if (IS_ERR(chi)) {
		mntput(mnt);
		return 0;
	}
	if (!d_is_positive(chi) || !d_is_dir(chi)) {
		dput(chi);
		mntput(mnt);
		return 0;
	}

	path.mnt = mnt;
	path.dentry = chi;
	dirf = dentry_open(&path, O_RDONLY | O_NOATIME | O_DIRECTORY,
			   current_cred());
	dput(chi);
	mntput(mnt);
	if (IS_ERR(dirf))
		return 0;

	memset(&sctx, 0, sizeof(sctx));
	sctx.ctx.actor = chi_sum_actor;
	sctx.sb = sb;
	err = iterate_dir(dirf, &sctx.ctx);
	fput(dirf);
	if (err)
		return 0;
	return sctx.sum_fsblocks;
}

void ext4_chiaplots_adjust_statfs(struct super_block *sb, struct kstatfs *buf)
{
	struct ext4_sb_info *sbi = EXT4_SB(sb);
	struct ext4_super_block *es = sbi->s_es;
	ext4_fsblk_t resv_blocks = EXT4_C2B(sbi, atomic64_read(&sbi->s_resv_clusters));
	u64 extra = ext4_chiaplots_sum_fsblocks(sb);

	if (!extra)
		return;

	buf->f_bfree = min_t(u64, (u64)buf->f_bfree + extra, buf->f_blocks);
	buf->f_bavail = buf->f_bfree -
			(ext4_r_blocks_count(es) + resv_blocks);
	if (buf->f_bfree < (ext4_r_blocks_count(es) + resv_blocks))
		buf->f_bavail = 0;
}

struct chi_names_ctx {
	struct dir_context ctx;
	unsigned long inos[CHIAPLOTS_MAX_NAMES];
	char names[CHIAPLOTS_MAX_NAMES][EXT4_NAME_LEN + 1];
	int n;
};

static bool chi_names_actor(struct dir_context *ctx, const char *name, int namlen,
			    loff_t offset, u64 ino, unsigned int dtype)
{
	struct chi_names_ctx *c = container_of(ctx, struct chi_names_ctx, ctx);

	(void)offset;
	(void)dtype;

	if (namlen <= 2 && name[0] == '.' &&
	    (namlen == 1 || (namlen == 2 && name[1] == '.')))
		return true;
	if (namlen > EXT4_NAME_LEN)
		return true;
	if (c->n >= CHIAPLOTS_MAX_NAMES)
		return false;
	memcpy(c->names[c->n], name, namlen);
	c->names[c->n][namlen] = '\0';
	c->inos[c->n] = ino;
	c->n++;
	return true;
}

static int ext4_chiaplots_evict_one(struct super_block *sb)
{
	struct vfsmount *mnt;
	struct dentry *chi;
	struct path path;
	struct file *dirf;
	struct chi_names_ctx nctx;
	int i, err, best = -1;
	struct dentry *victim;

	mnt = sb_sample_vfsmnt(sb);
	if (IS_ERR(mnt))
		return PTR_ERR(mnt);

	chi = lookup_one_unlocked(&nop_mnt_idmap,
				  &QSTR_LEN(CHIAPLOTS_DIR, sizeof(CHIAPLOTS_DIR) - 1),
				  sb->s_root);
	if (IS_ERR(chi)) {
		err = PTR_ERR(chi);
		goto out_mnt;
	}
	if (!d_is_positive(chi) || !d_is_dir(chi)) {
		dput(chi);
		err = -ENOENT;
		goto out_mnt;
	}

	path.mnt = mnt;
	path.dentry = chi;
	dirf = dentry_open(&path, O_RDONLY | O_NOATIME | O_DIRECTORY,
			   current_cred());
	dput(chi);
	if (IS_ERR(dirf)) {
		err = PTR_ERR(dirf);
		goto out_mnt;
	}

	memset(&nctx, 0, sizeof(nctx));
	nctx.ctx.actor = chi_names_actor;
	err = iterate_dir(dirf, &nctx.ctx);
	fput(dirf);
	if (err)
		goto out_mnt;
	if (!nctx.n) {
		err = -ENOENT;
		goto out_mnt;
	}

	for (i = 0; i < nctx.n; i++) {
		struct inode *inode =
			ext4_iget(sb, nctx.inos[i], EXT4_IGET_NORMAL);

		if (IS_ERR(inode))
			continue;
		if (S_ISREG(inode->i_mode)) {
			best = i;
			iput(inode);
			break;
		}
		iput(inode);
	}
	if (best < 0) {
		err = -ENOENT;
		goto out_mnt;
	}

	err = mnt_want_write(mnt);
	if (err)
		goto out_mnt;

	chi = lookup_one_unlocked(&nop_mnt_idmap,
				  &QSTR_LEN(CHIAPLOTS_DIR, sizeof(CHIAPLOTS_DIR) - 1),
				  sb->s_root);
	if (IS_ERR(chi)) {
		err = PTR_ERR(chi);
		goto out_drop_write;
	}
	if (!d_is_positive(chi) || !d_is_dir(chi)) {
		dput(chi);
		err = -ENOENT;
		goto out_drop_write;
	}

	inode_lock(chi->d_inode);
	victim = lookup_one(&nop_mnt_idmap,
			    &QSTR_LEN(nctx.names[best], strlen(nctx.names[best])),
			    chi);
	if (IS_ERR(victim)) {
		err = PTR_ERR(victim);
		inode_unlock(chi->d_inode);
		dput(chi);
		goto out_drop_write;
	}
	if (!d_is_positive(victim)) {
		dput(victim);
		inode_unlock(chi->d_inode);
		dput(chi);
		err = -ENOENT;
		goto out_drop_write;
	}

	err = vfs_unlink(mnt_idmap(mnt), d_inode(chi), victim, NULL);
	dput(victim);
	inode_unlock(chi->d_inode);
	dput(chi);

out_drop_write:
	mnt_drop_write(mnt);
out_mnt:
	mntput(mnt);
	return err;
}

void ext4_chiaplots_try_make_space(struct ext4_sb_info *sbi, s64 nclusters,
				   unsigned int flags)
{
	struct super_block *sb = sbi->s_sb;

	if (!sb || sb_rdonly(sb))
		return;

	while (!ext4_has_free_clusters(sbi, nclusters, flags)) {
		int err = ext4_chiaplots_evict_one(sb);

		if (err)
			break;
		cond_resched();
	}
}
