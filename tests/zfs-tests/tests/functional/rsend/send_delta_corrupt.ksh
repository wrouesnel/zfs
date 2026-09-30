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

. $STF_SUITE/tests/functional/rsend/rsend.kshlib

#
# Description:
# Verify that the receiver of a "zfs send --delta" stream refuses a
# DRR_WRITE_DELTA record that does not rebuild the block it describes,
# even when the stream checksums are valid.
#
# Strategy:
# 1. Create a filesystem with a file of random data, snapshot @a and
#    replicate it.  Modify the file in place; snapshot @b.  Send -i @a @b
#    --delta.
# 2. Rewrite the stream with a python helper that changes a byte of the
#    first DRR_WRITE_DELTA record (its block checksum, the last byte of its
#    patch, or its first patch op) and recomputes every stream checksum.
#    The helper reproduces the original stream exactly when it changes
#    nothing.
# 3. Each tampered stream passes zstream dump (the stream is consistent)
#    but fails to receive; the target keeps @a only.
# 4. The original stream is still received and verified.
#

verify_runnable "both"

sendfs=$POOL/refs_send
recvfs=$POOL2/refs_recv
stream=$BACKDIR/delta
bad=$BACKDIR/delta.bad
tamper=$BACKDIR/delta_tamper.py
typeset -i nrec=8

function cleanup
{
	datasetexists $sendfs && destroy_dataset $sendfs -r
	datasetexists $recvfs && destroy_dataset $recvfs -r
	rm -f $stream $bad $tamper $BACKDIR/full $BACKDIR/recv.err
}

#
# The helper: delta_tamper.py <in> <out> none|cksum|patch|op
#
cat >$tamper <<'EOF'
import struct
import sys

HDR = 312
CKOFF = HDR - 32
BEGIN, OBJECT, WRITE, END, SPILL, EMBEDDED, DELTA = 0, 1, 3, 5, 7, 8, 11
M = (1 << 64) - 1


def rup8(n):
	return (n + 7) & ~7


def payload_len(buf, off, rtype):
	u = off + 8
	if rtype == BEGIN:
		return struct.unpack_from("<I", buf, off + 4)[0]
	if rtype == OBJECT:
		return rup8(struct.unpack_from("<I", buf, u + 20)[0])
	if rtype == WRITE:
		comp = buf[u + 42]
		lsize = struct.unpack_from("<Q", buf, u + 24)[0]
		psize = struct.unpack_from("<Q", buf, u + 88)[0]
		return psize if comp != 0 else lsize
	if rtype == SPILL:
		length, = struct.unpack_from("<Q", buf, u + 8)
		csize, = struct.unpack_from("<Q", buf, u + 32)
		return csize if csize != 0 else length
	if rtype == EMBEDDED:
		return rup8(struct.unpack_from("<I", buf, u + 44)[0])
	if rtype == DELTA:
		return rup8(struct.unpack_from("<Q", buf, u + 64)[0])
	return 0


class Fletcher4:
	def __init__(self):
		self.a = self.b = self.c = self.d = 0

	def update(self, data):
		a, b, c, d = self.a, self.b, self.c, self.d
		for (w,) in struct.iter_unpack("<I", data):
			a = (a + w) & M
			b = (b + a) & M
			c = (c + b) & M
			d = (d + c) & M
		self.a, self.b, self.c, self.d = a, b, c, d

	def pack(self):
		return struct.pack("<4Q", self.a, self.b, self.c, self.d)


src, dst, mode = sys.argv[1:4]
buf = bytearray(open(src, "rb").read())
off = 0
done = False
ck = Fletcher4()
while True:
	rtype = struct.unpack_from("<I", buf, off)[0]
	plen = payload_len(buf, off, rtype)
	if rtype == DELTA and not done and mode != "none":
		u = off + 8
		patchlen = struct.unpack_from("<Q", buf, u + 64)[0]
		if mode == "cksum":
			buf[u + 80] ^= 0xff
		elif mode == "patch":
			buf[off + HDR + patchlen - 1] ^= 0x5a
		elif mode == "op":
			buf[off + HDR] = 0x7f
		done = True
	if rtype == END:
		buf[off + 8:off + 40] = ck.pack()
	ck.update(bytes(buf[off:off + CKOFF]))
	if rtype != BEGIN:
		buf[off + CKOFF:off + HDR] = ck.pack()
	ck.update(bytes(buf[off + CKOFF:off + HDR]))
	ck.update(bytes(buf[off + HDR:off + HDR + plen]))
	off += HDR + plen
	if rtype == END:
		break
if off != len(buf):
	sys.exit("stream not parsed to its end: %d of %d" % (off, len(buf)))
if mode != "none" and not done:
	sys.exit("no DRR_WRITE_DELTA record")
open(dst, "wb").write(buf)
EOF

log_assert "A DRR_WRITE_DELTA record that does not rebuild its block is" \
	"refused"
log_onexit cleanup

log_must zfs create -o recordsize=$REFS_RECSIZE $sendfs
mntpnt=$(get_prop mountpoint $sendfs)
refs_mkfile $mntpnt/f1 $nrec
log_must zfs snapshot $sendfs@a
log_must eval "zfs send $sendfs@a >$BACKDIR/full"
log_must eval "zfs recv -u $recvfs <$BACKDIR/full"
for rec in 1 3 5; do
	refs_poke $mntpnt/f1 $rec
done
log_must zfs snapshot $sendfs@b
log_must eval "zfs send --delta -i @a $sendfs@b >$stream"
log_must test "$(stream_delta_records $stream)" -eq 3

log_must python3 $tamper $stream $bad none
log_must cmp $stream $bad

for mode in cksum patch op; do
	log_must python3 $tamper $stream $bad $mode
	log_mustnot cmp -s $stream $bad
	log_must eval "zstream dump $bad >/dev/null"
	# (comparing the snapshots below mounts the target)
	log_must zfs rollback $recvfs@a
	log_mustnot eval "zfs recv -u $recvfs <$bad 2>$BACKDIR/recv.err"
	cat $BACKDIR/recv.err
	log_mustnot grep -q "has been modified" $BACKDIR/recv.err
	log_mustnot snapexists $recvfs@b
	refs_cmp_snaps $sendfs $recvfs a
done

log_must zfs rollback $recvfs@a
log_must eval "zfs recv -u $recvfs <$stream"
refs_cmp_snaps $sendfs $recvfs a b

log_pass "A DRR_WRITE_DELTA record that does not rebuild its block is" \
	"refused"
