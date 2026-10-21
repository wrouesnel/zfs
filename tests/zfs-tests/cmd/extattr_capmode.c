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
 * extattr_capmode FILE NAME VALUE
 *
 * Open FILE, enter capability mode (cap_enter(2)), then use the user
 * namespace extended attribute NAME through the descriptor: it must
 * read back as VALUE and be listed; a new attribute NAME.new must be
 * set, read back and deleted.  Prints the failing call and exits 1 on
 * the first error.
 */

#include <sys/types.h>
#include <sys/capsicum.h>
#include <sys/extattr.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int
fail(const char *what, const char *name)
{
	(void) fprintf(stderr, "%s(%s) in capability mode: %s\n",
	    what, name, strerror(errno));
	return (1);
}

int
main(int argc, char **argv)
{
	char buf[1024];
	char newname[256];
	ssize_t n;
	int fd;

	if (argc != 4) {
		(void) fprintf(stderr, "usage: %s FILE NAME VALUE\n", argv[0]);
		return (2);
	}
	const char *name = argv[2];
	const char *value = argv[3];
	(void) snprintf(newname, sizeof (newname), "%s.new", name);

	if ((fd = open(argv[1], O_RDWR)) < 0) {
		perror("open");
		return (2);
	}
	if (cap_enter() != 0) {
		perror("cap_enter");
		return (2);
	}

	n = extattr_get_fd(fd, EXTATTR_NAMESPACE_USER, name, buf,
	    sizeof (buf));
	if (n < 0)
		return (fail("extattr_get_fd", name));
	if ((size_t)n != strlen(value) || memcmp(buf, value, n) != 0) {
		(void) fprintf(stderr, "extattr_get_fd(%s) returned %d bytes, "
		    "not \"%s\"\n", name, (int)n, value);
		return (1);
	}

	n = extattr_list_fd(fd, EXTATTR_NAMESPACE_USER, buf, sizeof (buf));
	if (n < 0)
		return (fail("extattr_list_fd", name));
	/* Entries are a length byte followed by the name, unterminated. */
	ssize_t off = 0;
	int found = 0;
	while (off < n) {
		size_t len = (unsigned char)buf[off];
		if (len == strlen(name) && off + 1 + (ssize_t)len <= n &&
		    memcmp(&buf[off + 1], name, len) == 0)
			found = 1;
		off += 1 + len;
	}
	if (!found) {
		(void) fprintf(stderr, "extattr_list_fd doesn't list %s\n",
		    name);
		return (1);
	}

	if (extattr_set_fd(fd, EXTATTR_NAMESPACE_USER, newname, value,
	    strlen(value)) < 0)
		return (fail("extattr_set_fd", newname));
	n = extattr_get_fd(fd, EXTATTR_NAMESPACE_USER, newname, buf,
	    sizeof (buf));
	if (n < 0)
		return (fail("extattr_get_fd", newname));
	if (extattr_delete_fd(fd, EXTATTR_NAMESPACE_USER, newname) != 0)
		return (fail("extattr_delete_fd", newname));

	(void) close(fd);
	return (0);
}
