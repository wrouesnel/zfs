// SPDX-License-Identifier: CDDL-1.0
/*
 * CDDL HEADER START
 *
 * The contents of this file are subject to the terms of the
 * Common Development and Distribution License (the "License").
 * You may not use this file except in compliance with the License.
 *
 * You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
 * or https://opensource.org/licenses/CDDL-1.0.
 * See the License for the specific language governing permissions
 * and limitations under the License.
 *
 * CDDL HEADER END
 */

/*
 * Block delta encoding and similarity sketches for DRR_WRITE_DELTA
 * (prototype).  See sys/zfs_delta.h for the patch format.
 *
 * This file only depends on memcpy/memcmp/memset so that it can be
 * built and tested outside the kernel.
 */

#ifndef ZFS_DELTA_STANDALONE
#include <sys/zfs_context.h>
#endif
#include <sys/zfs_delta.h>

/* Shortest match worth a COPY op. */
#define	DELTA_MINMATCH	16

static inline uint64_t
delta_load64(const uint8_t *p)
{
	uint64_t v;
	memcpy(&v, p, sizeof (v));
	return (v);
}

static inline uint64_t
delta_mix64(uint64_t x)
{
	x ^= x >> 30;
	x *= 0xbf58476d1ce4e5b9ULL;
	x ^= x >> 27;
	x *= 0x94d049bb133111ebULL;
	x ^= x >> 31;
	return (x);
}

static inline uint32_t
delta_hash(const uint8_t *p)
{
	uint64_t h = delta_load64(p) * 0x9e3779b97f4a7c15ULL ^
	    delta_load64(p + 8) * 0xc2b2ae3d27d4eb4fULL;
	h ^= h >> 29;
	return ((uint32_t)((h * 0x165667b19e3779f9ULL) >>
	    (64 - ZFS_DELTA_HASH_BITS)));
}

static boolean_t
delta_put_varint(uint8_t *out, size_t *op, size_t cap, uint64_t v)
{
	do {
		if (*op >= cap)
			return (B_FALSE);
		uint8_t b = v & 0x7f;
		v >>= 7;
		out[(*op)++] = b | (v != 0 ? 0x80 : 0);
	} while (v != 0);
	return (B_TRUE);
}

static boolean_t
delta_get_varint(const uint8_t *in, size_t *ip, size_t len, uint64_t *vp)
{
	uint64_t v = 0;
	for (int shift = 0; shift < 64; shift += 7) {
		if (*ip >= len)
			return (B_FALSE);
		uint8_t b = in[(*ip)++];
		v |= (uint64_t)(b & 0x7f) << shift;
		if (!(b & 0x80)) {
			*vp = v;
			return (B_TRUE);
		}
	}
	return (B_FALSE);
}

static boolean_t
delta_put_add(uint8_t *out, size_t *op, size_t cap, const uint8_t *lit,
    size_t len)
{
	if (*op >= cap)
		return (B_FALSE);
	out[(*op)++] = ZFS_DELTA_OP_ADD;
	if (!delta_put_varint(out, op, cap, len) || cap - *op < len)
		return (B_FALSE);
	memcpy(out + *op, lit, len);
	*op += len;
	return (B_TRUE);
}

static boolean_t
delta_put_copy(uint8_t *out, size_t *op, size_t cap, size_t refoff,
    size_t len)
{
	if (*op >= cap)
		return (B_FALSE);
	out[(*op)++] = ZFS_DELTA_OP_COPY;
	return (delta_put_varint(out, op, cap, refoff) &&
	    delta_put_varint(out, op, cap, len));
}

static inline boolean_t
delta_match_at(const uint8_t *ref, size_t reflen, const uint8_t *tgt,
    size_t j, int64_t i)
{
	return (i >= 0 && (size_t)i + DELTA_MINMATCH <= reflen &&
	    memcmp(ref + i, tgt + j, DELTA_MINMATCH) == 0);
}

/*
 * Greedy encoder.  At each target position we try, in order: the same
 * position in the reference (in-place edits), the position predicted by
 * the previous copy (shifted content), and the hash table of every
 * reference position.  Matches are extended in both directions.
 */
