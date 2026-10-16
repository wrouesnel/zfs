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
# Copyright (c) 2026 by Will Rouesnel. All rights reserved.
#

. $STF_SUITE/include/libtest.shlib

#
# DESCRIPTION:
# A sequential resilver reads each metaslab's space map.  When that read
# fails on one copy of the block, ZFS reads another copy and repairs the
# bad one, and the read completes only after the repair write has
# completed in the write interrupt taskq.  A thread of that taskq may be
# freeing a block in the same metaslab at the time, so the resilver must
# not hold the metaslab's ms_lock while it reads the space map, or the
# pool hangs when that taskq has a single thread (as on systems with two
# CPUs).
#
# STRATEGY:
#	1. Use a single write interrupt thread (zio_taskq_write), make the
#	   sequential resilver wait before it reads each space map
#	   (zfs_rebuild_sm_load_delay_ms), and disable the scrub after it.
#	2. Create a pool whose metadata, and so the space maps, goes to two
#	   special vdevs, and fill a dozen metaslabs of its normal vdev.
#	3. Re-import the pool so that no space map is cached, and inject read
#	   errors into one special vdev.  Each space map block has copies on
#	   both special vdevs, and a read that tries the failing copy first is
#	   repaired from the other one.
#	4. Attach a second disk to the normal vdev with a sequential
#	   resilver.  Each time the resilver waits before reading a space
#	   map, overwrite blocks in that metaslab and sync, so that the write
#	   interrupt taskq frees them while the space map is read.
#	5. Verify that the resilver finishes, that the new disk is online
#	   with no errors, and that a scrub finds no errors.  Repeat until a
#	   space map read has hit the injected errors, as the copy read first
#	   is random.
#

verify_runnable "global"

DISKDIR=$(mktemp -d -p $TEST_BASE_DIR)
DISK0=$DISKDIR/dsk0
DISK1=$DISKDIR/dsk1
SPEC0=$DISKDIR/spec0
SPEC1=$DISKDIR/spec1
MAP=$DISKDIR/map
SMOBJS=$DISKDIR/smobjs
DELAY_MS=2000
NFILES=24
HUNG=false

function cleanup
{
	restore_tunable REBUILD_SM_LOAD_DELAY_MS
	restore_tunable REBUILD_SCRUB_ENABLED
	[[ -n "$TASKQ_WRITE" ]] && set_taskq_write "$TASKQ_WRITE"
	if $HUNG; then
		# Any command on the hung pool would hang as well.
		log_note "Leaving the hung pool $TESTPOOL1 in place"
	else
		zinject -c all
		poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
		log_must rm -rf $DISKDIR
	fi
}

#
# zio_taskq_write is a string with spaces, which set_tunable can not set.
#
function set_taskq_write
{
	case "$UNAME" in
	Linux)
		printf "%s" "$1" >/sys/module/zfs/parameters/$ZIO_TASKQ_WRITE
		;;
	FreeBSD)
		sysctl vfs.zfs.$ZIO_TASKQ_WRITE="$1"
		;;
	esac
}

#
# Print the state of the latest rebuild of vdev 0 from the debug log: the
# metaslabs it has waited for, in order, then "done" if it has completed.
#
function rebuild_progress
{
	kstat dbgmsg | awk '
	    / rebuild vdev_id=0 vdev_guid=[0-9]* started/ { ms = ""; done = "" }
	    /rebuild: waiting [0-9]* ms before loading space map of vdev 0 / {
		ms = ms " " $NF
	    }
	    / rebuild vdev_id=0 vdev_guid=[0-9]* complete/ { done = "done" }
	    END { print ms, done }'
}

function rebuild_starts
{
	kstat dbgmsg | grep -c " rebuild vdev_id=0 vdev_guid=[0-9]* started"
}

#
# Print the stacks of the threads involved in the hang, if we can.
#
function log_stacks
{
	typeset pid

	[[ "$UNAME" == "Linux" ]] || return
	for pid in $(pgrep -x z_wr_int) $(pgrep -x vdev_rebuild) \
	    $(pgrep -x txg_sync); do
		log_note "$(cat /proc/$pid/comm) $pid:" \
		    $(awk '{print $2}' /proc/$pid/stack | head -12)
	done
}

