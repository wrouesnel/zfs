dnl # SPDX-License-Identifier: CDDL-1.0
dnl #
dnl # 5.11 API change,
dnl #
dnl # The partitions of a gendisk are kept in the xarray disk->part_tbl,
dnl # indexed by partition number.
dnl #
AC_DEFUN([ZFS_AC_KERNEL_SRC_GENDISK_PART_TBL_XARRAY], [
	ZFS_LINUX_TEST_SRC([gendisk_part_tbl_xarray], [
		#include <linux/blkdev.h>
		#include <linux/xarray.h>
	], [
		struct gendisk *disk __attribute__ ((unused)) = NULL;
		struct block_device *part __attribute__ ((unused));
		unsigned long idx __attribute__ ((unused));

		xa_for_each(&disk->part_tbl, idx, part) {
		}
	])
])

AC_DEFUN([ZFS_AC_KERNEL_GENDISK_PART_TBL_XARRAY], [
	AC_MSG_CHECKING([whether gendisk part_tbl is an xarray])
	ZFS_LINUX_TEST_RESULT([gendisk_part_tbl_xarray], [
		AC_MSG_RESULT(yes)
		AC_DEFINE(HAVE_GENDISK_PART_TBL_XARRAY, 1,
		    [gendisk part_tbl is an xarray])
	], [
		AC_MSG_RESULT(no)
	])
])
