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
 * Copyright (c) 2017, Intle Corporation. All rights reserved.
 */

#include <errno.h>
#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <stddef.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/list.h>
#include <sys/zfs_project.h>

#include "zfs_util.h"
#include "zfs_projectutil.h"

typedef struct zfs_project_item {
	list_node_t	zpi_list;
	char		zpi_name[0];
} zfs_project_item_t;

static void
zfs_project_item_alloc(list_t *head, const char *name)
{
	zfs_project_item_t *zpi;

	zpi = safe_malloc(sizeof (zfs_project_item_t) + strlen(name) + 1);
	strcpy(zpi->zpi_name, name);
	list_insert_tail(head, zpi);
}

static int
zfs_project_sanity_check(const char *name, zfs_project_control_t *zpc,
    struct stat *st)
{
	int ret;

	ret = stat(name, st);
	if (ret) {
		(void) fprintf(stderr, "failed to stat %s: %s\n",
		    name, strerror(errno));
		return (ret);
	}

	if (!S_ISREG(st->st_mode) && !S_ISDIR(st->st_mode)) {
		(void) fprintf(stderr, zpc->zpc_extsize ?
		    "only regular files and directories have a block size "
		    "setting\n" :
		    "only support project quota on regular file or "
		    "directory\n");
		return (-1);
	}

	if (!S_ISDIR(st->st_mode)) {
		if (zpc->zpc_dironly) {
			(void) fprintf(stderr,
			    "'-d' option on non-dir target %s\n", name);
			return (-1);
		}

		if (zpc->zpc_recursive) {
			(void) fprintf(stderr,
			    "'-r' option on non-dir target %s\n", name);
			return (-1);
		}
	}

	return (0);
}

static int
zfs_project_load_projid(const char *name, zfs_project_control_t *zpc)
{
	zfsxattr_t fsx;
	int ret, fd;

	fd = open(name, O_RDONLY | O_NOCTTY);
	if (fd < 0) {
		(void) fprintf(stderr, "failed to open %s: %s\n",
		    name, strerror(errno));
		return (fd);
	}

	ret = ioctl(fd, ZFS_IOC_FSGETXATTR, &fsx);
	if (ret)
		(void) fprintf(stderr,
		    "failed to get xattr for %s: %s\n",
		    name, strerror(errno));
	else if (zpc->zpc_extsize)
		zpc->zpc_expected_extsize = (fsx.fsx_xflags &
		    (FS_XFLAG_EXTSIZE | FS_XFLAG_EXTSZINHERIT)) ?
		    fsx.fsx_extsize : 0;
	else
		zpc->zpc_expected_projid = fsx.fsx_projid;

	close(fd);
	return (ret);
}

/*
 * zfs fileblocksize on one file or directory.  Returns 1 when fsx should be
 * set, 0 when there is nothing to set, and -1 on error.
 */
static int
zfs_extsize_handle_one(int fd, const char *name, zfsxattr_t *fsx,
    zfs_project_control_t *zpc)
{
	struct stat st;
	uint32_t flag, size;

	if (fstat(fd, &st) != 0) {
		(void) fprintf(stderr, "failed to stat %s: %s\n",
		    name, strerror(errno));
		return (-1);
	}
	flag = S_ISDIR(st.st_mode) ? FS_XFLAG_EXTSZINHERIT : FS_XFLAG_EXTSIZE;
	size = (fsx->fsx_xflags & flag) ? fsx->fsx_extsize : 0;

	switch (zpc->zpc_op) {
	case ZFS_PROJECT_OP_LIST:
		(void) printf("%7u %c %s\n", size,
		    (fsx->fsx_xflags & FS_XFLAG_EXTSZINHERIT) ? 'I' : '-',
		    name);
		return (0);
	case ZFS_PROJECT_OP_CHECK:
		if (size == zpc->zpc_expected_extsize)
			return (0);
		if (!zpc->zpc_newline)
			(void) printf("%s%c", name, '\0');
		else
			(void) printf("%s - block size is not set properly "
			    "(%u/%u)\n", name, size,
			    zpc->zpc_expected_extsize);
		return (0);
	case ZFS_PROJECT_OP_CLEAR:
		if (size == 0)
			return (0);
		fsx->fsx_xflags &= ~(FS_XFLAG_EXTSIZE | FS_XFLAG_EXTSZINHERIT);
		fsx->fsx_extsize = 0;
		return (1);
	case ZFS_PROJECT_OP_SET:
		if (size == zpc->zpc_expected_extsize)
			return (0);
		/*
		 * A file with data can't change.  Below the top
		 * (zpc_ignore_noent), skip it; -c lists it.
		 */
		if (S_ISREG(st.st_mode) && st.st_size != 0) {
			if (zpc->zpc_ignore_noent)
				return (0);
			(void) fprintf(stderr, "cannot set the block size of "
			    "%s: the file already has data\n", name);
			return (-1);
		}
		fsx->fsx_xflags &= ~(FS_XFLAG_EXTSIZE | FS_XFLAG_EXTSZINHERIT);
		fsx->fsx_xflags |= flag;
		fsx->fsx_extsize = zpc->zpc_expected_extsize;
		return (1);
	default:
		ASSERT(0);
		return (-1);
	}
}

