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
. $STF_SUITE/tests/functional/block_cloning/block_cloning.kshlib

#
# DESCRIPTION:
#	Overwriting a cloned, deduplicated or gang block must not make the
#	zio write-done thread wait for a read of the pool's free bpobj.
#
#	dbuf_write_done() kills the overwritten block with
#	dsl_dataset_block_kill(..., async=B_TRUE) in a zio interrupt
#	(z_wr_int) thread.  Such blocks go on the pool's free bpobj, and
#	bpobj_enqueue() reads the bpobj's last block if it isn't cached.
#	With one z_wr_int thread and zfs_vdev_max_active=1 that read is
#	never issued: the vdev's only slot is held by a write whose
#	completion is queued behind the waiting thread, and the txg never
#	syncs.
#
# STRATEGY:
#	For a cloned, a deduplicated and a gang block:
#	1. Create a pool with a single z_wr_int thread.
#	2. With the free bpobj's processing disabled, overwrite a file
#	   so that its blocks fill several of the bpobj's blocks, then
#	   export and import the pool so that the bpobj isn't cached.
#	3. Set zfs_vdev_max_active=1 and delay writes, so that a write is
#	   in flight whenever one completes, overwrite more blocks of the
#	   file and wait up to 60 seconds for the txg to sync.
#	4. If it doesn't, restore zfs_vdev_max_active and read a file not
#	   in the ARC so that the queued read is issued; fail at the end.
#	5. Process the free bpobj, and verify that the freed space is
#	   released, the file holds the new data, and a scrub finds no
#	   errors.
#

verify_runnable "global"

claim="Overwriting cloned, dedup and gang blocks doesn't stall the txg"

log_assert $claim

VDEV=$TEST_BASE_DIR/bpobj_vdev
NBLKS=4000
KBLKS=64
TQ_WRITE=$(get_tunable ZIO_TASKQ_WRITE)
TQ_ONE="sync null fixed,1,1 null"
SYNC_PID=
STALLED=

function set_taskq_write
{
	# The parameter's parser doesn't accept a trailing newline.
	if is_linux; then
		printf "%s" "$1" > /sys/module/zfs/parameters/zio_taskq_write
	else
		sysctl vfs.zfs.zio.taskq_write="$1"
	fi
}

function cleanup
{
	restore_tunable VDEV_MAX_ACTIVE
	restore_tunable FREE_BPOBJ_ENABLED
	restore_tunable METASLAB_FORCE_GANGING
	restore_tunable METASLAB_FORCE_GANGING_PCT
	zinject -c all >/dev/null 2>&1
	set_taskq_write "$TQ_WRITE"
	poolexists $TESTPOOL && destroy_pool $TESTPOOL
	rm -f $VDEV $TEST_BASE_DIR/bpobj_new $TEST_BASE_DIR/bpobj_read
}

log_onexit cleanup

log_must save_tunable VDEV_MAX_ACTIVE
log_must save_tunable FREE_BPOBJ_ENABLED
log_must save_tunable METASLAB_FORCE_GANGING
log_must save_tunable METASLAB_FORCE_GANGING_PCT

