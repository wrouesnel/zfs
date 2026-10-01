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
 * Copyright (c) 2005, 2010, Oracle and/or its affiliates. All rights reserved.
 * Copyright 2011 Nexenta Systems, Inc. All rights reserved.
 * Copyright (c) 2011, 2018 by Delphix. All rights reserved.
 * Copyright (c) 2014, Joyent, Inc. All rights reserved.
 * Copyright 2014 HybridCluster. All rights reserved.
 * Copyright 2016 RackTop Systems.
 * Copyright (c) 2016 Actifio, Inc. All rights reserved.
 * Copyright (c) 2019, 2024, Klara, Inc.
 * Copyright (c) 2019, Allan Jude
 */

#include <sys/dmu.h>
#include <sys/dmu_impl.h>
#include <sys/dmu_tx.h>
#include <sys/dbuf.h>
#include <sys/dnode.h>
#include <sys/zfs_context.h>
#include <sys/dmu_objset.h>
#include <sys/dmu_traverse.h>
#include <sys/dsl_dataset.h>
#include <sys/dsl_dir.h>
#include <sys/dsl_prop.h>
#include <sys/dsl_pool.h>
#include <sys/dsl_synctask.h>
#include <sys/spa_impl.h>
#include <sys/zfs_ioctl.h>
#include <sys/zap.h>
#include <sys/zio_checksum.h>
#include <sys/zfs_znode.h>
#include <zfs_fletcher.h>
#include <sys/avl.h>
#include <sys/ddt.h>
#include <sys/zfs_onexit.h>
#include <sys/dmu_send.h>
#include <sys/dmu_recv.h>
#include <sys/dsl_destroy.h>
#include <sys/blkptr.h>
#include <sys/dsl_bookmark.h>
#include <sys/zfeature.h>
#include <sys/bqueue.h>
#include <sys/zvol.h>
#include <sys/policy.h>
#include <sys/objlist.h>
#include <sys/zfs_delta.h>
#include <sys/zio_compress.h>

/* Set this tunable to TRUE to replace corrupt data with 0x2f5baddb10c */
static int zfs_send_corrupt_data = B_FALSE;
/*
 * This tunable controls the amount of data (measured in bytes) that will be
 * prefetched by zfs send.  If the main thread is blocking on reads that haven't
 * completed, this variable might need to be increased.  If instead the main
 * thread is issuing new reads because the prefetches have fallen out of the
 * cache, this may need to be decreased.
 */
static uint_t zfs_send_queue_length = SPA_MAXBLOCKSIZE;
/*
 * This tunable controls the length of the queues that zfs send worker threads
 * use to communicate.  If the send_main_thread is blocking on these queues,
 * this variable may need to be increased.  If there is a significant slowdown
 * at the start of a send as these threads consume all the available IO
 * resources, this variable may need to be decreased.
 */
static uint_t zfs_send_no_prefetch_queue_length = 1024 * 1024;
/*
 * These tunables control the fill fraction of the queues by zfs send.  The fill
 * fraction controls the frequency with which threads have to be cv_signaled.
 * If a lot of cpu time is being spent on cv_signal, then these should be tuned
 * down.  If the queues empty before the signalled thread can catch up, then
 * these should be tuned up.
 */
static uint_t zfs_send_queue_ff = 20;
static uint_t zfs_send_no_prefetch_queue_ff = 20;

/*
 * Use this to override the recordsize calculation for fast zfs send estimates.
 */
static uint_t zfs_override_estimate_recordsize = 0;

/* Set this tunable to FALSE to disable setting of DRR_FLAG_FREERECORDS */
static const boolean_t zfs_send_set_freerecords_bit = B_TRUE;

/* Set this tunable to FALSE is disable sending unmodified spill blocks. */
static int zfs_send_unmodified_spill_blocks = B_TRUE;

/*
 * Upper bound on the number of blocks a --refs send tracks as possible
 * references (about 64 bytes each).  Blocks beyond it are sent in full.
 */
static uint64_t zfs_send_refs_max_blocks = 1ULL << 20;

/*
 * zfs send --delta: a changed block is sent as a patch against a similar
 * fromsnap block when the patch is at most this percentage of the size of
 * the WRITE record it replaces.
 */
static uint_t zfs_send_delta_max_pct = 50;
/* Blocks of a file scanned to find the fromsnap file it was copied from. */
static uint_t zfs_send_delta_sibling_scan = 1024;
/*
 * The similarity (sketch) index reads fromsnap data.  These bound the
 * number of blocks it covers (about 200 bytes of memory each) and the
 * data read to build it; zero for either disables it.
 */
static uint64_t zfs_send_delta_sketch_max_blocks = 1ULL << 19;
static uint64_t zfs_send_delta_sketch_max_bytes = 8ULL << 30;
/*
 * The sketch index only helps blocks that have no cheaper candidate,
 * which are mostly blocks of files that are not in the fromsnap.  Only
 * build it if at least this percentage of the new data blocks are.
 */
static uint_t zfs_send_delta_sketch_min_pct = 10;

static send_refs_stats_t send_refs_stats = {
	{ "send_refs_candidates",	KSTAT_DATA_UINT64 },
	{ "send_refs_resolved",		KSTAT_DATA_UINT64 },
	{ "send_refs_truncated",	KSTAT_DATA_UINT64 },
	{ "send_refs_records",		KSTAT_DATA_UINT64 },
	{ "send_refs_bytes",		KSTAT_DATA_UINT64 },
	{ "recv_refs_cloned",		KSTAT_DATA_UINT64 },
	{ "recv_refs_copied",		KSTAT_DATA_UINT64 },
	{ "send_delta_attempts",	KSTAT_DATA_UINT64 },
	{ "send_delta_records",		KSTAT_DATA_UINT64 },
	{ "send_delta_payload_bytes",	KSTAT_DATA_UINT64 },
	{ "send_delta_logical_bytes",	KSTAT_DATA_UINT64 },
	{ "send_delta_same_hits",	KSTAT_DATA_UINT64 },
	{ "send_delta_sibling_hits",	KSTAT_DATA_UINT64 },
	{ "send_delta_sketch_hits",	KSTAT_DATA_UINT64 },
	{ "send_delta_rejected",	KSTAT_DATA_UINT64 },
	{ "send_delta_sketch_blocks",	KSTAT_DATA_UINT64 },
	{ "send_delta_sketch_truncated", KSTAT_DATA_UINT64 },
	{ "send_delta_sketch_ns",	KSTAT_DATA_UINT64 },
	{ "send_delta_sketch_skipped",	KSTAT_DATA_UINT64 },
	{ "recv_delta_records",		KSTAT_DATA_UINT64 },
};
static kstat_t *send_refs_ksp;

#define	REFS_STAT_BUMP(stat)	\
	atomic_inc_64(&send_refs_stats.stat.value.ui64)
#define	REFS_STAT_INCR(stat, val)	\
	atomic_add_64(&send_refs_stats.stat.value.ui64, (val))

void
send_refs_stat_bump(send_refs_stat_t stat)
{
	switch (stat) {
	case SEND_REFS_STAT_RECV_CLONED:
		REFS_STAT_BUMP(recv_refs_cloned);
		break;
	case SEND_REFS_STAT_RECV_COPIED:
		REFS_STAT_BUMP(recv_refs_copied);
		break;
	case SEND_REFS_STAT_RECV_DELTA:
		REFS_STAT_BUMP(recv_delta_records);
		break;
	}
}

void
dmu_send_init(void)
{
	send_refs_ksp = kstat_create("zfs", 0, "send_refs", "misc",
	    KSTAT_TYPE_NAMED, sizeof (send_refs_stats) / sizeof (kstat_named_t),
	    KSTAT_FLAG_VIRTUAL);
	if (send_refs_ksp != NULL) {
		send_refs_ksp->ks_data = &send_refs_stats;
		kstat_install(send_refs_ksp);
	}
}

void
dmu_send_fini(void)
{
	if (send_refs_ksp != NULL) {
		kstat_delete(send_refs_ksp);
		send_refs_ksp = NULL;
	}
}

static inline boolean_t
overflow_multiply(uint64_t a, uint64_t b, uint64_t *c)
{
	uint64_t temp = a * b;
	if (b != 0 && temp / b != a)
		return (B_FALSE);
	*c = temp;
	return (B_TRUE);
}

struct send_thread_arg {
	bqueue_t	q;
	objset_t	*os;		/* Objset to traverse */
	uint64_t	fromtxg;	/* Traverse from this txg */
	int		flags;		/* flags to pass to traverse_dataset */
	int		error_code;
	boolean_t	cancel;
	zbookmark_phys_t resume;
	uint64_t	*num_blocks_visited;
};

struct redact_list_thread_arg {
	boolean_t		cancel;
	bqueue_t		q;
	zbookmark_phys_t	resume;
	redaction_list_t	*rl;
	boolean_t		mark_redact;
	int			error_code;
	uint64_t		*num_blocks_visited;
};

struct send_merge_thread_arg {
	bqueue_t			q;
	objset_t			*os;
	struct redact_list_thread_arg	*from_arg;
	struct send_thread_arg		*to_arg;
	struct redact_list_thread_arg	*redact_arg;
	int				error;
	boolean_t			cancel;
};

struct send_range {
	boolean_t		eos_marker; /* Marks the end of the stream */
	uint64_t		object;
	uint64_t		start_blkid;
	uint64_t		end_blkid;
	bqueue_node_t		ln;
	enum type {DATA, HOLE, OBJECT, OBJECT_RANGE, REDACT,
	    PREVIOUSLY_REDACTED} type;
	union {
		struct srd {
			dmu_object_type_t	obj_type;
			uint32_t		datablksz; // logical size
			uint32_t		datasz; // payload size
			blkptr_t		bp;
			arc_buf_t		*abuf;
			abd_t			*abd;
			kmutex_t		lock;
			kcondvar_t		cv;
			boolean_t		io_outstanding;
			boolean_t		io_compressed;
			int			io_err;
			/* send as a DRR_WRITE_BYREF to this fromsnap block */
			boolean_t		byref;
			uint64_t		ref_object;
			uint64_t		ref_offset;
		} data;
		struct srh {
			uint32_t		datablksz;
		} hole;
		struct sro {
			/*
			 * This is a pointer because embedding it in the
			 * struct causes these structures to be massively larger
			 * for all range types; this makes the code much less
			 * memory efficient.
			 */
			dnode_phys_t		*dnp;
			blkptr_t		bp;
			/* Piggyback unmodified spill block */
			struct send_range	*spill_range;
		} object;
		struct srr {
			uint32_t		datablksz;
		} redact;
		struct sror {
			blkptr_t		bp;
		} object_range;
	} sru;
};

/*
 * The list of data whose inclusion in a send stream can be pending from
 * one call to backup_cb to another.  Multiple calls to dump_free(),
 * dump_freeobjects(), and dump_redact() can be aggregated into a single
 * DRR_FREE, DRR_FREEOBJECTS, or DRR_REDACT replay record.
 */
typedef enum {
	PENDING_NONE,
	PENDING_FREE,
	PENDING_FREEOBJECTS,
	PENDING_REDACT
} dmu_pendop_t;

typedef struct dmu_send_cookie {
	dmu_replay_record_t *dsc_drr;
	dmu_send_outparams_t *dsc_dso;
	offset_t *dsc_off;
	objset_t *dsc_os;
	zio_cksum_t dsc_zc;
	uint64_t dsc_toguid;
	uint64_t dsc_fromtxg;
	uint64_t dsc_fromguid;
	/* zfs send --delta state; see send_delta_try() */
	struct send_delta *dsc_delta;
	int dsc_err;
	dmu_pendop_t dsc_pending_op;
	uint64_t dsc_featureflags;
	uint64_t dsc_last_data_object;
	uint64_t dsc_last_data_offset;
	uint64_t dsc_resume_object;
	uint64_t dsc_resume_offset;
	boolean_t dsc_sent_begin;
	boolean_t dsc_sent_end;
} dmu_send_cookie_t;

static int do_dump(dmu_send_cookie_t *dscp, struct send_range *range);
static int send_delta_try(dmu_send_cookie_t *dscp, struct send_range *range,
    char *data, boolean_t *sentp);

static void
range_free(struct send_range *range)
{
	if (range->type == OBJECT) {
		size_t size = sizeof (dnode_phys_t) *
		    (range->sru.object.dnp->dn_extra_slots + 1);
		kmem_free(range->sru.object.dnp, size);
		if (range->sru.object.spill_range)
			range_free(range->sru.object.spill_range);
	} else if (range->type == DATA) {
		mutex_enter(&range->sru.data.lock);
		while (range->sru.data.io_outstanding)
			cv_wait(&range->sru.data.cv, &range->sru.data.lock);
		if (range->sru.data.abd != NULL)
			abd_free(range->sru.data.abd);
		if (range->sru.data.abuf != NULL) {
			arc_buf_destroy(range->sru.data.abuf,
			    &range->sru.data.abuf);
		}
		mutex_exit(&range->sru.data.lock);

		cv_destroy(&range->sru.data.cv);
		mutex_destroy(&range->sru.data.lock);
	}
	kmem_free(range, sizeof (*range));
}

/*
 * For all record types except BEGIN, fill in the checksum (overlaid in
 * drr_u.drr_checksum.drr_checksum).  The checksum verifies everything
 * up to the start of the checksum itself.
 */
static int
dump_record(dmu_send_cookie_t *dscp, void *payload, int payload_len)
{
	dmu_send_outparams_t *dso = dscp->dsc_dso;
	ASSERT3U(offsetof(dmu_replay_record_t, drr_u.drr_checksum.drr_checksum),
	    ==, sizeof (dmu_replay_record_t) - sizeof (zio_cksum_t));
	(void) fletcher_4_incremental_native(dscp->dsc_drr,
	    offsetof(dmu_replay_record_t, drr_u.drr_checksum.drr_checksum),
	    &dscp->dsc_zc);
	if (dscp->dsc_drr->drr_type == DRR_BEGIN) {
		dscp->dsc_sent_begin = B_TRUE;
	} else {
		ASSERT(ZIO_CHECKSUM_IS_ZERO(&dscp->dsc_drr->drr_u.
		    drr_checksum.drr_checksum));
		dscp->dsc_drr->drr_u.drr_checksum.drr_checksum = dscp->dsc_zc;
	}
	if (dscp->dsc_drr->drr_type == DRR_END) {
		dscp->dsc_sent_end = B_TRUE;
	}
	(void) fletcher_4_incremental_native(&dscp->dsc_drr->
	    drr_u.drr_checksum.drr_checksum,
	    sizeof (zio_cksum_t), &dscp->dsc_zc);
	*dscp->dsc_off += sizeof (dmu_replay_record_t);
	dscp->dsc_err = dso->dso_outfunc(dscp->dsc_os, dscp->dsc_drr,
	    sizeof (dmu_replay_record_t), dso->dso_arg);
	if (dscp->dsc_err != 0)
		return (SET_ERROR(EINTR));
	if (payload_len != 0) {
		*dscp->dsc_off += payload_len;
		/*
		 * payload is null when dso_dryrun == B_TRUE (i.e. when we're
		 * doing a send size calculation)
		 */
		if (payload != NULL) {
			(void) fletcher_4_incremental_native(
			    payload, payload_len, &dscp->dsc_zc);
		}

		/*
		 * The code does not rely on this (len being a multiple of 8).
		 * We keep this assertion because of the corresponding assertion
		 * in receive_read().  Keeping this assertion ensures that we do
		 * not inadvertently break backwards compatibility (causing the
		 * assertion in receive_read() to trigger on old software).
		 *
		 * Raw sends cannot be received on old software, and so can
		 * bypass this assertion.
		 */

		ASSERT((payload_len % 8 == 0) ||
		    (dscp->dsc_featureflags & DMU_BACKUP_FEATURE_RAW));

		dscp->dsc_err = dso->dso_outfunc(dscp->dsc_os, payload,
		    payload_len, dso->dso_arg);
		if (dscp->dsc_err != 0)
			return (SET_ERROR(EINTR));
	}
	return (0);
}

/*
 * Fill in the drr_free struct, or perform aggregation if the previous record is
 * also a free record, and the two are adjacent.
 *
 * Note that we send free records even for a full send, because we want to be
 * able to receive a full send as a clone, which requires a list of all the free
 * and freeobject records that were generated on the source.
 */
static int
dump_free(dmu_send_cookie_t *dscp, uint64_t object, uint64_t offset,
    uint64_t length)
{
	struct drr_free *drrf = &(dscp->dsc_drr->drr_u.drr_free);

	/*
	 * When we receive a free record, dbuf_free_range() assumes
	 * that the receiving system doesn't have any dbufs in the range
	 * being freed.  This is always true because there is a one-record
	 * constraint: we only send one WRITE record for any given
	 * object,offset.  We know that the one-record constraint is
	 * true because we always send data in increasing order by
	 * object,offset.
	 *
	 * If the increasing-order constraint ever changes, we should find
	 * another way to assert that the one-record constraint is still
	 * satisfied.
	 */
	ASSERT(object > dscp->dsc_last_data_object ||
	    (object == dscp->dsc_last_data_object &&
	    offset > dscp->dsc_last_data_offset));

	/*
	 * If there is a pending op, but it's not PENDING_FREE, push it out,
	 * since free block aggregation can only be done for blocks of the
	 * same type (i.e., DRR_FREE records can only be aggregated with
	 * other DRR_FREE records.  DRR_FREEOBJECTS records can only be
	 * aggregated with other DRR_FREEOBJECTS records).
	 */
	if (dscp->dsc_pending_op != PENDING_NONE &&
	    dscp->dsc_pending_op != PENDING_FREE) {
		if (dump_record(dscp, NULL, 0) != 0)
			return (SET_ERROR(EINTR));
		dscp->dsc_pending_op = PENDING_NONE;
	}

	if (dscp->dsc_pending_op == PENDING_FREE) {
		/*
		 * Check to see whether this free block can be aggregated
		 * with pending one.
		 */
		if (drrf->drr_object == object && drrf->drr_offset +
		    drrf->drr_length == offset) {
			if (offset + length < offset || length == UINT64_MAX)
				drrf->drr_length = UINT64_MAX;
			else
				drrf->drr_length += length;
			return (0);
		} else {
			/* not a continuation.  Push out pending record */
			if (dump_record(dscp, NULL, 0) != 0)
				return (SET_ERROR(EINTR));
			dscp->dsc_pending_op = PENDING_NONE;
		}
	}
	/* create a FREE record and make it pending */
	memset(dscp->dsc_drr, 0, sizeof (dmu_replay_record_t));
	dscp->dsc_drr->drr_type = DRR_FREE;
	drrf->drr_object = object;
	drrf->drr_offset = offset;
	if (offset + length < offset)
		drrf->drr_length = DMU_OBJECT_END;
	else
		drrf->drr_length = length;
	drrf->drr_toguid = dscp->dsc_toguid;
	if (length == DMU_OBJECT_END) {
		if (dump_record(dscp, NULL, 0) != 0)
			return (SET_ERROR(EINTR));
	} else {
		dscp->dsc_pending_op = PENDING_FREE;
	}

	return (0);
}

/*
 * Fill in the drr_redact struct, or perform aggregation if the previous record
 * is also a redaction record, and the two are adjacent.
 */
static int
dump_redact(dmu_send_cookie_t *dscp, uint64_t object, uint64_t offset,
    uint64_t length)
{
	struct drr_redact *drrr = &dscp->dsc_drr->drr_u.drr_redact;

	/*
	 * If there is a pending op, but it's not PENDING_REDACT, push it out,
	 * since free block aggregation can only be done for blocks of the
	 * same type (i.e., DRR_REDACT records can only be aggregated with
	 * other DRR_REDACT records).
	 */
	if (dscp->dsc_pending_op != PENDING_NONE &&
	    dscp->dsc_pending_op != PENDING_REDACT) {
		if (dump_record(dscp, NULL, 0) != 0)
			return (SET_ERROR(EINTR));
		dscp->dsc_pending_op = PENDING_NONE;
	}

	if (dscp->dsc_pending_op == PENDING_REDACT) {
		/*
		 * Check to see whether this redacted block can be aggregated
		 * with pending one.
		 */
		if (drrr->drr_object == object && drrr->drr_offset +
		    drrr->drr_length == offset) {
			drrr->drr_length += length;
			return (0);
		} else {
			/* not a continuation.  Push out pending record */
			if (dump_record(dscp, NULL, 0) != 0)
				return (SET_ERROR(EINTR));
			dscp->dsc_pending_op = PENDING_NONE;
		}
	}
	/* create a REDACT record and make it pending */
	memset(dscp->dsc_drr, 0, sizeof (dmu_replay_record_t));
	dscp->dsc_drr->drr_type = DRR_REDACT;
	drrr->drr_object = object;
	drrr->drr_offset = offset;
	drrr->drr_length = length;
	drrr->drr_toguid = dscp->dsc_toguid;
	dscp->dsc_pending_op = PENDING_REDACT;

	return (0);
}

