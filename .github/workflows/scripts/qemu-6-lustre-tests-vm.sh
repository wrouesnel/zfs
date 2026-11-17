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
# LU-19249 build: Compatibility updates for kernel v6.16
#
patches=('https://review.whamcloud.com/changes/fs%2Flustre-release~62101/revisions/2/patch?download'
	'https://review.whamcloud.com/changes/fs%2Flustre-release~63267/revisions/9/patch?download'
	'https://review.whamcloud.com/changes/fs%2Flustre-release~60619/revisions/13/patch?download')

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
