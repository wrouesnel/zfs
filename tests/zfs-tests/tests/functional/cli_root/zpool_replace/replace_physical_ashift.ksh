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
#	A device keeps its own native block size (physical ashift) when the
#	replacing or mirror vdev above it goes away: a device that replaced
#	another reports its own native block size, not the replaced
#	device's, and a device left after a detach from a 2-way mirror
#	doesn't report the detached device's.
#
# STRATEGY:
#	1. Create a mirror with ashift=12 of file vdevs with a 512B native
#	   block size (vdev_file_physical_ashift=9)
#	2. Replace one side with a file vdev with a 16K native block size
#	   (vdev_file_physical_ashift=14); verify 'zpool status' reports
#	   "block size: 4096B configured, 16384B native" for it (its own)
#	3. Replace that device with a 512B one; verify 'zpool status' doesn't
#	   report a block size for the new device
#	4. Create a single-device pool, attach a 16K device and detach it
#	   again; verify 'zpool status' doesn't report a block size for the
#	   remaining device
#

verify_runnable "global"

function cleanup
{
	log_must set_tunable32 VDEV_FILE_PHYSICAL_ASHIFT $orig_ashift
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	poolexists $TESTPOOL2 && destroy_pool $TESTPOOL2
	rm -f $TEST_BASE_DIR/pashift_disk[1-7]
}

# status_line POOL DISK: the device's line in 'zpool status -P POOL'
function status_line
{
	zpool status -P $1 | awk -v d="$2" '$1 == d'
}

log_assert "A device doesn't take the native block size of the device it" \
	"replaced or was mirrored with"
log_onexit cleanup

typeset -i i
for i in 1 2 3 4 5 6 7; do
	log_must truncate -s $MINVDEVSIZE $TEST_BASE_DIR/pashift_disk$i
done
d1=$TEST_BASE_DIR/pashift_disk1
d2=$TEST_BASE_DIR/pashift_disk2
d3=$TEST_BASE_DIR/pashift_disk3
d4=$TEST_BASE_DIR/pashift_disk4
d5=$TEST_BASE_DIR/pashift_disk5
d6=$TEST_BASE_DIR/pashift_disk6

orig_ashift=$(get_tunable VDEV_FILE_PHYSICAL_ASHIFT)
log_must set_tunable32 VDEV_FILE_PHYSICAL_ASHIFT 9
log_must zpool create -f -o ashift=12 $TESTPOOL1 mirror $d1 $d2
log_must dd if=/dev/urandom of=/$TESTPOOL1/file bs=1M count=8
log_must zpool sync $TESTPOOL1
log_mustnot eval "zpool status $TESTPOOL1 | grep 'block size'"

# Replace with a 16K device: it reports its own block size
log_must set_tunable32 VDEV_FILE_PHYSICAL_ASHIFT 14
log_must zpool replace $TESTPOOL1 $d2 $d3
log_must wait_replacing $TESTPOOL1
log_must set_tunable32 VDEV_FILE_PHYSICAL_ASHIFT 9
log_note "$(status_line $TESTPOOL1 $d3)"
log_must eval "status_line $TESTPOOL1 $d3 | grep -q" \
	"'block size: 4096B configured, 16384B native'"

# Replace it with a 512B device: that one keeps its own block size
log_must zpool replace $TESTPOOL1 $d3 $d4
log_must wait_replacing $TESTPOOL1
log_note "$(status_line $TESTPOOL1 $d4)"
log_must test -n "$(status_line $TESTPOOL1 $d4)"
log_mustnot eval "status_line $TESTPOOL1 $d4 | grep 'block size'"
log_mustnot eval "zpool status $TESTPOOL1 | grep 'block size'"

# Attach a 16K device to a single device and detach it again
log_must zpool create -f -o ashift=12 $TESTPOOL2 $d5
log_must set_tunable32 VDEV_FILE_PHYSICAL_ASHIFT 14
log_must zpool attach -w $TESTPOOL2 $d5 $d6
log_must set_tunable32 VDEV_FILE_PHYSICAL_ASHIFT 9
log_must eval "status_line $TESTPOOL2 $d6 | grep -q 'block size'"
log_must zpool detach $TESTPOOL2 $d6
log_note "$(status_line $TESTPOOL2 $d5)"
log_must test -n "$(status_line $TESTPOOL2 $d5)"
log_mustnot eval "status_line $TESTPOOL2 $d5 | grep 'block size'"

log_pass "A device doesn't take the native block size of the device it" \
	"replaced or was mirrored with"