static int
dmu_dump_write(dmu_send_cookie_t *dscp, dmu_object_type_t type, uint64_t object,
    uint64_t offset, int lsize, int psize, const blkptr_t *bp,
    boolean_t io_compressed, void *data)
{
	uint64_t payload_size;
	boolean_t raw = (dscp->dsc_featureflags & DMU_BACKUP_FEATURE_RAW);
	struct drr_write *drrw = &(dscp->dsc_drr->drr_u.drr_write);

	/*
	 * We send data in increasing object, offset order.
	 * See comment in dump_free() for details.
	 */
	ASSERT(object > dscp->dsc_last_data_object ||
	    (object == dscp->dsc_last_data_object &&
	    offset > dscp->dsc_last_data_offset));
	dscp->dsc_last_data_object = object;
	dscp->dsc_last_data_offset = offset + lsize - 1;

	/*
	 * If there is any kind of pending aggregation (currently either
	 * a grouping of free objects or free blocks), push it out to
	 * the stream, since aggregation can't be done across operations
	 * of different types.
	 */
	if (dscp->dsc_pending_op != PENDING_NONE) {
		if (dump_record(dscp, NULL, 0) != 0)
			return (SET_ERROR(EINTR));
		dscp->dsc_pending_op = PENDING_NONE;
	}
	/* write a WRITE record */
	memset(dscp->dsc_drr, 0, sizeof (dmu_replay_record_t));
	dscp->dsc_drr->drr_type = DRR_WRITE;
	drrw->drr_object = object;
	drrw->drr_type = type;
	drrw->drr_offset = offset;
	drrw->drr_toguid = dscp->dsc_toguid;
	drrw->drr_logical_size = lsize;

	/* only set the compression fields if the buf is compressed or raw */
	boolean_t compressed =
	    (bp != NULL ? BP_GET_COMPRESS(bp) != ZIO_COMPRESS_OFF &&
	    io_compressed : lsize != psize);
	if (raw || compressed) {
		ASSERT(bp != NULL);
		ASSERT(raw || dscp->dsc_featureflags &
		    DMU_BACKUP_FEATURE_COMPRESSED);
		ASSERT(!BP_IS_EMBEDDED(bp));
		ASSERT3S(psize, >, 0);

		if (raw) {
			ASSERT(BP_IS_PROTECTED(bp));

			/*
			 * This is a raw protected block so we need to pass
			 * along everything the receiving side will need to
			 * interpret this block, including the byteswap, salt,
			 * IV, and MAC.
			 */
			if (BP_SHOULD_BYTESWAP(bp))
				drrw->drr_flags |= DRR_RAW_BYTESWAP;
			zio_crypt_decode_params_bp(bp, drrw->drr_salt,
			    drrw->drr_iv);
			zio_crypt_decode_mac_bp(bp, drrw->drr_mac);
		} else {
			/* this is a compressed block */
			ASSERT(dscp->dsc_featureflags &
			    DMU_BACKUP_FEATURE_COMPRESSED);
			ASSERT(!BP_SHOULD_BYTESWAP(bp));
			ASSERT(!DMU_OT_IS_METADATA(BP_GET_TYPE(bp)));
			ASSERT3U(BP_GET_COMPRESS(bp), !=, ZIO_COMPRESS_OFF);
			ASSERT3S(lsize, >=, psize);
		}

		/* set fields common to compressed and raw sends */
		drrw->drr_compressiontype = BP_GET_COMPRESS(bp);
		drrw->drr_compressed_size = psize;
		payload_size = drrw->drr_compressed_size;
	} else {
		payload_size = drrw->drr_logical_size;
	}

	if (bp == NULL || BP_IS_EMBEDDED(bp) || (BP_IS_PROTECTED(bp) && !raw)) {
		/*
		 * There's no pre-computed checksum for partial-block writes,
		 * embedded BP's, or encrypted BP's that are being sent as
		 * plaintext, so (like fletcher4-checksummed blocks) userland
		 * will have to compute a dedup-capable checksum itself.
		 */
		drrw->drr_checksumtype = ZIO_CHECKSUM_OFF;
	} else {
		drrw->drr_checksumtype = BP_GET_CHECKSUM(bp);
		if (zio_checksum_table[drrw->drr_checksumtype].ci_flags &
		    ZCHECKSUM_FLAG_DEDUP)
			drrw->drr_flags |= DRR_CHECKSUM_DEDUP;
		DDK_SET_LSIZE(&drrw->drr_key, BP_GET_LSIZE(bp));
		DDK_SET_PSIZE(&drrw->drr_key, BP_GET_PSIZE(bp));
		DDK_SET_COMPRESS(&drrw->drr_key, BP_GET_COMPRESS(bp));
		DDK_SET_CRYPT(&drrw->drr_key, BP_IS_PROTECTED(bp));
		drrw->drr_key.ddk_cksum = bp->blk_cksum;
	}

	if (dump_record(dscp, data, payload_size) != 0)
		return (SET_ERROR(EINTR));
	return (0);
}

static int
dump_write_byref(dmu_send_cookie_t *dscp, uint64_t object, uint64_t offset,
    uint64_t lsize, const blkptr_t *bp, uint64_t refobject, uint64_t refoffset)
{
	struct drr_write_byref *drrwb =
	    &(dscp->dsc_drr->drr_u.drr_write_byref);

	/* Same ordering rules as dmu_dump_write(). */
	ASSERT(object > dscp->dsc_last_data_object ||
	    (object == dscp->dsc_last_data_object &&
	    offset > dscp->dsc_last_data_offset));
	dscp->dsc_last_data_object = object;
	dscp->dsc_last_data_offset = offset + lsize - 1;

	if (dscp->dsc_pending_op != PENDING_NONE) {
		if (dump_record(dscp, NULL, 0) != 0)
			return (SET_ERROR(EINTR));
		dscp->dsc_pending_op = PENDING_NONE;
	}

	memset(dscp->dsc_drr, 0, sizeof (dmu_replay_record_t));
	dscp->dsc_drr->drr_type = DRR_WRITE_BYREF;
	drrwb->drr_object = object;
	drrwb->drr_offset = offset;
	drrwb->drr_length = lsize;
	drrwb->drr_toguid = dscp->dsc_toguid;
	drrwb->drr_refguid = dscp->dsc_fromguid;
	drrwb->drr_refobject = refobject;
	drrwb->drr_refoffset = refoffset;
	drrwb->drr_checksumtype = BP_GET_CHECKSUM(bp);
	if (zio_checksum_table[drrwb->drr_checksumtype].ci_flags &
	    ZCHECKSUM_FLAG_DEDUP)
		drrwb->drr_flags |= DRR_CHECKSUM_DEDUP;
	DDK_SET_LSIZE(&drrwb->drr_key, BP_GET_LSIZE(bp));
	DDK_SET_PSIZE(&drrwb->drr_key, BP_GET_PSIZE(bp));
	DDK_SET_COMPRESS(&drrwb->drr_key, BP_GET_COMPRESS(bp));
	DDK_SET_CRYPT(&drrwb->drr_key, BP_IS_PROTECTED(bp));
	drrwb->drr_key.ddk_cksum = bp->blk_cksum;

	if (dump_record(dscp, NULL, 0) != 0)
		return (SET_ERROR(EINTR));

	REFS_STAT_BUMP(send_refs_records);
	REFS_STAT_INCR(send_refs_bytes, lsize);
	return (0);
}

static int
dump_write_embedded(dmu_send_cookie_t *dscp, uint64_t object, uint64_t offset,
    int blksz, const blkptr_t *bp)
{
	char buf[BPE_PAYLOAD_SIZE];
	struct drr_write_embedded *drrw =
	    &(dscp->dsc_drr->drr_u.drr_write_embedded);

	if (dscp->dsc_pending_op != PENDING_NONE) {
		if (dump_record(dscp, NULL, 0) != 0)
			return (SET_ERROR(EINTR));
		dscp->dsc_pending_op = PENDING_NONE;
	}

	ASSERT(BP_IS_EMBEDDED(bp));

	memset(dscp->dsc_drr, 0, sizeof (dmu_replay_record_t));
	dscp->dsc_drr->drr_type = DRR_WRITE_EMBEDDED;
	drrw->drr_object = object;
	drrw->drr_offset = offset;
	drrw->drr_length = blksz;
	drrw->drr_toguid = dscp->dsc_toguid;
	drrw->drr_compression = BP_GET_COMPRESS(bp);
	drrw->drr_etype = BPE_GET_ETYPE(bp);
	drrw->drr_lsize = BPE_GET_LSIZE(bp);
	drrw->drr_psize = BPE_GET_PSIZE(bp);

	decode_embedded_bp_compressed(bp, buf);

	uint32_t psize = drrw->drr_psize;
	uint32_t rsize = P2ROUNDUP(psize, 8);

	if (psize != rsize)
		memset(buf + psize, 0, rsize - psize);

	if (dump_record(dscp, buf, rsize) != 0)
		return (SET_ERROR(EINTR));
	return (0);
}

static int
dump_spill(dmu_send_cookie_t *dscp, const blkptr_t *bp, uint64_t object,
    void *data)
{
	struct drr_spill *drrs = &(dscp->dsc_drr->drr_u.drr_spill);
	uint64_t blksz = BP_GET_LSIZE(bp);
	uint64_t payload_size = blksz;

	if (dscp->dsc_pending_op != PENDING_NONE) {
		if (dump_record(dscp, NULL, 0) != 0)
			return (SET_ERROR(EINTR));
		dscp->dsc_pending_op = PENDING_NONE;
	}

	/* write a SPILL record */
	memset(dscp->dsc_drr, 0, sizeof (dmu_replay_record_t));
	dscp->dsc_drr->drr_type = DRR_SPILL;
	drrs->drr_object = object;
	drrs->drr_length = blksz;
	drrs->drr_toguid = dscp->dsc_toguid;

	/* See comment in piggyback_unmodified_spill() for full details */
	if (zfs_send_unmodified_spill_blocks &&
	    (BP_GET_LOGICAL_BIRTH(bp) <= dscp->dsc_fromtxg)) {
		drrs->drr_flags |= DRR_SPILL_UNMODIFIED;
	}

	/* handle raw send fields */
	if (dscp->dsc_featureflags & DMU_BACKUP_FEATURE_RAW) {
		ASSERT(BP_IS_PROTECTED(bp));

		if (BP_SHOULD_BYTESWAP(bp))
			drrs->drr_flags |= DRR_RAW_BYTESWAP;
		drrs->drr_compressiontype = BP_GET_COMPRESS(bp);
		drrs->drr_compressed_size = BP_GET_PSIZE(bp);
		zio_crypt_decode_params_bp(bp, drrs->drr_salt, drrs->drr_iv);
		zio_crypt_decode_mac_bp(bp, drrs->drr_mac);
		payload_size = drrs->drr_compressed_size;
	}

	if (dump_record(dscp, data, payload_size) != 0)
		return (SET_ERROR(EINTR));
	return (0);
}

static int
dump_freeobjects(dmu_send_cookie_t *dscp, uint64_t firstobj, uint64_t numobjs)
{
	struct drr_freeobjects *drrfo = &(dscp->dsc_drr->drr_u.drr_freeobjects);
	uint64_t maxobj = DNODES_PER_BLOCK *
	    (DMU_META_DNODE(dscp->dsc_os)->dn_maxblkid + 1);

	/*
	 * ZoL < 0.7 does not handle large FREEOBJECTS records correctly,
	 * leading to zfs recv never completing. to avoid this issue, don't
	 * send FREEOBJECTS records for object IDs which cannot exist on the
	 * receiving side.
	 */
	if (maxobj > 0) {
		if (maxobj <= firstobj)
			return (0);

		if (maxobj < firstobj + numobjs)
			numobjs = maxobj - firstobj;
	}

	/*
	 * If there is a pending op, but it's not PENDING_FREEOBJECTS,
	 * push it out, since free block aggregation can only be done for
	 * blocks of the same type (i.e., DRR_FREE records can only be
	 * aggregated with other DRR_FREE records.  DRR_FREEOBJECTS records
	 * can only be aggregated with other DRR_FREEOBJECTS records).
	 */
	if (dscp->dsc_pending_op != PENDING_NONE &&
	    dscp->dsc_pending_op != PENDING_FREEOBJECTS) {
		if (dump_record(dscp, NULL, 0) != 0)
			return (SET_ERROR(EINTR));
		dscp->dsc_pending_op = PENDING_NONE;
	}

	if (dscp->dsc_pending_op == PENDING_FREEOBJECTS) {
		/*
		 * See whether this free object array can be aggregated
		 * with pending one
		 */
		if (drrfo->drr_firstobj + drrfo->drr_numobjs == firstobj) {
			drrfo->drr_numobjs += numobjs;
			return (0);
		} else {
			/* can't be aggregated.  Push out pending record */
			if (dump_record(dscp, NULL, 0) != 0)
				return (SET_ERROR(EINTR));
			dscp->dsc_pending_op = PENDING_NONE;
		}
	}

	/* write a FREEOBJECTS record */
	memset(dscp->dsc_drr, 0, sizeof (dmu_replay_record_t));
	dscp->dsc_drr->drr_type = DRR_FREEOBJECTS;
	drrfo->drr_firstobj = firstobj;
	drrfo->drr_numobjs = numobjs;
	drrfo->drr_toguid = dscp->dsc_toguid;

	dscp->dsc_pending_op = PENDING_FREEOBJECTS;

	return (0);
}

static int
dump_dnode(dmu_send_cookie_t *dscp, const blkptr_t *bp, uint64_t object,
    dnode_phys_t *dnp)
{
	struct drr_object *drro = &(dscp->dsc_drr->drr_u.drr_object);
	int bonuslen;

	if (object < dscp->dsc_resume_object) {
		/*
		 * Note: when resuming, we will visit all the dnodes in
		 * the block of dnodes that we are resuming from.  In
		 * this case it's unnecessary to send the dnodes prior to
		 * the one we are resuming from.  We should be at most one
		 * block's worth of dnodes behind the resume point.
		 */
		ASSERT3U(dscp->dsc_resume_object - object, <,
		    1 << (DNODE_BLOCK_SHIFT - DNODE_SHIFT));
		return (0);
	}

	if (dnp == NULL || dnp->dn_type == DMU_OT_NONE)
		return (dump_freeobjects(dscp, object, 1));

	if (dscp->dsc_pending_op != PENDING_NONE) {
		if (dump_record(dscp, NULL, 0) != 0)
			return (SET_ERROR(EINTR));
		dscp->dsc_pending_op = PENDING_NONE;
	}

	/* write an OBJECT record */
	memset(dscp->dsc_drr, 0, sizeof (dmu_replay_record_t));
	dscp->dsc_drr->drr_type = DRR_OBJECT;
	drro->drr_object = object;
	drro->drr_type = dnp->dn_type;
	drro->drr_bonustype = dnp->dn_bonustype;
	drro->drr_blksz = dnp->dn_datablkszsec << SPA_MINBLOCKSHIFT;
	drro->drr_bonuslen = dnp->dn_bonuslen;
	drro->drr_dn_slots = dnp->dn_extra_slots + 1;
	drro->drr_checksumtype = dnp->dn_checksum;
	drro->drr_compress = dnp->dn_compress;
	drro->drr_toguid = dscp->dsc_toguid;

	if (!(dscp->dsc_featureflags & DMU_BACKUP_FEATURE_LARGE_BLOCKS) &&
	    drro->drr_blksz > SPA_OLD_MAXBLOCKSIZE)
		drro->drr_blksz = SPA_OLD_MAXBLOCKSIZE;

	bonuslen = P2ROUNDUP(dnp->dn_bonuslen, 8);

	if ((dscp->dsc_featureflags & DMU_BACKUP_FEATURE_RAW)) {
		ASSERT(BP_IS_ENCRYPTED(bp));

		if (BP_SHOULD_BYTESWAP(bp))
			drro->drr_flags |= DRR_RAW_BYTESWAP;

		/* needed for reconstructing dnp on recv side */
		drro->drr_maxblkid = dnp->dn_maxblkid;
		drro->drr_indblkshift = dnp->dn_indblkshift;
		drro->drr_nlevels = dnp->dn_nlevels;
		drro->drr_nblkptr = dnp->dn_nblkptr;

		/*
		 * Since we encrypt the entire bonus area, the (raw) part
		 * beyond the bonuslen is actually nonzero, so we need
		 * to send it.
		 */
		if (bonuslen != 0) {
			if (drro->drr_bonuslen > DN_MAX_BONUS_LEN(dnp))
				return (SET_ERROR(EINVAL));
			drro->drr_raw_bonuslen = DN_MAX_BONUS_LEN(dnp);
			bonuslen = drro->drr_raw_bonuslen;
		}
	}

	/*
	 * DRR_OBJECT_SPILL is set for every dnode which references a
	 * spill block.	 This allows the receiving pool to definitively
	 * determine when a spill block should be kept or freed.
	 */
	if (dnp->dn_flags & DNODE_FLAG_SPILL_BLKPTR)
		drro->drr_flags |= DRR_OBJECT_SPILL;

	if (dump_record(dscp, DN_BONUS(dnp), bonuslen) != 0)
		return (SET_ERROR(EINTR));

	/* Free anything past the end of the file. */
	if (dump_free(dscp, object, (dnp->dn_maxblkid + 1) *
	    (dnp->dn_datablkszsec << SPA_MINBLOCKSHIFT), DMU_OBJECT_END) != 0)
		return (SET_ERROR(EINTR));

	if (dscp->dsc_err != 0)
		return (SET_ERROR(EINTR));

	return (0);
}

static int
dump_object_range(dmu_send_cookie_t *dscp, const blkptr_t *bp,
    uint64_t firstobj, uint64_t numslots)
{
	struct drr_object_range *drror =
	    &(dscp->dsc_drr->drr_u.drr_object_range);

	/* we only use this record type for raw sends */
	ASSERT(BP_IS_PROTECTED(bp));
	ASSERT(dscp->dsc_featureflags & DMU_BACKUP_FEATURE_RAW);
	ASSERT3U(BP_GET_COMPRESS(bp), ==, ZIO_COMPRESS_OFF);
	ASSERT3U(BP_GET_TYPE(bp), ==, DMU_OT_DNODE);
	ASSERT0(BP_GET_LEVEL(bp));

	if (dscp->dsc_pending_op != PENDING_NONE) {
		if (dump_record(dscp, NULL, 0) != 0)
			return (SET_ERROR(EINTR));
		dscp->dsc_pending_op = PENDING_NONE;
	}

	memset(dscp->dsc_drr, 0, sizeof (dmu_replay_record_t));
	dscp->dsc_drr->drr_type = DRR_OBJECT_RANGE;
	drror->drr_firstobj = firstobj;
	drror->drr_numslots = numslots;
	drror->drr_toguid = dscp->dsc_toguid;
	if (BP_SHOULD_BYTESWAP(bp))
		drror->drr_flags |= DRR_RAW_BYTESWAP;
	zio_crypt_decode_params_bp(bp, drror->drr_salt, drror->drr_iv);
	zio_crypt_decode_mac_bp(bp, drror->drr_mac);

	if (dump_record(dscp, NULL, 0) != 0)
		return (SET_ERROR(EINTR));
	return (0);
}

static boolean_t
send_do_embed(const blkptr_t *bp, uint64_t featureflags)
{
	if (!BP_IS_EMBEDDED(bp))
		return (B_FALSE);

	/*
	 * Spill blocks (DMU_OT_SA) are sent as DRR_SPILL, not
	 * DRR_WRITE_EMBEDDED.
	 */
	if (BP_GET_TYPE(bp) == DMU_OT_SA)
		return (B_FALSE);

	/*
	 * Without DMU_BACKUP_FEATURE_LARGE_BLOCKS the object's block size is
	 * clamped to SPA_OLD_MAXBLOCKSIZE in the DRR_OBJECT record (see
	 * dump_dnode()), so a larger embedded block cannot be represented on
	 * the receiving side. Decline it here and let do_dump() split it
	 * into SPA_OLD_MAXBLOCKSIZE chunks.
	 */
	if (BP_GET_LSIZE(bp) > SPA_OLD_MAXBLOCKSIZE &&
	    !(featureflags & DMU_BACKUP_FEATURE_LARGE_BLOCKS))
		return (B_FALSE);

	/*
	 * Compression function must be legacy, or explicitly enabled.
	 */
	if ((BP_GET_COMPRESS(bp) >= ZIO_COMPRESS_LEGACY_FUNCTIONS &&
	    !(featureflags & DMU_BACKUP_FEATURE_LZ4)))
		return (B_FALSE);

	/*
	 * If we have not set the ZSTD feature flag, we can't send ZSTD
	 * compressed embedded blocks, as the receiver may not support them.
	 */
	if ((BP_GET_COMPRESS(bp) == ZIO_COMPRESS_ZSTD &&
	    !(featureflags & DMU_BACKUP_FEATURE_ZSTD)))
		return (B_FALSE);

	/*
	 * Embed type must be explicitly enabled.
	 */
	switch (BPE_GET_ETYPE(bp)) {
	case BP_EMBEDDED_TYPE_DATA:
		if (featureflags & DMU_BACKUP_FEATURE_EMBED_DATA)
			return (B_TRUE);
		break;
	default:
		return (B_FALSE);
	}
	return (B_FALSE);
}

/*
 * This function actually handles figuring out what kind of record needs to be
 * dumped, and calling the appropriate helper function.  In most cases,
 * the data has already been read by send_reader_thread().
 */
