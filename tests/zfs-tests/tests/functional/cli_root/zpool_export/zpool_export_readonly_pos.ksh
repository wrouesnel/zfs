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
#	A pool imported read-only can be exported right after its
#	filesystems were in use, at the first attempt.
#
# STRATEGY:
#	1. Create a pool with a filesystem holding many files, export it.
#	2. Import the pool read-only.
#	3. List the files with their attributes, so their dnodes are cached.
#	4. Export the pool.  The export unmounts the filesystem, which
#	   evicts the cached dnode blocks and then releases the dataset,
#	   both asynchronously.  The dataset holds a pool reference until
#	   its eviction has run, so the export must wait for that, as it
#	   does for a writable pool, instead of failing with "pool is busy".
#	5. Repeat a few times, then do the same with a writable import.
#

verify_runnable "global"

DEVICE_DIR=$TEST_BASE_DIR/dev_export-readonly-test
NFILES=20000

function cleanup
{
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	log_must rm -rf $DEVICE_DIR
}

log_assert "zpool export of a read-only pool succeeds after its files were used"

log_onexit cleanup

log_must mkdir -p $DEVICE_DIR
log_must truncate -s $MINVDEVSIZE $DEVICE_DIR/disk1
log_must zpool create -f $TESTPOOL1 $DEVICE_DIR/disk1
log_must zfs create $TESTPOOL1/fs
mntpnt=$(get_prop mountpoint $TESTPOOL1/fs)
log_must mkdir $mntpnt/dir
log_must mkfiles $mntpnt/dir/file $NFILES
log_must zpool export $TESTPOOL1

for i in {1..5}; do
	log_must zpool import -d $DEVICE_DIR -o readonly=on $TESTPOOL1
	log_must eval "ls -l $mntpnt/dir | wc -l"
	log_must zpool export $TESTPOOL1
done

log_must zpool import -d $DEVICE_DIR $TESTPOOL1
log_must eval "ls -l $mntpnt/dir | wc -l"
log_must zpool export $TESTPOOL1

log_pass "zpool export of a read-only pool succeeds after its files were used"
