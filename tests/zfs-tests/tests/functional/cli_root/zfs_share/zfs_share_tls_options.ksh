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
#	The NFS-over-TLS export options, and the other exports(5) options
#	of the platform, are accepted in the sharenfs property and written
#	to the ZFS exports file as options.
#
# STRATEGY:
#	1. On Linux, set sharenfs with each of xprtsec=, nordirplus, pnfs,
#	   no_pnfs, security_label and reexport=, and verify that the
#	   property is set and the option is in the export's line of
#	   /etc/exports.d/zfs.exports
#	2. On FreeBSD, set sharenfs with each of tls, tlscert and
#	   tlscertuser, and verify that /etc/zfs/exports has it as an
#	   option (-tls), not as a host name
#

verify_runnable "global"

function cleanup
{
	log_must zfs set sharenfs=off $TESTPOOL/$TESTFS
	is_shared $TESTPOOL/$TESTFS && \
		log_must unshare_fs $TESTPOOL/$TESTFS
}

#
# Set sharenfs to $1 and check that the export's line in the exports file
# contains $2.  The NFS server may not know every option (exportfs then
# complains), but the exports file is written either way.
#
function check_option # sharenfs expected
{
	typeset opts=$1 expected=$2
	typeset line

	log_must zfs set sharenfs="$opts" $TESTPOOL/$TESTFS
	log_must eval "[[ \"\$(get_prop sharenfs $TESTPOOL/$TESTFS)\" == \"$opts\" ]]"
	line=$(awk -v m="$mntpt" '$1 == m' $exports)
	[[ -n $line ]] || log_fail "$mntpt is not in $exports"
	log_note "$exports: $line"
	[[ $line == *"$expected"* ]] || \
	    log_fail "sharenfs=$opts: '$expected' is not in '$line'"
}

log_assert "The NFS-over-TLS options are accepted in sharenfs."
log_onexit cleanup

cleanup
mntpt=$(get_prop mountpoint $TESTPOOL/$TESTFS)

if is_linux; then
	exports=/etc/exports.d/zfs.exports
	for opt in xprtsec=mtls xprtsec=tls:mtls nordirplus pnfs no_pnfs \
	    security_label reexport=auto-fsidnum; do
		check_option "rw=@127.0.0.1,$opt" ",$opt"
	done
elif is_freebsd; then
	exports=/etc/zfs/exports
	for opt in tls tlscert tlscertuser; do
		check_option "$opt,network=127.0.0.0/8" "-$opt "
	done
else
	log_unsupported "No ZFS exports file on this platform."
fi

log_pass "The NFS-over-TLS options are accepted in sharenfs."