static int
do_dump(dmu_send_cookie_t *dscp, struct send_range *range)
{
	int err = 0;
	switch (range->type) {
	case OBJECT:
		err = dump_dnode(dscp, &range->sru.object.bp, range->object,
		    range->sru.object.dnp);
		/* Dump piggybacked unmodified spill block */
		if (!err && range->sru.object.spill_range)
			err = do_dump(dscp, range->sru.object.spill_range);
		return (err);
	case OBJECT_RANGE: {
		ASSERT3U(range->start_blkid + 1, ==, range->end_blkid);
		if (!(dscp->dsc_featureflags & DMU_BACKUP_FEATURE_RAW)) {
			return (0);
		}
		uint64_t epb = BP_GET_LSIZE(&range->sru.object_range.bp) >>
		    DNODE_SHIFT;
		uint64_t firstobj = range->start_blkid * epb;
		err = dump_object_range(dscp, &range->sru.object_range.bp,
		    firstobj, epb);
		break;
	}
	case REDACT: {
		struct srr *srrp = &range->sru.redact;
		err = dump_redact(dscp, range->object, range->start_blkid *
		    srrp->datablksz, (range->end_blkid - range->start_blkid) *
		    srrp->datablksz);
		return (err);
	}
	case DATA: {
		struct srd *srdp = &range->sru.data;
		blkptr_t *bp = &srdp->bp;
		spa_t *spa =
		    dmu_objset_spa(dscp->dsc_os);

		ASSERT3U(srdp->datablksz, ==, BP_GET_LSIZE(bp));
		ASSERT3U(range->start_blkid + 1, ==, range->end_blkid);

		if (send_do_embed(bp, dscp->dsc_featureflags)) {
			err = dump_write_embedded(dscp, range->object,
			    range->start_blkid * srdp->datablksz,
			    srdp->datablksz, bp);
			return (err);
		}
		ASSERT(range->object > dscp->dsc_resume_object ||
		    (range->object == dscp->dsc_resume_object &&
		    (range->start_blkid == DMU_SPILL_BLKID ||
		    range->start_blkid * srdp->datablksz >=
		    dscp->dsc_resume_offset)));
		/* it's a level-0 block of a regular object */

		if (srdp->byref) {
			return (dump_write_byref(dscp, range->object,
			    range->start_blkid * srdp->datablksz,
			    srdp->datablksz, bp, srdp->ref_object,
			    srdp->ref_offset));
		}

		mutex_enter(&srdp->lock);
		while (srdp->io_outstanding)
			cv_wait(&srdp->cv, &srdp->lock);
		err = srdp->io_err;
		mutex_exit(&srdp->lock);

		if (err != 0) {
			if (zfs_send_corrupt_data &&
			    !dscp->dsc_dso->dso_dryrun) {
				/*
				 * Send a block filled with 0x"zfs badd bloc"
				 */
				srdp->abuf = arc_alloc_buf(spa, &srdp->abuf,
				    ARC_BUFC_DATA, srdp->datablksz);
				uint64_t *ptr;
				for (ptr = srdp->abuf->b_data;
				    (char *)ptr < (char *)srdp->abuf->b_data +
				    srdp->datablksz; ptr++)
					*ptr = 0x2f5baddb10cULL;
			} else {
				return (SET_ERROR(EIO));
			}
		}

		ASSERT(dscp->dsc_dso->dso_dryrun ||
		    srdp->abuf != NULL || srdp->abd != NULL);

		char *data = NULL;
		if (srdp->abd != NULL) {
			data = abd_to_buf(srdp->abd);
			ASSERT0P(srdp->abuf);
		} else if (srdp->abuf != NULL) {
			data = srdp->abuf->b_data;
		}

		if (BP_GET_TYPE(bp) == DMU_OT_SA) {
			ASSERT3U(range->start_blkid, ==, DMU_SPILL_BLKID);
			err = dump_spill(dscp, bp, range->object, data);
			return (err);
		}

		uint64_t offset = range->start_blkid * srdp->datablksz;

		if (dscp->dsc_delta != NULL && data != NULL &&
		    !(srdp->datablksz > SPA_OLD_MAXBLOCKSIZE &&
		    !(dscp->dsc_featureflags &
		    DMU_BACKUP_FEATURE_LARGE_BLOCKS))) {
			boolean_t sent;
			err = send_delta_try(dscp, range, data, &sent);
			if (err != 0 || sent)
				return (err);
		}

		/*
		 * If we have large blocks stored on disk but the send flags
		 * don't allow us to send large blocks, we split the data from
		 * the arc buf into chunks.
		 */
		if (srdp->datablksz > SPA_OLD_MAXBLOCKSIZE &&
		    !(dscp->dsc_featureflags &
		    DMU_BACKUP_FEATURE_LARGE_BLOCKS)) {
			while (srdp->datablksz > 0 && err == 0) {
				int n = MIN(srdp->datablksz,
				    SPA_OLD_MAXBLOCKSIZE);
				err = dmu_dump_write(dscp, srdp->obj_type,
				    range->object, offset, n, n, NULL, B_FALSE,
				    data);
				offset += n;
				/*
				 * When doing dry run, data==NULL is used as a
				 * sentinel value by
				 * dmu_dump_write()->dump_record().
				 */
				if (data != NULL)
					data += n;
				srdp->datablksz -= n;
			}
		} else {
			err = dmu_dump_write(dscp, srdp->obj_type,
			    range->object, offset,
			    srdp->datablksz, srdp->datasz, bp,
			    srdp->io_compressed, data);
		}
		return (err);
	}
	case HOLE: {
		struct srh *srhp = &range->sru.hole;
		if (range->object == DMU_META_DNODE_OBJECT) {
			uint32_t span = srhp->datablksz >> DNODE_SHIFT;
			uint64_t first_obj = range->start_blkid * span;
			uint64_t numobj = range->end_blkid * span - first_obj;
			return (dump_freeobjects(dscp, first_obj, numobj));
		}
		uint64_t offset = 0;

		/*
		 * If this multiply overflows, we don't need to send this block.
		 * Even if it has a birth time, it can never not be a hole, so
		 * we don't need to send records for it.
		 */
		if (!overflow_multiply(range->start_blkid, srhp->datablksz,
		    &offset)) {
			return (0);
		}
		uint64_t len = 0;

		if (!overflow_multiply(range->end_blkid, srhp->datablksz, &len))
			len = UINT64_MAX;
		len = len - offset;
		return (dump_free(dscp, range->object, offset, len));
	}
	default:
		panic("Invalid range type in do_dump: %d", range->type);
	}
	return (err);
}

static struct send_range *
range_alloc(enum type type, uint64_t object, uint64_t start_blkid,
    uint64_t end_blkid, boolean_t eos)
{
	struct send_range *range = kmem_alloc(sizeof (*range), KM_SLEEP);
	range->type = type;
	range->object = object;
	range->start_blkid = start_blkid;
	range->end_blkid = end_blkid;
	range->eos_marker = eos;
	if (type == DATA) {
		range->sru.data.abd = NULL;
		range->sru.data.abuf = NULL;
		mutex_init(&range->sru.data.lock, NULL, MUTEX_DEFAULT, NULL);
		cv_init(&range->sru.data.cv, NULL, CV_DEFAULT, NULL);
		range->sru.data.io_outstanding = 0;
		range->sru.data.io_err = 0;
		range->sru.data.io_compressed = B_FALSE;
		range->sru.data.byref = B_FALSE;
	} else if (type == OBJECT) {
		range->sru.object.spill_range = NULL;
	}
	return (range);
}

/*
 * This is the callback function to traverse_dataset that acts as a worker
 * thread for dmu_send_impl.
 */
static int
send_cb(spa_t *spa, zilog_t *zilog, const blkptr_t *bp,
    const zbookmark_phys_t *zb, const struct dnode_phys *dnp, void *arg)
{
	(void) zilog;
	struct send_thread_arg *sta = arg;
	struct send_range *record;

	ASSERT(zb->zb_object == DMU_META_DNODE_OBJECT ||
	    zb->zb_object >= sta->resume.zb_object);

	/*
	 * All bps of an encrypted os should have the encryption bit set.
	 * If this is not true it indicates tampering and we report an error.
	 */
	if (sta->os->os_encrypted &&
	    !BP_IS_HOLE(bp) && !BP_USES_CRYPT(bp)) {
		spa_log_error(spa, zb, BP_GET_PHYSICAL_BIRTH(bp));
		return (SET_ERROR(EIO));
	}

	if (sta->cancel)
		return (SET_ERROR(EINTR));
	if (zb->zb_object != DMU_META_DNODE_OBJECT &&
	    DMU_OBJECT_IS_SPECIAL(zb->zb_object))
		return (0);
	atomic_inc_64(sta->num_blocks_visited);

	if (zb->zb_level == ZB_DNODE_LEVEL) {
		if (zb->zb_object == DMU_META_DNODE_OBJECT)
			return (0);
		record = range_alloc(OBJECT, zb->zb_object, 0, 0, B_FALSE);
		record->sru.object.bp = *bp;
		size_t size  = sizeof (*dnp) * (dnp->dn_extra_slots + 1);
		record->sru.object.dnp = kmem_alloc(size, KM_SLEEP);
		memcpy(record->sru.object.dnp, dnp, size);
		bqueue_enqueue(&sta->q, record, sizeof (*record));
		return (0);
	}
	if (zb->zb_level == 0 && zb->zb_object == DMU_META_DNODE_OBJECT &&
	    !BP_IS_HOLE(bp)) {
		record = range_alloc(OBJECT_RANGE, 0, zb->zb_blkid,
		    zb->zb_blkid + 1, B_FALSE);
		record->sru.object_range.bp = *bp;
		bqueue_enqueue(&sta->q, record, sizeof (*record));
		return (0);
	}
	if (zb->zb_level < 0 || (zb->zb_level > 0 && !BP_IS_HOLE(bp)))
		return (0);
	if (zb->zb_object == DMU_META_DNODE_OBJECT && !BP_IS_HOLE(bp))
		return (0);

	uint64_t span = bp_span_in_blocks(dnp->dn_indblkshift, zb->zb_level);
	uint64_t start;

	/*
	 * If this multiply overflows, we don't need to send this block.
	 * Even if it has a birth time, it can never not be a hole, so
	 * we don't need to send records for it.
	 */
	if (!overflow_multiply(span, zb->zb_blkid, &start) || (!(zb->zb_blkid ==
	    DMU_SPILL_BLKID || DMU_OT_IS_METADATA(dnp->dn_type)) &&
	    span * zb->zb_blkid > dnp->dn_maxblkid)) {
		ASSERT(BP_IS_HOLE(bp));
		return (0);
	}

	if (zb->zb_blkid == DMU_SPILL_BLKID)
		ASSERT3U(BP_GET_TYPE(bp), ==, DMU_OT_SA);

	enum type record_type = DATA;
	if (BP_IS_HOLE(bp))
		record_type = HOLE;
	else if (BP_IS_REDACTED(bp))
		record_type = REDACT;
	else
		record_type = DATA;

	record = range_alloc(record_type, zb->zb_object, start,
	    (start + span < start ? 0 : start + span), B_FALSE);

	uint64_t datablksz = (zb->zb_blkid == DMU_SPILL_BLKID ?
	    BP_GET_LSIZE(bp) : dnp->dn_datablkszsec << SPA_MINBLOCKSHIFT);

	if (BP_IS_HOLE(bp)) {
		record->sru.hole.datablksz = datablksz;
	} else if (BP_IS_REDACTED(bp)) {
		record->sru.redact.datablksz = datablksz;
	} else {
		record->sru.data.datablksz = datablksz;
		record->sru.data.obj_type = dnp->dn_type;
		record->sru.data.bp = *bp;
	}

	bqueue_enqueue(&sta->q, record, sizeof (*record));
	return (0);
}

struct redact_list_cb_arg {
	uint64_t *num_blocks_visited;
	bqueue_t *q;
	boolean_t *cancel;
	boolean_t mark_redact;
};

static int
redact_list_cb(redact_block_phys_t *rb, void *arg)
{
	struct redact_list_cb_arg *rlcap = arg;

	atomic_inc_64(rlcap->num_blocks_visited);
	if (*rlcap->cancel)
		return (-1);

	struct send_range *data = range_alloc(REDACT, rb->rbp_object,
	    rb->rbp_blkid, rb->rbp_blkid + redact_block_get_count(rb), B_FALSE);
	ASSERT3U(data->end_blkid, >, rb->rbp_blkid);
	if (rlcap->mark_redact) {
		data->type = REDACT;
		data->sru.redact.datablksz = redact_block_get_size(rb);
	} else {
		data->type = PREVIOUSLY_REDACTED;
	}
	bqueue_enqueue(rlcap->q, data, sizeof (*data));

	return (0);
}

/*
 * This function kicks off the traverse_dataset.  It also handles setting the
 * error code of the thread in case something goes wrong, and pushes the End of
 * Stream record when the traverse_dataset call has finished.
 */
static __attribute__((noreturn)) void
send_traverse_thread(void *arg)
{
	struct send_thread_arg *st_arg = arg;
	int err = 0;
	struct send_range *data;
	fstrans_cookie_t cookie = spl_fstrans_mark();

	err = traverse_dataset_resume(st_arg->os->os_dsl_dataset,
	    st_arg->fromtxg, &st_arg->resume,
	    st_arg->flags | TRAVERSE_LOGICAL, send_cb, st_arg);

	if (err != EINTR)
		st_arg->error_code = err;
	data = range_alloc(DATA, 0, 0, 0, B_TRUE);
	bqueue_enqueue_flush(&st_arg->q, data, sizeof (*data));
	spl_fstrans_unmark(cookie);
	thread_exit();
}

/*
 * Utility function that causes End of Stream records to compare after of all
 * others, so that other threads' comparison logic can stay simple.
 */
static int __attribute__((unused))
send_range_after(const struct send_range *from, const struct send_range *to)
{
	if (from->eos_marker == B_TRUE)
		return (1);
	if (to->eos_marker == B_TRUE)
		return (-1);

	uint64_t from_obj = from->object;
	uint64_t from_end_obj = from->object + 1;
	uint64_t to_obj = to->object;
	uint64_t to_end_obj = to->object + 1;
	if (from_obj == 0) {
		ASSERT(from->type == HOLE || from->type == OBJECT_RANGE);
		from_obj = from->start_blkid << DNODES_PER_BLOCK_SHIFT;
		from_end_obj = from->end_blkid << DNODES_PER_BLOCK_SHIFT;
	}
	if (to_obj == 0) {
		ASSERT(to->type == HOLE || to->type == OBJECT_RANGE);
		to_obj = to->start_blkid << DNODES_PER_BLOCK_SHIFT;
		to_end_obj = to->end_blkid << DNODES_PER_BLOCK_SHIFT;
	}

	if (from_end_obj <= to_obj)
		return (-1);
	if (from_obj >= to_end_obj)
		return (1);
	int64_t cmp = TREE_CMP(to->type == OBJECT_RANGE, from->type ==
	    OBJECT_RANGE);
	if (unlikely(cmp))
		return (cmp);
	cmp = TREE_CMP(to->type == OBJECT, from->type == OBJECT);
	if (unlikely(cmp))
		return (cmp);
	/*
	 * A meta-dnode range and an ordinary object's range express their
	 * blkids in different units, dnode blocks against that object's data
	 * blocks, so the blkid comparisons below cannot be applied to them.
	 * Reaching here means their object ranges overlap; the meta-dnode
	 * range sorts before the ranges of every object it covers, which is
	 * the order send_range_start_compare() also establishes.
	 */
	cmp = TREE_CMP(to->object == 0, from->object == 0);
	if (unlikely(cmp))
		return (cmp);
	if (from->end_blkid <= to->start_blkid)
		return (-1);
	if (from->start_blkid >= to->end_blkid)
		return (1);
	return (0);
}

/*
 * Pop the new data off the queue, check that the records we receive are in
 * the right order, but do not free the old data.  This is used so that the
 * records can be sent on to the main thread without copying the data.
 */
static struct send_range *
get_next_range_nofree(bqueue_t *bq, struct send_range *prev)
{
	struct send_range *next = bqueue_dequeue(bq);
	ASSERT3S(send_range_after(prev, next), ==, -1);
	return (next);
}

/*
 * Pop the new data off the queue, check that the records we receive are in
 * the right order, and free the old data.
 */
static struct send_range *
get_next_range(bqueue_t *bq, struct send_range *prev)
{
	struct send_range *next = get_next_range_nofree(bq, prev);
	range_free(prev);
	return (next);
}

static __attribute__((noreturn)) void
redact_list_thread(void *arg)
{
	struct redact_list_thread_arg *rlt_arg = arg;
	struct send_range *record;
	fstrans_cookie_t cookie = spl_fstrans_mark();
	if (rlt_arg->rl != NULL) {
		struct redact_list_cb_arg rlcba = {0};
		rlcba.cancel = &rlt_arg->cancel;
		rlcba.q = &rlt_arg->q;
		rlcba.num_blocks_visited = rlt_arg->num_blocks_visited;
		rlcba.mark_redact = rlt_arg->mark_redact;
		int err = dsl_redaction_list_traverse(rlt_arg->rl,
		    &rlt_arg->resume, redact_list_cb, &rlcba);
		if (err != EINTR)
			rlt_arg->error_code = err;
	}
	record = range_alloc(DATA, 0, 0, 0, B_TRUE);
	bqueue_enqueue_flush(&rlt_arg->q, record, sizeof (*record));
	spl_fstrans_unmark(cookie);

	thread_exit();
}

/*
 * Compare the start point of the two provided ranges. End of stream ranges
 * compare last, objects compare before any data or hole inside that object and
 * multi-object holes that start at the same object.
 */
static int
send_range_start_compare(struct send_range *r1, struct send_range *r2)
{
	uint64_t r1_objequiv = r1->object;
	uint64_t r1_l0equiv = r1->start_blkid;
	uint64_t r2_objequiv = r2->object;
	uint64_t r2_l0equiv = r2->start_blkid;
	int64_t cmp = TREE_CMP(r1->eos_marker, r2->eos_marker);
	if (unlikely(cmp))
		return (cmp);
	if (r1->object == 0) {
		r1_objequiv = r1->start_blkid * DNODES_PER_BLOCK;
		r1_l0equiv = 0;
	}
	if (r2->object == 0) {
		r2_objequiv = r2->start_blkid * DNODES_PER_BLOCK;
		r2_l0equiv = 0;
	}

	cmp = TREE_CMP(r1_objequiv, r2_objequiv);
	if (likely(cmp))
		return (cmp);
	cmp = TREE_CMP(r2->type == OBJECT_RANGE, r1->type == OBJECT_RANGE);
	if (unlikely(cmp))
		return (cmp);
	cmp = TREE_CMP(r2->type == OBJECT, r1->type == OBJECT);
	if (unlikely(cmp))
		return (cmp);
	/*
	 * A meta-dnode range covering dnode block b has the same objequiv as
	 * the first block of object b * DNODES_PER_BLOCK, but the two do not
	 * start at the same place: their blkids count different things.  The
	 * merge in find_next_range() may only treat ranges as starting
	 * together when they genuinely share an object and a block, so order
	 * the meta-dnode range first rather than reporting them equal.
	 */
	cmp = TREE_CMP(r2->object == 0, r1->object == 0);
	if (unlikely(cmp))
		return (cmp);

	return (TREE_CMP(r1_l0equiv, r2_l0equiv));
}

enum q_idx {
	REDACT_IDX = 0,
	TO_IDX,
	FROM_IDX,
	NUM_THREADS
};

/*
 * This function returns the next range the send_merge_thread should operate on.
 * The inputs are two arrays; the first one stores the range at the front of the
 * queues stored in the second one.  The ranges are sorted in descending
 * priority order; the metadata from earlier ranges overrules metadata from
 * later ranges.  out_mask is used to return which threads the ranges came from;
 * bit i is set if ranges[i] started at the same place as the returned range.
 *
 * This code is not hardcoded to compare a specific number of threads; it could
 * be used with any number, just by changing the q_idx enum.
 *
 * The "next range" is the one with the earliest start; if two starts are equal,
 * the highest-priority range is the next to operate on.  If a higher-priority
 * range starts in the middle of the first range, then the first range will be
 * truncated to end where the higher-priority range starts, and we will operate
 * on that one next time.   In this way, we make sure that each block covered by
 * some range gets covered by a returned range, and each block covered is
 * returned using the metadata of the highest-priority range it appears in.
 *
 * For example, if the three ranges at the front of the queues were [2,4),
 * [3,5), and [1,3), then the ranges returned would be [1,2) with the metadata
 * from the third range, [2,4) with the metadata from the first range, and then
 * [4,5) with the metadata from the second.
 */