static int
zfs_project_handle_one(const char *name, zfs_project_control_t *zpc)
{
	zfsxattr_t fsx;
	int ret, fd;

	/*
	 * Below the top, don't follow a symlink swapped in after readdir(),
	 * or block on a FIFO.
	 */
	fd = open(name, O_RDONLY | O_NOCTTY |
	    (zpc->zpc_ignore_noent ? O_NOFOLLOW | O_NONBLOCK : 0));
	if (fd < 0) {
		if (zpc->zpc_ignore_noent &&
		    (errno == ENOENT || errno == ELOOP || errno == ENXIO))
			return (0);

		(void) fprintf(stderr, "failed to open %s: %s\n",
		    name, strerror(errno));
		return (fd);
	}

	if (zpc->zpc_ignore_noent) {
		struct stat st;

		if (fstat(fd, &st) != 0 ||
		    !(S_ISREG(st.st_mode) || S_ISDIR(st.st_mode))) {
			close(fd);
			return (0);
		}
	}

	ret = ioctl(fd, ZFS_IOC_FSGETXATTR, &fsx);
	if (ret) {
		(void) fprintf(stderr,
		    "failed to get xattr for %s: %s\n",
		    name, strerror(errno));
		goto out;
	}

	if (zpc->zpc_extsize) {
		ret = zfs_extsize_handle_one(fd, name, &fsx, zpc);
		if (ret <= 0)
			goto out;
		goto set;
	}

	switch (zpc->zpc_op) {
	case ZFS_PROJECT_OP_LIST:
		(void) printf("%5u %c %s\n", fsx.fsx_projid,
		    (fsx.fsx_xflags & FS_XFLAG_PROJINHERIT) ? 'P' : '-', name);
		goto out;
	case ZFS_PROJECT_OP_CHECK:
		if (fsx.fsx_projid == zpc->zpc_expected_projid &&
		    fsx.fsx_xflags & FS_XFLAG_PROJINHERIT)
			goto out;

		if (!zpc->zpc_newline) {
			char c = '\0';

			(void) printf("%s%c", name, c);
			goto out;
		}

		if (fsx.fsx_projid != zpc->zpc_expected_projid)
			(void) printf("%s - project ID is not set properly "
			    "(%u/%u)\n", name, fsx.fsx_projid,
			    (uint32_t)zpc->zpc_expected_projid);

		if (!(fsx.fsx_xflags & FS_XFLAG_PROJINHERIT))
			(void) printf("%s - project inherit flag is not set\n",
			    name);

		goto out;
	case ZFS_PROJECT_OP_CLEAR:
		if (!(fsx.fsx_xflags & FS_XFLAG_PROJINHERIT) &&
		    (zpc->zpc_keep_projid ||
		    fsx.fsx_projid == ZFS_DEFAULT_PROJID))
			goto out;

		fsx.fsx_xflags &= ~FS_XFLAG_PROJINHERIT;
		if (!zpc->zpc_keep_projid)
			fsx.fsx_projid = ZFS_DEFAULT_PROJID;
		break;
	case ZFS_PROJECT_OP_SET:
		if (fsx.fsx_projid == zpc->zpc_expected_projid &&
		    (!zpc->zpc_set_flag ||
		    fsx.fsx_xflags & FS_XFLAG_PROJINHERIT))
			goto out;

		fsx.fsx_projid = zpc->zpc_expected_projid;
		if (zpc->zpc_set_flag)
			fsx.fsx_xflags |= FS_XFLAG_PROJINHERIT;
		break;
	default:
		ASSERT(0);
		break;
	}

set:
	ret = ioctl(fd, ZFS_IOC_FSSETXATTR, &fsx);
	if (ret) {
		(void) fprintf(stderr,
		    "failed to set xattr for %s: %s\n",
		    name, strerror(errno));

		if (errno == ENOTSUP && zpc->zpc_extsize)
			(void) fprintf(stderr, "The dataset's fileblocksize "
			    "property may be off, or the pool may lack the "
			    "project_quota feature.\n");
		if (errno == ENOTSUP) {
			char *kver = zfs_version_kernel();
			/*
			 * Special case: a module/userspace version mismatch can
			 * return ENOTSUP due to us fixing the XFLAGs bits in
			 * #17884.  In that case give a hint to the user that
			 * they should take action to make the versions match.
			 */
			if (strcmp(kver, ZFS_META_ALIAS) != 0) {
				fprintf(stderr,
				    "Warning: The zfs module version "
				    "(%s) and userspace\nversion (%s) do not "
				    "match up.  This may be the\ncause of the "
				    "\"Operation not supported\" error.\n",
				    kver, ZFS_META_ALIAS);
			}
		}
	}

out:
	close(fd);
	return (ret);
}

