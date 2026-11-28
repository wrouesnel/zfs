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
#	A write whose source is a mapping of the file being written, or a
#	read into a mapping of the file being read, must complete, even when
#	the mapping has to be faulted in while the file's range lock is
#	held.
#
# STRATEGY:
#	1. Write a 32M+128K file onto itself from a shared mapping of it
#	   (openzfs #18135).  zfs_write() prefaults only the first 32M of
#	   the source before it takes the range lock, so the rest is
#	   faulted in under the lock, and that fault reads a page of the
#	   same file.
#	2. Append 32M of anonymous memory and then the tail of the file,
#	   from a mapping of its last page: for a file of several blocks,
#	   a single block, and with another thread rewriting the first byte
#	   of the file meanwhile, which makes the size reached so far
#	   visible.
#	3. Append 32M and the file's first page with O_APPEND while another
#	   thread appends 4K records: the write must stay contiguous.
#	4. Read a file onto itself, into a shared writable mapping of it,
#	   while another thread overwrites part of it: the read's page
#	   faults must not wait behind the writer queued on its own range
#	   lock.
#	5. Each write and read must return its full length within 60
#	   seconds and the data must read back correctly.  One that hangs is
#	   stuck in the kernel for good and can not be killed: the test fails
#	   and the machine must be rebooted.
#

verify_runnable "global"

function cleanup
{
	rm -f $TESTDIR/selfmap.*
}

log_assert "Writes from and reads into a mapping of the same file complete"
log_onexit cleanup

log_must zfs set recordsize=128k $TESTPOOL/$TESTFS

typeset -i failed=0
typeset -i hung=0
set -A modes inplace append single pub apprace readself
for mode in ${modes[@]}; do
	out=$(mmap_write_selfmap -t 60 $mode $TESTDIR/selfmap.$mode)
	ret=$?
	log_note "$mode: $out"
	if (( ret != 0 )); then
		failed+=1
		[[ "$out" == *HANG* ]] && hung+=1
	fi
done

if (( hung > 0 )); then
	log_note "$hung case(s) hung in the kernel and can not be killed;" \
	    "reboot this machine before running more tests"
fi
(( failed == 0 )) || log_fail "$failed of ${#modes[@]} self-mapped cases failed"

log_pass "Writes from and reads into a mapping of the same file complete"
