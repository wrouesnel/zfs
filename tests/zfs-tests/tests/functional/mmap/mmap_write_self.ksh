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
# Copyright (c) 2026 by Will Rouesnel.
#

. $STF_SUITE/include/libtest.shlib

#
# DESCRIPTION:
#	A file can be written onto itself from a mapping of the same file.
#
# STRATEGY:
#	1. Create a file one byte larger than the window zfs_write() faults
#	   in before it takes the range lock, either a hole or data.
#	2. Export and import the pool, so that none of its pages is resident.
#	3. Map the file, private or shared, and write it onto itself.
#	4. Verify the write finishes, transfers everything and leaves the
#	   content unchanged.
#

verify_runnable "global"

file=$TESTDIR/mmap_write_self

function cleanup
{
	log_must rm -f $file
}

log_assert "A file can be written onto itself from its own mapping"
log_onexit cleanup

for kind in sparse data; do
	for map in private shared; do
		log_must mmap_write_self $file $kind $map create
		log_must zpool export $TESTPOOL
		log_must zpool import $TESTPOOL

		mmap_write_self $file $kind $map &
		pid=$!
		for i in {1..60}; do
			kill -0 $pid 2>/dev/null || break
			sleep 1
		done
		if kill -0 $pid 2>/dev/null; then
			log_note "$(cat /proc/$pid/stack 2>/dev/null)"
			log_fail "$kind/$map: write onto itself hung"
		fi
		wait $pid || log_fail "$kind/$map: write onto itself failed"
	done
done

log_pass "A file can be written onto itself from its own mapping"
