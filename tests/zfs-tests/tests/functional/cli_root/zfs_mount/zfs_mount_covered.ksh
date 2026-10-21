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
#	Mounting a file system doesn't hide a file system that is already
#	mounted below its mountpoint: 'zfs mount', 'zfs mount -R' and
#	'zfs mount -a' mount it again on top, so it stays visible and can be
#	unmounted (and the pool exported).
#
# STRATEGY:
#	1. Create a file system with a child that holds a file
#	2. Unmount both, mount only the child, then mount the parent with
#	   'zfs mount', 'zfs mount -R' and 'zfs mount -a'; each time verify
#	   that the child's file is visible and the child can be unmounted
#	3. With an encrypted parent and an unencrypted child (the child is
#	   mounted while the parent's key isn't loaded), export and import
#	   the pool, 'zfs mount -a', then 'zfs mount -lR' the parent; verify
#	   the same, and that the pool can be exported
#

verify_runnable "global"

function cleanup
{
	# Without the fix the child is hidden under the parent, and can
	# only be unmounted after the parent.
	if poolexists $TESTPOOL; then
		umount $base 2>/dev/null
		umount $base/child 2>/dev/null
	fi
	if poolexists $pool; then
		umount $base/enc 2>/dev/null
		umount $base/enc/plain 2>/dev/null
		destroy_pool $pool
	fi
	datasetexists $fs && destroy_dataset $fs -r
	rm -rf $base $TEST_BASE_DIR/covered.img $TEST_BASE_DIR/covered.key
}

# check_visible step: the child's file is visible and the child unmounts
function check_visible # step dataset file
{
	typeset step=$1 ds=$2 file=$3

	[[ -f $file ]] || \
	    log_fail "after $step: $file is not visible ($ds is hidden)"
	log_must zfs unmount $ds
}

log_assert "Mounting a file system doesn't hide one mounted below it."
log_onexit cleanup

base=$TEST_BASE_DIR/covered
fs=$TESTPOOL/covered
pool=covered_pool

log_must zfs create -o mountpoint=$base $fs
log_must zfs create $fs/child
log_must touch $base/child/file

log_must zfs unmount $fs/child
log_must zfs unmount $fs
for cmd in "zfs mount $fs" "zfs mount -R $fs" "zfs mount -a"; do
	log_must zfs mount $fs/child
	log_must eval "$cmd"
	log_must mounted $fs
	log_must mounted $fs/child
	check_visible "$cmd" $fs/child $base/child/file
	log_must zfs unmount $fs
done

# The case from the report: an unencrypted child of an encryption root.
log_must truncate -s $MINVDEVSIZE $TEST_BASE_DIR/covered.img
log_must eval "echo 'password' > $TEST_BASE_DIR/covered.key"
log_must zpool create -O mountpoint=none $pool $TEST_BASE_DIR/covered.img
log_must zfs create -o encryption=on -o keyformat=passphrase \
    -o keylocation=file://$TEST_BASE_DIR/covered.key \
    -o mountpoint=$base/enc $pool/enc
log_must zfs create -o encryption=off $pool/enc/plain
log_must touch $base/enc/plain/file
log_must zpool export $pool
log_must zpool import -d $TEST_BASE_DIR $pool
log_must zfs mount -a
log_must mounted $pool/enc/plain
log_mustnot mounted $pool/enc
log_must zfs mount -lR $pool/enc
log_must mounted $pool/enc
check_visible "zfs mount -lR" $pool/enc/plain $base/enc/plain/file
log_must zfs mount $pool/enc/plain
log_must zpool export $pool
log_must zpool import -d $TEST_BASE_DIR $pool

log_pass "Mounting a file system doesn't hide one mounted below it."