static int
zfs_project_handle_dir(const char *name, zfs_project_control_t *zpc,
    list_t *head)
{
	struct dirent *ent;
	DIR *dir;
	int ret = 0;
	int type;

	dir = opendir(name);
	if (dir == NULL) {
		if (errno == ENOENT && zpc->zpc_ignore_noent)
			return (0);

		ret = -errno;
		(void) fprintf(stderr, "failed to opendir %s: %s\n",
		    name, strerror(errno));
		return (ret);
	}

	/* Non-top item, ignore the case of being removed or renamed by race. */
	zpc->zpc_ignore_noent = B_TRUE;
	/* Skipped entries may leave errno set; only readdir()'s counts. */
	while (!ret && (errno = 0, ent = readdir(dir)) != NULL) {
		char *fullname;

		/* skip "." and ".." */
		if (strcmp(ent->d_name, ".") == 0 ||
		    strcmp(ent->d_name, "..") == 0)
			continue;

		if (strlen(ent->d_name) + strlen(name) + 1 >= PATH_MAX) {
			errno = ENAMETOOLONG;
			break;
		}

		if (asprintf(&fullname, "%s/%s", name, ent->d_name) == -1) {
			errno = ENOMEM;
			break;
		}

		/* Only files and directories have project IDs. */
		type = ent->d_type;
		if (type == DT_UNKNOWN) {
			struct stat st;

			if (lstat(fullname, &st) != 0)
				type = DT_UNKNOWN;
			else if (S_ISDIR(st.st_mode))
				type = DT_DIR;
			else if (S_ISREG(st.st_mode))
				type = DT_REG;
			else
				type = DT_LNK;
		}
		if (type != DT_REG && type != DT_DIR) {
			free(fullname);
			continue;
		}

		ret = zfs_project_handle_one(fullname, zpc);
		if (!ret && zpc->zpc_recursive && type == DT_DIR)
			zfs_project_item_alloc(head, fullname);

		free(fullname);
	}

	if (errno && !ret) {
		ret = -errno;
		(void) fprintf(stderr, "failed to readdir %s: %s\n",
		    name, strerror(errno));
	}

	closedir(dir);
	return (ret);
}

int
zfs_project_handle(const char *name, zfs_project_control_t *zpc)
{
	zfs_project_item_t *zpi;
	struct stat st;
	list_t head;
	int ret;

	ret = zfs_project_sanity_check(name, zpc, &st);
	if (ret)
		return (ret);

	if (zpc->zpc_extsize ? (zpc->zpc_op == ZFS_PROJECT_OP_CHECK &&
	    zpc->zpc_expected_extsize == ZFS_EXTSIZE_FROM_TARGET) :
	    ((zpc->zpc_op == ZFS_PROJECT_OP_SET ||
	    zpc->zpc_op == ZFS_PROJECT_OP_CHECK) &&
	    zpc->zpc_expected_projid == ZFS_INVALID_PROJID)) {
		ret = zfs_project_load_projid(name, zpc);
		if (ret)
			return (ret);
	}

	zpc->zpc_ignore_noent = B_FALSE;
	ret = zfs_project_handle_one(name, zpc);
	if (ret || !S_ISDIR(st.st_mode) || zpc->zpc_dironly ||
	    (!zpc->zpc_recursive &&
	    zpc->zpc_op != ZFS_PROJECT_OP_LIST &&
	    zpc->zpc_op != ZFS_PROJECT_OP_CHECK))
		return (ret);

	list_create(&head, sizeof (zfs_project_item_t),
	    offsetof(zfs_project_item_t, zpi_list));
	zfs_project_item_alloc(&head, name);
	while ((zpi = list_remove_head(&head)) != NULL) {
		if (!ret)
			ret = zfs_project_handle_dir(zpi->zpi_name, zpc, &head);
		free(zpi);
	}

	return (ret);
}
