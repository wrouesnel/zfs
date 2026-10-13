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
# Copyright 2007 Sun Microsystems, Inc.  All rights reserved.
# Use is subject to license terms.
#

#
# Copyright (c) 2023 Klara, Inc.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/cli_root/zpool_import/zpool_import.cfg
. $STF_SUITE/tests/functional/cli_root/zpool_import/zpool_import.kshlib

#
# DESCRIPTION:
# 	Verify that admin commands to different pool are not blocked by import
#
# STRATEGY:
#	1. Create 2 pools
#	2. Export one of the pools
#	4. Import the pool with an injected delay
#	5. Once the import is in that delay, execute some admin commands
#	   against both pools
#	6. Verify that the admin commands to the non-imported pool finished
#	   while the import was still in progress
#

verify_runnable "global"

function cleanup
{
	zinject -c all
	destroy_pool $TESTPOOL1
	destroy_pool $TESTPOOL2
}

#
# Is the import of $TESTPOOL1 still in progress (with notes matching the
# optional pattern)?  The pool is listed in the import_progress kstat until
# its load, and so the injected delay, is over.  Only after that are
# commands that wait for the import let through.
#
function importing
{
	typeset notes=$1

	kstat import_progress | awk -v pool=$TESTPOOL1 -v notes="$notes" \
	    '$5 == pool && $0 ~ notes { found = 1 } END { exit !found }'
}

#
# Record how long a command took, and whether $TESTPOOL1 was still being
# imported when it finished.
#
function record
{
	typeset file=$1
	typeset msg=$2
	typeset state="after"

	importing && state="during"
	echo $SECONDS $state > $file
	echo "$msg in $SECONDS secs ($state the import of $TESTPOOL1)"
}

function pool_import
{
	typeset dir=$1
	typeset pool=$2

	SECONDS=0
	errmsg=$(zpool import -d $dir -f $pool 2>&1 > /dev/null)
	if [[ $? -eq 0 ]]; then
		echo ${pool}: imported in $SECONDS secs
		echo $SECONDS > ${DEVICE_DIR}/${pool}-import
	else
		echo ${pool}: import failed $errmsg in $SECONDS secs
	fi
}

function pool_add_device
{
	typeset pool=$1
	typeset device=$2
	typeset devtype=$3

	SECONDS=0
	errmsg=$(zpool add $pool $devtype $device 2>&1 > /dev/null)
	if [[ $? -eq 0 ]]; then
		record ${DEVICE_DIR}/${pool}-add "${pool}: added $devtype vdev"
	else
		echo ${pool}: add $devtype vdev failed ${errmsg}, in $SECONDS secs
	fi
}

function pool_stats
{
	typeset stats=$1
	typeset pool=$2

	SECONDS=0
	errmsg=$(zpool $stats $pool 2>&1 > /dev/null)
	if [[ $? -eq 0 ]]; then
		record ${DEVICE_DIR}/${pool}-${stats} "${pool}: $stats"
	else
		echo ${pool}: $stats failed ${errmsg}, in $SECONDS secs
	fi
}

function pool_create
{
	typeset pool=$1
	typeset device=$2

	SECONDS=0
	errmsg=$(zpool create $pool $device 2>&1 > /dev/null)
	if [[ $? -eq 0 ]]; then
		echo ${pool}: created in $SECONDS secs
		echo $SECONDS > ${DEVICE_DIR}/${pool}-create
	else
		echo ${pool}: create failed ${errmsg}, in $SECONDS secs
	fi
}

log_assert "Simple admin commands to different pool not blocked by import"

log_onexit cleanup

#
# create two pools and export one
#
log_must zpool create $TESTPOOL1 $VDEV0
log_must zpool export $TESTPOOL1
log_must zpool create $TESTPOOL2 $VDEV1

#
# import pool asyncronously with an injected 10 second delay
#
log_must zinject -P import -s 10 $TESTPOOL1
pool_import $DEVICE_DIR $TESTPOOL1 &

#
# wait until the import is in the injected delay
#
typeset -i tries=0
until importing "injecting"; do
	(( tries++ < 100 )) || log_fail "$TESTPOOL1 import never reached its delay"
	sleep 0.1
done

#
# run some admin commands on the pools while the import is in progress
#

pool_add_device $TESTPOOL1 $VDEV2 "log" &
pool_add_device $TESTPOOL2 $VDEV3 "cache" &
pool_stats "status" $TESTPOOL1 &
pool_stats "status" $TESTPOOL2 &
pool_stats "list" $TESTPOOL1 &
pool_stats "list" $TESTPOOL2 &
pool_create $TESTPOOL1 $VDEV4 &
wait

log_must zpool sync $TESTPOOL1 $TESTPOOL2

zpool history $TESTPOOL1
zpool history $TESTPOOL2

log_must test "5" -lt $(<${DEVICE_DIR}/${TESTPOOL1}-import)

#
# verify that commands to second pool did not wait for import to finish:
# each one finished while the import was still in its delay.  A command
# that waits for the import can only finish after it.
#
for cmd in status list add; do
	read secs state < ${DEVICE_DIR}/${TESTPOOL2}-$cmd
	[[ $state == "during" ]] || log_fail "zpool $cmd $TESTPOOL2" \
	    "finished after $TESTPOOL1's import (in $secs secs)"
done
[[ -e ${DEVICE_DIR}/${TESTPOOL1}-create ]] && log_fail "unexpected pool create"

log_pass "Simple admin commands to different pool not blocked by import"
