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
# Verify that renaming a ZVOL, a snapshot of it, or a dataset above it
# also updates the /dev/zvol links of the ZVOL's partitions (-partN).
#
# STRATEGY:
# 1. Create a ZVOL with snapdev=visible and a GPT with partitions 1 and 3
#    (partition 2 deleted), and a snapshot of it
# 2. Rename the snapshot; verify the snapshot's -part1 and -part3 links
#    follow and the old ones are gone
# 3. Rename the ZVOL; verify the same for the ZVOL's links
# 4. Rename the parent dataset; verify the same again
#

verify_runnable "global"

if ! is_linux; then
	log_unsupported "Only Linux has a /dev/zvol link per ZVOL partition"
fi

function cleanup
{
	destroy_dataset "$PARENT-renamed" "-rf"
	destroy_dataset "$PARENT" "-rf"
	block_device_wait
}

#
# Wait for udev to process its queue and for a /dev/zvol link to point to
# the given device node, or to be gone if no node is given.  This must not
# use block_device_wait(), which triggers change events and would hide a
# change event the kernel did not send.
#
function link_wait # link [node]
{
	typeset link=$1
	typeset node=$2
	typeset -i i

	for ((i = 0; i < 30; i++)); do
		udevadm settle
		if [[ -z $node ]]; then
			[[ ! -e $link && ! -L $link ]] && return 0
		else
			[[ -e $link && $(readlink -f $link) == $node ]] && \
			    return 0
		fi
		sleep 1
	done
	return 1
}

#
# Print the device node a /dev/zvol link points to, once udev has created
# the link.
#
function link_node # link
{
	typeset link=$1
	typeset -i i

	for ((i = 0; i < 30; i++)); do
		udevadm settle
		[[ -b $link ]] && break
		sleep 1
	done
	[[ -b $link ]] || return 1
	readlink -f $link
}

#
# Verify that the partition links of the old name are gone and that those
# of the new name point to the same partition device nodes.
#
function check_part_links # old new
{
	typeset old=$1
	typeset new=$2
	typeset p

	for p in 1 3; do
		link_wait "$ZVOL_DEVDIR/$new-part$p" ${NODE[$p]} || log_fail \
		    "$ZVOL_DEVDIR/$new-part$p does not point to ${NODE[$p]}"
		link_wait "$ZVOL_DEVDIR/$old-part$p" || \
		    log_fail "$ZVOL_DEVDIR/$old-part$p still exists"
	done
	log_note "The partition links moved from $old to $new"
}

log_assert "Renaming a ZVOL also updates the links of its partitions"
log_onexit cleanup

PARENT="$TESTPOOL/parent.$$"
VOL="$PARENT/vol"
typeset -A NODE

# 1. Create a ZVOL with partitions 1 and 3, and a snapshot of it
log_must zfs create "$PARENT"
log_must zfs create -V 64m -o snapdev=visible "$VOL"
DEV=$(link_node "$ZVOL_DEVDIR/$VOL") || log_fail "No device for $VOL"
log_must parted -s $DEV mklabel gpt mkpart p1 1MiB 16MiB \
    mkpart p2 16MiB 32MiB mkpart p3 32MiB 48MiB rm 2
log_must zfs snapshot "$VOL@snap"
for p in 1 3; do
	NODE[$p]=$(link_node "$ZVOL_DEVDIR/$VOL@snap-part$p") || \
	    log_fail "No partition $p link for $VOL@snap"
done

# 2. Rename the snapshot
log_must zfs rename "$VOL@snap" "$VOL@snap-renamed"
check_part_links "$VOL@snap" "$VOL@snap-renamed"

# 3. Rename the ZVOL
for p in 1 3; do
	NODE[$p]=$(link_node "$ZVOL_DEVDIR/$VOL-part$p") || \
	    log_fail "No partition $p link for $VOL"
done
log_must zfs rename "$VOL" "$VOL-renamed"
check_part_links "$VOL" "$VOL-renamed"

# 4. Rename the parent dataset
log_must zfs rename "$PARENT" "$PARENT-renamed"
check_part_links "$VOL-renamed" "$PARENT-renamed/vol-renamed"

log_pass "Renaming a ZVOL also updates the links of its partitions"
