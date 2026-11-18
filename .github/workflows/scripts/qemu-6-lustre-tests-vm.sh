#!/usr/bin/env bash

######################################################################
# 6) Test if Lustre can still build against ZFS
######################################################################
set -e

# Build from the latest Lustre tag rather than the master branch.  We do this
# under the assumption that master is going to have a lot of churn thus will be
# more prone to breaking the build than a point release.  We don't want ZFS
# PR's reporting bad test results simply because upstream Lustre accidentally
# broke their build.
#
# Skip any RC tags, or any tags where the last version digit is 50 or more.
# Versions with 50 or more are development versions of Lustre.
repo=https://github.com/lustre/lustre-release.git
tag="$(git ls-remote --refs --exit-code --sort=version:refname --tags $repo | \
	awk -F '_' '/-RC/{next}; /refs\/tags\/v/{if ($NF < 50){print}}' | \
	tail -n 1 | sed 's/.*\///')"

echo "Cloning Lustre tag $tag"
git clone --depth 1 --branch "$tag" "$repo"

cd lustre-release

# Include Lustre patches to build against master/zfs-2.4.x.  Once these
# patches are merged we can remove these lines.
#
# LU-19539 osd-zfs: use osd_dmu_write() wrapper for xattrs
# LU-19761 osd-zfs: Build against ZFS 2.4.0
# LU-19249 build: Compatibility updates for kernel v6.16 (b2_17 backport)
# LU-19459 build: Compatability updates for kernel v6.17
# LU-19249 osd-zfs: support kernel v6.16
#
patches=('https://review.whamcloud.com/changes/fs%2Flustre-release~62101/revisions/2/patch?download'
	'https://review.whamcloud.com/changes/fs%2Flustre-release~63267/revisions/9/patch?download'
	'https://review.whamcloud.com/changes/fs%2Flustre-release~66224/revisions/4/patch?download'
	'https://review.whamcloud.com/changes/fs%2Flustre-release~61767/revisions/14/patch?download'
	'https://review.whamcloud.com/changes/fs%2Flustre-release~65188/revisions/2/patch?download')

for p in "${patches[@]}" ; do
	curl $p | base64 -d > patch
	patch -p1 < patch || true
done

# LU-20373 build: Compatibility updates for kernel v7.1
#
# Linux 7.1 made the d_u union in struct dentry anonymous, so d_alias is now
# named directly (ZFS handles this in config/kernel-dentry-alias.m4).  EL 9.9
# kernels (5.14.0-741 and later) carry the change.  The Lustre fix (change
# 66662) does not apply to the 2.17.0 tag, so make its d_alias rename here.
# This can be removed once a Lustre release includes that fix.
dcache_h="/lib/modules/$(uname -r)/build/include/linux/dcache.h"
if [ -f "$dcache_h" ] && ! grep -Eq '^\s*}\s*d_u;' "$dcache_h" ; then
	echo "Kernel struct dentry has no d_u union, using d_alias directly"
	sed -i 's/d_u\.d_alias/d_alias/' lustre/llite/dcache.c \
	    lustre/llite/namei.c
fi

# LU-19459 build: Compatability updates for kernel v6.17
#
# One hunk of change 61767, for ll_write_end() in lustre/llite/rw26.c, does
# not apply to the 2.17.0 tag (the variable names differ), so make it here:
# kernels with HAVE_WRITE_BEGIN_KIOCB, such as EL 10.3 (6.12.0-264 and later),
# pass ->write_end() a kiocb instead of a file.
sed -i '/^static int ll_write_end(struct file \*file, /,/^{$/{
	s/^static int ll_write_end(struct file \*file, /static int ll_write_end(\n#ifdef HAVE_WRITE_BEGIN_KIOCB\n\t\t\tconst struct kiocb *kiocb,\n#else\n\t\t\tstruct file *file,\n#endif\n\t\t\t/
	s/^{$/{\n#ifdef HAVE_WRITE_BEGIN_KIOCB\n\tstruct file *file = kiocb->ki_filp;\n#endif/
}' lustre/llite/rw26.c

# LU-20739 build: check vfs_mkdir() and can_mmap_file() alone
#
# EL 10.3 changes inode_operations.mkdir to return a dentry, but vfs_mkdir()
# still returns an int, so ll_vfs_mkdir() must not be keyed on
# HAVE_IOPS_MKDIR_RETURNS_DENTRY there.  The Lustre fix (change 71053) is for
# master and does not apply to the 2.17.0 tag, so make its ll_vfs_mkdir()
# change here.  This can be removed once a Lustre release includes that fix.
fs_h="/lib/modules/$(uname -r)/build/include/linux/fs.h"
if [ -f "$fs_h" ] && grep -q '^int vfs_mkdir(' "$fs_h" ; then
	echo "Kernel vfs_mkdir() returns int, keying ll_vfs_mkdir() on that"
	sed -i '/^#ifdef HAVE_IOPS_MKDIR_RETURNS_DENTRY$/{
		N
		s/^#ifdef HAVE_IOPS_MKDIR_RETURNS_DENTRY\n#define ll_vfs_mkdir/#ifdef HAVE_VFS_MKDIR_RETURNS_DENTRY\n#define ll_vfs_mkdir/
	}' lustre/include/lustre_compat.h
fi

echo "Configure Lustre"
./autogen.sh
# EL 9 needs '--disable-gss-keyring'
./configure --with-zfs --disable-gss-keyring
echo "Building Lustre RPMs"
make rpms
ls *.rpm

# There's only a handful of Lustre RPMs we actually need to install
lustrerpms="$(ls *.rpm | grep -E 'kmod-lustre-osd-zfs-[0-9]|kmod-lustre-[0-9]|lustre-osd-zfs-mount-[0-9]')"
echo "Installing: $lustrerpms"
sudo dnf -y install $lustrerpms
sudo modprobe -v lustre

# Should see some Lustre lines in dmesg
sudo dmesg | grep -Ei 'lnet|lustre'
