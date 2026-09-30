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

#ifndef	_SYS_ZFS_DELTA_H
#define	_SYS_ZFS_DELTA_H

/*
 * Block delta encoding for DRR_WRITE_DELTA send stream records.
 *
 * A patch rebuilds a target block from a reference block using two ops:
 *   COPY: 0x01, varint(ref offset), varint(length)
 *   ADD:  0x02, varint(length), <length literal bytes>
 * Varints are unsigned LEB128.
 *
 * Similar blocks are found with content-defined "super-features": a gear
 * rolling hash picks anchor points, ZFS_DELTA_NFEATURES min-hash features
 * are taken over the anchors, and each ZFS_DELTA_NSF-way group of them is
 * hashed into one super-feature.  Blocks sharing any super-feature are
 * likely to share most of their content.
 */

#include <sys/types.h>

#ifdef	__cplusplus
extern "C" {
#endif

#define	ZFS_DELTA_OP_COPY	0x01
#define	ZFS_DELTA_OP_ADD	0x02

#define	ZFS_DELTA_HASH_BITS	16
#define	ZFS_DELTA_HASH_SIZE	(1U << ZFS_DELTA_HASH_BITS)

#define	ZFS_DELTA_NSF		3
#define	ZFS_DELTA_NFEATURES	12

/*
 * Encode tgt against ref into out.  htab is caller-provided scratch of
 * ZFS_DELTA_HASH_SIZE entries.  Returns the patch length, or 0 if the
 * patch would not fit in outcap bytes.
 */
extern size_t zfs_delta_encode(const uint8_t *ref, size_t reflen,
    const uint8_t *tgt, size_t tgtlen, uint8_t *out, size_t outcap,
    uint32_t *htab);

/*
 * Apply patch to ref, producing exactly tgtlen bytes in tgt.  Returns 0,
 * or EINVAL if the patch is malformed or does not produce tgtlen bytes.
 */
extern int zfs_delta_decode(const uint8_t *ref, size_t reflen,
    const uint8_t *patch, size_t patchlen, uint8_t *tgt, size_t tgtlen);

/*
 * Compute the super-features of buf.  Returns B_FALSE (and leaves sf
 * undefined) if the block has too few anchors to be sketched.
 */
extern boolean_t zfs_delta_sketch(const uint8_t *buf, size_t len,
    uint64_t sf[ZFS_DELTA_NSF]);

#ifdef	__cplusplus
}
#endif

#endif	/* _SYS_ZFS_DELTA_H */
