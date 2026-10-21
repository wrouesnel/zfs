#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.
#


. $STF_SUITE/include/libtest.shlib

#
# DESCRIPTION:
# 'zpool create' and 'zpool import' must not mount a pool's root file
# system that has canmount=noauto, as for any other file system with
# canmount=noauto.  Its children with canmount=on are still mounted, and
# the root can still be mounted explicitly (openzfs/zfs#18242).
#
# STRATEGY:
# 1. Create a pool with -O canmount=noauto: the root must not be mounted.
# 2. Create a child file system: it must be mounted.
# 3. Export and import the pool: the root must not be mounted, the child
#    must be.
# 4. With the child unmounted, 'zfs mount POOL' must mount the root.
#

verify_runnable "global"

typeset dir=$TEST_BASE_DIR/import_root_noauto
typeset pool=root_noauto

function cleanup
{
	poolexists $pool && destroy_pool $pool
	rm -rf $dir
}

log_onexit cleanup

log_assert "zpool create and import honour canmount=noauto on the root"

log_must mkdir -p $dir
log_must truncate -s $MINVDEVSIZE $dir/vdev
log_must zpool create -O canmount=noauto -O mountpoint=$dir/mnt \
    $pool $dir/vdev
log_must eval "[[ $(get_prop canmount $pool) == noauto ]]"
ismounted $pool && log_fail "zpool create mounted the noauto root $pool"

log_must zfs create $pool/child
log_must ismounted $pool/child

log_must zpool export $pool
log_must zpool import -d $dir $pool
ismounted $pool && log_fail "zpool import mounted the noauto root $pool"
log_must ismounted $pool/child

# Unmount the child first: mounting the root over it would hide it.
log_must zfs unmount $pool/child
log_must zfs mount $pool
log_must ismounted $pool

log_pass "zpool create and import honour canmount=noauto on the root"
