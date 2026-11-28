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
 * Write a file from a shared mapping of the same file, with the part of the
 * source that zfs_write() does not prefault before it takes the range lock
 * not resident, so that it is faulted in while the write holds the lock.
 *
 * usage: mmap_write_selfmap [-t timeout]
 *            inplace|append|single|pub|apprace|readself <file>
 *
 *   inplace	write a 32M+128K file onto itself (openzfs #18135)
 *   append	append 32M of anonymous memory and then the last 100 bytes
 *		of a 256K+100 byte file, from a mapping of that file
 *   single	the same with a 1000 byte file (a single block)
 *   pub	append, while another thread keeps rewriting the first byte
 *		of the file, which makes the size the append has reached so
 *		far visible as the file size while the append runs
 *   apprace	an O_APPEND writev of 32M of anonymous memory and the first
 *		page of the file (through a mapping), while another thread
 *		appends 4K records; repeated 5 times.  The 32M+4K write must
 *		return its full length and its bytes must be contiguous in the
 *		file.
 *   readself	read an 8M file onto itself, into a shared writable mapping
 *		of it, while another thread keeps overwriting 1M in the
 *		middle with the same bytes: the read's faults must not wait
 *		behind the writer queued on the read's own range lock;
 *		repeated 5 times.
 *
 * Each case runs in a child process.  The write must complete and its data
 * must read back correctly once the file's pages are evicted (a stale cached
 * end-of-file page, openzfs #14548, is only reported).  A write that is
 * still running after the timeout (60 seconds) is reported as hung, with
 * its state and kernel stack.  Such a writer is usually stuck in the kernel
 * for good and can not be killed.
 *
 * Exit status: 0 pass, 1 fail (including a hang), 2 setup error.
 */

#ifndef _GNU_SOURCE
#define	_GNU_SOURCE
#endif
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define	BIG	(32UL << 20)
#define	REC	4096

static int fd;
static atomic_int stop;

static unsigned char
pat(uint64_t off)
{
	return ((unsigned char)(off ^ (off >> 8) ^ (off >> 16) ^ 0x5a));
}

static unsigned char
bigpat(uint64_t off)
{
	return ((unsigned char)(off ^ (off >> 9) ^ (off >> 18) ^ 0xa5));
}

static void
die(const char *what)
{
	perror(what);
	exit(2);
}

/* Create the file with the pattern and drop its pages from the cache. */
static void
create(const char *path, size_t size, int flags)
{
	unsigned char *buf = malloc(size);
	if (buf == NULL)
		die("malloc");
	for (size_t i = 0; i < size; i++)
		buf[i] = pat(i);
	fd = open(path, O_RDWR | O_CREAT | O_TRUNC | flags, 0644);
	if (fd < 0)
		die("open");
	if (pwrite(fd, buf, size, 0) != (ssize_t)size)
		die("pwrite");
	if (fsync(fd) != 0)
		die("fsync");
	(void) posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
	free(buf);
}

static int
check(off_t off, size_t len, unsigned char (*fn)(uint64_t), uint64_t base,
    const char *what)
{
	unsigned char *buf = malloc(len);
	if (buf == NULL)
		die("malloc");
	if (pread(fd, buf, len, off) != (ssize_t)len)
		die("pread");
	for (size_t i = 0; i < len; i++) {
		if (buf[i] != fn(base + i)) {
			printf("FAIL: %s: byte at offset %lld is 0x%02x, "
			    "expected 0x%02x\n", what, (long long)(off + i),
			    buf[i], fn(base + i));
			free(buf);
			return (1);
		}
	}
	free(buf);
	return (0);
}

static int
check_size(off_t want)
{
	struct stat st;
	if (fstat(fd, &st) != 0)
		die("fstat");
	if (st.st_size != want) {
		printf("FAIL: file size %lld, expected %lld\n",
		    (long long)st.st_size, (long long)want);
		return (1);
	}
	return (0);
}

static void *
publisher(void *arg)
{
	(void) arg;
	unsigned char c = pat(0);
	while (!atomic_load(&stop))
		if (pwrite(fd, &c, 1, 0) != 1)
			die("pwrite publisher");
	return (NULL);
}

static int
do_inplace(const char *path)
{
	size_t size = BIG + (128 << 10);
	create(path, size, 0);
	unsigned char *m = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, 0);
	if (m == MAP_FAILED)
		die("mmap");
	ssize_t w = pwrite(fd, m, size, 0);
	if (w != (ssize_t)size) {
		printf("FAIL: pwrite returned %zd of %zu (%s)\n", w, size,
		    w < 0 ? strerror(errno) : "short");
		return (1);
	}
	return (check_size(size) | check(0, size, pat, 0, "file"));
}

