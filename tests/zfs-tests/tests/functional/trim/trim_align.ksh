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
. $STF_SUITE/tests/functional/trim/trim.kshlib
. $STF_SUITE/tests/functional/trim/trim.cfg

#
# DESCRIPTION:
#	With zfs_trim_align_shift set, every TRIM issued to a leaf vdev
#	covers whole aligned blocks; with it unset, TRIM ranges are exact.
#
# STRATEGY:
#	1. Fill a file vdev with a non-zero pattern and create an ashift=9
#	   pool on it.
#	2. Write 1.5K and 100.5K files alternately, remove every other
#	   large file, so the free extents start and end mid-4K-page.
#	3. Export the pool and copy the vdev, import, 'zpool trim -w',
#	   export again.  A sector that was non-zero and now reads zero
#	   was trimmed (the file vdev punches exactly the TRIM range).
#	4. Count 4K pages holding both a trimmed sector and an unchanged
#	   non-zero sector, i.e. pages the TRIMs covered partially.  Pages
#	   with rewritten sectors are new blocks allocated since the copy,
#	   whose zero sectors look trimmed, so they are not counted.
#	5. zfs_trim_align_shift=0: partial pages are expected.
#	   zfs_trim_align_shift=12: no partial pages, and still trimmed.
#	6. Verify the pool scrubs clean.
#

verify_runnable "global"

# Manual trim does not reclaim space on file vdevs on FreeBSD.
if is_freebsd; then
	log_unsupported "Manual trim on file vdevs not supported on FreeBSD"
fi

typeset VDEV=$TRIM_VDEV1
typeset COPY=$TRIM_DIR/trim-align-before

function cleanup
{
	poolexists $TESTPOOL && destroy_pool $TESTPOOL
	rm -f $VDEV $COPY
	set_tunable32 TRIM_ALIGN_SHIFT 0
}
log_onexit cleanup

log_assert "zfs_trim_align_shift rounds TRIM ranges in to its alignment"

# Prints "<partial pages> <trimmed sectors>" between the labels.
function partial_pages
{
	python3 - $COPY $VDEV <<-'EOF'
	import sys
	S, P = 512, 4096
	z = bytes(S)
	b, a = open(sys.argv[1], "rb"), open(sys.argv[2], "rb")
	b.seek(0, 2)
	end = b.tell() - 512 * 1024
	b.seek(4 << 20); a.seek(4 << 20)
	partial = trimmed = 0
	for off in range(4 << 20, end, P):
	    pb, pa = b.read(P), a.read(P)
	    t = k = w = 0
	    for i in range(0, P, S):
	        sb, sa = pb[i:i + S], pa[i:i + S]
	        if sb != z and sa == z:
	            t += 1
	        elif sb != z and sa == sb:
	            k += 1
	        elif sa != z:
	            w += 1
	    trimmed += t
	    if t and k and not w:
	        partial += 1
	print(partial, trimmed)
	EOF
}

for shift in 0 12; do
	# Not fatal: without the tunable the checks below fail instead.
	set_tunable32 TRIM_ALIGN_SHIFT $shift || \
	    log_note "cannot set zfs_trim_align_shift=$shift"

	log_must python3 -c \
	    "open('$VDEV', 'wb').write(b'\xaa' * $MINVDEVSIZE)"
	log_must zpool create -f -o ashift=9 -O compression=off \
	    $TESTPOOL $VDEV
	for i in $(seq 1 200); do
		log_must dd if=/dev/urandom of=/$TESTPOOL/s$i bs=512 count=3 \
		    status=none
		log_must dd if=/dev/urandom of=/$TESTPOOL/l$i bs=512 \
		    count=201 status=none
	done
	sync_pool $TESTPOOL
	for i in $(seq 1 2 200); do
		log_must rm /$TESTPOOL/l$i
	done
	for i in 1 2 3 4; do
		sync_pool $TESTPOOL
	done

	log_must zpool export $TESTPOOL
	log_must cp $VDEV $COPY
	log_must zpool import -d $TRIM_DIR $TESTPOOL
	log_must zpool trim -w $TESTPOOL
	log_must zpool export $TESTPOOL

	set -A res $(partial_pages)
	log_note "zfs_trim_align_shift=$shift: ${res[0]} partially" \
	    "trimmed 4K pages, ${res[1]} sectors trimmed"
	[[ ${res[1]} -gt 0 ]] || log_fail "nothing was trimmed"
	if [[ $shift -eq 0 ]]; then
		[[ ${res[0]} -gt 0 ]] || \
		    log_fail "expected partial-page TRIMs at ashift=9"
	else
		[[ ${res[0]} -eq 0 ]] || \
		    log_fail "${res[0]} pages trimmed partially"
	fi

	log_must zpool import -d $TRIM_DIR $TESTPOOL
	log_must zpool scrub -w $TESTPOOL
	log_must check_pool_status $TESTPOOL "errors" "No known data errors"
	log_must zpool destroy $TESTPOOL
	log_must rm -f $VDEV $COPY
done

log_pass "zfs_trim_align_shift rounds TRIM ranges in to its alignment"