size_t
zfs_delta_encode(const uint8_t *ref, size_t reflen, const uint8_t *tgt,
    size_t tgtlen, uint8_t *out, size_t outcap, uint32_t *htab)
{
	size_t op = 0, j = 0, lit = 0;
	int64_t shift = 0;

	memset(htab, 0xff, ZFS_DELTA_HASH_SIZE * sizeof (uint32_t));
	for (size_t i = 0; i + DELTA_MINMATCH <= reflen; i++)
		htab[delta_hash(ref + i)] = (uint32_t)i;

	while (j + DELTA_MINMATCH <= tgtlen) {
		int64_t i;

		if (delta_match_at(ref, reflen, tgt, j, (int64_t)j)) {
			i = (int64_t)j;
		} else if (shift != 0 &&
		    delta_match_at(ref, reflen, tgt, j, (int64_t)j + shift)) {
			i = (int64_t)j + shift;
		} else {
			uint32_t h = htab[delta_hash(tgt + j)];
			if (h == UINT32_MAX ||
			    !delta_match_at(ref, reflen, tgt, j, h)) {
				j++;
				continue;
			}
			i = h;
		}

		while (j > lit && i > 0 && tgt[j - 1] == ref[i - 1]) {
			j--;
			i--;
		}
		size_t len = DELTA_MINMATCH;
		while (j + len < tgtlen && (size_t)i + len < reflen &&
		    tgt[j + len] == ref[i + len])
			len++;

		if (j > lit && !delta_put_add(out, &op, outcap, tgt + lit,
		    j - lit))
			return (0);
		if (!delta_put_copy(out, &op, outcap, (size_t)i, len))
			return (0);
		shift = i - (int64_t)j;
		j += len;
		lit = j;
	}
	if (lit < tgtlen &&
	    !delta_put_add(out, &op, outcap, tgt + lit, tgtlen - lit))
		return (0);
	return (op);
}

int
zfs_delta_decode(const uint8_t *ref, size_t reflen, const uint8_t *patch,
    size_t patchlen, uint8_t *tgt, size_t tgtlen)
{
	size_t pp = 0, tp = 0;

	while (pp < patchlen) {
		uint8_t o = patch[pp++];
		uint64_t a, b;

		if (o == ZFS_DELTA_OP_COPY) {
			if (!delta_get_varint(patch, &pp, patchlen, &a) ||
			    !delta_get_varint(patch, &pp, patchlen, &b) ||
			    a > reflen || b > reflen - a || b > tgtlen - tp)
				return (SET_ERROR(EINVAL));
			memcpy(tgt + tp, ref + a, b);
			tp += b;
		} else if (o == ZFS_DELTA_OP_ADD) {
			if (!delta_get_varint(patch, &pp, patchlen, &a) ||
			    a > patchlen - pp || a > tgtlen - tp)
				return (SET_ERROR(EINVAL));
			memcpy(tgt + tp, patch + pp, a);
			pp += a;
			tp += a;
		} else {
			return (SET_ERROR(EINVAL));
		}
	}
	return (tp == tgtlen ? 0 : SET_ERROR(EINVAL));
}

static uint64_t delta_gear[256];
static volatile boolean_t delta_gear_ready = B_FALSE;

static void
delta_gear_init(void)
{
	/* Deterministic, so a racing initialization writes the same values. */
	for (int b = 0; b < 256; b++)
		delta_gear[b] = delta_mix64(0x5a5a5a5a00000000ULL + b);
	delta_gear_ready = B_TRUE;
}

boolean_t
zfs_delta_sketch(const uint8_t *buf, size_t len, uint64_t sf[ZFS_DELTA_NSF])
{
	uint64_t feat[ZFS_DELTA_NFEATURES] = {0};
	uint64_t g = 0;
	int anchors = 0;

	if (!delta_gear_ready)
		delta_gear_init();

	for (size_t i = 0; i < len; i++) {
		g = (g << 1) + delta_gear[buf[i]];
		/* ~1 anchor per 64 bytes; the hash covers the last 64 bytes. */
		if (i < 32 || (g >> 58) != 0)
			continue;
		anchors++;
		for (int k = 0; k < ZFS_DELTA_NFEATURES; k++) {
			uint64_t x = delta_mix64(g ^
			    (0x9e3779b97f4a7c15ULL * (uint64_t)(k + 1)));
			if (x > feat[k])
				feat[k] = x;
		}
	}
	if (anchors < 4)
		return (B_FALSE);

	const int per = ZFS_DELTA_NFEATURES / ZFS_DELTA_NSF;
	for (int s = 0; s < ZFS_DELTA_NSF; s++) {
		uint64_t h = 0xcbf29ce484222325ULL * (uint64_t)(s + 1);
		for (int k = 0; k < per; k++)
			h = delta_mix64(h ^ feat[s * per + k]);
		sf[s] = h;
	}
	return (B_TRUE);
}
