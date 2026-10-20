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
. $STF_SUITE/tests/functional/replacement/replacement.cfg

#
# DESCRIPTION:
# zfs_no_scrub_io only turns off scrub I/O.  A healing resilver must
# still copy the data to the new device while it is set.
#
# STRATEGY:
# 1. Create a single-device pool and write a file.
# 2. Set zfs_no_scrub_io and attach a second device, waiting for the
#    resilver to finish.
# 3. Detach the original device, so the data can only come from the
#    resilvered one.
# 4. Export and import the pool, read the file back and compare it.
# 5. Scrub and verify the pool has no errors.
#

verify_runnable "global"

function cleanup
{
	log_must set_tunable32 NO_SCRUB_IO $ORIG_NO_SCRUB_IO
	destroy_pool $TESTPOOL1
	rm -f ${VDEV_FILES[0]} ${VDEV_FILES[1]}
}

log_assert "A resilver copies the data while zfs_no_scrub_io is set"

ORIG_NO_SCRUB_IO=$(get_tunable NO_SCRUB_IO)
log_onexit cleanup

log_must truncate -s $VDEV_FILE_SIZE ${VDEV_FILES[0]} ${VDEV_FILES[1]}
log_must zpool create -f -O compression=off $TESTPOOL1 ${VDEV_FILES[0]}
mntpnt=$(get_prop mountpoint $TESTPOOL1)
log_must dd if=/dev/urandom of=$mntpnt/file bs=1M count=32
typeset sum=$(xxh128digest $mntpnt/file)
sync_pool $TESTPOOL1

log_must set_tunable32 NO_SCRUB_IO 1
log_must zpool attach -w $TESTPOOL1 ${VDEV_FILES[0]} ${VDEV_FILES[1]}
log_must set_tunable32 NO_SCRUB_IO $ORIG_NO_SCRUB_IO

log_must zpool detach $TESTPOOL1 ${VDEV_FILES[0]}
log_must zpool export $TESTPOOL1
log_must zpool import -d $TEST_BASE_DIR $TESTPOOL1

typeset newsum=$(xxh128digest $mntpnt/file)
[[ "$newsum" == "$sum" ]] || \
    log_fail "file read back from the resilvered device differs" \
    "('$newsum' != '$sum')"

log_must zpool scrub -w $TESTPOOL1
log_must check_pool_status $TESTPOOL1 "errors" "No known data errors"
typeset cksum=$(zpool status -p $TESTPOOL1 | \
    awk -v d=${VDEV_FILES[1]} '$1 == d { print $5 }')
[[ "$cksum" == "0" ]] || \
    log_fail "resilvered device has $cksum checksum errors"

log_pass "A resilver copies the data while zfs_no_scrub_io is set"
