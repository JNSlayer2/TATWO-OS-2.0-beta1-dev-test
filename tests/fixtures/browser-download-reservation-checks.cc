#include "TatwoDownloadReservation.h"
#include <cassert>
#include <fcntl.h>
#include <string>
#include <cstdio>
#include <cstdlib>

int main() {
  char pattern[] = "/tmp/tatwo-reservation-test-XXXXXX";
  auto directory = mkdtemp(pattern);
  assert(directory);
  const std::string path = std::string(directory) + "/reserved.txt";
  const auto create = [&]() {
    int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    assert(fd >= 0);
    struct stat info {};
    assert(fstat(fd, &info) == 0);
    close(fd);
    return info;
  };
  auto original = create();
  assert(tatwo::RemoveEmptyDownloadReservation(path.c_str(), original.st_dev, original.st_ino));
  assert(access(path.c_str(), F_OK) != 0);
  original = create();
  int fd = open(path.c_str(), O_WRONLY);
  assert(write(fd, "partial-user-data", 17) == 17); close(fd);
  assert(!tatwo::RemoveEmptyDownloadReservation(path.c_str(), original.st_dev, original.st_ino));
  struct stat partial {}; assert(stat(path.c_str(), &partial) == 0 && partial.st_size == 17);
  unlink(path.c_str());
  original = create();
  const auto retained = path + ".retained";
  assert(rename(path.c_str(), retained.c_str()) == 0);
  auto replacement = create();
  assert(replacement.st_ino != original.st_ino);
  assert(!tatwo::RemoveEmptyDownloadReservation(path.c_str(), original.st_dev, original.st_ino));
  assert(access(path.c_str(), F_OK) == 0);
  unlink(path.c_str());
  assert(symlink(retained.c_str(), path.c_str()) == 0);
  assert(!tatwo::RemoveEmptyDownloadReservation(path.c_str(), original.st_dev, original.st_ino));
  assert(access(retained.c_str(), F_OK) == 0);
  assert(!tatwo::RemoveEmptyDownloadReservation(nullptr, original.st_dev, original.st_ino));
  unlink(path.c_str()); unlink(retained.c_str()); rmdir(directory);
  puts("PASS: empty owned reservation removed; partial data, replacement inode, and symlink preserved");
}