static struct send_range *
find_next_range(struct send_range **ranges, bqueue_t **qs, uint64_t *out_mask)
{
	int idx = 0; // index of the range with the earliest start
	int i;
	uint64_t bmask = 0;
	for (i = 1; i < NUM_THREADS; i++) {
		if (send_range_start_compare(ranges[i], ranges[idx]) < 0)
			idx = i;
	}
	if (ranges[idx]->eos_marker) {
		struct send_range *ret = range_alloc(DATA, 0, 0, 0, B_TRUE);
		*out_mask = 0;
		return (ret);
	}
	/*
	 * Find all the ranges that start at that same point.
	 */
	for (i = 0; i < NUM_THREADS; i++) {
		if (send_range_start_compare(ranges[i], ranges[idx]) == 0)
			bmask |= 1 << i;
	}
	*out_mask = bmask;
	/*
	 * OBJECT_RANGE records only come from the TO thread, and should always
	 * be treated as overlapping with nothing and sent on immediately.  They
	 * are only used in raw sends, and are never redacted.
	 */
	if (ranges[idx]->type == OBJECT_RANGE) {
		ASSERT3U(idx, ==, TO_IDX);
		ASSERT3U(*out_mask, ==, 1 << TO_IDX);
		struct send_range *ret = ranges[idx];
		ranges[idx] = get_next_range_nofree(qs[idx], ranges[idx]);
		return (ret);
	}
	/*
	 * Find the first start or end point after the start of the first range.
	 */
	uint64_t first_change = ranges[idx]->end_blkid;
	for (i = 0; i < NUM_THREADS; i++) {
		if (i == idx || ranges[i]->eos_marker ||
		    ranges[i]->object > ranges[idx]->object ||
		    ranges[i]->object == DMU_META_DNODE_OBJECT)
			continue;
		ASSERT3U(ranges[i]->object, ==, ranges[idx]->object);
		if (first_change > ranges[i]->start_blkid &&
		    (bmask & (1 << i)) == 0)
			first_change = ranges[i]->start_blkid;
		else if (first_change > ranges[i]->end_blkid)
			first_change = ranges[i]->end_blkid;
	}
	/*
	 * Update all ranges to no longer overlap with the range we're
	 * returning. All such ranges must start at the same place as the range
	 * being returned, and end at or after first_change. Thus we update
	 * their start to first_change. If that makes them size 0, then free
	 * them and pull a new range from that thread.
	 */
	for (i = 0; i < NUM_THREADS; i++) {
		if (i == idx || (bmask & (1 << i)) == 0)
			continue;
		ASSERT3U(ranges[i]->object, ==, ranges[idx]->object);
		ASSERT3U(first_change, >, ranges[i]->start_blkid);
		ranges[i]->start_blkid = first_change;
		ASSERT3U(ranges[i]->start_blkid, <=, ranges[i]->end_blkid);
		if (ranges[i]->start_blkid == ranges[i]->end_blkid)
			ranges[i] = get_next_range(qs[i], ranges[i]);
	}
	/*
	 * Short-circuit the simple case; if the range doesn't overlap with
	 * anything else, or it only overlaps with things that start at the same
	 * place and are longer, send it on.
	 */
	if (first_change == ranges[idx]->end_blkid) {
		struct send_range *ret = ranges[idx];
		ranges[idx] = get_next_range_nofree(qs[idx], ranges[idx]);
		return (ret);
	}

	/*
	 * Otherwise, return a truncated copy of ranges[idx] and move the start
	 * of ranges[idx] back to first_change.
	 */
	struct send_range *ret = kmem_alloc(sizeof (*ret), KM_SLEEP);
	*ret = *ranges[idx];
	ret->end_blkid = first_change;
	ranges[idx]->start_blkid = first_change;
	return (ret);
}

#define	FROM_AND_REDACT_BITS ((1 << REDACT_IDX) | (1 << FROM_IDX))

/*
 * Merge the results from the from thread and the to thread, and then hand the
 * records off to send_prefetch_thread to prefetch them.  If this is not a
 * send from a redaction bookmark, the from thread will push an end of stream
 * record and stop, and we'll just send everything that was changed in the
 * to_ds since the ancestor's creation txg. If it is, then since
 * traverse_dataset has a canonical order, we can compare each change as
 * they're pulled off the queues.  That will give us a stream that is
 * appropriately sorted, and covers all records.  In addition, we pull the
 * data from the redact_list_thread and use that to determine which blocks
 * should be redacted.
 */
static __attribute__((noreturn)) void
send_merge_thread(void *arg)
{
	struct send_merge_thread_arg *smt_arg = arg;
	struct send_range *front_ranges[NUM_THREADS];
	bqueue_t *queues[NUM_THREADS];
	int err = 0;
	fstrans_cookie_t cookie = spl_fstrans_mark();

	if (smt_arg->redact_arg == NULL) {
		front_ranges[REDACT_IDX] =
		    kmem_zalloc(sizeof (struct send_range), KM_SLEEP);
		front_ranges[REDACT_IDX]->eos_marker = B_TRUE;
		front_ranges[REDACT_IDX]->type = REDACT;
		queues[REDACT_IDX] = NULL;
	} else {
		front_ranges[REDACT_IDX] =
		    bqueue_dequeue(&smt_arg->redact_arg->q);
		queues[REDACT_IDX] = &smt_arg->redact_arg->q;
	}
	front_ranges[TO_IDX] = bqueue_dequeue(&smt_arg->to_arg->q);
	queues[TO_IDX] = &smt_arg->to_arg->q;
	front_ranges[FROM_IDX] = bqueue_dequeue(&smt_arg->from_arg->q);
	queues[FROM_IDX] = &smt_arg->from_arg->q;
	uint64_t mask = 0;
	struct send_range *range;
	for (range = find_next_range(front_ranges, queues, &mask);
	    !range->eos_marker && err == 0 && !smt_arg->cancel;
	    range = find_next_range(front_ranges, queues, &mask)) {
		/*
		 * If the range in question was in both the from redact bookmark
		 * and the bookmark we're using to redact, then don't send it.
		 * It's already redacted on the receiving system, so a redaction
		 * record would be redundant.
		 */
		if ((mask & FROM_AND_REDACT_BITS) == FROM_AND_REDACT_BITS) {
			ASSERT3U(range->type, ==, REDACT);
			range_free(range);
			continue;
		}
		bqueue_enqueue(&smt_arg->q, range, sizeof (*range));

		if (smt_arg->to_arg->error_code != 0) {
			err = smt_arg->to_arg->error_code;
		} else if (smt_arg->from_arg->error_code != 0) {
			err = smt_arg->from_arg->error_code;
		} else if (smt_arg->redact_arg != NULL &&
		    smt_arg->redact_arg->error_code != 0) {
			err = smt_arg->redact_arg->error_code;
		}
	}
	if (smt_arg->cancel && err == 0)
		err = SET_ERROR(EINTR);
	smt_arg->error = err;
	if (smt_arg->error != 0) {
		smt_arg->to_arg->cancel = B_TRUE;
		smt_arg->from_arg->cancel = B_TRUE;
		if (smt_arg->redact_arg != NULL)
			smt_arg->redact_arg->cancel = B_TRUE;
	}
	for (int i = 0; i < NUM_THREADS; i++) {
		while (!front_ranges[i]->eos_marker) {
			front_ranges[i] = get_next_range(queues[i],
			    front_ranges[i]);
		}
		range_free(front_ranges[i]);
	}
	range->eos_marker = B_TRUE;
	bqueue_enqueue_flush(&smt_arg->q, range, 1);
	spl_fstrans_unmark(cookie);
	thread_exit();
}

struct send_reader_thread_arg {
	struct send_merge_thread_arg *smta;
	bqueue_t q;
	boolean_t cancel;
	boolean_t issue_reads;
	uint64_t featureflags;
	int error;
	/* fromsnap references for --refs sends, or NULL */
	struct send_refs *refs;
	/* the fromsnap, for prefetching --delta reference blocks, or NULL */
	objset_t *delta_ref_os;
};

/*
 * Fromsnap references (zfs send --refs).
 *
 * The receiver of an incremental stream already has the fromsnap, so a
 * delta block whose data the fromsnap also references need not be sent:
 * a DRR_WRITE_BYREF naming the fromsnap location is enough.  Such blocks
 * arise when dedup or block cloning shares a block between the fromsnap
 * and data written after it.  Both keep the original DVAs and physical
 * birth, so they are cheap to recognize: the block pointer's logical
 * birth is after the fromsnap but its physical birth is not.
 *
 * Before the stream starts we build an index of such blocks:
 *
 *  1. Traverse the delta (blocks born after the fromsnap, block pointers
 *     only) and record each L0 data block whose physical birth is at or
 *     before the fromsnap, keyed by its first DVA.  These are candidates.
 *
 *  2. Traverse the fromsnap, pruned to blocks born no earlier than the
 *     oldest candidate, and record where each candidate DVA is referenced.
 *
 * Memory is bounded by zfs_send_refs_max_blocks.  The receiver's copy of
 * the fromsnap is a logical replica of ours, so it may clone its own block
 * or copy it; either way the data never crosses the wire.
 */
#define	REFS_UNRESOLVED	UINT64_MAX

typedef struct refs_entry {
	avl_node_t	re_node;
	dva_t		re_dva;
	uint64_t	re_birth;	/* physical birth */
	uint64_t	re_object;	/* fromsnap location, or */
	uint64_t	re_offset;	/* REFS_UNRESOLVED */
} refs_entry_t;

typedef struct send_refs {
	avl_tree_t	sr_index;
	uint64_t	sr_fromtxg;
	uint64_t	sr_minbirth;	/* oldest candidate physical birth */
	uint64_t	sr_candidates;
	uint64_t	sr_resolved;
	boolean_t	sr_full;	/* zfs_send_refs_max_blocks reached */
	/*
	 * For --delta: data blocks with new data (written after the
	 * fromsnap), and how many of them belong to objects the fromsnap
	 * does not have.  Only counted if sr_from_os is set.
	 */
	objset_t	*sr_from_os;
	uint64_t	sr_new_blocks;
	uint64_t	sr_new_blocks_new_obj;
	uint64_t	sr_obj;		/* object existence cache */
	boolean_t	sr_obj_in_from;
} send_refs_t;

static int
refs_entry_compare(const void *a, const void *b)
{
	const refs_entry_t *ea = a, *eb = b;
	int cmp = TREE_CMP(DVA_GET_VDEV(&ea->re_dva),
	    DVA_GET_VDEV(&eb->re_dva));
	if (cmp != 0)
		return (cmp);
	return (TREE_CMP(DVA_GET_OFFSET(&ea->re_dva),
	    DVA_GET_OFFSET(&eb->re_dva)));
}

static boolean_t
refs_bp_eligible(const blkptr_t *bp)
{
	return (!BP_IS_HOLE(bp) && !BP_IS_EMBEDDED(bp) &&
	    !BP_IS_REDACTED(bp) && !BP_IS_GANG(bp) &&
	    !DMU_OT_IS_METADATA(BP_GET_TYPE(bp)));
}

static boolean_t
refs_zb_eligible(const zbookmark_phys_t *zb)
{
	return (zb->zb_level == 0 && zb->zb_object != DMU_META_DNODE_OBJECT &&
	    zb->zb_blkid != DMU_SPILL_BLKID);
}

static int
refs_candidate_cb(spa_t *spa, zilog_t *zilog, const blkptr_t *bp,
    const zbookmark_phys_t *zb, const dnode_phys_t *dnp, void *arg)
{
	(void) spa, (void) zilog, (void) dnp;
	send_refs_t *sr = arg;
	avl_index_t where;

	if (bp == NULL || !refs_zb_eligible(zb) || !refs_bp_eligible(bp))
		return (0);

	if (BP_GET_PHYSICAL_BIRTH(bp) > sr->sr_fromtxg) {
		if (sr->sr_from_os == NULL)
			return (0);
		if (sr->sr_obj != zb->zb_object) {
			dnode_t *dn;

			sr->sr_obj = zb->zb_object;
			sr->sr_obj_in_from = (dnode_hold(sr->sr_from_os,
			    zb->zb_object, FTAG, &dn) == 0);
			if (sr->sr_obj_in_from)
				dnode_rele(dn, FTAG);
		}
		sr->sr_new_blocks++;
		if (!sr->sr_obj_in_from)
			sr->sr_new_blocks_new_obj++;
		return (0);
	}

	refs_entry_t search = { .re_dva = bp->blk_dva[0] };
	if (sr->sr_full || avl_find(&sr->sr_index, &search, &where) != NULL)
		return (0);
	if (sr->sr_candidates >= zfs_send_refs_max_blocks) {
		REFS_STAT_BUMP(send_refs_truncated);
		/* Keep counting new data blocks if asked to. */
		if (sr->sr_from_os == NULL)
			return (SET_ERROR(ERANGE));
		sr->sr_full = B_TRUE;
		return (0);
	}

	refs_entry_t *re = kmem_alloc(sizeof (*re), KM_SLEEP);
	re->re_dva = bp->blk_dva[0];
	re->re_birth = BP_GET_PHYSICAL_BIRTH(bp);
	re->re_object = REFS_UNRESOLVED;
	re->re_offset = REFS_UNRESOLVED;
	avl_insert(&sr->sr_index, re, where);
	sr->sr_candidates++;
	sr->sr_minbirth = MIN(sr->sr_minbirth, re->re_birth);
	return (0);
}

static int
refs_resolve_cb(spa_t *spa, zilog_t *zilog, const blkptr_t *bp,
    const zbookmark_phys_t *zb, const dnode_phys_t *dnp, void *arg)
{
	(void) spa, (void) zilog, (void) dnp;
	send_refs_t *sr = arg;

	if (bp == NULL || !refs_zb_eligible(zb) || !refs_bp_eligible(bp))
		return (0);

	refs_entry_t search = { .re_dva = bp->blk_dva[0] };
	refs_entry_t *re = avl_find(&sr->sr_index, &search, NULL);
	if (re == NULL || re->re_object != REFS_UNRESOLVED ||
	    re->re_birth != BP_GET_PHYSICAL_BIRTH(bp))
		return (0);

	re->re_object = zb->zb_object;
	re->re_offset = zb->zb_blkid * BP_GET_LSIZE(bp);
	/* Stop early once every candidate has a location. */
	if (++sr->sr_resolved == sr->sr_candidates)
		return (SET_ERROR(ERANGE));
	return (0);
}

static void
send_refs_destroy(send_refs_t *sr)
{
	refs_entry_t *re;
	void *cookie = NULL;

	while ((re = avl_destroy_nodes(&sr->sr_index, &cookie)) != NULL)
		kmem_free(re, sizeof (*re));
	avl_destroy(&sr->sr_index);
	kmem_free(sr, sizeof (*sr));
}

/*
 * Find and long-hold the snapshot in to_ds's history that the incremental
 * is from.  Called with the pool config lock held.  Returns NULL if the
 * source is not an existing snapshot (e.g. a bookmark of a destroyed one).
 */
static dsl_dataset_t *
send_refs_fromsnap_hold(dsl_pool_t *dp, dsl_dataset_t *to_ds,
    const zfs_bookmark_phys_t *ancestor_zb, const void *tag)
{
	uint64_t obj = dsl_dataset_phys(to_ds)->ds_prev_snap_obj;

	ASSERT(dsl_pool_config_held(dp));
	while (obj != 0) {
		dsl_dataset_t *ds;

		if (dsl_dataset_hold_obj(dp, obj, tag, &ds) != 0)
			return (NULL);
		if (dsl_dataset_phys(ds)->ds_guid == ancestor_zb->zbm_guid) {
			dsl_dataset_long_hold(ds, tag);
			return (ds);
		}
		obj = dsl_dataset_phys(ds)->ds_prev_snap_obj;
		boolean_t older = dsl_dataset_phys(ds)->ds_creation_txg <
		    ancestor_zb->zbm_creation_txg;
		dsl_dataset_rele(ds, tag);
		if (older)
			return (NULL);
	}
	return (NULL);
}

static void
send_refs_fromsnap_rele(dsl_dataset_t *ds, const void *tag)
{
	dsl_dataset_long_rele(ds, tag);
	dsl_dataset_rele(ds, tag);
}

/*
 * Build the reference index for an incremental from fromds to to_ds.
 * Returns NULL if there is nothing to reference or a traversal fails, in
 * which case the stream is sent without references.
 */
static send_refs_t *
send_refs_build(dsl_dataset_t *to_ds, dsl_dataset_t *fromds,
    uint64_t fromtxg, boolean_t count_new, uint64_t *new_blocksp,
    uint64_t *new_blocks_new_objp)
{
	send_refs_t *sr = kmem_zalloc(sizeof (*sr), KM_SLEEP);
	int err;

	avl_create(&sr->sr_index, refs_entry_compare, sizeof (refs_entry_t),
	    offsetof(refs_entry_t, re_node));
	sr->sr_fromtxg = fromtxg;
	sr->sr_minbirth = UINT64_MAX;
	sr->sr_obj = UINT64_MAX;
	if (count_new && dmu_objset_from_ds(fromds, &sr->sr_from_os) != 0)
		sr->sr_from_os = NULL;

	err = traverse_dataset(to_ds, fromtxg,
	    TRAVERSE_PRE | TRAVERSE_PREFETCH_METADATA, refs_candidate_cb, sr);
	if (err == ERANGE)
		err = 0;
	if (new_blocksp != NULL) {
		*new_blocksp = sr->sr_new_blocks;
		*new_blocks_new_objp = sr->sr_new_blocks_new_obj;
	}
	if (err == 0 && sr->sr_candidates > 0) {
		err = traverse_dataset(fromds, sr->sr_minbirth - 1,
		    TRAVERSE_PRE | TRAVERSE_PREFETCH_METADATA,
		    refs_resolve_cb, sr);
		if (err == ERANGE)
			err = 0;
	}
	REFS_STAT_INCR(send_refs_candidates, sr->sr_candidates);
	REFS_STAT_INCR(send_refs_resolved, sr->sr_resolved);
	if (err != 0 || sr->sr_resolved == 0) {
		send_refs_destroy(sr);
		return (NULL);
	}
	return (sr);
}

/*
 * Decide whether a delta block can be sent as a fromsnap reference.
 */
static boolean_t
send_refs_lookup(struct send_reader_thread_arg *srta, struct send_range *range,
    boolean_t split_large_blocks)
{
	send_refs_t *sr = srta->refs;
	struct srd *srdp = &range->sru.data;
	const blkptr_t *bp = &srdp->bp;

	if (sr == NULL || split_large_blocks ||
	    range->start_blkid == DMU_SPILL_BLKID || !refs_bp_eligible(bp) ||
	    BP_GET_LOGICAL_BIRTH(bp) <= sr->sr_fromtxg ||
	    BP_GET_PHYSICAL_BIRTH(bp) > sr->sr_fromtxg)
		return (B_FALSE);

	refs_entry_t search = { .re_dva = bp->blk_dva[0] };
	refs_entry_t *re = avl_find(&sr->sr_index, &search, NULL);
	if (re == NULL || re->re_object == REFS_UNRESOLVED ||
	    re->re_birth != BP_GET_PHYSICAL_BIRTH(bp))
		return (B_FALSE);

	srdp->byref = B_TRUE;
	srdp->ref_object = re->re_object;
	srdp->ref_offset = re->re_offset;
	return (B_TRUE);
}

static void
dmu_send_read_done(zio_t *zio)
{
	struct send_range *range = zio->io_private;

	mutex_enter(&range->sru.data.lock);
	if (zio->io_error != 0) {
		abd_free(range->sru.data.abd);
		range->sru.data.abd = NULL;
		range->sru.data.io_err = zio->io_error;
	}

	ASSERT(range->sru.data.io_outstanding);
	range->sru.data.io_outstanding = B_FALSE;
	cv_broadcast(&range->sru.data.cv);
	mutex_exit(&range->sru.data.lock);
}

/*
 * Partial block deltas (zfs send --delta).
 *
 * A changed block that is not identical to any fromsnap block may still be
 * mostly the same as one: a file edited in place, or a copy of a file with
 * a few bytes changed.  Such blocks are sent as DRR_WRITE_DELTA records,
 * a patch (sys/zfs_delta.h) against a fromsnap block, which the receiver
 * reads from its own copy of the fromsnap.  Reference candidates are tried
 * in this order until one yields a small enough patch:
 *
 *  - same: the same object and offset in the fromsnap, for files modified
 *    in place;
 *  - sibling: the same offset in the fromsnap file that other blocks of
 *    this file are sent as references to (see send_refs_t), for files
 *    that were copied and then modified;
 *  - sketch: a fromsnap block sharing a content super-feature, from an
 *    index built by reading the fromsnap before the stream starts, bounded
 *    by zfs_send_delta_sketch_max_blocks and zfs_send_delta_sketch_max_bytes.
 */
typedef struct delta_sketch_entry {
	avl_node_t	dse_node;
	uint64_t	dse_sf;
	uint64_t	dse_object;
	uint64_t	dse_offset;
	uint64_t	dse_length;
} delta_sketch_entry_t;

typedef struct send_delta {
	objset_t	*sd_ref_os;	/* the fromsnap */
	send_refs_t	*sd_refs;	/* may be NULL */
	avl_tree_t	sd_sketch;
	uint64_t	sd_sketch_blocks;
	uint64_t	sd_sketch_bytes;
	uint32_t	*sd_htab;	/* zfs_delta_encode() scratch */
	uint64_t	sd_sib_object;	/* delta_sibling() cache */
	uint64_t	sd_sib_ref;
	/* delta_same_exists() cache: the fromsnap's dnode for an object */
	uint64_t	sd_same_object;
	boolean_t	sd_same_found;
	dmu_object_type_t sd_same_type;
	uint64_t	sd_same_blksz;
	uint64_t	sd_same_maxblkid;
	/* buffers reused across blocks, all sd_bufsize bytes */
	uint64_t	sd_bufsize;
	uint8_t		*sd_refbuf;
	uint8_t		*sd_tgtbuf;
	uint8_t		*sd_patchbuf;
} send_delta_t;

typedef enum delta_ref_kind {
	DELTA_REF_SAME,
	DELTA_REF_SIBLING,
	DELTA_REF_SKETCH,
	DELTA_REF_KINDS
} delta_ref_kind_t;

static int
delta_sketch_compare(const void *a, const void *b)
{
	const delta_sketch_entry_t *ea = a, *eb = b;
	return (TREE_CMP(ea->dse_sf, eb->dse_sf));
}

