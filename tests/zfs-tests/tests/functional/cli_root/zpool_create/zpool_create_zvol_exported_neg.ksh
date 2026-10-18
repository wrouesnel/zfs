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
. $STF_SUITE/tests/functional/cli_root/zpool_create/zpool_create.shlib

#
# DESCRIPTION:
# 'zpool create' without -f must refuse a zvol that holds an exported
# pool, as it does for a disk.
#
# STRATEGY:
# 1. Create a pool on a zvol (as a whole disk, so it gets partitioned),
#    write a file to it and export it.
# 2. Verify that 'zpool create' of a new pool on the zvol fails without
#    -f and names the exported pool.
# 3. Verify that the exported pool still imports with its file intact.
# 4. Export it again and verify that 'zpool create -f' still works.
#

verify_runnable "global"

function cleanup
{
	poolexists $TESTPOOL2 && destroy_pool $TESTPOOL2
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	datasetexists $TESTPOOL/$TESTVOL && \
	    log_must_busy zfs destroy $TESTPOOL/$TESTVOL
	poolexists $TESTPOOL && destroy_pool $TESTPOOL
}

log_assert "'zpool create' refuses a zvol that holds an exported pool"
log_onexit cleanup

typeset voldev=${ZVOL_DEVDIR}/$TESTPOOL/$TESTVOL

create_pool $TESTPOOL $DISK0
log_must zfs create -V 256m $TESTPOOL/$TESTVOL
block_device_wait $voldev

log_must zpool create $TESTPOOL1 $voldev
block_device_wait
log_must eval "echo keep > /$TESTPOOL1/file"
log_must zpool export $TESTPOOL1

out=$(zpool create $TESTPOOL2 $voldev 2>&1)
rc=$?
log_note "zpool create without -f: rc=$rc: $out"
(( rc != 0 )) || log_fail "'zpool create' overwrote the exported pool on $voldev"
echo "$out" | grep -q "part of exported pool '$TESTPOOL1'" || \
    log_fail "'zpool create' didn't name the exported pool: $out"

log_must zpool import -d ${ZVOL_DEVDIR}/$TESTPOOL $TESTPOOL1
log_must test "$(cat /$TESTPOOL1/file)" = "keep"
log_must zpool export $TESTPOOL1

log_must zpool create -f $TESTPOOL2 $voldev
log_must destroy_pool $TESTPOOL2

log_pass "'zpool create' refuses a zvol that holds an exported pool"
