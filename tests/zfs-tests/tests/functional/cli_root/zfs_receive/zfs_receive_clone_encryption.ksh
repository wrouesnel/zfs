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
# Receiving a clone from a non-raw stream with properties doesn't set
# the encryption property locally, and a user with the receive
# permission (but no encryption permission) gets no error about it.
#
# STRATEGY:
# 1. Create a filesystem, a snapshot, a clone of it and a snapshot of
#    the clone.
# 2. Receive the origin, then the clone from 'zfs send -p -i' (an
#    incremental clone stream), and from 'zfs send -p' (a full stream)
#    with 'zfs recv -o origin='.
# 3. Verify the received datasets' encryption property is not set
#    locally.
# 4. Receive the clone stream as a user with create, mount and receive
#    delegated, and verify the receive reports no property error.
#

verify_runnable "global"

RECVUSER=zrecvuser
RECVGROUP=zrecvgroup
src=$TESTPOOL/clsrc
dst=$TESTPOOL/cldst
stream=$TEST_BASE_DIR/zfs_receive_clone_encryption.$$
fstream=$TEST_BASE_DIR/zfs_receive_clone_encryption_full.$$

function cleanup
{
	for ds in $src $dst $TESTPOOL/deleg; do
		datasetexists $ds && destroy_dataset $ds -R
	done
	del_user $RECVUSER
	del_group $RECVGROUP
	rm -f $stream $fstream
}

log_assert "Receiving a clone with properties doesn't set encryption locally"
log_onexit cleanup

# 1. Source filesystem, clone and snapshots
log_must zfs create $src
log_must zfs create $src/fs
log_must zfs snapshot $src/fs@origin
log_must zfs clone $src/fs@origin $src/clone
log_must zfs snapshot $src/clone@snap
log_must eval "zfs send -p -i $src/fs@origin $src/clone@snap > $stream"
log_must eval "zfs send -p $src/clone@snap > $fstream"

# 2. Receive the origin, then the clone both ways
log_must zfs create $dst
log_must eval "zfs send $src/fs@origin | zfs recv -u $dst/fs"
log_must eval "zfs recv -u $dst/clone < $stream"
log_must eval "zfs recv -u -o origin=$dst/fs@origin $dst/fullclone < $fstream"

# 3. The encryption property isn't set locally on either (the full
#    stream isn't made a clone, but the origin is still passed)
log_must test "$(get_prop origin $dst/clone)" == "$dst/fs@origin"
for ds in $dst/clone $dst/fullclone; do
	typeset source=$(zfs get -H -o source encryption $ds)
	log_note "$ds: encryption source '$source'"
	[[ "$source" == "local" ]] && \
	    log_fail "$ds: encryption property set locally by the receive"
	log_must test "$(get_prop encryption $ds)" == "off"
done

# 4. A delegated receive of the clone reports no property error
del_user $RECVUSER
del_group $RECVGROUP
log_must add_group $RECVGROUP
log_must add_user $RECVGROUP $RECVUSER
user_run $RECVUSER zfs list ||
	log_unsupported "Test user $RECVUSER cannot execute zfs utilities"
log_must zfs create $TESTPOOL/deleg
log_must eval "zfs send $src/fs@origin | zfs recv -u $TESTPOOL/deleg/fs"
log_must zfs allow -u $RECVUSER create,mount,receive $TESTPOOL/deleg
log_must user_run $RECVUSER "zfs recv -u $TESTPOOL/deleg/clone < $stream"
log_must test "$(get_prop origin $TESTPOOL/deleg/clone)" == \
    "$TESTPOOL/deleg/fs@origin"
grep -q "cannot receive" $TEST_BASE_DIR/err && \
    log_fail "delegated receive reported: $(<$TEST_BASE_DIR/err)"

log_pass "Receiving a clone with properties doesn't set encryption locally"
