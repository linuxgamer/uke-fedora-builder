// Host-only offline SELinux labels. Preserve Fedora ownership, modes and xattrs.
#include <ext2fs/ext2fs.h>
#include <selinux/label.h>
#include <selinux/selinux.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <array>
#include <cerrno>
#include <cstring>
#include <cstdint>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>

namespace fs = std::filesystem;
static void check(errcode_t code, const char *operation) {
    if (code) throw std::runtime_error(std::string(operation) + ": " + error_message(code));
}
static int verify_tree(const fs::path &directory, const char *contexts) {
    struct stat root_stat {};
    if (lstat(directory.c_str(), &root_stat) || !S_ISDIR(root_stat.st_mode))
        throw std::runtime_error("Tree must be a directory, never a symlink");
    const fs::path root = fs::canonical(directory);
    selinux_opt options[] = {{SELABEL_OPT_PATH, contexts}};
    selabel_handle *labels = selabel_open(SELABEL_CTX_FILE, options, 1);
    if (!labels) throw std::runtime_error("Cannot load the target file-context policy");
    unsigned long count = 0, excluded = 0;
    auto visit = [&](const fs::path &entry) {
        const std::string path = entry == root ? "/" : "/" + entry.lexically_relative(root).generic_string();
        struct stat metadata {};
        if (lstat(entry.c_str(), &metadata)) throw std::runtime_error("Cannot stat " + path);
        char *expected = nullptr;
        if (selabel_lookup_raw(labels, &expected, path.c_str(), metadata.st_mode)) {
            if (errno == ENOENT) { ++excluded; return; }
            throw std::runtime_error("Policy has no context for " + path);
        }
        char *actual = nullptr;
        const int length = lgetfilecon_raw(entry.c_str(), &actual);
        const bool matches = length >= 0 && actual && !std::strcmp(expected, actual);
        const std::string difference = matches ? "" : "Context differs at " + path +
            ": expected " + expected + "; found " + (actual ? actual : "<missing>");
        freecon(expected);
        if (actual) freecon(actual);
        if (!matches) throw std::runtime_error(difference);
        ++count;
    };
    try {
        visit(root);
        for (const auto &entry : fs::recursive_directory_iterator(root)) visit(entry.path());
    } catch (...) { selabel_close(labels); throw; }
    selabel_close(labels);
    std::cout << "Verified " << count << " SELinux tree contexts; " << excluded << " policy-excluded paths\n";
    return 0;
}
int main(int argc, char **argv) {
    try {
        if (argc == 4 && !std::strcmp(argv[1], "verify-tree")) return verify_tree(argv[2], argv[3]);
        initialize_ext2_error_table();
        if (argc != 5 || (std::strcmp(argv[1], "apply") && std::strcmp(argv[1], "verify")))
            throw std::runtime_error("Usage: ext4-labels apply|verify IMAGE ROOT FILE_CONTEXTS; verify-tree ROOT FILE_CONTEXTS");
        struct stat image_stat {};
        if (lstat(argv[2], &image_stat) || !S_ISREG(image_stat.st_mode))
            throw std::runtime_error("Image must be a regular file, never a symlink or block device");
        const bool write = !std::strcmp(argv[1], "apply");
        ext2_filsys image = nullptr;
        check(ext2fs_open(argv[2], (write ? EXT2_FLAG_RW : 0) | EXT2_FLAG_64BITS,
                          0, 0, unix_io_manager, &image), "open ext4");
        selinux_opt options[] = {{SELABEL_OPT_PATH, argv[4]}};
        selabel_handle *labels = selabel_open(SELABEL_CTX_FILE, options, 1);
        if (!labels) throw std::runtime_error("Cannot load the target file-context policy");
        const fs::path root = fs::canonical(argv[3]);
        unsigned long count = 0, excluded = 0;
        auto visit = [&](const std::string &path, const fs::path &source, bool generated) {
            ext2_ino_t number;
            check(ext2fs_namei(image, EXT2_ROOT_INO, EXT2_ROOT_INO, path.c_str(), &number), "resolve inode");
            ext2_inode inode {};
            check(ext2fs_read_inode(image, number, &inode), "read inode");
            struct stat original {};
            if (!generated) {
                if (lstat(source.c_str(), &original)) throw std::runtime_error("Cannot stat source");
                if (inode.i_mode != original.st_mode || inode_uid(inode) != original.st_uid ||
                    inode_gid(inode) != original.st_gid)
                    throw std::runtime_error("Ownership or mode differs at " + path);
            }
            char *context = nullptr;
            // ENOENT also represents the target policy's explicit <<none>> entries.
            if (selabel_lookup_raw(labels, &context, path.c_str(), inode.i_mode) && errno != ENOENT)
                throw std::runtime_error("Policy has no context for " + path);
            ext2_xattr_handle *attrs = nullptr;
            check(ext2fs_xattrs_open(image, number, &attrs), "open xattrs");
            check(ext2fs_xattrs_read(attrs), "read xattrs");
            if (!generated) {
                std::array<char, 128> original_cap {};
                ssize_t size = lgetxattr(source.c_str(), "security.capability", original_cap.data(), original_cap.size());
                if (size < 0 && errno != ENODATA && errno != ENOTSUP)
                    throw std::runtime_error("Cannot inspect source capability at " + path);
                void *actual_cap = nullptr;
                size_t cap_length = 0;
                errcode_t cap_error = ext2fs_xattr_get(attrs, "security.capability", &actual_cap, &cap_length);
                if (size > 0) {
                    check(cap_error, "get capability");
                    if (cap_length != static_cast<size_t>(size) ||
                        std::memcmp(actual_cap, original_cap.data(), cap_length))
                        throw std::runtime_error("Capability differs at " + path);
                } else if (!cap_error) {
                    throw std::runtime_error("Unexpected image capability at " + path);
                } else if (cap_error != EXT2_ET_EA_KEY_NOT_FOUND) check(cap_error, "get capability");
                if (actual_cap) ext2fs_free_mem(&actual_cap);
            }
            if (write && context) {
                check(ext2fs_xattr_set(attrs, "security.selinux", context, std::strlen(context) + 1), "set context");
                check(ext2fs_xattrs_write(attrs), "write xattrs");
            } else if (context) {
                void *actual = nullptr;
                size_t length = 0;
                const std::string operation = "get context at " + path;
                check(ext2fs_xattr_get(attrs, "security.selinux", &actual, &length), operation.c_str());
                if (length != std::strlen(context) + 1 || std::memcmp(actual, context, length))
                    throw std::runtime_error("Context differs at " + path);
                ext2fs_free_mem(&actual);
            }
            ext2fs_xattrs_close(&attrs);
            if (!generated) {
                // Population does not retain root time or subsecond precision.
                // Copy the actual staging mtime after xattr writes, then verify it.
                ext2_inode_large timed {};
                check(ext2fs_read_inode_full(image, number, reinterpret_cast<ext2_inode *>(&timed),
                                            sizeof(timed)), "read extended inode time");
                if (!ext2fs_inode_includes(EXT2_GOOD_OLD_INODE_SIZE + timed.i_extra_isize, i_mtime_extra))
                    throw std::runtime_error("Image inode cannot retain subsecond time: " + path);
                const std::int64_t seconds = original.st_mtim.tv_sec;
                const auto nanoseconds = original.st_mtim.tv_nsec;
                if (seconds < -2147483648LL || seconds > ((3LL << 32) + 2147483647LL) ||
                    nanoseconds < 0 || nanoseconds >= 1000000000L)
                    throw std::runtime_error("Source mtime is outside EXT4 range: " + path);
                const auto low = static_cast<std::uint32_t>(seconds);
                const auto epoch = static_cast<std::uint32_t>(
                    (seconds - static_cast<std::int32_t>(low)) / (1LL << 32));
                const auto extra = (static_cast<std::uint32_t>(nanoseconds) << 2) | epoch;
                if (write) {
                    timed.i_mtime = low;
                    timed.i_mtime_extra = extra;
                    check(ext2fs_write_inode_full(image, number, reinterpret_cast<ext2_inode *>(&timed),
                                                 sizeof(timed)), "write original inode mtime");
                } else if (timed.i_mtime != low || timed.i_mtime_extra != extra) {
                    throw std::runtime_error("Mtime differs at " + path);
                }
            }
            if (context) { freecon(context); ++count; }
            else ++excluded;
        };
        visit("/", root, false);
        for (const auto &entry : fs::recursive_directory_iterator(root)) {
            // lexical_relative must not resolve absolute target symlinks on the host.
            visit("/" + entry.path().lexically_relative(root).generic_string(), entry.path(), false);
        }
        if (!fs::exists(root / "lost+found")) visit("/lost+found", {}, true);
        selabel_close(labels);
        check(ext2fs_close(image), "close ext4");
        std::cout << (write ? "Applied" : "Verified") << " " << count
                  << " SELinux inode contexts; " << excluded
                  << " policy-excluded paths; source ownership, modes and capabilities preserved\n";
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
