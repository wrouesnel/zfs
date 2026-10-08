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

#
# DESCRIPTION:
# posix_fadvise() on a file must be safe while a 'zfs recv' replaces the
# objset of the file system the file is on (openzfs/zfs#19175).
#
# STRATEGY:
# 1. Receive a file system with a large file, and prepare a series of
#    incremental streams for it.
# 2. Call posix_fadvise(POSIX_FADV_DONTNEED) and
#    posix_fadvise(POSIX_FADV_WILLNEED) on the file in a few loops, while
#    receiving the incremental streams into the file system.
# 3. Every fadvise call must return normally, not be killed by a fault.
#

verify_runnable "global"

typeset src=$TESTPOOL/fadvise_recv_src
typeset dst=$TESTPOOL/fadvise_recv_dst
typeset -i duration=60
typeset -i nsnaps=20

function cleanup
{
	destroy_dataset $dst -r
	destroy_dataset $src -r
	rm -f $TEST_BASE_DIR/fadvise_recv.*
}

log_assert "posix_fadvise() is safe while 'zfs recv' replaces the objset"

log_onexit cleanup

log_must zfs create $src
log_must file_write -o create -f /$src/file -b 1048576 -c 32 -d R
log_must zfs snapshot $src@0
for i in $(seq 1 $nsnaps); do
	log_must file_write -o overwrite -f /$src/file -b 1048576 -c 2 -d R
	log_must zfs snapshot $src@$i
	log_must eval "zfs send -i @$((i - 1)) $src@$i > $TEST_BASE_DIR/fadvise_recv.$i"
done
log_must eval "zfs send $src@0 | zfs recv $dst"
typeset file=$(get_prop mountpoint $dst)/file

# Each loop writes a line for every fadvise call killed by a signal.
typeset -i end=$(( $(date +%s) + duration ))
for j in 1 2 3 4; do
	(
		while (( $(date +%s) < end )); do
			for a in POSIX_FADV_DONTNEED POSIX_FADV_WILLNEED; do
				file_fadvise -f $file -a $a >/dev/null 2>&1
				(( $? >= 128 )) && echo "killed: $a"
			done
		done
	) > $TEST_BASE_DIR/fadvise_recv.loop$j &
done

typeset -i recvs=0
while (( $(date +%s) < end )); do
	for i in $(seq 1 $nsnaps); do
		log_must eval "zfs recv -F $dst < $TEST_BASE_DIR/fadvise_recv.$i"
		(( recvs += 1 ))
	done
	log_must zfs rollback -r $dst@0
done
wait
log_note "$recvs receives"

typeset killed=$(cat $TEST_BASE_DIR/fadvise_recv.loop*)
[[ -z "$killed" ]] || log_fail "fadvise calls were killed: $killed"

log_pass "posix_fadvise() is safe while 'zfs recv' replaces the objset"
