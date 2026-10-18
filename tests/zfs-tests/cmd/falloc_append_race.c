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
 * falloc_append_race MODE PATH ITERATIONS BLOCKSIZE
 *
 * Race a write that appends the second block of an empty file against a
 * mode 0 fallocate(2) of its first block, as xfstests generic/586 does.
 * Either order must leave a two-block file whose second block holds the
 * written data.
 *
 *   live   PATH is a file, raced ITERATIONS times.  After each race the
 *          size must be two blocks through the racing descriptor, a new
 *          descriptor and stat(2), and a write at lseek(SEEK_END) must
 *          land after the second block, not over it.
 *   keep   PATH is a directory.  Race ITERATIONS fresh files PATH/f.N,
 *          fsync each and keep it, for a later check after ZIL replay.
 *   check  PATH is a directory written by keep: every PATH/f.N must be
 *          two blocks long with its second block intact.
 *
 * Prints each bad iteration or file and a summary line.  Exits 1 if any
 * were bad, 2 on errors.
 */

#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define	FILL	0xa5

static int fd;
static size_t bs;
static char *buf;
static char *rbuf;
static pthread_barrier_t barrier;

static void *
writer(void *arg)
{
	(void) arg;
	(void) pthread_barrier_wait(&barrier);
	if (pwrite(fd, buf, bs, bs) != (ssize_t)bs)
		perror("pwrite");
	return (NULL);
}

static void *
allocator(void *arg)
{
	(void) arg;
	(void) pthread_barrier_wait(&barrier);
	if (fallocate(fd, 0, 0, bs) != 0)
		perror("fallocate");
	return (NULL);
}

static int
race(const char *path)
{
	pthread_t a, b;

	fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		perror(path);
		return (-1);
	}
	(void) pthread_barrier_init(&barrier, NULL, 2);
	(void) pthread_create(&a, NULL, writer, NULL);
	(void) pthread_create(&b, NULL, allocator, NULL);
	(void) pthread_join(a, NULL);
	(void) pthread_join(b, NULL);
	(void) pthread_barrier_destroy(&barrier);
	return (0);
}

static off_t
fsize(int f)
{
	struct stat st;

	return (fstat(f, &st) == 0 ? st.st_size : -1);
}

/* Is the second block of f still the written data? */
static int
block2_intact(int f)
{
	if (pread(f, rbuf, bs, bs) != (ssize_t)bs)
		return (0);
	for (size_t i = 0; i < bs; i++) {
		if ((unsigned char)rbuf[i] != FILL)
			return (0);
	}
	return (1);
}

static int
live(const char *path, int iters)
{
	int bad = 0;

	for (int i = 0; i < iters; i++) {
		struct stat st;
		off_t want = 2 * bs, s1, s2, s3, end;
		int f2, ok;

		if (race(path) != 0)
			return (2);
		s1 = fsize(fd);
		f2 = open(path, O_RDONLY);
		s2 = f2 >= 0 ? fsize(f2) : -1;
		s3 = stat(path, &st) == 0 ? st.st_size : -1;
		end = lseek(fd, 0, SEEK_END);
		ok = (s1 == want && s2 == want && s3 == want && end == want);
		/* A write at the end must not land on the second block. */
		if (write(fd, "S", 1) != 1)
			perror("write");
		if (f2 >= 0 && !block2_intact(f2))
			ok = 0;
		if (!ok) {
			(void) printf("iteration %d: size %lld (racing fd), "
			    "%lld (new fd), %lld (stat), SEEK_END %lld, "
			    "second block %s; expected %lld\n", i,
			    (long long)s1, (long long)s2, (long long)s3,
			    (long long)end, f2 >= 0 && block2_intact(f2) ?
			    "intact" : "overwritten", (long long)want);
			bad++;
		}
		if (f2 >= 0)
			(void) close(f2);
		(void) close(fd);
	}
	(void) printf("%d of %d iterations went wrong\n", bad, iters);
	return (bad != 0);
}

static int
keep(const char *dir, int iters)
{
	char path[4096];

	for (int i = 0; i < iters; i++) {
		(void) snprintf(path, sizeof (path), "%s/f.%d", dir, i);
		if (race(path) != 0)
			return (2);
		if (fsync(fd) != 0)
			perror("fsync");
		(void) close(fd);
	}
	(void) printf("raced and synced %d files\n", iters);
	return (0);
}

static int
check(const char *dir, int iters)
{
	char path[4096];
	int bad = 0;

	for (int i = 0; i < iters; i++) {
		off_t s;
		int f, intact;

		(void) snprintf(path, sizeof (path), "%s/f.%d", dir, i);
		if ((f = open(path, O_RDONLY)) < 0) {
			perror(path);
			bad++;
			continue;
		}
		s = fsize(f);
		intact = block2_intact(f);
		if (s != (off_t)(2 * bs) || !intact) {
			(void) printf("%s: size %lld, second block %s; "
			    "expected %zu bytes\n", path, (long long)s,
			    intact ? "intact" : "missing", 2 * bs);
			bad++;
		}
		(void) close(f);
	}
	(void) printf("%d of %d files are wrong\n", bad, iters);
	return (bad != 0);
}

int
main(int argc, char **argv)
{
	int iters, ret;

	if (argc != 5) {
		(void) fprintf(stderr, "usage: %s live|keep|check PATH "
		    "ITERATIONS BLOCKSIZE\n", argv[0]);
		return (2);
	}
	iters = atoi(argv[3]);
	bs = strtoul(argv[4], NULL, 0);
	if ((buf = malloc(bs)) == NULL || (rbuf = malloc(bs)) == NULL) {
		perror("malloc");
		return (2);
	}
	(void) memset(buf, FILL, bs);

	if (strcmp(argv[1], "live") == 0)
		ret = live(argv[2], iters);
	else if (strcmp(argv[1], "keep") == 0)
		ret = keep(argv[2], iters);
	else if (strcmp(argv[1], "check") == 0)
		ret = check(argv[2], iters);
	else
		ret = 2;
	free(buf);
	free(rbuf);
	return (ret);
}
