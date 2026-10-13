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
# Exporting a pool while 'zfs recv' with properties runs into it
# (openzfs/zfs#16988) either fails with EBUSY, or succeeds and makes the
# receive fail with an error.  Either way the pool imports again with
# consistent properties, and the receive can be run again.
#
# STRATEGY:
# zfs_recv_hasrecvd_suspend holds a receive where it marks a dataset as
# having received properties (or clears that mark), and logs the dataset's
# name in dbgmsg; the test releases holds until it reaches the one it wants.
# 1. Full replication receive: while the receive ioctl marks the new file
#    system, an export must fail, because the receive holds the pool.
# 2. libzfs sets a snapshot's received properties with a second ioctl.
#    Export the pool just before that ioctl marks the last snapshot of a
#    full replication receive.  The export must succeed and the receive
#    must fail, naming the snapshot.  After an import the snapshot has no
#    received properties and nothing is held; the next incremental
#    replication receive sets them.
# 3. The same for an incremental replication receive; running the same
#    receive again succeeds and sets the snapshot's properties.
# 4. Truncated incremental receive with properties into a file system
#    that has never received properties: when the failed receive clears
#    the mark again, an export must fail, and the receive must restore
#    the file system's local properties.  A complete receive then
#    replaces them, as the first receive of properties does.
#

verify_runnable "global"

typeset src=$TESTPOOL/recvexp_src
typeset pool=recvexp$$
typeset dir=$TEST_BASE_DIR/recvexp.$$
typeset vdev=$dir/vdev
typeset out=$dir/recv.out
typeset recvpid=""
typeset -i recvrc=0
typeset -i gen=0
typeset -i holds=0
typeset orig_dbgmsg=""

function cleanup
{
	set_tunable32 RECV_HASRECVD_SUSPEND 0
	[[ -n "$recvpid" ]] && wait $recvpid
	[[ -n "$orig_dbgmsg" ]] && set_tunable32 DBGMSG_ENABLE $orig_dbgmsg
	poolexists $pool && destroy_pool $pool
	datasetexists $src && destroy_dataset $src -r
	rm -rf $dir
}

# Hold the next receive where it marks a dataset; each call releases the
# receive held before it.
function suspend_next
{
	(( gen += 1 ))
	log_must set_tunable32 RECV_HASRECVD_SUSPEND $gen
}

function resume
{
	gen=0
	log_must set_tunable32 RECV_HASRECVD_SUSPEND 0
}

function start_recv # stream dataset
{
	zfs receive -u $2 < $1 > $out 2>&1 &
	recvpid=$!
}

function wait_recv
{
	wait $recvpid
	recvrc=$?
	recvpid=""
	log_note "zfs receive exited $recvrc: $(<$out)"
}

# Wait until the receive is held on dataset $1, releasing it from the
# holds on other datasets before that one.
function hold_at # dataset
{
	typeset -i i=0
	typeset -i n
	typeset held

	while true; do
		held=$(kstat dbgmsg | \
		    sed -n "s/.*hasrecvd suspended on \($pool[^ ]*\)\$/\1/p")
		n=$(echo "$held" | grep -c .)
		if (( n > holds )); then
			holds=$n
			[[ "$(echo "$held" | tail -1)" == "$1" ]] && return
			log_note "zfs receive held on $(echo "$held" | tail -1)"
			suspend_next
			continue
		fi
		kill -0 $recvpid 2>/dev/null || \
		    log_fail "zfs receive exited before marking $1: $(<$out)"
		(( (i += 1) > 600 )) && log_fail "zfs receive never marked $1"
		sleep 0.1
	done
}

function check_prop # dataset property value source
{
	typeset got=$(zfs get -H -o value,source $2 $1)

	[[ "$got" == "$3"$'\t'"$4" ]] || \
	    log_fail "$1 $2 is '$got', expected '$3 $4'"
}

# The pool imports again, and nothing is left held or half received.
function check_reimport
{
	log_must zpool export $pool
	log_must zpool import -d $dir $pool
	for snap in $(zfs list -H -o name -t snapshot -r $pool); do
		[[ -z "$(zfs holds -H $snap)" ]] || log_fail "$snap is held"
	done
	for fs in $(zfs list -H -o name -t filesystem -r $pool); do
		check_prop $fs receive_resume_token - -
	done
}