static int
do_append(const char *path, int single, int pub)
{
	long pg = sysconf(_SC_PAGESIZE);
	size_t size = single ? 1000 : (256 << 10) + 100;
	size_t srcoff = single ? 0 : (256 << 10);
	size_t srclen = size - srcoff;
	create(path, size, 0);
	unsigned char *m = mmap(NULL, size + pg, PROT_READ, MAP_SHARED, fd, 0);
	if (m == MAP_FAILED)
		die("mmap");
	unsigned char *big = malloc(BIG);
	if (big == NULL)
		die("malloc");
	for (size_t i = 0; i < BIG; i++)
		big[i] = bigpat(i);
	struct iovec iov[2] = {
		{ .iov_base = big, .iov_len = BIG },
		{ .iov_base = m + srcoff, .iov_len = srclen },
	};
	pthread_t thr;
	if (pub && pthread_create(&thr, NULL, publisher, NULL) != 0)
		die("pthread_create");
	ssize_t w = pwritev(fd, iov, 2, size);
	int err = errno;
	atomic_store(&stop, 1);
	if (pub)
		pthread_join(thr, NULL);
	if (w != (ssize_t)(BIG + srclen)) {
		printf("FAIL: pwritev returned %zd of %zu (%s)\n", w,
		    BIG + srclen, w < 0 ? strerror(err) : "short");
		return (1);
	}
	/*
	 * The write's own fault on the file's last page can leave that page
	 * cached with zeros past the old end of file (openzfs #14548), which
	 * read() then returns.  That is reported, but this test is about the
	 * write completing: the data is checked after the page is evicted.
	 */
	unsigned char *c = malloc(pg);
	if (c == NULL)
		die("malloc");
	size_t eofpg = size & ~(size_t)(pg - 1);
	if (pread(fd, c, pg, eofpg) != pg)
		die("pread");
	for (size_t i = size - eofpg; i < (size_t)pg; i++) {
		if (c[i] != bigpat(eofpg + i - size)) {
			printf("NOTE: #14548: the cached page at %zu reads "
			    "0x%02x at %zu, expected 0x%02x (stale page "
			    "cache; the data is checked after evicting it)\n",
			    eofpg, c[i], eofpg + i, bigpat(eofpg + i - size));
			break;
		}
	}
	free(c);
	(void) munmap(m, size + pg);
	(void) posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
	return (check_size(size + BIG + srclen) |
	    check(0, size, pat, 0, "original data") |
	    check(size, BIG, bigpat, 0, "appended anonymous data") |
	    check(size + BIG, srclen, pat, srcoff, "appended mapped data"));
}

static void *
appender(void *arg)
{
	int afd = *(int *)arg;
	unsigned char *rec = malloc(REC);
	if (rec == NULL)
		die("malloc");
	memset(rec, 'b', REC);
	while (!atomic_load(&stop))
		if (write(afd, rec, REC) != REC)
			die("write appender");
	free(rec);
	return (NULL);
}

