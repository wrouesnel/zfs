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

. $STF_SUITE/tests/functional/delegate/delegate_common.kshlib

#
# DESCRIPTION:
#	The 'send' permission alone is enough for 'zfs send -I' and
#	'zfs send -R'.  Those take temporary user holds on the snapshots
#	they send, which a user without the 'hold' permission can't take;
#	the send must go ahead without them.
#
# STRATEGY:
#	1. Create three snapshots and allow a user only 'send'.
#	2. As that user, 'zfs send -i', '-I' and '-R' must succeed without
#	   "cannot hold" and produce the same stream as root.
#	3. No holds may be left on the snapshots.
#	4. Without 'send', the user's 'zfs send -I' must still fail.
#

verify_runnable "both"

function cleanup
{
	rm -f $TEST_BASE_DIR/bak.user $TEST_BASE_DIR/bak.root
	restore_root_datasets
}

log_assert "'send' permission is enough for 'zfs send -I' and '-R'"
log_onexit cleanup

fs=$ROOT_TESTFS
log_must restore_root_datasets
mntpnt=$(get_prop mountpoint $fs)
for s in s1 s2 s3; do
	log_must dd if=/dev/urandom of=$mntpnt/$s bs=128k count=2
	log_must zfs snapshot $fs@$s
done
log_must zfs allow $STAFF1 send $fs

bak_user=$TEST_BASE_DIR/bak.user
bak_root=$TEST_BASE_DIR/bak.root
for opts in "-i $fs@s1 $fs@s3" "-I $fs@s1 $fs@s3" "-R $fs@s3"; do
	if ! user_run $STAFF1 "zfs send $opts > $bak_user"; then
		log_fail "'zfs send $opts' as $STAFF1 failed:" \
		    "$(<$TEST_BASE_DIR/err)"
	fi
	log_mustnot grep -q "cannot hold" $TEST_BASE_DIR/err
	log_must eval "zfs send $opts > $bak_root"
	if [[ "$(cksum <$bak_user)" != "$(cksum <$bak_root)" ]]; then
		log_fail "'zfs send $opts' stream differs for $STAFF1 and root"
	fi
	for s in s1 s2 s3; do
		holds=$(zfs holds -H $fs@$s)
		[[ -z "$holds" ]] || log_fail "hold left on $fs@$s: $holds"
	done
done

log_must zfs unallow $STAFF1 send $fs
if user_run $STAFF1 "zfs send -I $fs@s1 $fs@s3 > $bak_user"; then
	log_fail "'zfs send -I' as $STAFF1 succeeded without 'send'"
fi

log_pass "'send' permission is enough for 'zfs send -I' and '-R'"
