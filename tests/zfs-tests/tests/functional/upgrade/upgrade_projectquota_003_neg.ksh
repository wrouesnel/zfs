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

. $STF_SUITE/tests/functional/upgrade/upgrade_common.kshlib

#
# DESCRIPTION:
#	Setting a project ID on a file created before project quota was
#	enabled must fail cleanly when the file's old layout can't be read.
#
#	zfs_setattr() moves such a file to the project ID layout with
#	sa_add_projid() after it has assigned its transaction.  If that
#	fails (here: the file's spill block, which holds its xattrs, returns
#	EIO), the error must reach the caller, the assigned transaction
#	must be committed rather than aborted, and the pool must keep
#	syncing.
#
# STRATEGY:
#	1. Create a pool with all features disabled, and on it a file with
#	   an xattr=sa xattr too large for the bonus buffer (spill block).
#	2. Enable project quota, then export and import the pool so that
#	   nothing has read the spill block.
#	3. Inject EIO on reads of that spill block only.
#	4. "zfs project -p" must fail with "Input/output error" and leave
#	   the project ID unchanged.
#	5. Clear the injection: the pool must sync, and a retry must set
#	   the project ID, charge it to the project, and keep it across
#	   export/import.
#

verify_runnable "global"

function cleanup
{
	zinject -c all >/dev/null 2>&1
	cleanup_upgrade
}

log_assert "zfs project -p fails cleanly if the old file layout can't be read"
log_onexit cleanup

typeset file=$TESTDIR/file
typeset projid=303
typeset out=$TEST_BASE_DIR/upgrade_projectquota_003.out

# 1. Pre-project-quota file whose xattr sits in its spill block.
log_must zpool create -d -m $TESTDIR $TESTPOOL $TMPDEV
log_must zfs set xattr=sa $TESTPOOL
log_must eval "echo data > $file"
# Random data, so the spill block is not embedded in its block pointer.
log_must eval "dd if=/dev/urandom bs=1100 count=1 2>/dev/null | \
    openssl base64 -A | set_xattr_stdin big $file"
typeset obj=$(get_objnum $file)
typeset objset=$(get_prop objsetid $TESTPOOL)

# 2. Enable project quota; the import mounts and upgrades the dataset.
log_must zpool upgrade $TESTPOOL
log_must zpool export $TESTPOOL
log_must zpool import -d $TMPDEV $TESTPOOL
typeset -i i=0
while ! zfs projectspace -o used $TESTPOOL | grep -q "USED"; do
	((i++ < 30)) || log_fail "project quota not enabled on $TESTPOOL"
	sleep 1
done

# 3. EIO on the spill block (DMU_SPILL_BLKID); flush the ARC first.
log_must zinject -a -b $(printf '%x:%x:0:fffffffffffffffe' $objset $obj) \
    -e io $TESTPOOL

# 4. The project ID can't be set, and the error reaches the caller.
log_mustnot eval "zfs project -p $projid $file > $out 2>&1"
cat $out
log_must grep -q "Input/output error" $out
log_must zinject -c all
log_must eval "zfs project $file | grep -q '^ *0 '"

# 5. The pool still syncs, and the retry works and persists.
log_must timeout 60 zpool sync $TESTPOOL
log_must zfs project -p $projid $file
log_must eval "zfs project $file | grep -q '^ *$projid '"
log_must zpool sync $TESTPOOL
typeset used=$(get_prop projectobjused@$projid $TESTPOOL)
[[ "$used" == "1" ]] || log_fail "projectobjused@$projid is $used, not 1"
log_must zpool export $TESTPOOL
log_must zpool import -d $TMPDEV $TESTPOOL
log_must eval "zfs project $file | grep -q '^ *$projid '"
used=$(get_prop projectobjused@$projid $TESTPOOL)
[[ "$used" == "1" ]] || log_fail "projectobjused@$projid is $used after import"

rm -f $out
log_pass "zfs project -p fails cleanly if the old file layout can't be read"