static int
do_apprace(const char *path)
{
	unsigned char *big = malloc(BIG);
	unsigned char *want = malloc(BIG + REC);
	unsigned char *got = malloc(BIG + REC);
	if (big == NULL || want == NULL || got == NULL)
		die("malloc");
	for (size_t i = 0; i < BIG; i++)
		big[i] = bigpat(i);
	memcpy(want, big, BIG);
	for (size_t i = 0; i < REC; i++)
		want[BIG + i] = pat(i);

	for (int pass = 0; pass < 5; pass++) {
		create(path, REC, O_APPEND);
		int afd = open(path, O_WRONLY | O_APPEND);
		if (afd < 0)
			die("open appender");
		unsigned char *m = mmap(NULL, REC, PROT_READ, MAP_SHARED,
		    fd, 0);
		if (m == MAP_FAILED)
			die("mmap");
		struct iovec iov[2] = {
			{ .iov_base = big, .iov_len = BIG },
			{ .iov_base = m, .iov_len = REC },
		};
		pthread_t thr;
		atomic_store(&stop, 0);
		if (pthread_create(&thr, NULL, appender, &afd) != 0)
			die("pthread_create");
		usleep(1000);
		ssize_t w = writev(fd, iov, 2);
		int err = errno;
		atomic_store(&stop, 1);
		pthread_join(thr, NULL);
		(void) close(afd);
		(void) munmap(m, REC);
		if (w != (ssize_t)(BIG + REC)) {
			printf("FAIL: pass %d: writev returned %zd of %zu (%s)"
			    "\n", pass, w, BIG + REC,
			    w < 0 ? strerror(err) : "short");
			return (1);
		}
		struct stat st;
		if (fstat(fd, &st) != 0)
			die("fstat");
		off_t at = -1;
		for (off_t off = REC; off + (off_t)(BIG + REC) <= st.st_size;
		    off += REC) {
			if (pread(fd, got, 16, off) != 16)
				die("pread");
			if (memcmp(got, want, 16) == 0) {
				at = off;
				break;
			}
		}
		if (at < 0) {
			printf("FAIL: pass %d: the start of the %zu byte "
			    "write is not in the file (size %lld)\n", pass,
			    BIG + REC, (long long)st.st_size);
			return (1);
		}
		if (pread(fd, got, BIG + REC, at) != (ssize_t)(BIG + REC))
			die("pread");
		for (size_t i = 0; i < BIG + REC; i++) {
			if (got[i] != want[i]) {
				printf("FAIL: pass %d: the %zu byte O_APPEND "
				    "write returned its full length but is "
				    "not contiguous: it starts at %lld, byte "
				    "%zu of it is 0x%02x, expected 0x%02x "
				    "(file size %lld)\n", pass, BIG + REC,
				    (long long)at, i, got[i], want[i],
				    (long long)st.st_size);
				return (1);
			}
		}
		printf("pass %d: %zu bytes contiguous at %lld, file size "
		    "%lld\n", pass, BIG + REC, (long long)at,
		    (long long)st.st_size);
		(void) close(fd);
	}
	return (0);
}

/* Print the lines of a /proc file that start with prefix (all if NULL). */
static void
show(const char *path, const char *prefix, int max)
{
	char line[256];
	FILE *f = fopen(path, "r");
	if (f == NULL)
		return;
	while (max > 0 && fgets(line, sizeof (line), f) != NULL) {
		if (prefix == NULL ||
		    strncmp(line, prefix, strlen(prefix)) == 0) {
			printf("    %s", line);
			max--;
		}
	}
	fclose(f);
}

static void *
overwriter(void *arg)
{
	size_t off = 4 << 20, len = 1 << 20;
	unsigned char *buf = malloc(len);
	(void) arg;
	if (buf == NULL)
		die("malloc");
	for (size_t i = 0; i < len; i++)
		buf[i] = pat(off + i);
	while (!atomic_load(&stop))
		if (pwrite(fd, buf, len, off) != (ssize_t)len)
			die("pwrite overwriter");
	free(buf);
	return (NULL);
}

