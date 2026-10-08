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
# Exporting a pool while a 'zfs recv' with properties is running into it
# must not panic the kernel (openzfs/zfs#16988).
#
# STRATEGY:
# 1. Make a replication stream of a file system with user properties on
#    the file system and its snapshots.
# 2. Repeatedly create a small pool, start receiving the stream into it,
#    and force-export the pool while the receive is setting properties.
# 3. Every iteration must leave the system able to import and destroy
#    the pool.
#

verify_runnable "global"

typeset src=$TESTPOOL/recv_export_src
typeset pool=recv_export_race
typeset vdev=$TEST_BASE_DIR/recv_export_race.vdev
typeset stream=$TEST_BASE_DIR/recv_export_race.stream
typeset -i duration=120

function cleanup
{
	poolexists $pool && destroy_pool $pool
	destroy_dataset $src -r
	rm -f $vdev $stream
}

log_assert "Exporting a pool during 'zfs recv' with properties is safe"

log_onexit cleanup

log_must zfs create -o test:prop=fs $src
for i in 1 2 3; do
	log_must zfs snapshot $src@$i
	log_must zfs set test:snap$i=yes $src@$i
done
log_must eval "zfs send -R $src@3 > $stream"

typeset -i n=0
typeset -i end=$(( $(date +%s) + duration ))
while (( $(date +%s) < end )); do
	log_must truncate -s $MINVDEVSIZE $vdev
	log_must zpool create -f -O mountpoint=none $pool $vdev
	zfs recv -F -u $pool/fs < $stream >/dev/null 2>&1 &
	typeset pid=$!
	sleep 0.0$(( RANDOM % 9 ))
	zpool export -f $pool >/dev/null 2>&1
	wait $pid
	poolexists $pool || log_must zpool import -d $TEST_BASE_DIR $pool
	log_must zpool destroy -f $pool
	log_must rm -f $vdev
	(( n += 1 ))
done
log_note "$n receive/export races"

log_pass "Exporting a pool during 'zfs recv' with properties is safe"
