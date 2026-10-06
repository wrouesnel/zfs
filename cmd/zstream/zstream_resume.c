// SPDX-License-Identifier: CDDL-1.0
/*
 * This file and its contents are supplied under the terms of the
 * Common Development and Distribution License ("CDDL"), version 1.0.
 * You may only use this file in accordance with the terms of version
 * 1.0 of the CDDL.
 *
 * A full copy of the text of the CDDL should have accompanied this
 * source.  A copy of the CDDL is also available via the Internet at
 * https://opensource.org/license/CDDL-1.0.
 */

/*
 * Copyright (c) 2026 by Will Rouesnel. All rights reserved.
 */

#include <err.h>
#include <errno.h>
#include <libnvpair.h>
#include <libzfs.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/dmu_send.h>
#include <sys/nvpair.h>
#include <sys/stdtypes.h>
#include <sys/sysmacros.h>
#include <sys/zfs_ioctl.h>
#include <sys/zio.h>
#include <unistd.h>
#include <zfs_fletcher.h>

#include "zstream.h"

/*
 * zstream resume converts a complete (or partial) saved send stream into the
 * stream that "zfs send -t" would have generated for a given receive resume
 * token. Only the records at or after the resume point are passed through,
 * and the DRR_BEGIN record is marked as resuming so that "zfs receive" will
 * accept it into the partially received dataset.
 *
 * The token's "bytes" field is not used to locate the resume point. It
 * excludes the DRR_BEGIN header, accumulates across successive resumed
 * receives, and can be held back by records the receiver deferred, so it
 * does not reliably correspond to an offset in the saved stream. Instead,
 * records are matched against the token's object and offset, mirroring the
 * logic that the kernel uses when it generates a resumed stream.
 */

/*
 * Stream features that are recorded in the resume token and must agree with
 * the saved stream. See dmu_recv_begin_sync().
 */
#define	RESUME_FEATURES	(DMU_BACKUP_FEATURE_LARGE_BLOCKS |		\
	DMU_BACKUP_FEATURE_EMBED_DATA | DMU_BACKUP_FEATURE_COMPRESSED |	\
	DMU_BACKUP_FEATURE_RAW)

typedef struct {
	uint64_t	rc_object;
	uint64_t	rc_offset;
	uint64_t	rc_toguid;
	uint64_t	rc_fromguid;
	uint64_t	rc_features;
	boolean_t	rc_seen_begin;
	boolean_t	rc_seen_end;
	boolean_t	rc_found;	/* saw the record named by the token */
	boolean_t	rc_resumed;	/* passed a record after the BEGIN */
	boolean_t	rc_verbose;
	off_t		rc_stream_offset;
	off_t		rc_resume_stream_offset;
	uint64_t	rc_dropped;
	uint64_t	rc_skipped;	/* records seeked or read past */
} resume_context_t;

/*
 * Compare a stream position against the resume point.
 */
static inline int
resume_cmp(const resume_context_t *rc, uint64_t object, uint64_t offset)
{
	if (object != rc->rc_object)
		return (object < rc->rc_object ? -1 : 1);
	if (offset != rc->rc_offset)
		return (offset < rc->rc_offset ? -1 : 1);
	return (0);
}

static inline uint64_t
saturating_end(uint64_t start, uint64_t length)
{
	return (length > UINT64_MAX - start ? UINT64_MAX : start + length);
}