#
# $1: clone, dedup or gang
#
function overwrite_cold_bpobj
{
	typeset kind=$1
	typeset bs=4096 props="" file=/$TESTPOOL/fs/a

	log_note "Overwriting $kind blocks"
	case $kind in
	dedup)	props="-o dedup=on" ;;
	gang)	bs=16384 ;;
	esac

	log_must set_taskq_write "$TQ_ONE"
	log_must truncate -s 1G $VDEV
	log_must zpool create -f -o ashift=12 -o feature@block_cloning=enabled \
	    -O compression=off -O recordsize=$bs $TESTPOOL $VDEV
	log_must zfs create $props $TESTPOOL/fs

	# Every block bigger than 8K is a gang block.
	if [[ $kind == gang ]]; then
		log_must set_tunable64 METASLAB_FORCE_GANGING 8193
		log_must set_tunable32 METASLAB_FORCE_GANGING_PCT 100
	fi

	log_must dd if=/dev/urandom of=$file bs=$bs count=$NBLKS
	log_must sync_pool $TESTPOOL
	if [[ $kind == clone ]]; then
		log_must clonefile -f $file /$TESTPOOL/fs/b 0 0 $((NBLKS * bs))
		log_must sync_pool $TESTPOOL
		file=/$TESTPOOL/fs/b
	fi

	# Fill the free bpobj, and leave it there.
	log_must set_tunable32 FREE_BPOBJ_ENABLED 0
	log_must dd if=/dev/urandom of=$file bs=$bs count=$NBLKS conv=notrunc
	log_must sync_pool $TESTPOOL
	typeset freeing=$(zpool get -Hpo value freeing $TESTPOOL)
	log_note "freeing $freeing bytes"
	log_must test $freeing -ge $((NBLKS * bs))

	# Never read after the import, so a read of it misses the ARC.
	log_must dd if=/dev/urandom of=/$TESTPOOL/kick bs=128k count=8
	log_must zpool export $TESTPOOL
	log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
	log_must eval "cat $file > /dev/null"

	# The blocks overwritten next are gang blocks; the new ones needn't be.
	log_must restore_tunable METASLAB_FORCE_GANGING
	log_must save_tunable METASLAB_FORCE_GANGING
	log_must restore_tunable METASLAB_FORCE_GANGING_PCT
	log_must save_tunable METASLAB_FORCE_GANGING_PCT

	log_must dd if=/dev/urandom of=$TEST_BASE_DIR/bpobj_new bs=$bs \
	    count=$KBLKS
	log_must zinject -d $VDEV -D 100:1 -T write $TESTPOOL
	log_must set_tunable32 VDEV_MAX_ACTIVE 1
	log_must dd if=$TEST_BASE_DIR/bpobj_new of=$file bs=$bs \
	    count=$KBLKS conv=notrunc
	zpool sync $TESTPOOL &
	SYNC_PID=$!

	typeset -i i=0
	while ((i < 60)) && kill -0 $SYNC_PID 2>/dev/null; do
		sleep 1
		((i += 1))
	done
	if kill -0 $SYNC_PID 2>/dev/null; then
		log_note "txg not synced after 60s with zfs_vdev_max_active=1"
		zinject -c all
		restore_tunable VDEV_MAX_ACTIVE
		save_tunable VDEV_MAX_ACTIVE
		cat /$TESTPOOL/kick > /dev/null
		i=0
		while ((i < 60)) && kill -0 $SYNC_PID 2>/dev/null; do
			sleep 1
			((i += 1))
		done
		kill -0 $SYNC_PID 2>/dev/null && \
		    log_fail "txg sync still stuck after restarting the queue"
		wait $SYNC_PID
		log_note "overwriting $kind blocks stalled the txg sync"
		STALLED="$STALLED $kind"
		log_must destroy_pool $TESTPOOL
		log_must rm -f $VDEV $TEST_BASE_DIR/bpobj_new
		return
	fi
	wait $SYNC_PID
	log_note "txg synced in ${i}s"
	log_must zinject -c all
	log_must restore_tunable VDEV_MAX_ACTIVE
	log_must save_tunable VDEV_MAX_ACTIVE

	log_must set_tunable32 FREE_BPOBJ_ENABLED 1
	log_must sync_pool $TESTPOOL
	log_must wait_freeing $TESTPOOL
	log_must test "$(zpool get -Hpo value leaked $TESTPOOL)" -eq 0

	log_must dd if=$file of=$TEST_BASE_DIR/bpobj_read bs=$bs count=$KBLKS
	log_must cmp $TEST_BASE_DIR/bpobj_new $TEST_BASE_DIR/bpobj_read
	log_must zpool scrub -w $TESTPOOL
	log_must check_pool_status $TESTPOOL "errors" "No known data errors"

	log_must destroy_pool $TESTPOOL
	log_must rm -f $VDEV $TEST_BASE_DIR/bpobj_new $TEST_BASE_DIR/bpobj_read
}

for kind in clone dedup gang; do
	overwrite_cold_bpobj $kind
done
[[ -n "$STALLED" ]] && log_fail "txg sync stalled overwriting:$STALLED"

log_pass $claim
