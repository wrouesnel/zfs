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

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <err.h>

/* backward compat in case it's not defined */
#ifndef O_TMPFILE
#define	O_TMPFILE	(020000000|O_DIRECTORY)
#endif

/*
 * DESCRIPTION:
 *	Verify that data written through mmap(2) to an O_TMPFILE file is
 *	written back, and survives once the file is linked.
 *
 * STRATEGY:
 *	1. open(2) with O_TMPFILE, ftruncate(2) to 64 MiB.
 *	2. Fill it through a shared mapping, munmap(2), no msync(2) or
 *	   fsync(2).
 *	3. linkat(2) it into the directory and close(2) it.
 *	4. syncfs(2), export and re-import the pool.
 *	5. Read the file back and compare every page with what was
 *	   written.
 */

#define	FILESIZE	(64UL << 20)
#define	PAGESZ		4096UL

static unsigned char
pattern(size_t off)
{
	return ((unsigned char)(((off / PAGESZ) % 251) + 1));
}

static void
run(const char *op)
{
	int ret;
	char buf[50];
	sprintf(buf, "sudo -E zpool %s $TESTPOOL", op);
	if ((ret = system(buf)) != 0) {
		if (ret == -1)
			err(4, "system \"zpool %s\"", op);
		else
			errx(4, "zpool %s exited %d\n",
			    op, WEXITSTATUS(ret));
	}
}

int
main(void)
{
	int i, fd, dfd;
	char spath[1024], dpath[1024];
	const char *penv[] = {"TESTDIR", "TESTFILE0"};
	unsigned char *p, buf[PAGESZ];
	struct stat st;
	size_t off, j, bad = 0, first_bad = 0;

	(void) fprintf(stdout, "Verify mmap writes to an O_TMPFILE file "
	    "are written back.\n");

	for (i = 0; i < ARRAY_SIZE(penv); i++)
		if ((penv[i] = getenv(penv[i])) == NULL)
			errx(1, "getenv(penv[%d])", i);

	fd = open(penv[0], O_RDWR|O_TMPFILE, 0666);
	if (fd < 0)
		err(2, "open(%s)", penv[0]);
	if (ftruncate(fd, FILESIZE) != 0)
		err(2, "ftruncate");

	p = mmap(NULL, FILESIZE, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
	if (p == MAP_FAILED)
		err(2, "mmap");
	for (off = 0; off < FILESIZE; off += PAGESZ)
		memset(p + off, pattern(off), PAGESZ);
	if (munmap(p, FILESIZE) != 0)
		err(2, "munmap");

	snprintf(spath, sizeof (spath), "/proc/self/fd/%d", fd);
	snprintf(dpath, sizeof (dpath), "%s/%s", penv[0], penv[1]);
	if (linkat(AT_FDCWD, spath, AT_FDCWD, dpath, AT_SYMLINK_FOLLOW) < 0)
		err(3, "linkat");
	close(fd);

	if ((dfd = open(penv[0], O_RDONLY|O_DIRECTORY)) < 0)
		err(3, "open(%s)", penv[0]);
	if (syncfs(dfd) != 0)
		err(3, "syncfs");
	close(dfd);

	run("export");
	run("import");

	if ((fd = open(dpath, O_RDONLY)) < 0)
		err(5, "open(%s)", dpath);
	if (fstat(fd, &st) != 0)
		err(5, "fstat");
	for (off = 0; off < FILESIZE; off += PAGESZ) {
		if (pread(fd, buf, PAGESZ, off) != PAGESZ)
			err(5, "pread at %zu", off);
		for (j = 0; j < PAGESZ; j++) {
			if (buf[j] != pattern(off)) {
				if (bad++ == 0)
					first_bad = off;
				break;
			}
		}
	}
	close(fd);

	if (bad != 0)
		errx(6, "%zu of %lu pages lost after export/import (first at "
		    "offset %zu: 0x%02x, expected 0x%02x); %lld KiB allocated",
		    bad, FILESIZE / PAGESZ, first_bad, buf[0],
		    pattern(first_bad), (long long)st.st_blocks / 2);
	if (unlink(dpath) == -1)
		err(8, "unlink");

	(void) fprintf(stdout, "All %lu pages intact after export/import.\n",
	    FILESIZE / PAGESZ);
	return (0);
}