static int
do_readself(const char *path)
{
	size_t size = 8 << 20;
	create(path, size, 0);
	for (int pass = 0; pass < 5; pass++) {
		(void) posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
		unsigned char *m = mmap(NULL, size, PROT_READ | PROT_WRITE,
		    MAP_SHARED, fd, 0);
		if (m == MAP_FAILED)
			die("mmap");
		pthread_t thr;
		atomic_store(&stop, 0);
		if (pthread_create(&thr, NULL, overwriter, NULL) != 0)
			die("pthread_create");
		usleep(1000);
		ssize_t r = pread(fd, m, size, 0);
		int err = errno;
		atomic_store(&stop, 1);
		pthread_join(thr, NULL);
		(void) munmap(m, size);
		if (r != (ssize_t)size) {
			printf("FAIL: pass %d: pread returned %zd of %zu "
			    "(%s)\n", pass, r, size,
			    r < 0 ? strerror(err) : "short");
			return (1);
		}
		if (check_size(size) | check(0, size, pat, 0, "file"))
			return (1);
	}
	return (0);
}

static void
report_hang(pid_t pid, int timeout)
{
	char path[300];
	printf("FAIL: HANG: the writer (pid %d) has not finished after %d "
	    "seconds\n", (int)pid, timeout);
	snprintf(path, sizeof (path), "/proc/%d/task", (int)pid);
	DIR *d = opendir(path);
	struct dirent *de;
	while (d != NULL && (de = readdir(d)) != NULL) {
		if (de->d_name[0] == '.')
			continue;
		printf("  thread %s:\n", de->d_name);
		snprintf(path, sizeof (path), "/proc/%d/task/%s/status",
		    (int)pid, de->d_name);
		show(path, "State:", 1);
		snprintf(path, sizeof (path), "/proc/%d/task/%s/stack",
		    (int)pid, de->d_name);
		show(path, NULL, 12);
	}
	if (d != NULL)
		closedir(d);
	printf("  A writer that faults on its own range lock can not be "
	    "killed; reboot the machine before further testing.\n");
	fflush(stdout);
}

int
main(int argc, char **argv)
{
	int timeout = 60, c;
	while ((c = getopt(argc, argv, "t:")) != -1) {
		if (c == 't')
			timeout = atoi(optarg);
		else
			goto usage;
	}
	if (argc - optind != 2)
		goto usage;
	const char *mode = argv[optind], *path = argv[optind + 1];
	if (strcmp(mode, "inplace") != 0 && strcmp(mode, "append") != 0 &&
	    strcmp(mode, "single") != 0 && strcmp(mode, "pub") != 0 &&
	    strcmp(mode, "apprace") != 0 && strcmp(mode, "readself") != 0)
		goto usage;

	fflush(stdout);
	pid_t pid = fork();
	if (pid < 0)
		die("fork");
	if (pid == 0) {
		int ret;
		if (strcmp(mode, "inplace") == 0)
			ret = do_inplace(path);
		else if (strcmp(mode, "apprace") == 0)
			ret = do_apprace(path);
		else if (strcmp(mode, "readself") == 0)
			ret = do_readself(path);
		else
			ret = do_append(path, strcmp(mode, "single") == 0,
			    strcmp(mode, "pub") == 0);
		fflush(stdout);
		_exit(ret);
	}

	struct timespec t0, t1;
	clock_gettime(CLOCK_MONOTONIC, &t0);
	for (;;) {
		int status;
		pid_t r = waitpid(pid, &status, WNOHANG);
		if (r == pid) {
			clock_gettime(CLOCK_MONOTONIC, &t1);
			if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
				printf("PASS: %s: completed in %ld s, "
				    "data correct\n", mode,
				    (long)(t1.tv_sec - t0.tv_sec));
				return (0);
			}
			if (WIFEXITED(status))
				return (WEXITSTATUS(status));
			printf("FAIL: %s: writer killed by signal %d\n", mode,
			    WTERMSIG(status));
			return (1);
		}
		if (r < 0)
			die("waitpid");
		clock_gettime(CLOCK_MONOTONIC, &t1);
		if (t1.tv_sec - t0.tv_sec >= timeout) {
			report_hang(pid, timeout);
			(void) kill(pid, SIGKILL);
			return (1);
		}
		usleep(100000);
	}
usage:
	fprintf(stderr, "usage: mmap_write_selfmap [-t timeout] "
	    "inplace|append|single|pub|apprace|readself <file>\n");
	return (2);
}
