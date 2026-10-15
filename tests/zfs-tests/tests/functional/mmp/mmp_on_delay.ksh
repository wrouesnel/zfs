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

#
# DESCRIPTION:
#	An uberblock written with multihost=on must not carry mmp_delay 0.
#	An importing host reads MMP_MAGIC with mmp_delay 0 as "multihost is
#	off" and skips the activity check.  mmp_delay stays 0 until the MMP
#	thread has run, so the txg that turns multihost on, and the first
#	txg after an import, could be synced with a valid MMP config but
#	mmp_delay 0.
#
# STRATEGY:
#	1. Create a pool with multihost=off.
#	2. Turn multihost on, then off, a few times, each time waiting until
#	   the MMP thread has seen the change.
#	3. Export and import the pool a few times with multihost=on.
#	4. Export the pool and read every uberblock in its labels with zdb.
#	5. Verify that txg sync wrote uberblocks with an MMP config, and that
#	   none of them has mmp_delay 0.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/mmp/mmp.cfg
. $STF_SUITE/tests/functional/mmp/mmp.kshlib

verify_runnable "global"

function cleanup
{
	mmp_pool_destroy $MMP_POOL $MMP_DIR
	log_must mmp_clear_hostid
}

#
# Print "<uberblocks with an MMP config> <of those, with mmp_delay 0>" for
# the uberblocks txg sync wrote (mmp_seq 0) in the labels of the device.
# MMP writes are left out: one that races with multihost=off can carry
# mmp_delay 0 too, which only makes an importer wait for an activity check.
#
function count_mmp_uberblocks # device
{
	zdb -luuuu $1 | awk '
	    /Uberblock\[/	{ delay = -1; seq = -1 }
	    /mmp_delay =/	{ delay = $3 }
	    /mmp_seq =/		{ seq = $3 }
	    /mmp_valid =/	{
		if ($3 != "0" && seq == 0) {
			valid++
			if (delay == 0)
				zero++
		}
	    }
	    END			{ print valid + 0, zero + 0 }'
}

log_assert "uberblocks written with multihost=on never carry mmp_delay 0"
log_onexit cleanup

log_must mkdir -p $MMP_DIR
log_must rm -f $MMP_DIR/*
log_must truncate -s $MINVDEVSIZE $MMP_DIR/vdev1
log_must mmp_clear_hostid
log_must mmp_set_hostid $HOSTID1
log_must zpool create -f -o cachefile=none -O compression=off \
    -o multihost=off $MMP_POOL $MMP_DIR/vdev1
log_must sync_pool $MMP_POOL

#
# The MMP thread zeroes mmp_delay when it sees multihost go off, and sets it
# again when it sees multihost go on.  It looks once a second, so let it see
# each change, and the txg that turns multihost on again is synced before it
# looks next.
#
for i in 1 2 3; do
	log_must zpool set multihost=on $MMP_POOL
	log_must sync_pool $MMP_POOL
	log_must sleep 3
	log_must zpool set multihost=off $MMP_POOL
	log_must sync_pool $MMP_POOL
	log_must sleep 3
done

log_must zpool set multihost=on $MMP_POOL
for i in 1 2 3; do
	log_must zpool export $MMP_POOL
	log_must zpool import -d $MMP_DIR $MMP_POOL
	log_must sync_pool $MMP_POOL
done
log_must zpool export $MMP_POOL

counts=$(count_mmp_uberblocks $MMP_DIR/vdev1)
valid=${counts% *}
zero=${counts#* }
log_note "uberblocks with an MMP config: $valid, with mmp_delay 0: $zero"
if [[ -z "$valid" || $valid -eq 0 ]]; then
	zdb -luuuu $MMP_DIR/vdev1
	log_fail "no uberblock with an MMP config found"
fi
if [[ $zero -ne 0 ]]; then
	zdb -luuuu $MMP_DIR/vdev1 | grep -E 'Uberblock|txg =|mmp_'
	log_fail "$zero uberblocks have a valid MMP config but mmp_delay 0," \
	    "which importing hosts read as multihost=off"
fi

log_pass "uberblocks written with multihost=on never carry mmp_delay 0"
