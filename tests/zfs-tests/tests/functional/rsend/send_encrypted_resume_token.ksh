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
# DESCRIPTION:
# The resume token comes from the receiving system.  A token for a raw
# send of an encrypted dataset whose 'rawok' flag was removed must not
# make 'zfs send -t' send that dataset decrypted, unless the caller asks
# for that with --no-preserve-encryption (-U).
#
# STRATEGY:
# 1. Create an encrypted dataset holding a file of known plaintext.
# 2. Raw send a snapshot of it, and receive a truncated copy of the
#    stream with 'zfs recv -s', which leaves a resume token.
# 3. Verify 'zfs send -t' of that token sends a raw stream.
# 4. Make a copy of the token without 'rawok'.
# 5. Verify 'zfs send -t' of the modified token fails, and doesn't write
#    the plaintext.
# 6. Verify 'zfs send -w -t' of the modified token sends a raw stream.
# 7. Verify 'zfs send -U -t' of the modified token sends the dataset
#    decrypted, as asked.
#

verify_runnable "both"

function cleanup
{
	datasetexists $TESTPOOL/recv && destroy_dataset $TESTPOOL/recv -r
	datasetexists $TESTPOOL/crypt && destroy_dataset $TESTPOOL/crypt -r
	rm -f $keyfile $sendfile $resumefile $errfile
}
log_onexit cleanup

#
# Print the resume token $1 with its 'rawok' flag renamed to 'xawok',
# which libzfs ignores.  A token is "1-<checksum>-<packed length>-<hex
# payload>": the payload is a zlib-compressed packed nvlist and the
# checksum is the first word of its fletcher-4 checksum (the sum of its
# native-endian 32-bit words).
#
function token_without_rawok
{
	python3 -c '
import struct, sys, zlib
ver, cksum, plen, payload = sys.argv[1].split("-")
packed = zlib.decompress(bytes.fromhex(payload))
if len(packed) != int(plen, 16) or packed.count(b"rawok") != 1:
	sys.exit("unexpected resume token payload")
packed = packed.replace(b"rawok", b"xawok")
comp = zlib.compress(packed)
n = len(comp) // 4
a = sum(struct.unpack("=%dI" % n, comp[:n * 4])) % 2**64
print("%s-%x-%x-%s" % (ver, a, len(packed), comp.hex()))
' "$1"
}

log_assert "'zfs send -t' must not send an encrypted dataset decrypted" \
	"because the resume token lacks 'rawok'"

typeset keyfile=$TEST_BASE_DIR/pkey
typeset sendfile=$TEST_BASE_DIR/sendfile
typeset resumefile=$TEST_BASE_DIR/resumefile
typeset errfile=$TEST_BASE_DIR/errfile
typeset marker="zfs-resume-token-plaintext-marker"

log_must eval "echo 'password' > $keyfile"
log_must zfs create -o encryption=on -o keyformat=passphrase \
	-o keylocation=file://$keyfile -o compression=off $TESTPOOL/crypt
# The stream is cut inside the first file, so the second one (with the
# marker) is sent by the resumed stream.
log_must dd if=/dev/urandom of=/$TESTPOOL/crypt/first bs=1M count=4
log_must eval "awk 'BEGIN { for (i = 0; i < 32768; i++) print \"$marker\" }'" \
	"> /$TESTPOOL/crypt/second"
log_must zfs snapshot $TESTPOOL/crypt@snap

log_must eval "zfs send -w $TESTPOOL/crypt@snap > $sendfile"
log_mustnot grep -qa $marker $sendfile
log_must truncate -s 1M $sendfile
log_mustnot eval "zfs recv -s $TESTPOOL/recv < $sendfile"
typeset token=$(get_prop receive_resume_token $TESTPOOL/recv)
[[ -n "$token" && "$token" != "-" ]] || log_fail "no resume token"

# The unmodified token resumes the raw send.
log_must eval "zfs send -t $token > $resumefile"
log_must eval "zstream dump $resumefile | grep -q crypt_keydata"
log_mustnot grep -qa $marker $resumefile

typeset badtoken=$(token_without_rawok $token)
[[ -n "$badtoken" ]] || log_fail "could not modify the resume token"
log_must eval "zfs send -nvt $badtoken | grep -q xawok"

if zfs send -t $badtoken > $resumefile 2> $errfile; then
	grep -qa $marker $resumefile && log_fail "'zfs send -t' of a token" \
	    "without rawok sent $TESTPOOL/crypt@snap decrypted"
	log_fail "'zfs send -t' of a token without rawok succeeded"
fi
cat $errfile
log_mustnot grep -qa $marker $resumefile
log_must grep -q "raw flag or no-preserve-encryption flag" $errfile

# With --raw the modified token resumes the raw send.
log_must eval "zfs send -w -t $badtoken > $resumefile"
log_must eval "zstream dump $resumefile | grep -q crypt_keydata"
log_mustnot grep -qa $marker $resumefile

# With --no-preserve-encryption the caller asked for decrypted data.
log_must eval "zfs send -U -t $badtoken > $resumefile"
log_mustnot eval "zstream dump $resumefile | grep -q crypt_keydata"
log_must grep -qa $marker $resumefile

log_pass "'zfs send -t' doesn't send an encrypted dataset decrypted" \
	"because the resume token lacks 'rawok'"