static int
delta_sketch_cb(spa_t *spa, zilog_t *zilog, const blkptr_t *bp,
    const zbookmark_phys_t *zb, const dnode_phys_t *dnp, void *arg)
{
	(void) zilog, (void) dnp;
	send_delta_t *sd = arg;
	arc_flags_t aflags = ARC_FLAG_WAIT;
	arc_buf_t *abuf = NULL;
	uint64_t sf[ZFS_DELTA_NSF];

	if (bp == NULL || !refs_zb_eligible(zb) || !refs_bp_eligible(bp) ||
	    BP_IS_PROTECTED(bp))
		return (0);
	if (sd->sd_sketch_blocks >= zfs_send_delta_sketch_max_blocks ||
	    sd->sd_sketch_bytes >= zfs_send_delta_sketch_max_bytes) {
		REFS_STAT_BUMP(send_delta_sketch_truncated);
		return (SET_ERROR(ERANGE));
	}

	/* A block that cannot be read is simply left out of the index. */
	if (arc_read(NULL, spa, bp, arc_getbuf_func, &abuf,
	    ZIO_PRIORITY_ASYNC_READ, ZIO_FLAG_CANFAIL, &aflags, zb) != 0)
		return (0);
	sd->sd_sketch_blocks++;
	sd->sd_sketch_bytes += BP_GET_LSIZE(bp);
	boolean_t ok = zfs_delta_sketch(abuf->b_data, BP_GET_LSIZE(bp), sf);
	arc_buf_destroy(abuf, &abuf);
	if (!ok)
		return (0);

	for (int i = 0; i < ZFS_DELTA_NSF; i++) {
		delta_sketch_entry_t search = { .dse_sf = sf[i] };
		avl_index_t where;

		if (avl_find(&sd->sd_sketch, &search, &where) != NULL)
			continue;
		delta_sketch_entry_t *dse = kmem_alloc(sizeof (*dse),
		    KM_SLEEP);
		dse->dse_sf = sf[i];
		dse->dse_object = zb->zb_object;
		dse->dse_offset = zb->zb_blkid * BP_GET_LSIZE(bp);
		dse->dse_length = BP_GET_LSIZE(bp);
		avl_insert(&sd->sd_sketch, dse, where);
	}
	return (0);
}

static void
send_delta_destroy(send_delta_t *sd)
{
	delta_sketch_entry_t *dse;
	void *cookie = NULL;

	while ((dse = avl_destroy_nodes(&sd->sd_sketch, &cookie)) != NULL)
		kmem_free(dse, sizeof (*dse));
	avl_destroy(&sd->sd_sketch);
	vmem_free(sd->sd_htab, ZFS_DELTA_HASH_SIZE * sizeof (uint32_t));
	if (sd->sd_bufsize != 0) {
		vmem_free(sd->sd_refbuf, sd->sd_bufsize);
		vmem_free(sd->sd_tgtbuf, sd->sd_bufsize);
		vmem_free(sd->sd_patchbuf, sd->sd_bufsize);
	}
	kmem_free(sd, sizeof (*sd));
}

/*
 * Set up delta sends against fromds, which the caller keeps held for the
 * duration of the send.  Returns NULL if the fromsnap cannot be used.
 */
static send_delta_t *
send_delta_create(dsl_dataset_t *fromds, send_refs_t *refs,
    uint64_t new_blocks, uint64_t new_blocks_new_obj)
{
	send_delta_t *sd;
	objset_t *ref_os;

	if (dmu_objset_from_ds(fromds, &ref_os) != 0)
		return (NULL);

	sd = kmem_zalloc(sizeof (*sd), KM_SLEEP);
	sd->sd_ref_os = ref_os;
	sd->sd_refs = refs;
	sd->sd_sib_object = UINT64_MAX;
	sd->sd_same_object = UINT64_MAX;
	sd->sd_htab = vmem_alloc(ZFS_DELTA_HASH_SIZE * sizeof (uint32_t),
	    KM_SLEEP);
	avl_create(&sd->sd_sketch, delta_sketch_compare,
	    sizeof (delta_sketch_entry_t),
	    offsetof(delta_sketch_entry_t, dse_node));

	/*
	 * When nearly all new data is in files the fromsnap already has (a
	 * database or image modified in place), the same-object candidate
	 * covers it, and reading the whole fromsnap for the sketch index
	 * would cost far more than it saves.
	 */
	boolean_t sketch = zfs_send_delta_sketch_max_blocks != 0 &&
	    zfs_send_delta_sketch_max_bytes != 0;
	if (sketch && (new_blocks == 0 || new_blocks_new_obj * 100 <
	    new_blocks * MIN(zfs_send_delta_sketch_min_pct, 100))) {
		REFS_STAT_BUMP(send_delta_sketch_skipped);
		sketch = B_FALSE;
	}
	if (sketch) {
		hrtime_t start = gethrtime();
		int err = traverse_dataset(fromds, 0,
		    TRAVERSE_PRE | TRAVERSE_PREFETCH, delta_sketch_cb, sd);
		/* A partial index is still useful. */
		if (err != 0 && err != ERANGE)
			REFS_STAT_BUMP(send_delta_sketch_truncated);
		REFS_STAT_INCR(send_delta_sketch_blocks, sd->sd_sketch_blocks);
		REFS_STAT_INCR(send_delta_sketch_ns, gethrtime() - start);
	}
	return (sd);
}

/*
 * Find the fromsnap object that other blocks of this (tosnap) object are
 * sent as references to at the same offsets: for a file that was copied
 * and then partly changed, that is the file it was copied from.  Returns
 * 0 if there is none.  Blocks arrive in object order, so cache the answer.
 */
static uint64_t
delta_sibling(dmu_send_cookie_t *dscp, uint64_t object)
{
	send_delta_t *sd = dscp->dsc_delta;
	send_refs_t *sr = sd->sd_refs;
	dnode_t *dn;

	if (sd->sd_sib_object == object)
		return (sd->sd_sib_ref);
	sd->sd_sib_object = object;
	sd->sd_sib_ref = 0;
	if (sr == NULL || dnode_hold(dscp->dsc_os, object, FTAG, &dn) != 0)
		return (0);

	rw_enter(&dn->dn_struct_rwlock, RW_READER);
	uint64_t lsize = dn->dn_datablksz;
	uint64_t maxblk = MIN(dn->dn_maxblkid,
	    (uint64_t)zfs_send_delta_sibling_scan);
	for (uint64_t blkid = 0; blkid <= maxblk; blkid++) {
		blkptr_t bp;

		if (dbuf_dnode_findbp(dn, 0, blkid, &bp, NULL, NULL) != 0 ||
		    !refs_bp_eligible(&bp) ||
		    BP_GET_PHYSICAL_BIRTH(&bp) > sr->sr_fromtxg)
			continue;
		refs_entry_t search = { .re_dva = bp.blk_dva[0] };
		refs_entry_t *re = avl_find(&sr->sr_index, &search, NULL);
		if (re != NULL && re->re_object != REFS_UNRESOLVED &&
		    re->re_birth == BP_GET_PHYSICAL_BIRTH(&bp) &&
		    re->re_offset == blkid * lsize) {
			sd->sd_sib_ref = re->re_object;
			break;
		}
	}
	rw_exit(&dn->dn_struct_rwlock);
	dnode_rele(dn, FTAG);
	return (sd->sd_sib_ref);
}

/*
 * Whether the fromsnap has a block of the same kind at this object and
 * offset (the object may since have been freed or reallocated).
 */
static boolean_t
delta_same_exists(send_delta_t *sd, uint64_t object, uint64_t offset,
    dmu_object_type_t type, uint64_t lsize)
{
	/* Blocks arrive in object order, so look each object up once. */
	if (sd->sd_same_object != object) {
		dnode_t *dn;

		sd->sd_same_object = object;
		sd->sd_same_found = (dnode_hold(sd->sd_ref_os, object, FTAG,
		    &dn) == 0);
		if (sd->sd_same_found) {
			sd->sd_same_type = dn->dn_type;
			sd->sd_same_blksz = dn->dn_datablksz;
			sd->sd_same_maxblkid = dn->dn_maxblkid;
			dnode_rele(dn, FTAG);
		}
	}
	return (sd->sd_same_found && sd->sd_same_type == type &&
	    sd->sd_same_blksz == lsize &&
	    offset / lsize <= sd->sd_same_maxblkid);
}

static int
dump_write_delta(dmu_send_cookie_t *dscp, struct send_range *range,
    const uint8_t *tgt, uint64_t refobject, uint64_t refoffset,
    uint64_t reflength, uint8_t *patch, size_t patchlen)
{
	struct srd *srdp = &range->sru.data;
	struct drr_write_delta *drrwd =
	    &(dscp->dsc_drr->drr_u.drr_write_delta);
	uint64_t object = range->object;
	uint64_t lsize = srdp->datablksz;
	uint64_t offset = range->start_blkid * lsize;
	size_t payload = P2ROUNDUP(patchlen, 8);

	/* Same ordering rules as dmu_dump_write(). */
	ASSERT(object > dscp->dsc_last_data_object ||
	    (object == dscp->dsc_last_data_object &&
	    offset > dscp->dsc_last_data_offset));
	dscp->dsc_last_data_object = object;
	dscp->dsc_last_data_offset = offset + lsize - 1;

	if (dscp->dsc_pending_op != PENDING_NONE) {
		if (dump_record(dscp, NULL, 0) != 0)
			return (SET_ERROR(EINTR));
		dscp->dsc_pending_op = PENDING_NONE;
	}

	memset(dscp->dsc_drr, 0, sizeof (dmu_replay_record_t));
	dscp->dsc_drr->drr_type = DRR_WRITE_DELTA;
	drrwd->drr_object = object;
	drrwd->drr_offset = offset;
	drrwd->drr_length = lsize;
	drrwd->drr_toguid = dscp->dsc_toguid;
	drrwd->drr_refguid = dscp->dsc_fromguid;
	drrwd->drr_refobject = refobject;
	drrwd->drr_refoffset = refoffset;
	drrwd->drr_reflength = reflength;
	drrwd->drr_patchlen = patchlen;
	drrwd->drr_type = srdp->obj_type;
	fletcher_4_native(tgt, lsize, NULL, &drrwd->drr_cksum);
	memset(patch + patchlen, 0, payload - patchlen);

	if (dump_record(dscp, patch, payload) != 0)
		return (SET_ERROR(EINTR));

	REFS_STAT_BUMP(send_delta_records);
	REFS_STAT_INCR(send_delta_payload_bytes, payload);
	REFS_STAT_INCR(send_delta_logical_bytes, lsize);
	return (0);
}

/*
 * Make the reusable buffers at least size bytes.
 */
static void
send_delta_bufs(send_delta_t *sd, uint64_t size)
{
	if (size <= sd->sd_bufsize)
		return;
	if (sd->sd_bufsize != 0) {
		vmem_free(sd->sd_refbuf, sd->sd_bufsize);
		vmem_free(sd->sd_tgtbuf, sd->sd_bufsize);
		vmem_free(sd->sd_patchbuf, sd->sd_bufsize);
	}
	sd->sd_bufsize = size;
	sd->sd_refbuf = vmem_alloc(size, KM_SLEEP);
	sd->sd_tgtbuf = vmem_alloc(size, KM_SLEEP);
	sd->sd_patchbuf = vmem_alloc(size, KM_SLEEP);
}

/*
 * Encode tgt against one candidate reference and, if the patch fits in
 * cap bytes, send it.  Returns the record's error, with *sentp set if a
 * record was sent.
 */
static int
send_delta_try_ref(dmu_send_cookie_t *dscp, struct send_range *range,
    const uint8_t *tgt, size_t cap, uint64_t refobject, uint64_t refoffset,
    uint64_t reflength, delta_ref_kind_t kind, boolean_t *sentp)
{
	send_delta_t *sd = dscp->dsc_delta;
	uint64_t lsize = range->sru.data.datablksz;
	size_t n = 0;

	send_delta_bufs(sd, MAX(reflength, lsize));
	if (dmu_read(sd->sd_ref_os, refobject, refoffset, reflength,
	    sd->sd_refbuf, DMU_READ_PREFETCH) == 0) {
		n = zfs_delta_encode(sd->sd_refbuf, reflength, tgt, lsize,
		    sd->sd_patchbuf, cap, sd->sd_htab);
	}
	if (n == 0) {
		REFS_STAT_BUMP(send_delta_rejected);
		return (0);
	}

	int err = dump_write_delta(dscp, range, tgt, refobject, refoffset,
	    reflength, sd->sd_patchbuf, n);
	if (err != 0)
		return (err);
	*sentp = B_TRUE;
	switch (kind) {
	case DELTA_REF_SAME:
		REFS_STAT_BUMP(send_delta_same_hits);
		break;
	case DELTA_REF_SIBLING:
		REFS_STAT_BUMP(send_delta_sibling_hits);
		break;
	default:
		REFS_STAT_BUMP(send_delta_sketch_hits);
		break;
	}
	return (0);
}

/*
 * Try to send a data block as a patch against a similar fromsnap block.
 * Sets *sentp if a DRR_WRITE_DELTA record was sent.  The cheap candidates
 * are tried first; the block's sketch is only computed if they fail.
 */
static int
send_delta_try(dmu_send_cookie_t *dscp, struct send_range *range, char *data,
    boolean_t *sentp)
{
	send_delta_t *sd = dscp->dsc_delta;
	struct srd *srdp = &range->sru.data;
	const blkptr_t *bp = &srdp->bp;
	uint64_t lsize = srdp->datablksz;
	uint64_t offset = range->start_blkid * lsize;
	const uint8_t *tgt = (const uint8_t *)data;
	int err = 0;

	*sentp = B_FALSE;
	if (range->start_blkid == DMU_SPILL_BLKID || BP_IS_EMBEDDED(bp) ||
	    BP_IS_HOLE(bp) || BP_IS_PROTECTED(bp) || BP_SHOULD_BYTESWAP(bp) ||
	    DMU_OT_IS_METADATA(BP_GET_TYPE(bp)) || lsize != BP_GET_LSIZE(bp))
		return (0);

	/*
	 * The patch must be smaller than the WRITE it replaces (it leaves
	 * room for the patch's own varints), and is written to a buffer of
	 * lsize bytes.
	 */
	size_t cap = (size_t)srdp->datasz *
	    MIN(zfs_send_delta_max_pct, 100) / 100;
	cap = MIN(cap, lsize - 8);
	if (cap == 0)
		return (0);

	boolean_t same = delta_same_exists(sd, range->object, offset,
	    srdp->obj_type, lsize);
	uint64_t sib = delta_sibling(dscp, range->object);
	if (sib == range->object)
		sib = 0;
	if (!same && sib == 0 && avl_numnodes(&sd->sd_sketch) == 0)
		return (0);
	REFS_STAT_BUMP(send_delta_attempts);

	/* The patch is computed on logical data. */
	send_delta_bufs(sd, lsize);
	if (srdp->io_compressed && BP_GET_COMPRESS(bp) != ZIO_COMPRESS_OFF) {
		abd_t *sabd = abd_get_from_buf(data, srdp->datasz);
		abd_t *dabd = abd_get_from_buf(sd->sd_tgtbuf, lsize);
		err = zio_decompress_data(BP_GET_COMPRESS(bp), sabd, dabd,
		    srdp->datasz, lsize, NULL);
		abd_free(sabd);
		abd_free(dabd);
		if (err != 0)
			return (0);
		tgt = sd->sd_tgtbuf;
	}

	if (same) {
		err = send_delta_try_ref(dscp, range, tgt, cap, range->object,
		    offset, lsize, DELTA_REF_SAME, sentp);
		if (err != 0 || *sentp)
			return (err);
	}
	if (sib != 0) {
		err = send_delta_try_ref(dscp, range, tgt, cap, sib, offset,
		    lsize, DELTA_REF_SIBLING, sentp);
		if (err != 0 || *sentp)
			return (err);
	}

	uint64_t sf[ZFS_DELTA_NSF];
	if (avl_numnodes(&sd->sd_sketch) == 0 ||
	    !zfs_delta_sketch(tgt, lsize, sf))
		return (0);
	for (int i = 0; i < ZFS_DELTA_NSF; i++) {
		delta_sketch_entry_t search = { .dse_sf = sf[i] };
		delta_sketch_entry_t *dse = avl_find(&sd->sd_sketch, &search,
		    NULL);
		if (dse == NULL)
			continue;
		/* Already tried as the same or sibling candidate. */
		if (dse->dse_offset == offset &&
		    ((same && dse->dse_object == range->object) ||
		    dse->dse_object == sib))
			return (0);
		return (send_delta_try_ref(dscp, range, tgt, cap,
		    dse->dse_object, dse->dse_offset, dse->dse_length,
		    DELTA_REF_SKETCH, sentp));
	}
	return (0);
}

static void
issue_data_read(struct send_reader_thread_arg *srta, struct send_range *range)
{
	struct srd *srdp = &range->sru.data;
	blkptr_t *bp = &srdp->bp;
	objset_t *os = srta->smta->os;

	ASSERT3U(range->type, ==, DATA);
	ASSERT3U(range->start_blkid + 1, ==, range->end_blkid);
	/*
	 * If we have large blocks stored on disk but
	 * the send flags don't allow us to send large
	 * blocks, we split the data from the arc buf
	 * into chunks.
	 */
	boolean_t split_large_blocks =
	    srdp->datablksz > SPA_OLD_MAXBLOCKSIZE &&
	    !(srta->featureflags & DMU_BACKUP_FEATURE_LARGE_BLOCKS);
	/*
	 * We should only request compressed data from the ARC if all
	 * the following are true:
	 *  - stream compression was requested
	 *  - we aren't splitting large blocks into smaller chunks
	 *  - the data won't need to be byteswapped before sending
	 *  - this isn't an embedded block
	 *  - this isn't metadata (if receiving on a different endian
	 *    system it can be byteswapped more easily)
	 */
	boolean_t request_compressed =
	    (srta->featureflags & DMU_BACKUP_FEATURE_COMPRESSED) &&
	    !split_large_blocks && !BP_SHOULD_BYTESWAP(bp) &&
	    !BP_IS_EMBEDDED(bp) && !DMU_OT_IS_METADATA(BP_GET_TYPE(bp));

	zio_flag_t zioflags = ZIO_FLAG_CANFAIL;

	if (srta->featureflags & DMU_BACKUP_FEATURE_RAW) {
		zioflags |= ZIO_FLAG_RAW;
		srdp->io_compressed = B_TRUE;
	} else if (request_compressed) {
		zioflags |= ZIO_FLAG_RAW_COMPRESS;
		srdp->io_compressed = B_TRUE;
	}

	srdp->datasz = (zioflags & ZIO_FLAG_RAW_COMPRESS) ?
	    BP_GET_PSIZE(bp) : BP_GET_LSIZE(bp);

	if (send_refs_lookup(srta, range, split_large_blocks))
		return;

	/*
	 * A --delta send first tries this block's own previous version as
	 * the reference; start reading it now so that it is cached by the
	 * time the block is sent.  Nothing is read if the fromsnap does not
	 * have the object.
	 */
	if (srta->delta_ref_os != NULL && srta->issue_reads &&
	    !split_large_blocks && range->start_blkid != DMU_SPILL_BLKID &&
	    !BP_IS_EMBEDDED(bp) && !BP_IS_HOLE(bp) &&
	    !DMU_OT_IS_METADATA(BP_GET_TYPE(bp))) {
		dmu_prefetch(srta->delta_ref_os, range->object, 0,
		    range->start_blkid * srdp->datablksz, srdp->datablksz,
		    ZIO_PRIORITY_ASYNC_READ);
	}

	if (!srta->issue_reads)
		return;
	if (BP_IS_REDACTED(bp))
		return;
	if (send_do_embed(bp, srta->featureflags))
		return;

	zbookmark_phys_t zb = {
	    .zb_objset = dmu_objset_id(os),
	    .zb_object = range->object,
	    .zb_level = 0,
	    .zb_blkid = range->start_blkid,
	};

	arc_flags_t aflags = ARC_FLAG_CACHED_ONLY;

	int arc_err = arc_read(NULL, os->os_spa, bp,
	    arc_getbuf_func, &srdp->abuf, ZIO_PRIORITY_ASYNC_READ,
	    zioflags, &aflags, &zb);
	/*
	 * The ARC only honors a request for compressed data if the header
	 * is compressed, which is not the case for cached blocks when
	 * zfs_compressed_arc_enabled=0.  Such a buffer holds the logical
	 * data, while the record is sent with the block's compression and
	 * psize, so read the block from disk instead.
	 */
	if (arc_err == 0 && srdp->io_compressed &&
	    arc_get_compression(srdp->abuf) != BP_GET_COMPRESS(bp)) {
		arc_buf_destroy(srdp->abuf, &srdp->abuf);
		srdp->abuf = NULL;
		arc_err = SET_ERROR(ENOENT);
	}
	/*
	 * If the data is not already cached in the ARC, we read directly
	 * from zio.  This avoids the performance overhead of adding a new
	 * entry to the ARC, and we also avoid polluting the ARC cache with
	 * data that is not likely to be used in the future.
	 */
	if (arc_err != 0) {
		srdp->abd = abd_alloc_linear(srdp->datasz, B_FALSE);
		srdp->io_outstanding = B_TRUE;
		zio_nowait(zio_read(NULL, os->os_spa, bp, srdp->abd,
		    srdp->datasz, dmu_send_read_done, range,
		    ZIO_PRIORITY_ASYNC_READ, zioflags, &zb));
	}
}

