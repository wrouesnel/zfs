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
 * Write a file onto itself from a mapping of the same file.  The file is
 * one byte larger than the window zfs_write() faults in before it takes
 * the range lock, so the rest of the source is faulted in while the write
 * runs.  The write has to transfer everything and leave the content as it
 * was.
 *
 * usage: mmap_write_self <file> <sparse|data> <private|shared> [create]
 *
 * With "create", make the file (a hole, or a byte pattern) and exit.
 * Otherwise write the existing file onto itself and check it.  Making the
 * file and writing it in separate runs lets the caller drop its pages in
 * between, so that the mapping is not resident.
 */

#include <sys/mman.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define	FILE_SIZE	((32UL << 20) + 1)

static unsigned char
pattern(size_t i)
{
	return ((unsigned char)(i * 7 + (i >> 12)));
}

static int
create(const char *path, int sparse)
{
	int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0 || ftruncate(fd, sparse ? FILE_SIZE : 0) != 0) {
		perror(path);
		return (1);
	}
	if (!sparse) {
		unsigned char *buf = malloc(FILE_SIZE);
		if (buf == NULL) {
			perror("malloc");
			return (1);
		}
		for (size_t i = 0; i < FILE_SIZE; i++)
			buf[i] = pattern(i);
		if (write(fd, buf, FILE_SIZE) != (ssize_t)FILE_SIZE) {
			perror("write");
			return (1);
		}
		free(buf);
	}
	if (fsync(fd) != 0) {
		perror("fsync");
		return (1);
	}
	(void) close(fd);
	return (0);
}

int
main(int argc, char *argv[])
{
	if (argc < 4 || argc > 5) {
		(void) fprintf(stderr, "usage: %s <file> <sparse|data> "
		    "<private|shared> [create]\n", argv[0]);
		return (2);
	}
	int sparse = strcmp(argv[2], "sparse") == 0;
	int shared = strcmp(argv[3], "shared") == 0;

	if (argc == 5)
		return (create(argv[1], sparse));

	int fd = open(argv[1], O_RDWR);
	if (fd < 0) {
		perror(argv[1]);
		return (1);
	}
	unsigned char *map = mmap(NULL, FILE_SIZE, PROT_READ,
	    shared ? MAP_SHARED : MAP_PRIVATE, fd, 0);
	if (map == MAP_FAILED) {
		perror("mmap");
		return (1);
	}

	size_t done = 0;
	while (done < FILE_SIZE) {
		ssize_t n = pwrite(fd, map + done, FILE_SIZE - done, done);
		if (n < 0) {
			perror("pwrite");
			return (1);
		}
		if (n == 0)
			break;
		done += n;
	}
	(void) munmap(map, FILE_SIZE);
	if (done != FILE_SIZE) {
		(void) fprintf(stderr, "wrote %zu of %lu bytes\n", done,
		    FILE_SIZE);
		return (1);
	}

	unsigned char *buf = malloc(FILE_SIZE);
	if (buf == NULL) {
		perror("malloc");
		return (1);
	}
	ssize_t got = pread(fd, buf, FILE_SIZE, 0);
	if (got != (ssize_t)FILE_SIZE) {
		(void) fprintf(stderr, "read %zd of %lu bytes\n", got,
		    FILE_SIZE);
		return (1);
	}
	size_t bad = 0;
	for (size_t i = 0; i < FILE_SIZE; i++)
		if (buf[i] != (sparse ? 0 : pattern(i)))
			bad++;
	if (bad != 0) {
		(void) fprintf(stderr, "%zu bytes changed\n", bad);
		return (1);
	}
	free(buf);
	(void) close(fd);
	return (0);
}
