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
# posix_fadvise() on a file must be safe while a 'zfs recv' into its file
# system suspends and resumes the file system, which replaces the objset
# and frees the old one (openzfs/zfs#19175).
#
# 'zinject -n zfs_enter@<fadvise handler> -A pause' holds posix_fadvise()
# just before it enters the file system, so that a whole receive can run
# inside the call.
#
# STRATEGY:
# 1. Receive a file system with a file, and prepare incremental streams
#    for it.
# 2. For POSIX_FADV_WILLNEED and POSIX_FADV_DONTNEED:
#    a. Pause the fadvise handler at zfs_enter and call posix_fadvise() on
#       the file in the background.
#    b. Once the call has reached the pause, receive the next incremental
#       stream into the file system.
#    c. Verify that the call is still paused, clear the pause, and verify
#       that the call returns success.
# 3. Verify that the file has the received contents, and that
#    posix_fadvise() still works on it.
#

verify_runnable "global"

typeset src=$TESTPOOL/fadvise_recv_src
typeset dst=$TESTPOOL/fadvise_recv_dst
typeset -a advices=(POSIX_FADV_WILLNEED POSIX_FADV_DONTNEED)
typeset pid=""

if is_linux; then
	typeset point=zfs_enter@zpl_fadvise
else
	typeset point=zfs_enter@zfs_freebsd_advise
fi

function cleanup
{
	zinject -c all >/dev/null
	[[ -n "$pid" ]] && wait $pid
	destroy_dataset $dst -r
	destroy_dataset $src -r
	rm -f $TEST_BASE_DIR/fadvise_recv.*
}

log_assert "posix_fadvise() is safe while 'zfs recv' replaces the objset"

log_onexit cleanup

log_must zfs create $src
log_must file_write -o create -f /$src/file -b 1048576 -c 8 -d R
log_must zfs snapshot $src@0
typeset -i n=0
for advice in "${advices[@]}"; do
	((n++))
	log_must file_write -o overwrite -f /$src/file -b 1048576 -c 2 -d R
	log_must zfs snapshot $src@$n
	log_must eval "zfs send -i @$((n - 1)) $src@$n" \
	    "> $TEST_BASE_DIR/fadvise_recv.$n"
done
log_must eval "zfs send $src@0 | zfs recv $dst"

typeset file
typeset id
typeset -i status
file=$(get_prop mountpoint $dst)/file
n=0
for advice in "${advices[@]}"; do
	((n++))
	id=$(zinject -q -n $point -A pause $TESTPOOL) || \
	    log_fail "zinject -n $point -A pause failed"
	file_fadvise -f $file -a $advice &
	pid=$!
	wait_inject_point $id 1 30 || log_fail "$advice did not pause"

	# Replace the objset while the call is paused before entering.
	log_must eval "zfs recv -F $dst < $TEST_BASE_DIR/fadvise_recv.$n"
	kill -0 $pid || log_fail "$advice did not wait for the receive"

	log_must zinject -c $id
	wait $pid
	status=$?
	pid=""
	((status == 0)) || log_fail "$advice failed with status $status"
	log_note "$advice waited out a receive and returned success"
done

log_must cmp_xxh128 /$src/file $file
for advice in "${advices[@]}"; do
	log_must file_fadvise -f $file -a $advice
done

log_pass "posix_fadvise() is safe while 'zfs recv' replaces the objset"