/*
 * Create a new record with the given values.
 */
static void
enqueue_range(struct send_reader_thread_arg *srta, bqueue_t *q, dnode_t *dn,
    uint64_t blkid, uint64_t count, const blkptr_t *bp, uint32_t datablksz)
{
	enum type range_type = (bp == NULL || BP_IS_HOLE(bp) ? HOLE :
	    (BP_IS_REDACTED(bp) ? REDACT : DATA));

	struct send_range *range = range_alloc(range_type, dn->dn_object,
	    blkid, blkid + count, B_FALSE);

	if (blkid == DMU_SPILL_BLKID) {
		ASSERT3P(bp, !=, NULL);
		ASSERT3U(BP_GET_TYPE(bp), ==, DMU_OT_SA);
	}

	switch (range_type) {
	case HOLE:
		range->sru.hole.datablksz = datablksz;
		break;
	case DATA:
		ASSERT3U(count, ==, 1);
		range->sru.data.datablksz = datablksz;
		range->sru.data.obj_type = dn->dn_type;
		range->sru.data.bp = *bp;
		issue_data_read(srta, range);
		break;
	case REDACT:
		range->sru.redact.datablksz = datablksz;
		break;
	default:
		break;
	}
	bqueue_enqueue(q, range, datablksz);
}

/*
 * Send DRR_SPILL records for unmodified spill blocks.	This is useful
 * because changing certain attributes of the object (e.g. blocksize)
 * can cause old versions of ZFS to incorrectly remove a spill block.
 * Including these records in the stream forces an up to date version
 * to always be written ensuring they're never lost.  Current versions
 * of the code which understand the DRR_FLAG_SPILL_BLOCK feature can
 * ignore these unmodified spill blocks.
 *
 * We piggyback the spill_range to dnode range instead of enqueueing it
 * so send_range_after won't complain.
 */
static uint64_t
piggyback_unmodified_spill(struct send_reader_thread_arg *srta,
    struct send_range *range)
{
	ASSERT3U(range->type, ==, OBJECT);

	dnode_phys_t *dnp = range->sru.object.dnp;
	uint64_t fromtxg = srta->smta->to_arg->fromtxg;

	if (!zfs_send_unmodified_spill_blocks ||
	    !(dnp->dn_flags & DNODE_FLAG_SPILL_BLKPTR) ||
	    !(BP_GET_LOGICAL_BIRTH(DN_SPILL_BLKPTR(dnp)) <= fromtxg))
		return (0);

	blkptr_t *bp = DN_SPILL_BLKPTR(dnp);
	struct send_range *spill_range = range_alloc(DATA, range->object,
	    DMU_SPILL_BLKID, DMU_SPILL_BLKID+1, B_FALSE);
	spill_range->sru.data.bp = *bp;
	spill_range->sru.data.obj_type = dnp->dn_type;
	spill_range->sru.data.datablksz = BP_GET_LSIZE(bp);

	issue_data_read(srta, spill_range);
	range->sru.object.spill_range = spill_range;

	return (BP_GET_LSIZE(bp));
}

/*
 * This thread is responsible for two things: First, it retrieves the correct
 * blkptr in the to ds if we need to send the data because of something from
 * the from thread.  As a result of this, we're the first ones to discover that
 * some indirect blocks can be discarded because they're not holes. Second,
 * it issues prefetches for the data we need to send.
 */
static __attribute__((noreturn)) void
send_reader_thread(void *arg)
{
	struct send_reader_thread_arg *srta = arg;
	struct send_merge_thread_arg *smta = srta->smta;
	bqueue_t *inq = &smta->q;
	bqueue_t *outq = &srta->q;
	objset_t *os = smta->os;
	fstrans_cookie_t cookie = spl_fstrans_mark();
	struct send_range *range = bqueue_dequeue(inq);
	int err = 0;

	/*
	 * If the record we're analyzing is from a redaction bookmark from the
	 * fromds, then we need to know whether or not it exists in the tods so
	 * we know whether to create records for it or not. If it does, we need
	 * the datablksz so we can generate an appropriate record for it.
	 * Finally, if it isn't redacted, we need the blkptr so that we can send
	 * a WRITE record containing the actual data.
	 */
	uint64_t last_obj = UINT64_MAX;
	uint64_t last_obj_exists = B_TRUE;
	while (!range->eos_marker && !srta->cancel && smta->error == 0 &&
	    err == 0) {
		uint64_t spill = 0;
		switch (range->type) {
		case DATA:
			issue_data_read(srta, range);
			bqueue_enqueue(outq, range, range->sru.data.datablksz);
			range = get_next_range_nofree(inq, range);
			break;
		case OBJECT:
			spill = piggyback_unmodified_spill(srta, range);
			zfs_fallthrough;
		case HOLE:
		case OBJECT_RANGE:
		case REDACT: // Redacted blocks must exist
			bqueue_enqueue(outq, range, sizeof (*range) + spill);
			range = get_next_range_nofree(inq, range);
			break;
		case PREVIOUSLY_REDACTED: {
			/*
			 * This entry came from the "from bookmark" when
			 * sending from a bookmark that has a redaction
			 * list.  We need to check if this object/blkid
			 * exists in the target ("to") dataset, and if
			 * not then we drop this entry.  We also need
			 * to fill in the block pointer so that we know
			 * what to prefetch.
			 *
			 * To accomplish the above, we first cache whether or
			 * not the last object we examined exists.  If it
			 * doesn't, we can drop this record. If it does, we hold
			 * the dnode and use it to call dbuf_dnode_findbp. We do
			 * this instead of dbuf_bookmark_findbp because we will
			 * often operate on large ranges, and holding the dnode
			 * once is more efficient.
			 */
			boolean_t object_exists = B_TRUE;
			/*
			 * If the data is redacted, we only care if it exists,
			 * so that we don't send records for objects that have
			 * been deleted.
			 */
			dnode_t *dn;
			if (range->object == last_obj && !last_obj_exists) {
				/*
				 * If we're still examining the same object as
				 * previously, and it doesn't exist, we don't
				 * need to call dbuf_bookmark_findbp.
				 */
				object_exists = B_FALSE;
			} else {
				err = dnode_hold(os, range->object, FTAG, &dn);
				if (err == ENOENT) {
					object_exists = B_FALSE;
					err = 0;
				}
				last_obj = range->object;
				last_obj_exists = object_exists;
			}

			if (err != 0) {
				break;
			} else if (!object_exists) {
				/*
				 * The block was modified, but doesn't
				 * exist in the to dataset; if it was
				 * deleted in the to dataset, then we'll
				 * visit the hole bp for it at some point.
				 */
				range = get_next_range(inq, range);
				continue;
			}
			uint64_t file_max =
			    MIN(dn->dn_maxblkid + 1, range->end_blkid);
			/*
			 * The object exists, so we need to try to find the
			 * blkptr for each block in the range we're processing.
			 */
			rw_enter(&dn->dn_struct_rwlock, RW_READER);
			for (uint64_t blkid = range->start_blkid;
			    blkid < file_max; blkid++) {
				blkptr_t bp;
				uint32_t datablksz =
				    dn->dn_phys->dn_datablkszsec <<
				    SPA_MINBLOCKSHIFT;
				uint64_t offset = blkid * datablksz;
				/*
				 * This call finds the next non-hole block in
				 * the object. This is to prevent a
				 * performance problem where we're unredacting
				 * a large hole. Using dnode_next_offset to
				 * skip over the large hole avoids iterating
				 * over every block in it.
				 */
				err = dnode_next_offset(dn, DNODE_FIND_HAVELOCK,
				    &offset, 1, 1, 0);
				if (err == ESRCH) {
					offset = UINT64_MAX;
					err = 0;
				} else if (err != 0) {
					break;
				}
				if (offset != blkid * datablksz) {
					/*
					 * if there is a hole from here
					 * (blkid) to offset
					 */
					offset = MIN(offset, file_max *
					    datablksz);
					uint64_t nblks = (offset / datablksz) -
					    blkid;
					enqueue_range(srta, outq, dn, blkid,
					    nblks, NULL, datablksz);
					blkid += nblks;
				}
				if (blkid >= file_max)
					break;
				err = dbuf_dnode_findbp(dn, 0, blkid, &bp,
				    NULL, NULL);
				if (err != 0)
					break;
				ASSERT(!BP_IS_HOLE(&bp));
				enqueue_range(srta, outq, dn, blkid, 1, &bp,
				    datablksz);
			}
			rw_exit(&dn->dn_struct_rwlock);
			dnode_rele(dn, FTAG);
			range = get_next_range(inq, range);
		}
		}
	}
	if (srta->cancel || err != 0) {
		smta->cancel = B_TRUE;
		srta->error = err;
	} else if (smta->error != 0) {
		srta->error = smta->error;
	}
	while (!range->eos_marker)
		range = get_next_range(inq, range);

	bqueue_enqueue_flush(outq, range, 1);
	spl_fstrans_unmark(cookie);
	thread_exit();
}

#define	NUM_SNAPS_NOT_REDACTED UINT64_MAX

struct dmu_send_params {
	/* Pool args */
	const void *tag; // Tag dp was held with, will be used to release dp.
	dsl_pool_t *dp;
	/* To snapshot args */
	const char *tosnap;
	dsl_dataset_t *to_ds;
	/* From snapshot args */
	zfs_bookmark_phys_t ancestor_zb;
	uint64_t *fromredactsnaps;
	/* NUM_SNAPS_NOT_REDACTED if not sending from redaction bookmark */
	uint64_t numfromredactsnaps;
	/* Stream params */
	boolean_t is_clone;
	boolean_t embedok;
	boolean_t large_block_ok;
	boolean_t compressok;
	boolean_t rawok;
	boolean_t savedok;
	boolean_t refsok;
	boolean_t deltaok;
	uint64_t resumeobj;
	uint64_t resumeoff;
	uint64_t saved_guid;
	zfs_bookmark_phys_t *redactbook;
	/* Stream output params */
	dmu_send_outparams_t *dso;

	/* Stream progress params */
	offset_t *off;
	int outfd;
	char saved_toname[MAXNAMELEN];
};

static int
setup_featureflags(struct dmu_send_params *dspp, objset_t *os,
    uint64_t *featureflags)
{
	dsl_dataset_t *to_ds = dspp->to_ds;
	dsl_pool_t *dp = dspp->dp;

	if (dmu_objset_type(os) == DMU_OST_ZFS) {
		uint64_t version;
		if (zfs_get_zplprop(os, ZFS_PROP_VERSION, &version) != 0)
			return (SET_ERROR(EINVAL));

		if (version >= ZPL_VERSION_SA)
			*featureflags |= DMU_BACKUP_FEATURE_SA_SPILL;
	}

	/* raw sends imply large_block_ok */
	if ((dspp->rawok || dspp->large_block_ok) &&
	    dsl_dataset_feature_is_active(to_ds, SPA_FEATURE_LARGE_BLOCKS)) {
		*featureflags |= DMU_BACKUP_FEATURE_LARGE_BLOCKS;
	}

	/* encrypted datasets will not have embedded blocks */
	if ((dspp->embedok || dspp->rawok) && !os->os_encrypted &&
	    spa_feature_is_active(dp->dp_spa, SPA_FEATURE_EMBEDDED_DATA)) {
		*featureflags |= DMU_BACKUP_FEATURE_EMBED_DATA;
	}

	/* raw send implies compressok */
	if (dspp->compressok || dspp->rawok)
		*featureflags |= DMU_BACKUP_FEATURE_COMPRESSED;

	if (dspp->rawok && os->os_encrypted)
		*featureflags |= DMU_BACKUP_FEATURE_RAW;

	if ((*featureflags &
	    (DMU_BACKUP_FEATURE_EMBED_DATA | DMU_BACKUP_FEATURE_COMPRESSED |
	    DMU_BACKUP_FEATURE_RAW)) != 0 &&
	    spa_feature_is_active(dp->dp_spa, SPA_FEATURE_LZ4_COMPRESS)) {
		*featureflags |= DMU_BACKUP_FEATURE_LZ4;
	}

	/*
	 * We specifically do not include DMU_BACKUP_FEATURE_EMBED_DATA here to
	 * allow sending ZSTD compressed datasets to a receiver that does not
	 * support ZSTD
	 */
	if ((*featureflags &
	    (DMU_BACKUP_FEATURE_COMPRESSED | DMU_BACKUP_FEATURE_RAW)) != 0 &&
	    dsl_dataset_feature_is_active(to_ds, SPA_FEATURE_ZSTD_COMPRESS)) {
		*featureflags |= DMU_BACKUP_FEATURE_ZSTD;
	}

	if (dspp->resumeobj != 0 || dspp->resumeoff != 0) {
		*featureflags |= DMU_BACKUP_FEATURE_RESUMING;
	}

	if (dspp->redactbook != NULL) {
		*featureflags |= DMU_BACKUP_FEATURE_REDACTED;
	}

	if (dsl_dataset_feature_is_active(to_ds, SPA_FEATURE_LARGE_DNODE)) {
		*featureflags |= DMU_BACKUP_FEATURE_LARGE_DNODE;
	}

	if (dsl_dataset_feature_is_active(to_ds, SPA_FEATURE_LONGNAME)) {
		*featureflags |= DMU_BACKUP_FEATURE_LONGNAME;
	}

	if (dsl_dataset_feature_is_active(to_ds, SPA_FEATURE_LARGE_MICROZAP)) {
		/*
		 * We must never split a large microzap block, so we can only
		 * send large microzaps if LARGE_BLOCKS is already enabled.
		 */
		if (!(*featureflags & DMU_BACKUP_FEATURE_LARGE_BLOCKS))
			return (SET_ERROR(ZFS_ERR_STREAM_LARGE_MICROZAP));
		*featureflags |= DMU_BACKUP_FEATURE_LARGE_MICROZAP;
	}

	return (0);
}

static dmu_replay_record_t *
create_begin_record(struct dmu_send_params *dspp, objset_t *os,
    uint64_t featureflags)
{
	dmu_replay_record_t *drr = kmem_zalloc(sizeof (dmu_replay_record_t),
	    KM_SLEEP);
	drr->drr_type = DRR_BEGIN;

	struct drr_begin *drrb = &drr->drr_u.drr_begin;
	dsl_dataset_t *to_ds = dspp->to_ds;

	drrb->drr_magic = DMU_BACKUP_MAGIC;
	drrb->drr_creation_time = dsl_dataset_phys(to_ds)->ds_creation_time;
	drrb->drr_type = dmu_objset_type(os);
	drrb->drr_toguid = dsl_dataset_phys(to_ds)->ds_guid;
	drrb->drr_fromguid = dspp->ancestor_zb.zbm_guid;

	DMU_SET_STREAM_HDRTYPE(drrb->drr_versioninfo, DMU_SUBSTREAM);
	DMU_SET_FEATUREFLAGS(drrb->drr_versioninfo, featureflags);

	if (dspp->is_clone)
		drrb->drr_flags |= DRR_FLAG_CLONE;
	if (dsl_dataset_phys(dspp->to_ds)->ds_flags & DS_FLAG_CI_DATASET)
		drrb->drr_flags |= DRR_FLAG_CI_DATA;
	if (zfs_send_set_freerecords_bit)
		drrb->drr_flags |= DRR_FLAG_FREERECORDS;
	drr->drr_u.drr_begin.drr_flags |= DRR_FLAG_SPILL_BLOCK;

	if (dspp->savedok) {
		drrb->drr_toguid = dspp->saved_guid;
		strlcpy(drrb->drr_toname, dspp->saved_toname,
		    sizeof (drrb->drr_toname));
	} else {
		dsl_dataset_name(to_ds, drrb->drr_toname);
		if (!to_ds->ds_is_snapshot) {
			(void) strlcat(drrb->drr_toname, "@--head--",
			    sizeof (drrb->drr_toname));
		}
	}
	return (drr);
}

static void
setup_to_thread(struct send_thread_arg *to_arg, objset_t *to_os,
    dmu_sendstatus_t *dssp, uint64_t fromtxg, boolean_t rawok)
{
	VERIFY0(bqueue_init(&to_arg->q, zfs_send_no_prefetch_queue_ff,
	    MAX(zfs_send_no_prefetch_queue_length, 2 * zfs_max_recordsize),
	    offsetof(struct send_range, ln)));
	to_arg->error_code = 0;
	to_arg->cancel = B_FALSE;
	to_arg->os = to_os;
	to_arg->fromtxg = fromtxg;
	to_arg->flags = TRAVERSE_PRE | TRAVERSE_PREFETCH_METADATA;
	if (rawok)
		to_arg->flags |= TRAVERSE_NO_DECRYPT;
	if (zfs_send_corrupt_data)
		to_arg->flags |= TRAVERSE_HARD;
	to_arg->num_blocks_visited = &dssp->dss_blocks;
	(void) thread_create(NULL, 0, send_traverse_thread, to_arg, 0,
	    curproc, TS_RUN, minclsyspri);
}

static void
setup_from_thread(struct redact_list_thread_arg *from_arg,
    redaction_list_t *from_rl, dmu_sendstatus_t *dssp)
{
	VERIFY0(bqueue_init(&from_arg->q, zfs_send_no_prefetch_queue_ff,
	    MAX(zfs_send_no_prefetch_queue_length, 2 * zfs_max_recordsize),
	    offsetof(struct send_range, ln)));
	from_arg->error_code = 0;
	from_arg->cancel = B_FALSE;
	from_arg->rl = from_rl;
	from_arg->mark_redact = B_FALSE;
	from_arg->num_blocks_visited = &dssp->dss_blocks;
	/*
	 * If from_ds is null, send_traverse_thread just returns success and
	 * enqueues an eos marker.
	 */
	(void) thread_create(NULL, 0, redact_list_thread, from_arg, 0,
	    curproc, TS_RUN, minclsyspri);
}

static void
setup_redact_list_thread(struct redact_list_thread_arg *rlt_arg,
    struct dmu_send_params *dspp, redaction_list_t *rl, dmu_sendstatus_t *dssp)
{
	if (dspp->redactbook == NULL)
		return;

	rlt_arg->cancel = B_FALSE;
	VERIFY0(bqueue_init(&rlt_arg->q, zfs_send_no_prefetch_queue_ff,
	    MAX(zfs_send_no_prefetch_queue_length, 2 * zfs_max_recordsize),
	    offsetof(struct send_range, ln)));
	rlt_arg->error_code = 0;
	rlt_arg->mark_redact = B_TRUE;
	rlt_arg->rl = rl;
	rlt_arg->num_blocks_visited = &dssp->dss_blocks;

	(void) thread_create(NULL, 0, redact_list_thread, rlt_arg, 0,
	    curproc, TS_RUN, minclsyspri);
}

static void
setup_merge_thread(struct send_merge_thread_arg *smt_arg,
    struct dmu_send_params *dspp, struct redact_list_thread_arg *from_arg,
    struct send_thread_arg *to_arg, struct redact_list_thread_arg *rlt_arg,
    objset_t *os)
{
	VERIFY0(bqueue_init(&smt_arg->q, zfs_send_no_prefetch_queue_ff,
	    MAX(zfs_send_no_prefetch_queue_length, 2 * zfs_max_recordsize),
	    offsetof(struct send_range, ln)));
	smt_arg->cancel = B_FALSE;
	smt_arg->error = 0;
	smt_arg->from_arg = from_arg;
	smt_arg->to_arg = to_arg;
	if (dspp->redactbook != NULL)
		smt_arg->redact_arg = rlt_arg;

	smt_arg->os = os;
	(void) thread_create(NULL, 0, send_merge_thread, smt_arg, 0, curproc,
	    TS_RUN, minclsyspri);
}

static void
setup_reader_thread(struct send_reader_thread_arg *srt_arg,
    struct dmu_send_params *dspp, struct send_merge_thread_arg *smt_arg,
    uint64_t featureflags, send_refs_t *refs, objset_t *delta_ref_os)
{
	srt_arg->refs = refs;
	srt_arg->delta_ref_os = delta_ref_os;
	VERIFY0(bqueue_init(&srt_arg->q, zfs_send_queue_ff,
	    MAX(zfs_send_queue_length, 2 * zfs_max_recordsize),
	    offsetof(struct send_range, ln)));
	srt_arg->smta = smt_arg;
	srt_arg->issue_reads = !dspp->dso->dso_dryrun;
	srt_arg->featureflags = featureflags;
	(void) thread_create(NULL, 0, send_reader_thread, srt_arg, 0,
	    curproc, TS_RUN, minclsyspri);
}