static void
parse_resume_token(const char *token, resume_context_t *rc)
{
	libzfs_handle_t *hdl = libzfs_init();
	if (hdl == NULL)
		errx(1, "%s", libzfs_error_init(errno));
	nvlist_t *nvl = zfs_send_resume_token_to_nvlist(hdl, token);
	if (nvl == NULL) {
		errx(1, "unable to parse resume token: %s",
		    libzfs_error_description(hdl));
	}

	if (nvlist_lookup_uint64(nvl, "object", &rc->rc_object) != 0 ||
	    nvlist_lookup_uint64(nvl, "offset", &rc->rc_offset) != 0 ||
	    nvlist_lookup_uint64(nvl, "toguid", &rc->rc_toguid) != 0) {
		errx(1, "resume token is corrupt");
	}
	rc->rc_fromguid = 0;
	(void) nvlist_lookup_uint64(nvl, "fromguid", &rc->rc_fromguid);

	rc->rc_features = 0;
	if (nvlist_exists(nvl, "largeblockok"))
		rc->rc_features |= DMU_BACKUP_FEATURE_LARGE_BLOCKS;
	if (nvlist_exists(nvl, "embedok"))
		rc->rc_features |= DMU_BACKUP_FEATURE_EMBED_DATA;
	if (nvlist_exists(nvl, "compressok"))
		rc->rc_features |= DMU_BACKUP_FEATURE_COMPRESSED;
	if (nvlist_exists(nvl, "rawok"))
		rc->rc_features |= DMU_BACKUP_FEATURE_RAW;

	fnvlist_free(nvl);
	libzfs_fini(hdl);
}

/*
 * Framing of an XDR-encoded packed nvlist (see nvs_xdr_nvlist() and
 * nvs_xdr_nvpair()): a 4-byte stream header, the list version and flags,
 * then a sequence of pairs, each starting with its total encoded length and
 * its decoded length, terminated by a pair whose lengths are both zero.
 * All integers are 4-byte big-endian.
 */
#define	XDR_NVL_HDR_SIZE	(4 + 4 + 4)
#define	XDR_NVP_HDR_SIZE	(4 + 4 + 4)	/* lengths, name length */
#define	XDR_NVL_END_SIZE	(4 + 4)