#
# Number of space map reads of vdev 0 that failed on $SPEC0.
#
function sm_read_errors
{
	zpool events -v $TESTPOOL1 | \
	    awk -v objs="$(echo $(<$SMOBJS))" -v path="$SPEC0" '
	    BEGIN { n = split(objs, a); for (i = 1; i <= n; i++) sm[a[i]] = 1 }
	    /class = "ereport.fs.zfs.io"/ { io = 1 }
	    /zio_objset = / { os = $3 }
	    /zio_object = / { ob = $3 }
	    /vdev_path = / { vp = $3; gsub("\"", "", vp) }
	    /^$/ {
		if (io && os == "0x0" && (ob in sm) && vp == path) hits++
		io = 0; os = ""; ob = ""; vp = ""
	    }
	    END { print hits + 0 }'
}

#
# Read, write and checksum error counts of a vdev, as "R W C".
#
function vdev_errors # pool vdev
{
	zpool status -p $1 | awk -v v="$2" '$1 == v { print $3, $4, $5 }'
}

log_onexit cleanup
log_assert "A sequential resilver does not hang on a free while it reads" \
    "a space map"

log_must save_tunable REBUILD_SM_LOAD_DELAY_MS
log_must save_tunable REBUILD_SCRUB_ENABLED
log_must set_tunable32 REBUILD_SCRUB_ENABLED 0
TASKQ_WRITE=$(get_tunable ZIO_TASKQ_WRITE)
log_must set_taskq_write "sync null fixed,1,1 null"