log_assert "Exporting a pool during 'zfs recv' with properties is safe"
log_onexit cleanup

orig_dbgmsg=$(get_tunable DBGMSG_ENABLE)
log_must set_tunable32 DBGMSG_ENABLE 1

log_must mkdir -p $dir
log_must zfs create -o test:fs=1 $src
log_must zfs snapshot $src@1
log_must zfs set test:snap1=yes $src@1
log_must dd if=/dev/urandom of=$(get_prop mountpoint $src)/file bs=1M count=4
log_must zfs snapshot $src@2
log_must zfs set test:snap2=yes $src@2
log_must eval "zfs send -R $src@1 > $dir/full"
log_must eval "zfs send -R -I @1 $src@2 > $dir/incr"
log_must eval "zfs send $src@1 > $dir/plain"
log_must eval "zfs send -p -i @1 $src@2 > $dir/props"
log_must eval "head -c $(( $(stat_size $dir/props) / 2 )) $dir/props > \
    $dir/trunc"

log_must truncate -s $MINVDEVSIZE $vdev
log_must zpool create -f -O mountpoint=none $pool $vdev

# 1. The receive ioctl holds the pool.
suspend_next
start_recv $dir/full $pool/fs
hold_at $pool/fs
log_mustnot zpool export -f $pool
log_must poolexists $pool
resume
wait_recv
(( recvrc == 0 )) || log_fail "zfs receive failed"
check_prop $pool/fs test:fs 1 received
check_prop $pool/fs@1 test:snap1 yes received

# 2. Export before setting the last snapshot's properties.
suspend_next
start_recv $dir/full $pool/fs2
hold_at $pool/fs2@1
log_must zpool export -f $pool
resume
wait_recv
(( recvrc != 0 )) || log_fail "zfs receive succeeded without its pool"
log_must grep -q "cannot receive properties on $pool/fs2@1" $out
log_must zpool import -d $dir $pool
log_must snapexists $pool/fs2@1
check_prop $pool/fs2 test:fs 1 received
check_prop $pool/fs2@1 test:snap1 - -
check_reimport
log_must eval "zfs receive -u $pool/fs2 < $dir/incr"
check_prop $pool/fs2@1 test:snap1 yes received
check_prop $pool/fs2@2 test:snap2 yes received

# 3. The same for an incremental receive, then the same receive again.
suspend_next
start_recv $dir/incr $pool/fs
hold_at $pool/fs@2
log_must zpool export -f $pool
resume
wait_recv
(( recvrc != 0 )) || log_fail "zfs receive succeeded without its pool"
log_must grep -q "cannot receive properties on $pool/fs@2" $out
log_must zpool import -d $dir $pool
log_must snapexists $pool/fs@2
check_prop $pool/fs@2 test:snap2 - -
check_prop $pool/fs@1 test:snap1 yes received
check_reimport
log_must eval "zfs receive -u $pool/fs < $dir/incr"
check_prop $pool/fs@2 test:snap2 yes received
check_prop $pool/fs test:fs 1 received

# 4. Export while a failed receive restores the original properties.
log_must eval "zfs receive -u $pool/dst < $dir/plain"
log_must zfs set test:local=orig $pool/dst
suspend_next
start_recv $dir/trunc $pool/dst
hold_at $pool/dst
suspend_next
hold_at $pool/dst
log_mustnot zpool export -f $pool
log_must poolexists $pool
resume
wait_recv
(( recvrc != 0 )) || log_fail "zfs receive of a truncated stream succeeded"
log_mustnot grep -q "failed to restore" $out
log_mustnot snapexists $pool/dst@2
check_prop $pool/dst test:local orig local
check_prop $pool/dst test:fs - -
check_reimport
log_must eval "zfs receive -u $pool/dst < $dir/props"
check_prop $pool/dst test:fs 1 received
check_prop $pool/dst test:local - -

log_must zpool destroy $pool
log_pass "Exporting a pool during 'zfs recv' with properties is safe"