static inline uint32_t
xdr_get32(const uint8_t *p)
{
	return (((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
	    ((uint32_t)p[2] << 8) | (uint32_t)p[3]);
}

/*
 * Return the length of the XDR nvpair at buf[off], or 0 for the list
 * terminator. If name is not NULL, report whether the pair has that name.
 */
static size_t
xdr_nvpair_len(const uint8_t *buf, size_t len, size_t off,
    const char *name, boolean_t *match)
{
	if (off + XDR_NVL_END_SIZE > len)
		errx(1, "DRR_BEGIN payload is truncated");
	uint32_t encode_len = xdr_get32(buf + off);
	if (encode_len == 0)
		return (0);
	if (encode_len < XDR_NVP_HDR_SIZE || encode_len % 4 != 0 ||
	    encode_len > len - off - XDR_NVL_END_SIZE) {
		errx(1, "DRR_BEGIN payload is corrupt");
	}
	if (name != NULL) {
		uint32_t name_len = xdr_get32(buf + off + 8);
		*match = (name_len == strlen(name) &&
		    name_len <= encode_len - XDR_NVP_HDR_SIZE &&
		    memcmp(buf + off + XDR_NVP_HDR_SIZE, name, name_len) == 0);
	}
	return (encode_len);
}

static boolean_t
is_resume_nvpair(const uint8_t *buf, size_t len, size_t off)
{
	boolean_t object, offset;
	(void) xdr_nvpair_len(buf, len, off, BEGINNV_RESUME_OBJECT, &object);
	(void) xdr_nvpair_len(buf, len, off, BEGINNV_RESUME_OFFSET, &offset);
	return (object || offset);
}

/*
 * Insert the pairs of the packed nvlist "add" into the packed DRR_BEGIN
 * payload, replacing any existing resume pairs. The original pairs are
 * copied verbatim rather than being unpacked and repacked: the userland
 * XDR encoder sign-extends the elements of uint8 arrays (such as the wrapped
 * keys of a raw stream), producing an nvlist that the kernel will not
 * decode. The new pairs go before "crypt_keydata", matching the layout of
 * the stream that the kernel generates. As in the kernel, the result is
 * zero-padded to a multiple of 8 bytes.
 */
static char *
splice_resume_pairs(const void *orig_in, size_t orig_len,
    const void *add_in, size_t add_len, size_t *out_len)
{
	const uint8_t *orig = orig_in;
	const uint8_t *add = add_in;

	if (orig_len == 0) {
		*out_len = P2ROUNDUP(add_len, 8);
		char *out = safe_calloc(*out_len);
		memcpy(out, add, add_len);
		return (out);
	}
	if (orig_len < XDR_NVL_HDR_SIZE + XDR_NVL_END_SIZE)
		errx(1, "DRR_BEGIN payload is truncated");
	if (orig[0] != NV_ENCODE_XDR)
		errx(1, "DRR_BEGIN payload is not XDR encoded");

	const uint8_t *add_pairs = add + XDR_NVL_HDR_SIZE;
	size_t add_pairs_len = add_len - XDR_NVL_HDR_SIZE - XDR_NVL_END_SIZE;

	uint8_t *out = safe_calloc(P2ROUNDUP(orig_len + add_pairs_len,
	    8));
	memcpy(out, orig, XDR_NVL_HDR_SIZE);
	size_t pos = XDR_NVL_HDR_SIZE;
	boolean_t inserted = B_FALSE;

	size_t off = XDR_NVL_HDR_SIZE, pair_len;
	boolean_t is_keydata;
	while ((pair_len = xdr_nvpair_len(orig, orig_len, off, "crypt_keydata",
	    &is_keydata)) != 0) {
		if (is_keydata && !inserted) {
			memcpy(out + pos, add_pairs, add_pairs_len);
			pos += add_pairs_len;
			inserted = B_TRUE;
		}
		if (!is_resume_nvpair(orig, orig_len, off)) {
			memcpy(out + pos, orig + off, pair_len);
			pos += pair_len;
		}
		off += pair_len;
	}
	if (!inserted) {
		memcpy(out + pos, add_pairs, add_pairs_len);
		pos += add_pairs_len;
	}
	/* The terminator and padding are already zero */
	*out_len = P2ROUNDUP(pos + XDR_NVL_END_SIZE, 8);
	return ((char *)out);
}

/*
 * Rebuild a natively encoded DRR_BEGIN payload with the token's resume pairs,
 * replacing any existing ones. Released versions of OpenZFS pack the payload
 * in the native encoding, which, unlike XDR, can be safely unpacked and
 * repacked. The pairs are placed as in splice_resume_pairs().
 */
static char *
repack_native_payload(nvlist_t *nvl, const resume_context_t *rc,
    size_t *out_len)
{
	nvlist_t *out = fnvlist_alloc();
	boolean_t inserted = B_FALSE;

	for (nvpair_t *pair = nvlist_next_nvpair(nvl, NULL); pair != NULL;
	    pair = nvlist_next_nvpair(nvl, pair)) {
		const char *name = nvpair_name(pair);

		if (!inserted && strcmp(name, "crypt_keydata") == 0) {
			fnvlist_add_uint64(out, BEGINNV_RESUME_OBJECT,
			    rc->rc_object);
			fnvlist_add_uint64(out, BEGINNV_RESUME_OFFSET,
			    rc->rc_offset);
			inserted = B_TRUE;
		}
		if (strcmp(name, BEGINNV_RESUME_OBJECT) != 0 &&
		    strcmp(name, BEGINNV_RESUME_OFFSET) != 0)
			fnvlist_add_nvpair(out, pair);
	}
	if (!inserted) {
		fnvlist_add_uint64(out, BEGINNV_RESUME_OBJECT, rc->rc_object);
		fnvlist_add_uint64(out, BEGINNV_RESUME_OFFSET, rc->rc_offset);
	}

	char *buf = NULL;
	VERIFY0(nvlist_pack(out, &buf, out_len, NV_ENCODE_NATIVE, 0));
	fnvlist_free(out);
	return (buf);
}

/*
 * Check that the DRR_BEGIN record describes the stream that the token was
 * issued for, then mark it as resuming. Returns the new payload, which the
 * caller must free, and updates drr_payloadlen to match.
 */
static char *
resume_begin(dmu_replay_record_t *drr, const void *payload,
    size_t payload_size, resume_context_t *rc)
{
	struct drr_begin *drrb = &drr->drr_u.drr_begin;
	uint64_t featureflags = DMU_GET_FEATUREFLAGS(drrb->drr_versioninfo);

	if (rc->rc_seen_begin || rc->rc_stream_offset != 0) {
		errx(1, "unexpected DRR_BEGIN record at offset %llu",
		    (u_longlong_t)rc->rc_stream_offset);
	}
	rc->rc_seen_begin = B_TRUE;

	if (DMU_GET_STREAM_HDRTYPE(drrb->drr_versioninfo) ==
	    DMU_COMPOUNDSTREAM) {
		errx(1, "compound (replication) streams cannot be resumed");
	}
	if (drrb->drr_toguid != rc->rc_toguid) {
		errx(1, "stream toguid %llu does not match resume token "
		    "toguid %llu", (u_longlong_t)drrb->drr_toguid,
		    (u_longlong_t)rc->rc_toguid);
	}
	if (drrb->drr_fromguid != rc->rc_fromguid) {
		errx(1, "stream fromguid %llu does not match resume token "
		    "fromguid %llu", (u_longlong_t)drrb->drr_fromguid,
		    (u_longlong_t)rc->rc_fromguid);
	}
	if ((featureflags & RESUME_FEATURES) != rc->rc_features) {
		errx(1, "stream feature flags 0x%llx do not match the "
		    "features recorded in the resume token (0x%llx)",
		    (u_longlong_t)(featureflags & RESUME_FEATURES),
		    (u_longlong_t)rc->rc_features);
	}

	nvlist_t *nvl;
	if (payload_size > 0) {
		if (nvlist_unpack((char *)payload, payload_size, &nvl,
		    0) != 0) {
			errx(1, "unable to unpack DRR_BEGIN payload");
		}
	} else {
		nvl = fnvlist_alloc();
	}

	/*
	 * The saved stream may itself be a resumed stream, in which case it
	 * can serve only resume points at or after its own.
	 */
	uint64_t prev_object, prev_offset;
	if ((featureflags & DMU_BACKUP_FEATURE_RESUMING) &&
	    nvlist_lookup_uint64(nvl, BEGINNV_RESUME_OBJECT,
	    &prev_object) == 0 &&
	    nvlist_lookup_uint64(nvl, BEGINNV_RESUME_OFFSET,
	    &prev_offset) == 0 &&
	    resume_cmp(rc, prev_object, prev_offset) > 0) {
		errx(1, "stream was resumed at object %llu offset %llu, "
		    "which is past the token's resume point",
		    (u_longlong_t)prev_object, (u_longlong_t)prev_offset);
	}

	size_t size;
	char *new_payload;
	if (payload_size > 0 &&
	    ((const uint8_t *)payload)[0] == NV_ENCODE_NATIVE) {
		new_payload = repack_native_payload(nvl, rc, &size);
	} else {
		nvlist_t *resume_nvl = fnvlist_alloc();
		fnvlist_add_uint64(resume_nvl, BEGINNV_RESUME_OBJECT,
		    rc->rc_object);
		fnvlist_add_uint64(resume_nvl, BEGINNV_RESUME_OFFSET,
		    rc->rc_offset);
		char *resume_buf = NULL;
		size_t resume_size = 0;
		VERIFY0(nvlist_pack(resume_nvl, &resume_buf, &resume_size,
		    NV_ENCODE_XDR, 0));
		fnvlist_free(resume_nvl);

		new_payload = splice_resume_pairs(payload, payload_size,
		    resume_buf, resume_size, &size);
		free(resume_buf);
	}
	fnvlist_free(nvl);

	drr->drr_payloadlen = size;

	featureflags |= DMU_BACKUP_FEATURE_RESUMING;
	DMU_SET_FEATUREFLAGS(drrb->drr_versioninfo, featureflags);
	return (new_payload);
}

/*
 * Decide whether a record lies entirely before the resume point, so that it
 * can be dropped. Records that straddle the resume point are kept; the
 * receiver applies them idempotently. This must depend only on the record
 * header and the token, as it is also used to seek past records without
 * reading them.
 */
static boolean_t
resume_before_point(const dmu_replay_record_t *drr,
    const resume_context_t *rc)
{
	const struct drr_object *drro = &drr->drr_u.drr_object;
	const struct drr_freeobjects *drrfo = &drr->drr_u.drr_freeobjects;
	const struct drr_write *drrw = &drr->drr_u.drr_write;
	const struct drr_free *drrf = &drr->drr_u.drr_free;
	const struct drr_spill *drrs = &drr->drr_u.drr_spill;
	const struct drr_write_embedded *drrwe =
	    &drr->drr_u.drr_write_embedded;
	const struct drr_object_range *drror = &drr->drr_u.drr_object_range;
	const struct drr_redact *drrr = &drr->drr_u.drr_redact;
	uint64_t end;

	switch (drr->drr_type) {
	case DRR_END:
		return (B_FALSE);

	case DRR_OBJECT:
		return (drro->drr_object < rc->rc_object);

	case DRR_FREEOBJECTS:
		end = saturating_end(drrfo->drr_firstobj, drrfo->drr_numobjs);
		return (end <= rc->rc_object);

	case DRR_OBJECT_RANGE:
		end = saturating_end(drror->drr_firstobj, drror->drr_numslots);
		return (end <= rc->rc_object);

	case DRR_WRITE:
		return (resume_cmp(rc, drrw->drr_object,
		    drrw->drr_offset) < 0);

	case DRR_WRITE_EMBEDDED:
		return (resume_cmp(rc, drrwe->drr_object,
		    drrwe->drr_offset) < 0);

	case DRR_FREE:
		end = saturating_end(drrf->drr_offset, drrf->drr_length);
		return (drrf->drr_object < rc->rc_object ||
		    (drrf->drr_object == rc->rc_object &&
		    end <= rc->rc_offset));

	case DRR_REDACT:
		end = saturating_end(drrr->drr_offset, drrr->drr_length);
		return (drrr->drr_object < rc->rc_object ||
		    (drrr->drr_object == rc->rc_object &&
		    end <= rc->rc_offset));

	case DRR_SPILL:
		return (drrs->drr_object < rc->rc_object);

	default:
		errx(1, "unexpected record type %u in stream",
		    (unsigned)drr->drr_type);
	}
}

/*
 * Decide whether to keep a record, noting whether the record named by the
 * token was seen. FREEOBJECTS records are trimmed, as the kernel never sends
 * frees for objects before the resume object.
 */
static boolean_t
resume_keep_record(dmu_replay_record_t *drr, resume_context_t *rc)
{
	struct drr_freeobjects *drrfo = &drr->drr_u.drr_freeobjects;
	uint64_t end;

	if (resume_before_point(drr, rc))
		return (B_FALSE);

	switch (drr->drr_type) {
	case DRR_END:
		rc->rc_seen_end = B_TRUE;
		break;

	case DRR_OBJECT:
		/* The receiver records offset 0 for OBJECT records */
		if (drr->drr_u.drr_object.drr_object == rc->rc_object &&
		    rc->rc_offset == 0)
			rc->rc_found = B_TRUE;
		break;

	case DRR_FREEOBJECTS:
		end = saturating_end(drrfo->drr_firstobj, drrfo->drr_numobjs);
		if (drrfo->drr_firstobj < rc->rc_object) {
			drrfo->drr_numobjs = end - rc->rc_object;
			drrfo->drr_firstobj = rc->rc_object;
		}
		break;

	case DRR_WRITE:
		if (resume_cmp(rc, drr->drr_u.drr_write.drr_object,
		    drr->drr_u.drr_write.drr_offset) == 0)
			rc->rc_found = B_TRUE;
		break;

	case DRR_WRITE_EMBEDDED:
		if (resume_cmp(rc, drr->drr_u.drr_write_embedded.drr_object,
		    drr->drr_u.drr_write_embedded.drr_offset) == 0)
			rc->rc_found = B_TRUE;
		break;

	default:
		break;
	}
	return (B_TRUE);
}

/*
 * Read exactly size bytes. Returns B_FALSE if the input ended first, warning
 * if it ended part way through.
 */
static boolean_t
read_full(void *buf, size_t size, FILE *fp, off_t offset)
{
	size_t n = fread(buf, 1, size, fp);
	if (n == size)
		return (B_TRUE);
	if (ferror(fp)) {
		err(1, "error reading stream at offset %llu",
		    (u_longlong_t)offset);
	}
	if (n != 0 || offset % sizeof (dmu_replay_record_t) != 0 ||
	    size != sizeof (dmu_replay_record_t)) {
		warnx("input ends mid-record at offset %llu - "
		    "stream is likely corrupt", (u_longlong_t)offset);
	}
	return (B_FALSE);
}

/*
 * Return the size of the payload that follows a record header.
 */
static size_t
payload_size(dmu_replay_record_t *drr, off_t offset)
{
	switch (drr->drr_type) {
	case DRR_BEGIN:
		if (drr->drr_payloadlen > 1U << 28) {
			errx(1, "DRR_BEGIN payload too large at offset %llu",
			    (u_longlong_t)offset);
		}
		return (drr->drr_payloadlen);
	case DRR_OBJECT:
		return (DRR_OBJECT_PAYLOAD_SIZE(&drr->drr_u.drr_object));
	case DRR_SPILL:
		return (DRR_SPILL_PAYLOAD_SIZE(&drr->drr_u.drr_spill));
	case DRR_WRITE:
		return (DRR_WRITE_PAYLOAD_SIZE(&drr->drr_u.drr_write));
	case DRR_WRITE_EMBEDDED:
		return (P2ROUNDUP(
		    (uint64_t)drr->drr_u.drr_write_embedded.drr_psize, 8));
	case DRR_WRITE_BYREF:
		errx(1, "deduplicated streams are not supported; "
		    "use \"zstream redup\" first");
	case DRR_END:
	case DRR_FREEOBJECTS:
	case DRR_FREE:
	case DRR_OBJECT_RANGE:
	case DRR_REDACT:
		return (0);
	default:
		errx(1, "invalid record type %u at offset %llu",
		    (unsigned)drr->drr_type, (u_longlong_t)offset);
	}
}

/*
 * Payloads at least this large are skipped by seeking. Smaller ones are read
 * and discarded, because seeking over them turns sequential reads into small
 * random ones, which defeats readahead and is slower on most storage.
 */
#define	SKIP_SEEK_MIN	(1024 * 1024)

/*
 * Skip past the records before the resume point without validating them,
 * leaving the stream positioned at the last of them so that it is the next
 * record read. Returns B_TRUE if any records were skipped, in which case the
 * stream checksum must be taken up from that record's header. Streams that
 * cannot seek, such as pipes, are read normally. buf must hold at least
 * SKIP_SEEK_MIN bytes.
 */
static boolean_t
skip_records(FILE *fp, resume_context_t *rc, char *buf)
{
	dmu_replay_record_t drr;
	off_t last = -1;
	off_t here = rc->rc_stream_offset;

	if (fseeko(fp, 0, SEEK_CUR) != 0)
		return (B_FALSE);

	for (;;) {
		here = rc->rc_stream_offset;
		if (fread(&drr, sizeof (drr), 1, fp) != 1) {
			if (ferror(fp)) {
				err(1, "error reading stream at offset %llu",
				    (u_longlong_t)here);
			}
			break;
		}
		/* Leave anything unusual to be reported by the main loop */
		if (drr.drr_type == DRR_BEGIN || drr.drr_type == DRR_END ||
		    drr.drr_type == DRR_WRITE_BYREF ||
		    drr.drr_type >= DRR_NUMTYPES ||
		    !resume_before_point(&drr, rc)) {
			break;
		}

		size_t len = payload_size(&drr, here);
		if (len >= SKIP_SEEK_MIN) {
			if (fseeko(fp, len, SEEK_CUR) != 0) {
				err(1, "error seeking past record at offset "
				    "%llu", (u_longlong_t)here);
			}
		} else if (len > 0 && fread(buf, len, 1, fp) != 1) {
			if (ferror(fp)) {
				err(1, "error reading stream at offset %llu",
				    (u_longlong_t)here);
			}
			break;
		}
		if (last >= 0)
			rc->rc_skipped++;
		last = here;
		rc->rc_stream_offset += sizeof (drr) + len;
	}

	rc->rc_stream_offset = (last >= 0) ? last : here;
	if (fseeko(fp, rc->rc_stream_offset, SEEK_SET) != 0) {
		err(1, "error seeking to offset %llu",
		    (u_longlong_t)rc->rc_stream_offset);
	}
	return (last >= 0);
}

/*
 * Write a record, regenerating its checksum. See dump_record() in the kernel.
 */
static void
write_record(dmu_replay_record_t *drr, void *payload, size_t len,
    zio_cksum_t *zc)
{
	if (drr->drr_type == DRR_BEGIN) {
		ZIO_SET_CHECKSUM(zc, 0, 0, 0, 0);
	} else {
		memset(&drr->drr_u.drr_checksum.drr_checksum, 0,
		    sizeof (zio_cksum_t));
	}
	if (drr->drr_type == DRR_END &&
	    !ZIO_CHECKSUM_IS_ZERO(&drr->drr_u.drr_end.drr_checksum))
		drr->drr_u.drr_end.drr_checksum = *zc;

	fletcher_4_incremental_native(drr,
	    offsetof(dmu_replay_record_t, drr_u.drr_checksum.drr_checksum), zc);
	if (drr->drr_type != DRR_BEGIN)
		drr->drr_u.drr_checksum.drr_checksum = *zc;
	fletcher_4_incremental_native(&drr->drr_u.drr_checksum.drr_checksum,
	    sizeof (zio_cksum_t), zc);
	if (fwrite(drr, sizeof (*drr), 1, stdout) != 1)
		err(1, "error writing stream");
	if (len != 0) {
		fletcher_4_incremental_native(payload, len, zc);
		if (fwrite(payload, len, 1, stdout) != 1)
			err(1, "error writing stream");
	}
}

static void
resume_finish(resume_context_t *rc)
{
	if (!rc->rc_seen_begin)
		errx(1, "stream contains no DRR_BEGIN record");
	if (!rc->rc_resumed) {
		errx(1, "stream ends before the resume point "
		    "(object %llu offset %llu)",
		    (u_longlong_t)rc->rc_object,
		    (u_longlong_t)rc->rc_offset);
	}
	if (!rc->rc_found) {
		warnx("warning - no record at the resume point "
		    "(object %llu offset %llu) was found in the "
		    "stream", (u_longlong_t)rc->rc_object,
		    (u_longlong_t)rc->rc_offset);
	}
	if (!rc->rc_seen_end) {
		warnx("warning - input ended without a DRR_END "
		    "record; the resumed stream is incomplete");
	}
	if (rc->rc_verbose) {
		(void) fprintf(stderr, "resumed at object %llu "
		    "offset %llu, input stream offset %llu; "
		    "%llu records skipped\n",
		    (u_longlong_t)rc->rc_object,
		    (u_longlong_t)rc->rc_offset,
		    (u_longlong_t)rc->rc_resume_stream_offset,
		    (u_longlong_t)(rc->rc_dropped + rc->rc_skipped));
	}
}

static void
resume_stream(FILE *fp, resume_context_t *rc)
{
	dmu_replay_record_t thedrr;
	dmu_replay_record_t *drr = &thedrr;
	zio_cksum_t in_cksum = {{0}};
	zio_cksum_t out_cksum = {{0}};
	dmu_replay_record_t begin_drr;
	char *begin_payload = NULL;
	size_t bufsz = SPA_MAXBLOCKSIZE;
	char *buf = safe_malloc(bufsz);
	boolean_t skipping = B_TRUE;
	boolean_t resync = B_FALSE;

	for (;;) {
		resync = B_FALSE;
		if (skipping && rc->rc_seen_begin) {
			skipping = B_FALSE;
			resync = skip_records(fp, rc, buf);
		}
		if (!read_full(drr, sizeof (*drr), fp, rc->rc_stream_offset))
			break;
		if (rc->rc_stream_offset == 0) {
			if (drr->drr_u.drr_begin.drr_magic ==
			    BSWAP_64(DMU_BACKUP_MAGIC)) {
				errx(1, "byteswapped streams are not "
				    "supported");
			}
			if (drr->drr_type != DRR_BEGIN ||
			    drr->drr_u.drr_begin.drr_magic !=
			    DMU_BACKUP_MAGIC) {
				errx(1, "stream does not start with a "
				    "DRR_BEGIN record");
			}
		}

		/* Verify the checksum of the input stream */
		if (drr->drr_type == DRR_BEGIN)
			ZIO_SET_CHECKSUM(&in_cksum, 0, 0, 0, 0);
		fletcher_4_incremental_native(drr, offsetof(dmu_replay_record_t,
		    drr_u.drr_checksum.drr_checksum), &in_cksum);
		if (resync) {
			/*
			 * The records before this one were skipped without
			 * being read, so take up the stream checksum from
			 * this record's header and validate from here on.
			 */
			in_cksum = drr->drr_u.drr_checksum.drr_checksum;
		} else if (!ZIO_CHECKSUM_IS_ZERO(
		    &drr->drr_u.drr_checksum.drr_checksum) &&
		    !ZIO_CHECKSUM_EQUAL(in_cksum,
		    drr->drr_u.drr_checksum.drr_checksum)) {
			errx(1, "invalid checksum in record at offset %llu",
			    (u_longlong_t)rc->rc_stream_offset);
		}
		fletcher_4_incremental_native(
		    &drr->drr_u.drr_checksum.drr_checksum,
		    sizeof (zio_cksum_t), &in_cksum);

		size_t len = payload_size(drr, rc->rc_stream_offset);
		if (len > bufsz) {
			buf = realloc(buf, len);
			if (buf == NULL)
				err(1, "realloc");
			bufsz = len;
		}
		if (len != 0) {
			if (!read_full(buf, len, fp, rc->rc_stream_offset))
				break;
			fletcher_4_incremental_native(buf, len, &in_cksum);
		}

		if (drr->drr_type == DRR_BEGIN) {
			/*
			 * Hold back the DRR_BEGIN record until a record at
			 * the resume point is found, so that nothing is
			 * written if the stream ends before it.
			 */
			begin_payload = resume_begin(drr, buf, len, rc);
			begin_drr = *drr;
		} else if (!rc->rc_seen_begin) {
			errx(1, "stream does not start with a DRR_BEGIN "
			    "record");
		} else if (!resume_keep_record(drr, rc)) {
			rc->rc_dropped++;
		} else {
			if (!rc->rc_resumed) {
				rc->rc_resumed = B_TRUE;
				rc->rc_resume_stream_offset =
				    rc->rc_stream_offset;
				write_record(&begin_drr, begin_payload,
				    begin_drr.drr_payloadlen, &out_cksum);
			}
			write_record(drr, buf, len, &out_cksum);
		}

		rc->rc_stream_offset += sizeof (*drr) + len;
		if (drr->drr_type == DRR_END)
			break;
	}
	free(begin_payload);
	free(buf);

	if (fflush(stdout) != 0)
		err(1, "error writing stream");
	resume_finish(rc);
}

int
zstream_do_resume(int argc, char *argv[])
{
	int c;
	resume_context_t rc = {0};

	while ((c = getopt(argc, argv, "v")) != -1) {
		switch (c) {
		case 'v':
			rc.rc_verbose = B_TRUE;
			break;
		case '?':
			warnx("invalid option '%c'", optopt);
			zstream_usage();
		}
	}

	argc -= optind;
	argv += optind;

	if (argc < 1) {
		warnx("missing resume token");
		zstream_usage();
	} else if (argc > 2) {
		warnx("too many arguments");
		zstream_usage();
	}

	parse_resume_token(argv[0], &rc);

	FILE *fp = stdin;
	if (argc > 1) {
		fp = fopen(argv[1], "r");
		if (fp == NULL)
			err(1, "unable to open %s", argv[1]);
	} else if (isatty(STDIN_FILENO)) {
		errx(1, "the send stream is a binary format and can not be "
		    "read from a terminal; standard input must be "
		    "redirected");
	}

	fletcher_4_init();
	resume_stream(fp, &rc);
	fletcher_4_fini();

	if (fp != stdin)
		(void) fclose(fp);
	return (0);
}
