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
# Copyright 2009 Sun Microsystems, Inc.  All rights reserved.
# Use is subject to license terms.
#

#
# Copyright (c) 2013, 2016 by Delphix. All rights reserved.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/refreserv/refreserv.cfg

#
# DESCRIPTION:
#	Verify refreservation is limited by available space.
#
# STRATEGY:
#	1. Setting quota and refreservation on parent filesystem.
#	2. Get available space on sub-filesystem.
#	3. Verify refreservation is limited by available on it.
#

verify_runnable "both"

function cleanup
{
	if is_global_zone ; then
		log_must zfs set refreservation=none $TESTPOOL
	fi
	log_must zfs destroy -rf $TESTPOOL/$TESTFS
	log_must zfs create $TESTPOOL/$TESTFS
	log_must zfs set mountpoint=$TESTDIR $TESTPOOL/$TESTFS
}

log_assert "Verify refreservation is limited by available space."
log_onexit cleanup

pool=$TESTPOOL ; fs=$pool/$TESTFS ; subfs=$fs/subfs
log_must zfs create $subfs

typeset datasets
if is_global_zone; then
        datasets="$pool $fs"
else
        datasets="$fs"
fi

for ds in $datasets; do
	log_must zfs set quota=25M $ds
	log_must zfs set refreservation=15M $ds

	typeset -i avail
	avail=$(get_prop avail $subfs)
	log_must zfs set refreservation=$avail $subfs

	#
	# The parent is charged only for the part of the refreservation that
	# exceeds what $subfs already references, so a little of its quota
	# is still free.  The refreservation can grow by at most that much.
	# The parent's used space can still move by a few KB while the
	# property changes sync (seen on FreeBSD), so test the limit with a
	# margin rather than to the byte.
	#
	typeset -i room exceed
	((room = $(get_prop quota $ds) - $(get_prop used $ds)))
	((exceed = avail + room + 1024 * 1024))
	log_mustnot zfs set refreservation=$exceed $subfs

	typeset mntpnt
	mntpnt=$(get_prop mountpoint $subfs)

	#
	# The reserved space must be usable although the parent's quota is
	# now fully reserved.  Write incompressible data: with the default
	# compression mkfile's zeros become holes and use no space.  Write
	# whole records and leave 1 MiB for metadata: a file of exactly
	# $avail bytes ends in a partial record, but its last block is a full
	# record, so with incompressible data it cannot fit.  Sync after each
	# record: every write is checked against the quota with a worst-case
	# estimate of its size, and so is all the data not yet synced, so
	# writes that pile up in one txg can be refused well before the
	# reservation is used (seen on FreeBSD and Linux).
	#
	typeset -i recsize fill i
	recsize=$(get_prop recordsize $subfs)
	((fill = (avail - 1024 * 1024) / recsize))
	log_must touch $mntpnt/$TESTFILE
	for ((i = 0; i < fill; i++)); do
		file_write -o append -f $mntpnt/$TESTFILE -b $recsize -c 1 \
		    -d R || log_fail "write $i of $fill records failed"
		sync_pool $pool
	done
	typeset -i refer=$(get_prop referenced $subfs)
	((refer >= fill * recsize)) || \
	    log_fail "referenced $refer < written $((fill * recsize))"

	# What is left of the reservation cannot hold another $avail bytes.
	log_mustnot file_write -o create -f $mntpnt/$TESTFILE.2 -b $recsize \
	    -c $((avail / recsize + 1)) -d R

	log_must rm -f $mntpnt/$TESTFILE $mntpnt/$TESTFILE.2
	sync_all_pools true
	log_must zfs set quota=none $ds
	log_must zfs set reservation=15M $ds
done

log_pass "Verify refreservation is limited by available space."
