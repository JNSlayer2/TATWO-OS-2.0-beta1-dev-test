#pragma once

#ifdef __cplusplus
#include <sys/stat.h>
#include <unistd.h>

namespace tatwo {
// A cancelled transfer may leave the empty O_EXCL reservation behind. Only
// remove that same empty regular file; replacements and partial data survive.
inline bool RemoveEmptyDownloadReservation(const char *path, dev_t device, ino_t inode) {
  struct stat info {};
  return path && inode && lstat(path, &info) == 0 && S_ISREG(info.st_mode) &&
      info.st_dev == device && info.st_ino == inode && info.st_size == 0 && unlink(path) == 0;
}
}  // namespace tatwo
#endif
