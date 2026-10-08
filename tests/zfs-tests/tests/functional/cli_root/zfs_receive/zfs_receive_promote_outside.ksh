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
# 'zfs recv -F' of an incremental replication stream must work when the
# target's origin was moved out of the received tree by 'zfs promote'
# (openzfs/zfs#17087).
#
# STRATEGY:
# 1. Replicate a file system with three snapshots to "backup".
# 2. Clone backup@1 to "clone", promote the clone, and receive the rest
#    of the source's snapshots into it.
# 3. Promote "backup" again, so the clone's origin is outside the tree
#    that is received into.
# 4. Receive a new incremental replication stream into "clone".  It must
#    succeed and create the new snapshot.
#

verify_runnable "both"

typeset data=$TESTPOOL/promote_data
typeset backup=$TESTPOOL/promote_backup
typeset clone=$TESTPOOL/promote_clone

function cleanup
{
	for ds in $clone $backup $data; do
		datasetexists $ds && destroy_dataset $ds -Rf
	done
}

log_assert "'zfs recv -F' works after the target's origin was promoted away"

log_onexit cleanup

log_must zfs create $data
for i in 1 2 3; do
	log_must zfs snapshot $data@$i
done
log_must eval "zfs send -R $data@3 | zfs receive -F $backup"
log_must zfs destroy $backup@2
log_must zfs clone $backup@1 $clone
log_must zfs promote $clone
log_must eval "zfs send -R -I $data@1 $data@3 | zfs receive -F $clone"
log_must zfs promote $backup
log_must zfs snapshot $data@4

log_must eval "zfs send -R -I $data@3 $data@4 | zfs receive -F $clone"
log_must snapexists $clone@4

log_pass "'zfs recv -F' works after the target's origin was promoted away"
