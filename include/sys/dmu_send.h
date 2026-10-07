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
 * Copyright (c) 2012, 2018 by Delphix. All rights reserved.
 * Copyright 2011 Nexenta Systems, Inc. All rights reserved.
 * Copyright (c) 2013, Joyent, Inc. All rights reserved.
 */

#ifndef _DMU_SEND_H
#define	_DMU_SEND_H

#include <sys/dsl_crypt.h>
#include <sys/dsl_bookmark.h>
#include <sys/spa.h>
#include <sys/objlist.h>
#include <sys/dmu_redact.h>

#define	BEGINNV_REDACT_SNAPS		"redact_snaps"
#define	BEGINNV_REDACT_FROM_SNAPS	"redact_from_snaps"
#define	BEGINNV_RESUME_OBJECT		"resume_object"
#define	BEGINNV_RESUME_OFFSET		"resume_offset"

struct vnode;
struct dsl_dataset;
struct drr_begin;
struct avl_tree;
struct dmu_replay_record;
struct dmu_send_outparams;
int
dmu_send(const char *tosnap, const char *fromsnap, boolean_t embedok,
    boolean_t large_block_ok, boolean_t compressok, boolean_t rawok,
    boolean_t savedok, boolean_t refsok, boolean_t deltaok, int deltaindexfd,
    uint64_t resumeobj, uint64_t resumeoff, const char *redactbook, int outfd,
    offset_t *off, struct dmu_send_outparams *dsop);
int dmu_send_delta_index(const char *snapname,
    struct dmu_send_outparams *dsop);
int dmu_send_estimate_fast(struct dsl_dataset *ds, struct dsl_dataset *fromds,
    zfs_bookmark_phys_t *frombook, boolean_t stream_compressed,
    boolean_t saved, uint64_t *sizep);
int dmu_send_obj(const char *pool, uint64_t tosnap, uint64_t fromsnap,
    boolean_t embedok, boolean_t large_block_ok, boolean_t compressok,
    boolean_t rawok, boolean_t savedok, int outfd, offset_t *off,
    struct dmu_send_outparams *dso);

typedef int (*dmu_send_outfunc_t)(objset_t *os, void *buf, int len, void *arg);
/* Returns nonzero (e.g. EPIPE) if the output can no longer be written. */
typedef int (*dmu_send_checkfunc_t)(void *arg);

/* Statistics for fromsnap references (zfs send --refs), kstat send_refs. */
typedef struct send_refs_stats {
	kstat_named_t	send_refs_candidates;
	kstat_named_t	send_refs_resolved;
	kstat_named_t	send_refs_truncated;
	kstat_named_t	send_refs_records;
	kstat_named_t	send_refs_bytes;
	kstat_named_t	recv_refs_cloned;
	kstat_named_t	recv_refs_copied;
	kstat_named_t	send_delta_attempts;
	kstat_named_t	send_delta_records;
	kstat_named_t	send_delta_payload_bytes;
	kstat_named_t	send_delta_logical_bytes;
	kstat_named_t	send_delta_same_hits;
	kstat_named_t	send_delta_sibling_hits;
	kstat_named_t	send_delta_sketch_hits;
	kstat_named_t	send_delta_rejected;
	kstat_named_t	send_delta_sketch_blocks;
	kstat_named_t	send_delta_sketch_truncated;
	kstat_named_t	send_delta_sketch_ns;
	kstat_named_t	send_delta_sketch_skipped;
	kstat_named_t	send_delta_index_loaded;
	kstat_named_t	recv_delta_records;
} send_refs_stats_t;

typedef enum send_refs_stat {
	SEND_REFS_STAT_RECV_CLONED,
	SEND_REFS_STAT_RECV_COPIED,
	SEND_REFS_STAT_RECV_DELTA,
} send_refs_stat_t;

void send_refs_stat_bump(send_refs_stat_t stat);
void dmu_send_init(void);
void dmu_send_fini(void);
typedef struct dmu_send_outparams {
	dmu_send_outfunc_t	dso_outfunc;
	dmu_send_checkfunc_t	dso_checkfunc;	/* optional */
	void			*dso_arg;
	boolean_t		dso_dryrun;
} dmu_send_outparams_t;

#endif /* _DMU_SEND_H */
