// SPDX-License-Identifier: MIT
// Read-only boot diagnostic. A successful policy load alone is insufficient.
#include <sys/stat.h>
#include <sys/utsname.h>
#include <unistd.h>
#include <fcntl.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <string>

static std::string read_text(const char* path) {
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return {};
    char bytes[8192];
    ssize_t count = read(fd, bytes, sizeof bytes);
    close(fd);
    if (count <= 0 || count == static_cast<ssize_t>(sizeof bytes)) return {};
    return std::string(bytes, static_cast<size_t>(count));
}

int main(int argc, char** argv) {
    bool vm = argc == 2 && std::strcmp(argv[1], "--vm-policy-test") == 0;
    if (argc != 1 && !vm) return 2;
    struct utsname kernel {};
    if (geteuid() != 0 || uname(&kernel) != 0) return 1;
    if (!vm && std::strcmp(kernel.release, "7.3.1-1006u2") != 0) {
        std::fputs("UKE_UBUNTU_CORE_REJECTED: mismatched kernel cohort\n", stderr);
        return 1;
    }
    auto enabled = read_text("/sys/module/apparmor/parameters/enabled");
    auto lsm = read_text("/sys/kernel/security/lsm");
    auto context = read_text("/proc/self/attr/apparmor/current");
    if ((enabled != "Y\n" && enabled != "1\n") ||
        ("," + lsm.substr(0, lsm.find('\n')) + ",").find(",apparmor,") == std::string::npos ||
        context != "uke-apparmor-probe (enforce)\n") {
        std::fputs("UKE_UBUNTU_CORE_REJECTED: AppArmor is not active in enforce mode\n", stderr);
        return 1;
    }
    struct stat file {};
    if (stat("/etc/uke-test/denied", &file) != 0 || !S_ISREG(file.st_mode) ||
        file.st_uid != 0 || (file.st_mode & 0777) != 0644 ||
        read_text("/etc/uke-test/allowed") != "UKE_APPARMOR_ALLOWED\n") return 1;
    errno = 0;
    int fd = open("/etc/uke-test/denied", O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd >= 0) { close(fd); return 1; }
    if (errno != EACCES) return 1;
    std::printf("UKE_UBUNTU_CORE_PASS: scope=%s kernel=%s AppArmor=active profile=enforce allowed-read=pass denied-read=EACCES\n",
                vm ? "generic-kernel-VM-policy-only" : "exact-1006u2-runtime", kernel.release);
    return 0;
}