typeset -i round=0
typeset -i errors=0
while ((errors == 0 && round < 3)); do
	((round++))
	log_must truncate -s $((MINVDEVSIZE * 4)) $DISK0 $DISK1
	log_must truncate -s $MINVDEVSIZE $SPEC0 $SPEC1
	log_must zpool create -f $TESTPOOL1 $DISK0 special $SPEC0 $SPEC1
	log_must zfs create -o compression=off -o recordsize=128k \
	    -o mountpoint=$TESTDIR1 $TESTPOOL1/$TESTFS1
	for i in $(seq $NFILES); do
		log_must dd if=/dev/urandom of=$TESTDIR1/file.$i bs=1M \
		    count=16 status=none
	done

	#
	# Find out which blocks of the files are in which metaslab of vdev 0.
	#
	log_must zpool export $TESTPOOL1
	msshift=$(zdb -e -p $DISKDIR -C $TESTPOOL1 | \
	    awk '/metaslab_shift/ {print $2; exit}')
	zdb -e -p $DISKDIR -ddddd $TESTPOOL1/$TESTFS1 | \
	    awk '/^\tpath\t/ { p = $2 }
		/ L0 0:/ { split($3, a, ":"); print p, $1, a[2] }' | \
	    while read path off dva; do
		echo $path $((16#$off / 131072)) $((16#$dva >> msshift))
	    done > $MAP
	zdb -e -p $DISKDIR -m $TESTPOOL1 | awk '
	    /^\tvdev/ { v = $2 }
	    /metaslab +[0-9]+ +offset/ && v == 0 && $6 != 0 {
		printf("0x%x\n", $6)
	    }' > $SMOBJS
	log_note "Blocks of vdev 0 per metaslab:" \
	    $(awk '{print $3}' $MAP | sort -n | uniq -c | awk '{print $2":"$1}')
	(($(wc -l <$MAP) > 0)) || log_fail "no blocks of vdev 0 found"

	log_must zpool import -d $DISKDIR $TESTPOOL1
	log_must zpool events -c
	log_must zinject -d $SPEC0 -e io -T read -f 100 $TESTPOOL1
	log_must set_tunable32 REBUILD_SM_LOAD_DELAY_MS $DELAY_MS

	#
	# The debug log may hold earlier rebuilds of a vdev 0; wait for this
	# one to start.
	#
	typeset -i starts=$(rebuild_starts)
	log_must zpool attach -s $TESTPOOL1 $DISK0 $DISK1
	typeset -i i=0
	while (($(rebuild_starts) == starts)) && ((i < 300)); do
		sleep 0.1
		((i++))
	done
	(($(rebuild_starts) > starts)) || log_fail "the rebuild did not start"

	#
	# Each time the rebuild waits before reading a space map, overwrite
	# blocks in that metaslab.  Without a fix the pool can hang, and
	# then every zpool command waits forever, so run "zpool sync" in the
	# background and give up if the rebuild makes no progress for a
	# minute.
	#
	typeset -i attempts=0
	typeset -i last=$SECONDS
	while :; do
		typeset finished=false
		set -A progress -- $(rebuild_progress) ""
		typeset -i n=${#progress[@]}-1
		if ((n > 0)) && [[ ${progress[n - 1]} == "done" ]]; then
			finished=true
			((n--))
		fi
		while ((attempts < n)); do
			typeset ms=${progress[attempts]}
			awk -v ms=$ms '$3 == ms' $MAP | head -2 | \
			    while read path blk m; do
				dd if=/dev/urandom of=$TESTDIR1/$path \
				    bs=128k seek=$blk count=1 conv=notrunc \
				    status=none
			    done
			zpool sync $TESTPOOL1 >/dev/null 2>&1 &
			((attempts++))
			last=$SECONDS
		done
		$finished && break
		if ((SECONDS - last > 60)); then
			HUNG=true
			log_stacks
			log_fail "rebuild hung reading the space map of" \
			    "metaslab ${progress[attempts - 1]} of vdev 0"
		fi
		sleep 0.1
	done
	log_must set_tunable32 REBUILD_SM_LOAD_DELAY_MS 0

	errors=$(sm_read_errors)
	log_note "Round $round: the rebuild read $attempts space maps," \
	    "$errors reads failed on $SPEC0"
	((attempts >= 10)) || log_fail "only $attempts space maps were read"

	#
	# The resilver must have completed normally: both sides of the new
	# mirror online without errors, and nothing lost.  The space map
	# read errors were repaired, so a scrub finds nothing either.
	#
	log_must zinject -c all
	log_must zpool wait -t resilver $TESTPOOL1
	log_must is_pool_resilvered $TESTPOOL1
	for vdev in $DISK0 $DISK1; do
		log_must check_vdev_state $TESTPOOL1 $vdev "ONLINE"
		[[ "$(vdev_errors $TESTPOOL1 $vdev)" == "0 0 0" ]] || \
		    log_fail "$vdev has errors: $(vdev_errors $TESTPOOL1 $vdev)"
	done
	log_must zpool clear $TESTPOOL1
	log_must zpool scrub -w $TESTPOOL1
	log_must check_pool_status $TESTPOOL1 "errors" "No known data errors"
	for vdev in $DISK0 $DISK1 $SPEC0 $SPEC1; do
		[[ "$(vdev_errors $TESTPOOL1 $vdev)" == "0 0 0" ]] || \
		    log_fail "$vdev has errors after the scrub:" \
		    "$(vdev_errors $TESTPOOL1 $vdev)"
	done

	#
	# The rebuilt disk alone must hold all the data.
	#
	log_must zpool detach $TESTPOOL1 $DISK0
	log_must zpool export $TESTPOOL1
	log_must zpool import -d $DISKDIR $TESTPOOL1
	log_must zpool scrub -w $TESTPOOL1
	log_must check_pool_status $TESTPOOL1 "errors" "No known data errors"
	[[ "$(vdev_errors $TESTPOOL1 $DISK1)" == "0 0 0" ]] || \
	    log_fail "$DISK1 has errors: $(vdev_errors $TESTPOOL1 $DISK1)"

	log_must zpool destroy $TESTPOOL1
	log_must rm -f $DISK0 $DISK1 $SPEC0 $SPEC1
done
((errors > 0)) || log_fail "no space map read hit the injected errors"

log_pass "A sequential resilver does not hang on a free while it reads" \
    "a space map"
