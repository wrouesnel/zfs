#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source. A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.
#
# Copyright (c) 2026 by Will Rouesnel.
#

. $STF_SUITE/include/libtest.shlib

#
# DESCRIPTION:
#	A parity-epoch table whose logical width exceeds the number of
#	children of the RAIDZ vdev must be rejected, either by zhack when
#	it stores the table or when the pool is loaded.  Blocks written at
#	such an epoch put two columns of a row on one child (debug builds
#	panic in vdev_raidz_io_verify(); release builds lose redundancy).
#
# STRATEGY:
#	1. Create a 4-wide raidz1 pool and export it.
#	2. Control: store a valid table (0:4:1 T:4:2) and check that the
#	   pool imports read-only.
#	3. Store 0:4:1 T:6:1 (width 6 on 4 children).  T lies far in the
#	   future, and the import is read-only, so no block is ever
#	   written at the bad epoch, even when the table is accepted.
#	4. Either zhack or the read-only import must refuse the table.
#

verify_runnable "global"

typeset pool=${TESTPOOL}_pe_wide
typeset BASEDIR=$TEST_BASE_DIR/raidz_pe_wide.$$
typeset -a VDEVS

function cleanup
{
	poolexists $pool && destroy_pool $pool
	rm -rf $BASEDIR
}

log_onexit cleanup
log_assert "A parity-epoch table wider than the RAIDZ vdev is rejected"

log_must mkdir -p $BASEDIR
for i in 0 1 2 3; do
	VDEVS[$i]=$BASEDIR/vdev$i
	log_must truncate -s 512M ${VDEVS[$i]}
done

log_must zpool create -f -o ashift=12 -O compression=off $pool raidz1 \
    ${VDEVS[0]} ${VDEVS[1]} ${VDEVS[2]} ${VDEVS[3]}
log_must dd if=/dev/urandom of=/$pool/payload bs=1M count=8
sync_pool $pool
log_must zpool export $pool

typeset txg=$(zdb -lu ${VDEVS[0]} | awk '/txg = /{print $3}' | sort -n | \
    tail -1)
typeset future=$((txg + 1000000))

# Control: a valid table with the same future start imports.
log_must zhack -d $BASEDIR raidz_epochs $pool 0 0:4:1 $future:4:2
log_must zpool import -o readonly=on -d $BASEDIR $pool
log_must zpool export $pool

if ! zhack -d $BASEDIR raidz_epochs $pool 0 0:4:1 $future:6:1; then
	log_pass "zhack refuses a parity-epoch table wider than the vdev"
fi

if zpool import -o readonly=on -d $BASEDIR $pool; then
	zpool get -H feature@raidz_parity_epochs $pool
	log_fail "a parity epoch of width 6 on a 4-wide raidz1 was accepted"
fi

log_pass "A parity-epoch table wider than the RAIDZ vdev is rejected"
