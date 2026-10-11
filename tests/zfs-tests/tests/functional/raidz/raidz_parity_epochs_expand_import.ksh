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
#	RAIDZ expansion of a vdev that carries a parity-epoch table must
#	not leave the pool unimportable.  vdev_raidz_load() refuses a table
#	together with expansion history (ENOTSUP), so either "zpool attach"
#	must refuse to expand such a vdev, or the expanded pool must import
#	again with its data intact.
#
# STRATEGY:
#	1. Create a 4-wide raidz1 pool with data and export it.
#	2. Store a geometry-identical epoch table (0:4:1) with zhack.
#	3. Import and write more data.
#	4. Attach a fifth disk (raidz expansion).  If the attach is
#	   refused, the test passes.
#	5. Otherwise wait for the expansion, scrub, export, and require
#	   the pool to import again with the same data and a clean scrub.
#

verify_runnable "global"

typeset pool=${TESTPOOL}_pe_exp
typeset BASEDIR=$TEST_BASE_DIR/raidz_pe_exp.$$
typeset -a VDEVS

function cleanup
{
	poolexists $pool && destroy_pool $pool
	rm -rf $BASEDIR
}

log_onexit cleanup
log_assert "Expanding a RAIDZ vdev with a parity-epoch table keeps the" \
    "pool importable (or the attach is refused)"

log_must mkdir -p $BASEDIR
for i in 0 1 2 3 4; do
	VDEVS[$i]=$BASEDIR/vdev$i
	log_must truncate -s 512M ${VDEVS[$i]}
done

log_must zpool create -f -o ashift=12 -O compression=off \
    -O mountpoint=/$pool $pool raidz1 ${VDEVS[0]} ${VDEVS[1]} \
    ${VDEVS[2]} ${VDEVS[3]}
log_must dd if=/dev/urandom of=/$pool/a1 bs=1M count=8
sync_pool $pool
log_must zpool export $pool

log_must zhack -d $BASEDIR raidz_epochs $pool 0 0:4:1
log_must zpool import -d $BASEDIR $pool
log_must eval "zpool get -H -o value feature@raidz_parity_epochs $pool |" \
    "grep -q active"

log_must dd if=/dev/urandom of=/$pool/a2 bs=1M count=8
sync_pool $pool

if ! zpool attach -w $pool raidz1-0 ${VDEVS[4]}; then
	log_note "zpool attach refused to expand a vdev with an epoch table"
	log_must zpool scrub -w $pool
	log_must check_pool_status $pool "errors" "No known data errors"
	log_pass "Expansion of a RAIDZ vdev with a parity-epoch table is refused"
fi

log_must zpool status -v $pool
log_must dd if=/dev/urandom of=/$pool/a3 bs=1M count=8
sync_pool $pool
typeset before=$(cd /$pool && cksum a1 a2 a3)
log_must zpool scrub -w $pool
log_must check_pool_status $pool "errors" "No known data errors"
log_must zpool export $pool

if ! zpool import -d $BASEDIR $pool; then
	zpool import -d $BASEDIR
	log_fail "zpool attach expanded a RAIDZ vdev with a parity-epoch" \
	    "table, and the pool no longer imports"
fi
typeset after=$(cd /$pool && cksum a1 a2 a3)
[[ "$before" == "$after" ]] || log_fail "data changed across reimport"
log_must zpool scrub -w $pool
log_must check_pool_status $pool "errors" "No known data errors"

log_pass "Expanding a RAIDZ vdev with a parity-epoch table keeps the" \
    "pool importable"
