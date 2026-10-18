#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or https://opensource.org/licenses/CDDL-1.0.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/include/blkdev.shlib
. $STF_SUITE/tests/functional/cli_root/zpool_expand/zpool_expand.cfg

#
# DESCRIPTION:
# A whole-disk vdev can be onlined by its partition path when the
# device is relabelled (autoexpand=on, or zpool online -e).
#
# STRATEGY:
# 1. Create a mirror of a scsi_debug whole disk and a file, with
#    autoexpand=on.
# 2. Offline the disk by its partition path and online it again by the
#    partition path.  The online relabels the disk, which used to fail
#    with "unable to read disk capacity" because the partition was
#    passed to the relabel instead of the disk.
# 3. Do the same with autoexpand=off and zpool online -e.
# 4. Check that the disk is ONLINE and the pool is healthy each time.
#

verify_runnable "global"

function cleanup
{
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	unload_scsi_debug
	rm -f $FILE_RAW
	zed_start
}

log_onexit cleanup

log_assert "zpool online by partition path relabels the whole disk"

# With autoexpand=on, ZED onlines the disk again on its own after the
# offline; this test does the onlining itself.
zed_stop

MINVDEVSIZE_MB=$((MINVDEVSIZE / 1048576))
load_scsi_debug $MINVDEVSIZE_MB 1 1 1 '512b'
block_device_wait
SDISK=$(get_debug_device)
log_must truncate -s $MINVDEVSIZE $FILE_RAW

log_must zpool create -f -o autoexpand=on $TESTPOOL1 mirror $SDISK $FILE_RAW
block_device_wait
PART=$DEV_DSKDIR/${SDISK}1
log_must test -b $PART

log_must zpool offline $TESTPOOL1 $PART
log_must check_state $TESTPOOL1 $SDISK "OFFLINE"
log_must zpool online $TESTPOOL1 $PART
log_must check_state $TESTPOOL1 $SDISK "ONLINE"
log_must check_state $TESTPOOL1 "" "ONLINE"

log_must zpool set autoexpand=off $TESTPOOL1
log_must zpool offline $TESTPOOL1 $PART
log_must check_state $TESTPOOL1 $SDISK "OFFLINE"
log_must zpool online -e $TESTPOOL1 $PART
log_must check_state $TESTPOOL1 $SDISK "ONLINE"
log_must check_state $TESTPOOL1 "" "ONLINE"

# The whole-disk path keeps working.
log_must zpool offline $TESTPOOL1 $SDISK
log_must zpool online -e $TESTPOOL1 $SDISK
log_must check_state $TESTPOOL1 $SDISK "ONLINE"

log_pass "zpool online by partition path relabels the whole disk"