static int
setup_resume_points(struct dmu_send_params *dspp,
    struct send_thread_arg *to_arg, struct redact_list_thread_arg *from_arg,
    struct redact_list_thread_arg *rlt_arg,
    struct send_merge_thread_arg *smt_arg, boolean_t resuming, objset_t *os,
    redaction_list_t *redact_rl, nvlist_t *nvl)
{
	(void) smt_arg;
	dsl_dataset_t *to_ds = dspp->to_ds;
	int err = 0;

	uint64_t obj = 0;
	uint64_t blkid = 0;
	if (resuming) {
		obj = dspp->resumeobj;
		dmu_object_info_t to_doi;
		err = dmu_object_info(os, obj, &to_doi);
		if (err != 0)
			return (err);

		blkid = dspp->resumeoff / to_doi.doi_data_block_size;
	}
	/*
	 * If we're resuming a redacted send, we can skip to the appropriate
	 * point in the redaction bookmark by binary searching through it.
	 */
	if (redact_rl != NULL) {
		SET_BOOKMARK(&rlt_arg->resume, to_ds->ds_object, obj, 0, blkid);
	}

	SET_BOOKMARK(&to_arg->resume, to_ds->ds_object, obj, 0, blkid);
	if (nvlist_exists(nvl, BEGINNV_REDACT_FROM_SNAPS)) {
		uint64_t objset = dspp->ancestor_zb.zbm_redaction_obj;
		/*
		 * Note: If the resume point is in an object whose
		 * blocksize is different in the from vs to snapshots,
		 * we will have divided by the "wrong" blocksize.
		 * However, in this case fromsnap's send_cb() will
		 * detect that the blocksize has changed and therefore
		 * ignore this object.
		 *
		 * If we're resuming a send from a redaction bookmark,
		 * we still cannot accidentally suggest blocks behind
		 * the to_ds.  In addition, we know that any blocks in
		 * the object in the to_ds will have to be sent, since
		 * the size changed.  Therefore, we can't cause any harm
		 * this way either.
		 */
		SET_BOOKMARK(&from_arg->resume, objset, obj, 0, blkid);
	}
	if (resuming) {
		fnvlist_add_uint64(nvl, BEGINNV_RESUME_OBJECT, dspp->resumeobj);
		fnvlist_add_uint64(nvl, BEGINNV_RESUME_OFFSET, dspp->resumeoff);
	}
	return (0);
}

static dmu_sendstatus_t *
setup_send_progress(struct dmu_send_params *dspp)
{
	dmu_sendstatus_t *dssp = kmem_zalloc(sizeof (*dssp), KM_SLEEP);
	dssp->dss_outfd = dspp->outfd;
	dssp->dss_off = dspp->off;
	dssp->dss_proc = curproc;
	mutex_enter(&dspp->to_ds->ds_sendstream_lock);
	list_insert_head(&dspp->to_ds->ds_sendstreams, dssp);
	mutex_exit(&dspp->to_ds->ds_sendstream_lock);
	return (dssp);
}

/*
 * Payloads must be multiples of 8 bytes for historical compatibility, but
 * XDR-encoded nvlists are sized in multiples of 4 bytes and may need padding.
 *
 * Here we do the simplest possible thing and copy the data to a separate
 * buffer. Not ideal in terms of performance and memory use, but most BEGIN
 * nvlists are small or absent, the allocation is momentary, and we'll need
 * to do this at most once per dataset.
 *
 * It's OK if there is extra data after a packed nvlist on the receiving
 * side because packed nvlists have an internal end-of-list marker.
 *
 * The new buffer is allocated with kmem_alloc() and can be freed with
 * fnvlist_pack_free(), like the original.
 */
static inline void
pad_packed_nvlist(char **buffer, size_t *size)
{
	size_t size_in = *size;
	size_t extra_bytes = P2ROUNDUP(size_in, 8) - size_in;
	if (extra_bytes != 0) {
		size_t expanded_size = size_in + extra_bytes;
		char *longbuf = kmem_alloc(expanded_size, KM_SLEEP);
		memcpy(longbuf, *buffer, size_in);
		memset(longbuf + size_in, 0, extra_bytes);
		fnvlist_pack_free(*buffer, size_in);
		*buffer = longbuf;
		*size = expanded_size;
	}
}

/*
 * Actually do the bulk of the work in a zfs send.
 *
 * The idea is that we want to do a send from ancestor_zb to to_ds.  We also
 * want to not send any data that has been modified by all the datasets in
 * redactsnaparr, and store the list of blocks that are redacted in this way in
 * a bookmark named redactbook, created on the to_ds.  We do this by creating
 * several worker threads, whose function is described below.
 *
 * There are three cases.
 * The first case is a redacted zfs send.  In this case there are 5 threads.
 * The first thread is the to_ds traversal thread: it calls dataset_traverse on
 * the to_ds and finds all the blocks that have changed since ancestor_zb (if
 * it's a full send, that's all blocks in the dataset).  It then sends those
 * blocks on to the send merge thread. The redact list thread takes the data
 * from the redaction bookmark and sends those blocks on to the send merge
 * thread.  The send merge thread takes the data from the to_ds traversal
 * thread, and combines it with the redaction records from the redact list
 * thread.  If a block appears in both the to_ds's data and the redaction data,
 * the send merge thread will mark it as redacted and send it on to the prefetch
 * thread.  Otherwise, the send merge thread will send the block on to the
 * prefetch thread unchanged. The prefetch thread will issue prefetch reads for
 * any data that isn't redacted, and then send the data on to the main thread.
 * The main thread behaves the same as in a normal send case, issuing demand
 * reads for data blocks and sending out records over the network
 *
 * The graphic below diagrams the flow of data in the case of a redacted zfs
 * send.  Each box represents a thread, and each line represents the flow of
 * data.
 *
 *             Records from the |
 *           redaction bookmark |
 * +--------------------+       |  +---------------------------+
 * |                    |       v  | Send Merge Thread         |
 * | Redact List Thread +----------> Apply redaction marks to  |
 * |                    |          | records as specified by   |
 * +--------------------+          | redaction ranges          |
 *                                 +----^---------------+------+
 *                                      |               | Merged data
 *                                      |               |
 *                                      |  +------------v--------+
 *                                      |  | Prefetch Thread     |
 * +--------------------+               |  | Issues prefetch     |
 * | to_ds Traversal    |               |  | reads of data blocks|
 * | Thread (finds      +---------------+  +------------+--------+
 * | candidate blocks)  |  Blocks modified              | Prefetched data
 * +--------------------+  by to_ds since               |
 *                         ancestor_zb     +------------v----+
 *                                         | Main Thread     |  File Descriptor
 *                                         | Sends data over +->(to zfs receive)
 *                                         | wire            |
 *                                         +-----------------+
 *
 * The second case is an incremental send from a redaction bookmark.  The to_ds
 * traversal thread and the main thread behave the same as in the redacted
 * send case.  The new thread is the from bookmark traversal thread.  It
 * iterates over the redaction list in the redaction bookmark, and enqueues
 * records for each block that was redacted in the original send.  The send
 * merge thread now has to merge the data from the two threads.  For details
 * about that process, see the header comment of send_merge_thread().  Any data
 * it decides to send on will be prefetched by the prefetch thread.  Note that
 * you can perform a redacted send from a redaction bookmark; in that case,
 * the data flow behaves very similarly to the flow in the redacted send case,
 * except with the addition of the bookmark traversal thread iterating over the
 * redaction bookmark.  The send_merge_thread also has to take on the
 * responsibility of merging the redact list thread's records, the bookmark
 * traversal thread's records, and the to_ds records.
 *
 * +---------------------+
 * |                     |
 * | Redact List Thread  +--------------+
 * |                     |              |
 * +---------------------+              |
 *        Blocks in redaction list      | Ranges modified by every secure snap
 *        of from bookmark              | (or EOS if not readcted)
 *                                      |
 * +---------------------+   |     +----v----------------------+
 * | bookmark Traversal  |   v     | Send Merge Thread         |
 * | Thread (finds       +---------> Merges bookmark, rlt, and |
 * | candidate blocks)   |         | to_ds send records        |
 * +---------------------+         +----^---------------+------+
 *                                      |               | Merged data
 *                                      |  +------------v--------+
 *                                      |  | Prefetch Thread     |
 * +--------------------+               |  | Issues prefetch     |
 * | to_ds Traversal    |               |  | reads of data blocks|
 * | Thread (finds      +---------------+  +------------+--------+
 * | candidate blocks)  |  Blocks modified              | Prefetched data
 * +--------------------+  by to_ds since  +------------v----+
 *                         ancestor_zb     | Main Thread     |  File Descriptor
 *                                         | Sends data over +->(to zfs receive)
 *                                         | wire            |
 *                                         +-----------------+
 *
 * The final case is a simple zfs full or incremental send.  The to_ds traversal
 * thread behaves the same as always. The redact list thread is never started.
 * The send merge thread takes all the blocks that the to_ds traversal thread
 * sends it, prefetches the data, and sends the blocks on to the main thread.
 * The main thread sends the data over the wire.
 *
 * To keep performance acceptable, we want to prefetch the data in the worker
 * threads.  While the to_ds thread could simply use the TRAVERSE_PREFETCH
 * feature built into traverse_dataset, the combining and deletion of records
 * due to redaction and sends from redaction bookmarks mean that we could
 * issue many unnecessary prefetches.  As a result, we only prefetch data
 * after we've determined that the record is not going to be redacted.  To
 * prevent the prefetching from getting too far ahead of the main thread, the
 * blocking queues that are used for communication are capped not by the
 * number of entries in the queue, but by the sum of the size of the
 * prefetches associated with them.  The limit on the amount of data that the
 * thread can prefetch beyond what the main thread has reached is controlled
 * by the global variable zfs_send_queue_length.  In addition, to prevent poor
 * performance in the beginning of a send, we also limit the distance ahead
 * that the traversal threads can be.  That distance is controlled by the
 * zfs_send_no_prefetch_queue_length tunable.
 *
 * Note: Releases dp using the specified tag.
 */
static int
dmu_send_impl(struct dmu_send_params *dspp)
{
	objset_t *os;
	dmu_replay_record_t *drr;
	dmu_sendstatus_t *dssp;
	dmu_send_cookie_t dsc = {0};
	int err;
	uint64_t fromtxg = dspp->ancestor_zb.zbm_creation_txg;
	uint64_t featureflags = 0;
	struct redact_list_thread_arg *from_arg;
	struct send_thread_arg *to_arg;
	struct redact_list_thread_arg *rlt_arg;
	struct send_merge_thread_arg *smt_arg;
	struct send_reader_thread_arg *srt_arg;
	struct send_range *range;
	redaction_list_t *from_rl = NULL;
	redaction_list_t *redact_rl = NULL;
	boolean_t resuming = (dspp->resumeobj != 0 || dspp->resumeoff != 0);
	boolean_t book_resuming = resuming;
	send_refs_t *refs = NULL;
	dsl_dataset_t *refs_fromds = NULL;

	dsl_dataset_t *to_ds = dspp->to_ds;
	zfs_bookmark_phys_t *ancestor_zb = &dspp->ancestor_zb;
	dsl_pool_t *dp = dspp->dp;
	const void *tag = dspp->tag;

	err = dmu_objset_from_ds(to_ds, &os);
	if (err != 0) {
		dsl_pool_rele(dp, tag);
		return (err);
	}

	/*
	 * If this is a non-raw send of an encrypted ds, we can ensure that
	 * the objset_phys_t is authenticated. This is safe because this is
	 * either a snapshot or we have owned the dataset, ensuring that
	 * it can't be modified.
	 */
	if (!dspp->rawok && os->os_encrypted &&
	    arc_is_unauthenticated(os->os_phys_buf)) {
		zbookmark_phys_t zb;

		SET_BOOKMARK(&zb, to_ds->ds_object, ZB_ROOT_OBJECT,
		    ZB_ROOT_LEVEL, ZB_ROOT_BLKID);
		err = arc_untransform(os->os_phys_buf, os->os_spa,
		    &zb, B_FALSE);
		if (err != 0) {
			dsl_pool_rele(dp, tag);
			return (err);
		}

		ASSERT0(arc_is_unauthenticated(os->os_phys_buf));
	}

	if ((err = setup_featureflags(dspp, os, &featureflags)) != 0) {
		dsl_pool_rele(dp, tag);
		return (err);
	}

	/*
	 * If we're doing a redacted send, hold the bookmark's redaction list.
	 */
	if (dspp->redactbook != NULL) {
		err = dsl_redaction_list_hold_obj(dp,
		    dspp->redactbook->zbm_redaction_obj, FTAG,
		    &redact_rl);
		if (err != 0) {
			dsl_pool_rele(dp, tag);
			return (SET_ERROR(EINVAL));
		}
		dsl_redaction_list_long_hold(dp, redact_rl, FTAG);
	}

	/*
	 * If we're sending from a redaction bookmark, hold the redaction list
	 * so that we can consider sending the redacted blocks.
	 */
	if (ancestor_zb->zbm_redaction_obj != 0) {
		err = dsl_redaction_list_hold_obj(dp,
		    ancestor_zb->zbm_redaction_obj, FTAG, &from_rl);
		if (err != 0) {
			if (redact_rl != NULL) {
				dsl_redaction_list_long_rele(redact_rl, FTAG);
				dsl_redaction_list_rele(redact_rl, FTAG);
			}
			dsl_pool_rele(dp, tag);
			return (SET_ERROR(EINVAL));
		}
		dsl_redaction_list_long_hold(dp, from_rl, FTAG);
	}

	dsl_dataset_long_hold(to_ds, FTAG);

	/*
	 * Fromsnap references are only used for plain incrementals from an
	 * existing snapshot: not raw, encrypted or redacted.  Otherwise the
	 * request is ignored and a regular stream is sent.
	 */
	if (dspp->refsok && fromtxg != 0 && !dspp->rawok &&
	    !os->os_encrypted && dspp->redactbook == NULL &&
	    ancestor_zb->zbm_redaction_obj == 0 &&
	    dspp->numfromredactsnaps == NUM_SNAPS_NOT_REDACTED) {
		refs_fromds = send_refs_fromsnap_hold(dp, to_ds, ancestor_zb,
		    FTAG);
	}

	from_arg = kmem_zalloc(sizeof (*from_arg), KM_SLEEP);
	to_arg = kmem_zalloc(sizeof (*to_arg), KM_SLEEP);
	rlt_arg = kmem_zalloc(sizeof (*rlt_arg), KM_SLEEP);
	smt_arg = kmem_zalloc(sizeof (*smt_arg), KM_SLEEP);
	srt_arg = kmem_zalloc(sizeof (*srt_arg), KM_SLEEP);

	drr = create_begin_record(dspp, os, featureflags);
	dssp = setup_send_progress(dspp);

	dsc.dsc_drr = drr;
	dsc.dsc_dso = dspp->dso;
	dsc.dsc_os = os;
	dsc.dsc_off = dspp->off;
	dsc.dsc_toguid = dsl_dataset_phys(to_ds)->ds_guid;
	dsc.dsc_fromtxg = fromtxg;
	dsc.dsc_fromguid = ancestor_zb->zbm_guid;
	dsc.dsc_pending_op = PENDING_NONE;
	dsc.dsc_featureflags = featureflags;
	dsc.dsc_resume_object = dspp->resumeobj;
	dsc.dsc_resume_offset = dspp->resumeoff;

	dsl_pool_rele(dp, tag);

	/*
	 * The stream is only marked as using fromsnap references if there
	 * are any, so that it stays receivable by older software otherwise.
	 * Deltas read the fromsnap while the stream is generated, so it stays
	 * held until the end.
	 */
	if (refs_fromds != NULL) {
		uint64_t new_blocks = 0, new_blocks_new_obj = 0;

		refs = send_refs_build(to_ds, refs_fromds, fromtxg,
		    dspp->deltaok, &new_blocks, &new_blocks_new_obj);
		if (refs != NULL)
			featureflags |= DMU_BACKUP_FEATURE_FROMSNAP_REFS;
		if (dspp->deltaok)
			dsc.dsc_delta = send_delta_create(refs_fromds, refs,
			    new_blocks, new_blocks_new_obj);
		if (dsc.dsc_delta != NULL) {
			featureflags |= DMU_BACKUP_FEATURE_WRITE_DELTA;
		} else {
			send_refs_fromsnap_rele(refs_fromds, FTAG);
			refs_fromds = NULL;
		}
		dsc.dsc_featureflags = featureflags;
		DMU_SET_FEATUREFLAGS(drr->drr_u.drr_begin.drr_versioninfo,
		    featureflags);
	}

	char *payload = NULL;
	size_t payload_len = 0;
	nvlist_t *nvl = fnvlist_alloc();

	/*
	 * If we're doing a redacted send, we include the snapshots we're
	 * redacted with respect to so that the target system knows what send
	 * streams can be correctly received on top of this dataset. If we're
	 * instead sending a redacted dataset, we include the snapshots that the
	 * dataset was created with respect to.
	 */
	if (dspp->redactbook != NULL) {
		fnvlist_add_uint64_array(nvl, BEGINNV_REDACT_SNAPS,
		    redact_rl->rl_phys->rlp_snaps,
		    redact_rl->rl_phys->rlp_num_snaps);
	} else if (dsl_dataset_feature_is_active(to_ds,
	    SPA_FEATURE_REDACTED_DATASETS)) {
		uint64_t *tods_guids;
		uint64_t length;
		VERIFY(dsl_dataset_get_uint64_array_feature(to_ds,
		    SPA_FEATURE_REDACTED_DATASETS, &length, &tods_guids));
		fnvlist_add_uint64_array(nvl, BEGINNV_REDACT_SNAPS, tods_guids,
		    length);
	}

	/*
	 * If we're sending from a redaction bookmark, then we should retrieve
	 * the guids of that bookmark so we can send them over the wire.
	 */
	if (from_rl != NULL) {
		fnvlist_add_uint64_array(nvl, BEGINNV_REDACT_FROM_SNAPS,
		    from_rl->rl_phys->rlp_snaps,
		    from_rl->rl_phys->rlp_num_snaps);
	}

	/*
	 * If the snapshot we're sending from is redacted, include the redaction
	 * list in the stream.
	 */
	if (dspp->numfromredactsnaps != NUM_SNAPS_NOT_REDACTED) {
		ASSERT0P(from_rl);
		fnvlist_add_uint64_array(nvl, BEGINNV_REDACT_FROM_SNAPS,
		    dspp->fromredactsnaps, (uint_t)dspp->numfromredactsnaps);
		if (dspp->numfromredactsnaps > 0) {
			kmem_free(dspp->fromredactsnaps,
			    dspp->numfromredactsnaps * sizeof (uint64_t));
			dspp->fromredactsnaps = NULL;
		}
	}

	if (resuming || book_resuming) {
		err = setup_resume_points(dspp, to_arg, from_arg,
		    rlt_arg, smt_arg, resuming, os, redact_rl, nvl);
		if (err != 0)
			goto out;
	}

	if (featureflags & DMU_BACKUP_FEATURE_RAW) {
		uint64_t ivset_guid = ancestor_zb->zbm_ivset_guid;
		nvlist_t *keynvl = NULL;
		ASSERT(os->os_encrypted);

		err = dsl_crypto_populate_key_nvlist(os, ivset_guid,
		    &keynvl);
		if (err != 0) {
			fnvlist_free(nvl);
			goto out;
		}

		fnvlist_add_nvlist(nvl, "crypt_keydata", keynvl);
		fnvlist_free(keynvl);
	}

	if (!nvlist_empty(nvl)) {
		VERIFY0(nvlist_pack(nvl, &payload, &payload_len,
		    NV_ENCODE_XDR, KM_SLEEP));
		pad_packed_nvlist(&payload, &payload_len);
		drr->drr_payloadlen = payload_len;
	}

	fnvlist_free(nvl);
	err = dump_record(&dsc, payload, payload_len);
	fnvlist_pack_free(payload, payload_len);
	if (err != 0) {
		err = dsc.dsc_err;
		goto out;
	}

	setup_to_thread(to_arg, os, dssp, fromtxg, dspp->rawok);
	setup_from_thread(from_arg, from_rl, dssp);
	setup_redact_list_thread(rlt_arg, dspp, redact_rl, dssp);
	setup_merge_thread(smt_arg, dspp, from_arg, to_arg, rlt_arg, os);
	setup_reader_thread(srt_arg, dspp, smt_arg, featureflags,
	    refs, dsc.dsc_delta != NULL ? dsc.dsc_delta->sd_ref_os : NULL);

	range = bqueue_dequeue(&srt_arg->q);
	while (err == 0 && !range->eos_marker) {
		err = do_dump(&dsc, range);
		range = get_next_range(&srt_arg->q, range);
		if (issig())
			err = SET_ERROR(EINTR);
	}

	/*
	 * If we hit an error or are interrupted, cancel our worker threads and
	 * clear the queue of any pending records.  The threads will pass the
	 * cancel up the tree of worker threads, and each one will clean up any
	 * pending records before exiting.
	 */
	if (err != 0) {
		srt_arg->cancel = B_TRUE;
		while (!range->eos_marker) {
			range = get_next_range(&srt_arg->q, range);
		}
	}
	range_free(range);

	bqueue_destroy(&srt_arg->q);
	bqueue_destroy(&smt_arg->q);
	if (dspp->redactbook != NULL)
		bqueue_destroy(&rlt_arg->q);
	bqueue_destroy(&to_arg->q);
	bqueue_destroy(&from_arg->q);

	if (err == 0 && srt_arg->error != 0)
		err = srt_arg->error;

	if (err != 0)
		goto out;

	if (dsc.dsc_pending_op != PENDING_NONE)
		if (dump_record(&dsc, NULL, 0) != 0)
			err = SET_ERROR(EINTR);

	if (err != 0) {
		if (err == EINTR && dsc.dsc_err != 0)
			err = dsc.dsc_err;
		goto out;
	}

	/*
	 * Send the DRR_END record if this is not a saved stream.
	 * Otherwise, the omitted DRR_END record will signal to
	 * the receive side that the stream is incomplete.
	 */
	if (!dspp->savedok) {
		memset(drr, 0, sizeof (dmu_replay_record_t));
		drr->drr_type = DRR_END;
		drr->drr_u.drr_end.drr_checksum = dsc.dsc_zc;
		drr->drr_u.drr_end.drr_toguid = dsc.dsc_toguid;

		if (dump_record(&dsc, NULL, 0) != 0)
			err = dsc.dsc_err;
	}
out:
	mutex_enter(&to_ds->ds_sendstream_lock);
	list_remove(&to_ds->ds_sendstreams, dssp);
	mutex_exit(&to_ds->ds_sendstream_lock);

	VERIFY(err != 0 || (dsc.dsc_sent_begin &&
	    (dsc.dsc_sent_end || dspp->savedok)));

	kmem_free(drr, sizeof (dmu_replay_record_t));
	kmem_free(dssp, sizeof (dmu_sendstatus_t));
	kmem_free(from_arg, sizeof (*from_arg));
	kmem_free(to_arg, sizeof (*to_arg));
	kmem_free(rlt_arg, sizeof (*rlt_arg));
	kmem_free(smt_arg, sizeof (*smt_arg));
	kmem_free(srt_arg, sizeof (*srt_arg));
	if (dsc.dsc_delta != NULL)
		send_delta_destroy(dsc.dsc_delta);
	if (refs_fromds != NULL)
		send_refs_fromsnap_rele(refs_fromds, FTAG);
	if (refs != NULL)
		send_refs_destroy(refs);

	dsl_dataset_long_rele(to_ds, FTAG);
	if (from_rl != NULL) {
		dsl_redaction_list_long_rele(from_rl, FTAG);
		dsl_redaction_list_rele(from_rl, FTAG);
	}
	if (redact_rl != NULL) {
		dsl_redaction_list_long_rele(redact_rl, FTAG);
		dsl_redaction_list_rele(redact_rl, FTAG);
	}

	return (err);
}

