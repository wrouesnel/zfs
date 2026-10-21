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
# 'zfs receive' (without -u) mounts the file systems it creates only if
# their canmount property is "on", as 'zfs mount -a' does: a file system
# received with canmount=noauto (from -o or from the stream) is not
# mounted.
#
# STRATEGY:
# 1. Receive a full stream with -o canmount=noauto; verify the new file
#    system is not mounted, then that it can be mounted by hand and holds
#    the data
# 2. Receive an incremental stream into it (-F); verify it stays
#    unmounted
# 3. Receive a stream (send -p) of a file system with canmount=noauto;
#    verify the new file system is not mounted
# 4. Receive a replication stream (send -R) of a parent with a
#    canmount=noauto child and a canmount=on child; verify that the parent
#    and the canmount=on child are mounted and the noauto child is not
# 5. Receive a full stream with the default canmount; verify the new file
#    system is mounted
#

verify_runnable "both"

function cleanup
{
	typeset ds
	for ds in $src $rsrc $dst1 $dst2 $dst3 $rdst; do
		datasetexists $ds && destroy_dataset $ds -rf
	done
	rm -rf $TESTDIR/noauto.$$
}

log_onexit cleanup

log_assert "'zfs receive' doesn't mount received file systems with" \
	"canmount=noauto"

mnt=$TESTDIR/noauto.$$
src=$TESTPOOL/noauto_src
rsrc=$TESTPOOL/noauto_rsrc
dst1=$TESTPOOL/noauto_dst1
dst2=$TESTPOOL/noauto_dst2
dst3=$TESTPOOL/noauto_dst3
rdst=$TESTPOOL/noauto_rdst

log_must zfs create -o mountpoint=$mnt/src $src
log_must eval "echo data > $mnt/src/file"
log_must zfs snapshot $src@s1

# 1. -o canmount=noauto on a full receive
log_must eval "zfs send $src@s1 | zfs receive -o canmount=noauto" \
	"-o mountpoint=$mnt/dst1 $dst1"
log_must test "$(get_prop canmount $dst1)" = "noauto"
log_mustnot ismounted $dst1
log_must zfs mount $dst1
log_must test "$(cat $mnt/dst1/file)" = "data"
log_must zfs unmount $dst1

# 2. an incremental receive leaves it unmounted (-F: mounting it above
# may have changed atimes)
log_must eval "echo more > $mnt/src/file2"
log_must zfs snapshot $src@s2
log_must eval "zfs send -i @s1 $src@s2 | zfs receive -F $dst1"
log_mustnot ismounted $dst1

# 3. canmount=noauto received from the stream
log_must zfs set canmount=noauto $src
log_must zfs snapshot $src@s3
log_must eval "zfs send -p $src@s3 | zfs receive -o mountpoint=$mnt/dst2 $dst2"
log_must test "$(get_prop canmount $dst2)" = "noauto"
log_mustnot ismounted $dst2

# 4. a replication stream with a canmount=noauto child
log_must zfs create -o mountpoint=$mnt/rsrc $rsrc
log_must zfs create -o canmount=noauto $rsrc/a
log_must zfs create $rsrc/b
log_must zfs snapshot -r $rsrc@r1
log_must eval "zfs send -R $rsrc@r1 | zfs receive -o mountpoint=$mnt/rdst $rdst"
log_must ismounted $rdst
log_must ismounted $rdst/b
log_must test "$(get_prop canmount $rdst/a)" = "noauto"
log_mustnot ismounted $rdst/a

# 5. the default canmount=on is still mounted
log_must eval "zfs send $src@s1 | zfs receive -o mountpoint=$mnt/dst3 $dst3"
log_must ismounted $dst3

log_pass "'zfs receive' doesn't mount received file systems with" \
	"canmount=noauto"
