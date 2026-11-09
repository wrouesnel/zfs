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
 * Copyright (c) 2026 by Will Rouesnel.
 */

/*
 * concurrent_sync_write: several threads write into the same new block of
 * each of a set of new files at once, with O_DSYNC.
 *
 *   concurrent_sync_write -w|-p|-v|-z DIR NFILES NTHREADS LEN BLKSZ
 *
 * For each file DIR/fNNNNN (created with O_DSYNC and fsync'd, so the
 * create is logged), NTHREADS threads released together each pwrite() LEN
 * bytes of their own pattern at BLKSZ + i * (BLKSZ / NTHREADS), so all of
 * them fall into the file's second block, which does not exist yet.
 *
 *   -w  write the files
 *   -p  write the files; then each thread punches a hole over its own range
 *       as soon as its write returns
 *   -v  check every range holds its pattern
 *   -z  check every range reads as zeros
 *
 * -v and -z print each range that differs (ZERO, MISMATCH or SHORT) and
 * exit 1 if any does.
 */

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int nthreads;
static size_t len;
static off_t blksz;
static int punch;
static pthread_barrier_t bar;

typedef struct job {
	int fd;
	int idx;
	char *buf;
	ssize_t rc;
	int err;
} job_t;

static off_t
range_off(int i)
{
	return (blksz + (off_t)i * (blksz / nthreads));
}

static void
fill(char *buf, int file, int i)
{
	memset(buf, 1 + (file * 31 + i * 7) % 251, len);
	(void) snprintf(buf, len < 64 ? len : 64, "file=%d thread=%d off=%lld",
	    file, i, (long long)range_off(i));
}

static int
punch_hole(int fd, off_t off, off_t l)
{
#if defined(__linux__)
	return (fallocate(fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE,
	    off, l));
#elif defined(__FreeBSD__)
	struct spacectl_range r = { .r_offset = off, .r_len = l };
	return (fspacectl(fd, SPACECTL_DEALLOC, &r, 0, NULL));
#else
	errno = ENOTSUP;
	return (-1);
#endif
}

static void *
writer(void *arg)
{
	job_t *j = arg;

	(void) pthread_barrier_wait(&bar);
	j->rc = pwrite(j->fd, j->buf, len, range_off(j->idx));
	j->err = errno;
	if (j->rc == (ssize_t)len && punch &&
	    punch_hole(j->fd, range_off(j->idx), len) != 0) {
		j->rc = -1;
		j->err = errno;
	}
	return (NULL);
}

static int
do_write(const char *dir, int nfiles)
{
	char path[4096];
	job_t *jobs = calloc(nthreads, sizeof (job_t));
	pthread_t *tids = calloc(nthreads, sizeof (pthread_t));

	if (jobs == NULL || tids == NULL)
		return (2);
	for (int i = 0; i < nthreads; i++) {
		if ((jobs[i].buf = malloc(len)) == NULL)
			return (2);
	}
	for (int f = 0; f < nfiles; f++) {
		(void) snprintf(path, sizeof (path), "%s/f%05d", dir, f);
		int fd = open(path, O_CREAT | O_TRUNC | O_RDWR | O_DSYNC, 0644);
		if (fd < 0 || fsync(fd) != 0) {
			perror(path);
			return (2);
		}
		(void) pthread_barrier_init(&bar, NULL, nthreads);
		for (int i = 0; i < nthreads; i++) {
			jobs[i].fd = fd;
			jobs[i].idx = i;
			fill(jobs[i].buf, f, i);
			if (pthread_create(&tids[i], NULL, writer,
			    &jobs[i]) != 0) {
				perror("pthread_create");
				return (2);
			}
		}
		for (int i = 0; i < nthreads; i++)
			(void) pthread_join(tids[i], NULL);
		for (int i = 0; i < nthreads; i++) {
			if (jobs[i].rc != (ssize_t)len) {
				(void) fprintf(stderr, "%s: thread %d: %s\n",
				    path, i, strerror(jobs[i].err));
				return (2);
			}
		}
		(void) pthread_barrier_destroy(&bar);
		(void) close(fd);
	}
	return (0);
}

static int
do_verify(const char *dir, int nfiles, int zeros)
{
	char path[4096];
	char *want = malloc(len), *got = malloc(len);
	int bad = 0;

	if (want == NULL || got == NULL)
		return (2);
	for (int f = 0; f < nfiles; f++) {
		(void) snprintf(path, sizeof (path), "%s/f%05d", dir, f);
		int fd = open(path, O_RDONLY);
		if (fd < 0) {
			perror(path);
			return (2);
		}
		for (int i = 0; i < nthreads; i++) {
			if (zeros)
				memset(want, 0, len);
			else
				fill(want, f, i);
			ssize_t rc = pread(fd, got, len, range_off(i));
			const char *st = NULL;
			if (rc != (ssize_t)len) {
				st = "SHORT";
			} else if (memcmp(got, want, len) != 0) {
				size_t k;
				for (k = 0; k < len && got[k] == 0; k++)
					;
				st = k == len ? "ZERO" : "MISMATCH";
			}
			if (st != NULL) {
				(void) printf("%s thread=%d off=%lld %s\n",
				    path, i, (long long)range_off(i), st);
				bad++;
			}
		}
		(void) close(fd);
	}
	(void) printf("%d of %d ranges differ\n", bad, nfiles * nthreads);
	return (bad != 0);
}

int
main(int argc, char **argv)
{
	if (argc != 7 || argv[1][0] != '-' || strchr("wpvz", argv[1][1]) ==
	    NULL || argv[1][2] != '\0') {
		(void) fprintf(stderr, "usage: %s -w|-p|-v|-z DIR NFILES "
		    "NTHREADS LEN BLKSZ\n", argv[0]);
		return (2);
	}
	int nfiles = atoi(argv[3]);
	nthreads = atoi(argv[4]);
	len = strtoul(argv[5], NULL, 0);
	blksz = strtoll(argv[6], NULL, 0);
	if (nfiles < 1 || nthreads < 1 || len < 1 ||
	    (off_t)len > blksz / nthreads) {
		(void) fprintf(stderr, "need NTHREADS * LEN <= BLKSZ\n");
		return (2);
	}
	switch (argv[1][1]) {
	case 'p':
		punch = 1;
		/* FALLTHROUGH */
	case 'w':
		return (do_write(argv[2], nfiles));
	case 'v':
		return (do_verify(argv[2], nfiles, 0));
	default:
		return (do_verify(argv[2], nfiles, 1));
	}
}