int
dmu_send_obj(const char *pool, uint64_t tosnap, uint64_t fromsnap,
    boolean_t embedok, boolean_t large_block_ok, boolean_t compressok,
    boolean_t rawok, boolean_t savedok, int outfd, offset_t *off,
    dmu_send_outparams_t *dsop)
{
	int err;
	dsl_dataset_t *fromds;
	ds_hold_flags_t dsflags;
	struct dmu_send_params dspp = {0};
	dspp.embedok = embedok;
	dspp.large_block_ok = large_block_ok;
	dspp.compressok = compressok;
	dspp.outfd = outfd;
	dspp.off = off;
	dspp.dso = dsop;
	dspp.tag = FTAG;
	dspp.rawok = rawok;
	dspp.savedok = savedok;

	dsflags = (rawok) ? DS_HOLD_FLAG_NONE : DS_HOLD_FLAG_DECRYPT;
	err = dsl_pool_hold(pool, FTAG, &dspp.dp);
	if (err != 0)
		return (err);

	err = dsl_dataset_hold_obj_flags(dspp.dp, tosnap, dsflags, FTAG,
	    &dspp.to_ds);
	if (err != 0) {
		dsl_pool_rele(dspp.dp, FTAG);
		return (err);
	}

	if (fromsnap != 0) {
		err = dsl_dataset_hold_obj(dspp.dp, fromsnap, FTAG, &fromds);

		if (err != 0) {
			dsl_dataset_rele_flags(dspp.to_ds, dsflags, FTAG);
			dsl_pool_rele(dspp.dp, FTAG);
			return (err);
		}
		dspp.ancestor_zb.zbm_guid = dsl_dataset_phys(fromds)->ds_guid;
		dspp.ancestor_zb.zbm_creation_txg =
		    dsl_dataset_phys(fromds)->ds_creation_txg;
		dspp.ancestor_zb.zbm_creation_time =
		    dsl_dataset_phys(fromds)->ds_creation_time;

		if (dsl_dataset_is_zapified(fromds)) {
			(void) zap_lookup(dspp.dp->dp_meta_objset,
			    fromds->ds_object, DS_FIELD_IVSET_GUID, 8, 1,
			    &dspp.ancestor_zb.zbm_ivset_guid);
		}

		/* See dmu_send for the reasons behind this. */
		uint64_t *fromredact;

		if (!dsl_dataset_get_uint64_array_feature(fromds,
		    SPA_FEATURE_REDACTED_DATASETS,
		    &dspp.numfromredactsnaps,
		    &fromredact)) {
			dspp.numfromredactsnaps = NUM_SNAPS_NOT_REDACTED;
		} else if (dspp.numfromredactsnaps > 0) {
			uint64_t size = dspp.numfromredactsnaps *
			    sizeof (uint64_t);
			dspp.fromredactsnaps = kmem_zalloc(size, KM_SLEEP);
			memcpy(dspp.fromredactsnaps, fromredact, size);
		}

		boolean_t is_before =
		    dsl_dataset_is_before(dspp.to_ds, fromds, 0);
		dspp.is_clone = (dspp.to_ds->ds_dir !=
		    fromds->ds_dir);
		dsl_dataset_rele(fromds, FTAG);
		if (!is_before) {
			dsl_pool_rele(dspp.dp, FTAG);
			err = SET_ERROR(EXDEV);
		} else {
			err = dmu_send_impl(&dspp);
		}
	} else {
		dspp.numfromredactsnaps = NUM_SNAPS_NOT_REDACTED;
		err = dmu_send_impl(&dspp);
	}
	if (dspp.fromredactsnaps)
		kmem_free(dspp.fromredactsnaps,
		    dspp.numfromredactsnaps * sizeof (uint64_t));

	dsl_dataset_rele_flags(dspp.to_ds, dsflags, FTAG);
	return (err);
}

int
dmu_send(const char *tosnap, const char *fromsnap, boolean_t embedok,
    boolean_t large_block_ok, boolean_t compressok, boolean_t rawok,
    boolean_t savedok, boolean_t refsok, boolean_t deltaok,
    uint64_t resumeobj, uint64_t resumeoff, const char *redactbook, int outfd,
    offset_t *off, dmu_send_outparams_t *dsop)
{
	int err = 0;
	ds_hold_flags_t dsflags;
	boolean_t owned = B_FALSE;
	dsl_dataset_t *fromds = NULL;
	zfs_bookmark_phys_t book = {0};
	struct dmu_send_params dspp = {0};

	dsflags = (rawok) ? DS_HOLD_FLAG_NONE : DS_HOLD_FLAG_DECRYPT;
	dspp.tosnap = tosnap;
	dspp.embedok = embedok;
	dspp.large_block_ok = large_block_ok;
	dspp.compressok = compressok;
	dspp.outfd = outfd;
	dspp.off = off;
	dspp.dso = dsop;
	dspp.tag = FTAG;
	dspp.resumeobj = resumeobj;
	dspp.resumeoff = resumeoff;
	dspp.rawok = rawok;
	dspp.savedok = savedok;
	/* Deltas build on the reference index, so --delta implies --refs. */
	dspp.refsok = refsok || deltaok;
	dspp.deltaok = deltaok;

	if (fromsnap != NULL && strpbrk(fromsnap, "@#") == NULL)
		return (SET_ERROR(EINVAL));

	err = dsl_pool_hold(tosnap, FTAG, &dspp.dp);
	if (err != 0)
		return (err);

	if (strchr(tosnap, '@') == NULL && spa_writeable(dspp.dp->dp_spa)) {
		/*
		 * We are sending a filesystem or volume.  Ensure
		 * that it doesn't change by owning the dataset.
		 */

		if (savedok) {
			/*
			 * We are looking for the dataset that represents the
			 * partially received send stream. If this stream was
			 * received as a new snapshot of an existing dataset,
			 * this will be saved in a hidden clone named
			 * "<pool>/<dataset>/%recv". Otherwise, the stream
			 * will be saved in the live dataset itself. In
			 * either case we need to use dsl_dataset_own_force()
			 * because the stream is marked as inconsistent,
			 * which would normally make it unavailable to be
			 * owned.
			 */
			char *name = kmem_asprintf("%s/%s", tosnap,
			    recv_clone_name);
			err = dsl_dataset_own_force(dspp.dp, name, dsflags,
			    FTAG, &dspp.to_ds);
			if (err == ENOENT) {
				err = dsl_dataset_own_force(dspp.dp, tosnap,
				    dsflags, FTAG, &dspp.to_ds);
			}

			if (err == 0) {
				owned = B_TRUE;
				err = zap_lookup(dspp.dp->dp_meta_objset,
				    dspp.to_ds->ds_object,
				    DS_FIELD_RESUME_TOGUID, 8, 1,
				    &dspp.saved_guid);
			}

			if (err == 0) {
				err = zap_lookup(dspp.dp->dp_meta_objset,
				    dspp.to_ds->ds_object,
				    DS_FIELD_RESUME_TONAME, 1,
				    sizeof (dspp.saved_toname),
				    dspp.saved_toname);
			}
			/* Only disown if there was an error in the lookups */
			if (owned && (err != 0))
				dsl_dataset_disown(dspp.to_ds, dsflags, FTAG);

			kmem_strfree(name);
		} else {
			err = dsl_dataset_own(dspp.dp, tosnap, dsflags,
			    FTAG, &dspp.to_ds);
			if (err == 0)
				owned = B_TRUE;
		}
	} else {
		err = dsl_dataset_hold_flags(dspp.dp, tosnap, dsflags, FTAG,
		    &dspp.to_ds);
	}

	if (err != 0) {
		/* Note: dsl dataset is not owned at this point */
		dsl_pool_rele(dspp.dp, FTAG);
		return (err);
	}

	if (redactbook != NULL) {
		char path[ZFS_MAX_DATASET_NAME_LEN];
		(void) strlcpy(path, tosnap, sizeof (path));
		char *at = strchr(path, '@');
		if (at == NULL) {
			err = EINVAL;
		} else {
			(void) snprintf(at, sizeof (path) - (at - path), "#%s",
			    redactbook);
			err = dsl_bookmark_lookup(dspp.dp, path,
			    NULL, &book);
			dspp.redactbook = &book;
		}
	}

	if (err != 0) {
		dsl_pool_rele(dspp.dp, FTAG);
		if (owned)
			dsl_dataset_disown(dspp.to_ds, dsflags, FTAG);
		else
			dsl_dataset_rele_flags(dspp.to_ds, dsflags, FTAG);
		return (err);
	}

	if (fromsnap != NULL) {
		zfs_bookmark_phys_t *zb = &dspp.ancestor_zb;
		int fsnamelen;
		if (strpbrk(tosnap, "@#") != NULL)
			fsnamelen = strpbrk(tosnap, "@#") - tosnap;
		else
			fsnamelen = strlen(tosnap);

		/*
		 * If the fromsnap is in a different filesystem, then
		 * mark the send stream as a clone.
		 */
		if (strncmp(tosnap, fromsnap, fsnamelen) != 0 ||
		    (fromsnap[fsnamelen] != '@' &&
		    fromsnap[fsnamelen] != '#')) {
			dspp.is_clone = B_TRUE;
		}

		if (strchr(fromsnap, '@') != NULL) {
			err = dsl_dataset_hold(dspp.dp, fromsnap, FTAG,
			    &fromds);

			if (err != 0) {
				ASSERT0P(fromds);
			} else {
				/*
				 * We need to make a deep copy of the redact
				 * snapshots of the from snapshot, because the
				 * array will be freed when we evict from_ds.
				 */
				uint64_t *fromredact;
				if (!dsl_dataset_get_uint64_array_feature(
				    fromds, SPA_FEATURE_REDACTED_DATASETS,
				    &dspp.numfromredactsnaps,
				    &fromredact)) {
					dspp.numfromredactsnaps =
					    NUM_SNAPS_NOT_REDACTED;
				} else if (dspp.numfromredactsnaps > 0) {
					uint64_t size =
					    dspp.numfromredactsnaps *
					    sizeof (uint64_t);
					dspp.fromredactsnaps = kmem_zalloc(size,
					    KM_SLEEP);
					memcpy(dspp.fromredactsnaps, fromredact,
					    size);
				}
				if (!dsl_dataset_is_before(dspp.to_ds, fromds,
				    0)) {
					err = SET_ERROR(EXDEV);
				} else {
					zb->zbm_creation_txg =
					    dsl_dataset_phys(fromds)->
					    ds_creation_txg;
					zb->zbm_creation_time =
					    dsl_dataset_phys(fromds)->
					    ds_creation_time;
					zb->zbm_guid =
					    dsl_dataset_phys(fromds)->ds_guid;
					zb->zbm_redaction_obj = 0;

					if (dsl_dataset_is_zapified(fromds)) {
						(void) zap_lookup(
						    dspp.dp->dp_meta_objset,
						    fromds->ds_object,
						    DS_FIELD_IVSET_GUID, 8, 1,
						    &zb->zbm_ivset_guid);
					}
				}
				dsl_dataset_rele(fromds, FTAG);
			}
		} else {
			dspp.numfromredactsnaps = NUM_SNAPS_NOT_REDACTED;
			err = dsl_bookmark_lookup(dspp.dp, fromsnap, dspp.to_ds,
			    zb);
			if (err == EXDEV && zb->zbm_redaction_obj != 0 &&
			    zb->zbm_guid ==
			    dsl_dataset_phys(dspp.to_ds)->ds_guid)
				err = 0;
		}

		if (err == 0) {
			/* dmu_send_impl will call dsl_pool_rele for us. */
			err = dmu_send_impl(&dspp);
		} else {
			if (dspp.fromredactsnaps)
				kmem_free(dspp.fromredactsnaps,
				    dspp.numfromredactsnaps *
				    sizeof (uint64_t));
			dsl_pool_rele(dspp.dp, FTAG);
		}
	} else {
		dspp.numfromredactsnaps = NUM_SNAPS_NOT_REDACTED;
		err = dmu_send_impl(&dspp);
	}
	if (owned)
		dsl_dataset_disown(dspp.to_ds, dsflags, FTAG);
	else
		dsl_dataset_rele_flags(dspp.to_ds, dsflags, FTAG);
	return (err);
}

static int
dmu_adjust_send_estimate_for_indirects(dsl_dataset_t *ds, uint64_t uncompressed,
    uint64_t compressed, boolean_t stream_compressed, uint64_t *sizep)
{
	int err = 0;
	uint64_t size;
	/*
	 * Assume that space (both on-disk and in-stream) is dominated by
	 * data.  We will adjust for indirect blocks and the copies property,
	 * but ignore per-object space used (eg, dnodes and DRR_OBJECT records).
	 */

	uint64_t recordsize;
	uint64_t record_count;
	objset_t *os;
	VERIFY0(dmu_objset_from_ds(ds, &os));

	/* Assume all (uncompressed) blocks are recordsize. */
	if (zfs_override_estimate_recordsize != 0) {
		recordsize = zfs_override_estimate_recordsize;
	} else if (os->os_phys->os_type == DMU_OST_ZVOL) {
		err = dsl_prop_get_int_ds(ds,
		    zfs_prop_to_name(ZFS_PROP_VOLBLOCKSIZE), &recordsize);
	} else {
		err = dsl_prop_get_int_ds(ds,
		    zfs_prop_to_name(ZFS_PROP_RECORDSIZE), &recordsize);
	}
	if (err != 0)
		return (err);
	record_count = uncompressed / recordsize;

	/*
	 * If we're estimating a send size for a compressed stream, use the
	 * compressed data size to estimate the stream size. Otherwise, use the
	 * uncompressed data size.
	 */
	size = stream_compressed ? compressed : uncompressed;

	/*
	 * Subtract out approximate space used by indirect blocks.
	 * Assume most space is used by data blocks (non-indirect, non-dnode).
	 * Assume no ditto blocks or internal fragmentation.
	 *
	 * Therefore, space used by indirect blocks is sizeof(blkptr_t) per
	 * block.
	 */
	size -= record_count * sizeof (blkptr_t);

	/* Add in the space for the record associated with each block. */
	size += record_count * sizeof (dmu_replay_record_t);

	*sizep = size;

	return (0);
}

int
dmu_send_estimate_fast(dsl_dataset_t *origds, dsl_dataset_t *fromds,
    zfs_bookmark_phys_t *frombook, boolean_t stream_compressed,
    boolean_t saved, uint64_t *sizep)
{
	int err;
	dsl_dataset_t *ds = origds;
	uint64_t uncomp, comp;

	ASSERT(dsl_pool_config_held(origds->ds_dir->dd_pool));
	ASSERT(fromds == NULL || frombook == NULL);

	/*
	 * If this is a saved send we may actually be sending
	 * from the %recv clone used for resuming.
	 */
	if (saved) {
		objset_t *mos = origds->ds_dir->dd_pool->dp_meta_objset;
		uint64_t guid;
		char dsname[ZFS_MAX_DATASET_NAME_LEN + 6];

		dsl_dataset_name(origds, dsname);
		(void) strcat(dsname, "/");
		(void) strlcat(dsname, recv_clone_name, sizeof (dsname));

		err = dsl_dataset_hold(origds->ds_dir->dd_pool,
		    dsname, FTAG, &ds);
		if (err != ENOENT && err != 0) {
			return (err);
		} else if (err == ENOENT) {
			ds = origds;
		}

		/* check that this dataset has partially received data */
		err = zap_lookup(mos, ds->ds_object,
		    DS_FIELD_RESUME_TOGUID, 8, 1, &guid);
		if (err != 0) {
			err = SET_ERROR(err == ENOENT ? EINVAL : err);
			goto out;
		}

		err = zap_lookup(mos, ds->ds_object,
		    DS_FIELD_RESUME_TONAME, 1, sizeof (dsname), dsname);
		if (err != 0) {
			err = SET_ERROR(err == ENOENT ? EINVAL : err);
			goto out;
		}
	}

	/* tosnap must be a snapshot or the target of a saved send */
	if (!ds->ds_is_snapshot && ds == origds)
		return (SET_ERROR(EINVAL));

	if (fromds != NULL) {
		uint64_t used;
		if (!fromds->ds_is_snapshot) {
			err = SET_ERROR(EINVAL);
			goto out;
		}

		if (!dsl_dataset_is_before(ds, fromds, 0)) {
			err = SET_ERROR(EXDEV);
			goto out;
		}

		err = dsl_dataset_space_written(fromds, ds, &used, &comp,
		    &uncomp);
		if (err != 0)
			goto out;
	} else if (frombook != NULL) {
		uint64_t used;
		err = dsl_dataset_space_written_bookmark(frombook, ds, &used,
		    &comp, &uncomp);
		if (err != 0)
			goto out;
	} else {
		uncomp = dsl_dataset_phys(ds)->ds_uncompressed_bytes;
		comp = dsl_dataset_phys(ds)->ds_compressed_bytes;
	}

	err = dmu_adjust_send_estimate_for_indirects(ds, uncomp, comp,
	    stream_compressed, sizep);
	/*
	 * Add the size of the BEGIN and END records to the estimate.
	 */
	*sizep += 2 * sizeof (dmu_replay_record_t);

out:
	if (ds != origds)
		dsl_dataset_rele(ds, FTAG);
	return (err);
}

ZFS_MODULE_PARAM(zfs_send, zfs_send_, corrupt_data, INT, ZMOD_RW,
	"Allow sending corrupt data");

ZFS_MODULE_PARAM(zfs_send, zfs_send_, queue_length, UINT, ZMOD_RW,
	"Maximum send queue length");

ZFS_MODULE_PARAM(zfs_send, zfs_send_, unmodified_spill_blocks, INT, ZMOD_RW,
	"Send unmodified spill blocks");

ZFS_MODULE_PARAM(zfs_send, zfs_send_, refs_max_blocks, U64, ZMOD_RW,
	"Maximum number of blocks tracked as fromsnap references per send");

ZFS_MODULE_PARAM(zfs_send, zfs_send_, delta_max_pct, UINT, ZMOD_RW,
	"Largest WRITE_DELTA patch, as a percentage of the WRITE it replaces");

ZFS_MODULE_PARAM(zfs_send, zfs_send_, delta_sibling_scan, UINT, ZMOD_RW,
	"Blocks of a file scanned to find the file it was copied from");

ZFS_MODULE_PARAM(zfs_send, zfs_send_, delta_sketch_max_blocks, U64, ZMOD_RW,
	"Maximum fromsnap blocks in the WRITE_DELTA similarity index");

ZFS_MODULE_PARAM(zfs_send, zfs_send_, delta_sketch_min_pct, UINT, ZMOD_RW,
	"Build the WRITE_DELTA similarity index only if this share of new "
	"data blocks belongs to files not in the fromsnap");

ZFS_MODULE_PARAM(zfs_send, zfs_send_, delta_sketch_max_bytes, U64, ZMOD_RW,
	"Maximum fromsnap data read to build the WRITE_DELTA similarity index");

ZFS_MODULE_PARAM(zfs_send, zfs_send_, no_prefetch_queue_length, UINT, ZMOD_RW,
	"Maximum send queue length for non-prefetch queues");

ZFS_MODULE_PARAM(zfs_send, zfs_send_, queue_ff, UINT, ZMOD_RW,
	"Send queue fill fraction");

ZFS_MODULE_PARAM(zfs_send, zfs_send_, no_prefetch_queue_ff, UINT, ZMOD_RW,
	"Send queue fill fraction for non-prefetch queues");

ZFS_MODULE_PARAM(zfs_send, zfs_, override_estimate_recordsize, UINT, ZMOD_RW,
	"Override block size estimate with fixed size");
