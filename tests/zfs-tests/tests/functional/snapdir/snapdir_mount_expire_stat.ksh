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
# Description:
# Verify that stat(2) and statfs(2) of a snapshot automount's mountpoint
# do not keep it from expiring.  df(1), monitoring agents and desktop
# free-space checks do this to every mounted filesystem periodically, and
# an automounted snapshot that was looked at that way stayed mounted
# forever (openzfs/zfs#19215).
#
# Strategy:
# 1. Automount a snapshot, with a short expiry time.
# 2. For several expiry periods, stat and statfs the mountpoint, without
#    automounting it again once it has expired.
# 3. The snapshot must have expired.
# 4. The next access to the snapshot must automount it again.
#

. $STF_SUITE/tests/functional/snapdir/snapdir.kshlib
. $STF_SUITE/tests/functional/snapdir/snapdir.cfg

verify_runnable "both"

log_assert "Verify that stat and statfs don't stop snapshot automount expiry"

if ! is_linux ; then
	log_unsupported "EXPIRE_SNAPSHOT tunable only available on Linux"
fi

save_tunable EXPIRE_SNAPSHOT

function cleanup
{
	destroy_pool $TESTPOOL
	restore_tunable EXPIRE_SNAPSHOT
}

log_onexit cleanup

# Set snapshot expiry time to something we can test sanely.
log_must set_tunable64 EXPIRE_SNAPSHOT 2

# Create a pool and a snapshot
create_pool $TESTPOOL $DISKS
log_must zfs create -o snapdir=visible -o mountpoint=$TESTDIR/fs $TESTPOOL/$TESTFS
log_must touch $TESTDIR/fs/file
log_must zfs snapshot $TESTPOOL/$TESTFS@snap
mp=$TESTDIR/fs/$SNAPROOT/snap

# Trigger the mount
log_must ls -l $mp
log_must test "$(get_mount_paths $TESTPOOL/$TESTFS@snap)" == "$mp"

# For three expiry periods, stat and statfs the mountpoint four times a
# second.  stat(2) doesn't automount, and statfs(2) through an O_PATH
# descriptor doesn't either, so once the snapshot has expired these see
# the empty snapshot directory instead of mounting it again.
log_note "looking at the mountpoint until the snapshot expiry time has passed"
log_must python3 -c '
import os, sys, time
mp = sys.argv[1]
end = time.monotonic() + 6
while time.monotonic() < end:
    os.stat(mp)
    fd = os.open(mp, os.O_PATH)
    try:
        os.fstatvfs(fd)
    finally:
        os.close(fd)
    time.sleep(0.25)
' $mp

log_must test -z "$(get_mount_paths $TESTPOOL/$TESTFS@snap)"

# Expiry only took it out of view: the next access mounts it again.
log_must test -f $mp/file
log_must test "$(get_mount_paths $TESTPOOL/$TESTFS@snap)" == "$mp"

log_pass "stat and statfs of a snapshot automount don't stop it expiring."
