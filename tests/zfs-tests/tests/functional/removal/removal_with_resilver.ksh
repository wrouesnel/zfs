#! /bin/ksh -p
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
. $STF_SUITE/tests/functional/removal/removal.kshlib

#
# DESCRIPTION:
#	A top-level mirror or spare vdev cannot be removed while one of its
#	children still needs to be resilvered or rebuilt, since the removal
#	could copy stale data from that child.
#
# STRATEGY:
#	For a new mirror child (zpool attach) and a hot spare (zpool replace),
#	each with a healing resilver and with a sequential rebuild (-s):
#	1. Create a pool with two single-disk top-level vdevs and write data.
#	2. Suspend scan progress and attach the new disk to the first vdev,
#	   or replace the first vdev with the hot spare.
#	3. Verify that removing the (still resilvering) mirror-0 or spare-0
#	   fails.
#	4. Resume the resilver, wait for it to finish.
#	5. Verify the vdev can now be removed and the pool has no errors.
#

DISKDIR=$(mktemp -d)
DISK1="$DISKDIR/dsk1"
DISK2="$DISKDIR/dsk2"
DISK3="$DISKDIR/dsk3"

function cleanup
{
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
	default_cleanup_noexit
	log_must rm -rf $DISKDIR
}

log_onexit cleanup

for mode in attach spare; do
for opt in "" "-s"; do
	log_must truncate -s $MINVDEVSIZE $DISK1 $DISK2 $DISK3

	if [[ $mode == attach ]]; then
		log_must zpool create -f $TESTPOOL $DISK1 $DISK3
		top=mirror-0
	else
		log_must zpool create -f $TESTPOOL $DISK1 $DISK3 spare $DISK2
		top=spare-0
	fi
	log_must zfs set compression=off $TESTPOOL
	log_must dd if=/dev/urandom of=/$TESTPOOL/file bs=1M count=64
	log_must zpool sync $TESTPOOL
	typeset cksum=$(xxh128digest /$TESTPOOL/file)

	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
	if [[ $mode == attach ]]; then
		log_must zpool attach $opt $TESTPOOL $DISK1 $DISK2
	else
		log_must zpool replace $opt $TESTPOOL $DISK1 $DISK2
	fi
	log_must is_pool_resilvering $TESTPOOL

	log_mustnot zpool remove $TESTPOOL $top

	# A sequential rebuild is followed by a scrub; let it finish too.
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
	log_must zpool wait -t resilver,scrub $TESTPOOL

	log_must zpool remove -w $TESTPOOL $top
	log_must zpool export $TESTPOOL
	log_must zpool import -d $DISKDIR $TESTPOOL
	log_must [ "$(xxh128digest /$TESTPOOL/file)" = "$cksum" ]
	verify_pool $TESTPOOL

	log_must zpool destroy $TESTPOOL
	log_must rm -f $DISK1 $DISK2 $DISK3
done
done

log_pass "Mirror or spare with a resilvering child cannot be removed"
