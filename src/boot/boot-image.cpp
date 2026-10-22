// SPDX-License-Identifier: MIT
// Host-only Android boot v4 codec. Header layout: AOSP boot-image-header.
// This tool has no device, slot selection or flashing operations.
#include <array>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {
constexpr uint64_t page = 4096, limit = 512ULL * 1024 * 1024;
uint64_t aligned(uint64_t n) { return (n + page - 1) / page * page; }
uint32_t le32(const uint8_t* p) {
    return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
}
uint64_t le64(const uint8_t* p) { return le32(p) | uint64_t(le32(p + 4)) << 32; }
void put32(uint8_t* p, uint32_t n) {
    for (unsigned i = 0; i < 4; ++i) p[i] = uint8_t(n >> (8 * i));
}
struct File {
    int fd;
    explicit File(int value) : fd(value) { if (fd < 0) throw std::runtime_error(std::strerror(errno)); }
    ~File() { close(fd); }
    File(const File&) = delete;
    File& operator=(const File&) = delete;
};
std::vector<uint8_t> read(const char* name) {
    File in(open(name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC));
    struct stat st{};
    if (fstat(in.fd, &st) || !S_ISREG(st.st_mode) || st.st_size < 64 || uint64_t(st.st_size) > limit)
        throw std::runtime_error("Input must be a bounded regular file");
    std::vector<uint8_t> bytes(static_cast<size_t>(st.st_size));
    size_t off = 0;
    while (off < bytes.size()) {
        const auto n = ::read(in.fd, bytes.data() + off, bytes.size() - off);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) throw std::runtime_error("Truncated input");
        off += static_cast<size_t>(n);
    }
    return bytes;
}
void write_new(const char* name, const std::vector<uint8_t>& bytes) {
    File out(open(name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644));
    try {
        size_t off = 0;
        while (off < bytes.size()) {
            const auto n = ::write(out.fd, bytes.data() + off, bytes.size() - off);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) throw std::runtime_error("Output write failed");
            off += static_cast<size_t>(n);
        }
        if (fsync(out.fd)) throw std::runtime_error("Output sync failed");
    } catch (...) { unlink(name); throw; }
}
struct Header { uint32_t kernel, ramdisk, os, signature; uint64_t end; bool footer; };
Header inspect(const std::vector<uint8_t>& b) {
    if (b.size() < page || std::memcmp(b.data(), "ANDROID!", 8) ||
        le32(b.data() + 40) != 4 || le32(b.data() + 20) != 1584)
        throw std::runtime_error("Expected Android boot v4 (1584-byte header, 4096-byte pages)");
    for (unsigned i = 24; i < 40; ++i)
        if (b[i]) throw std::runtime_error("Nonzero reserved header field");
    if (!std::memchr(b.data() + 44, 0, 1536)) throw std::runtime_error("Unterminated command line");
    Header h{le32(b.data() + 8), le32(b.data() + 12), le32(b.data() + 16),
             le32(b.data() + 1580), 0, false};
    if (!h.kernel || h.kernel > limit || h.ramdisk > limit || h.signature > limit)
        throw std::runtime_error("Invalid payload size");
    h.end = page + aligned(h.kernel) + aligned(h.ramdisk) + aligned(h.signature);
    if (h.end > b.size()) throw std::runtime_error("Payload extends beyond image");
    h.footer = b.size() >= 64 && !std::memcmp(b.data() + b.size() - 64, "AVBf", 4);
    return h;
}
void raw_arm64(const std::vector<uint8_t>& b) {
    if (le32(b.data() + 56) != 0x644d5241 || le64(b.data() + 16) < b.size() ||
        le64(b.data() + 16) > limit || (le64(b.data() + 24) & 1))
        throw std::runtime_error("Expected little-endian raw ARM64 Linux Image");
}
uint64_t number(const char* s) {
    const std::string text(s);
    if (text.empty() || text.find_first_not_of("0123456789") != std::string::npos)
        throw std::runtime_error("Capacity must be an unsigned byte count");
    return std::stoull(text);
}
} // namespace

int main(int argc, char** argv) {
    try {
        if (argc == 3 && std::string(argv[1]) == "inspect") {
            const auto b = read(argv[2]); const auto h = inspect(b);
            std::cout << "{\"header_version\":4,\"page_size\":4096,\"kernel_bytes\":" << h.kernel
                      << ",\"ramdisk_bytes\":" << h.ramdisk << ",\"signature_bytes\":" << h.signature
                      << ",\"os_version_encoded\":" << h.os << ",\"payload_end\":" << h.end
                      << ",\"image_bytes\":" << b.size() << ",\"avb_footer_present\":"
                      << (h.footer ? "true" : "false") << "}\n";
        } else if (argc == 4 && std::string(argv[1]) == "extract") {
            const auto b = read(argv[2]); const auto h = inspect(b);
            write_new(argv[3], std::vector<uint8_t>(b.begin() + page, b.begin() + page + h.kernel));
        } else if ((argc == 6 && std::string(argv[1]) == "pack") ||
                   ((argc == 4 || argc == 5) && std::string(argv[1]) == "create")) {
            const bool create = std::string(argv[1]) == "create";
            const std::string profile = create && argc == 5 ? argv[4] : "";
            if (!profile.empty() && profile != "linux" && profile != "userdata" && profile != "userdata-vrr")
                throw std::runtime_error("Root profile must be linux, userdata or private userdata-vrr");
            if (create && argc == 5 && profile.empty())
                throw std::runtime_error("Empty root profile refused");
            // Uke stock-ABL metadata and capacity from the accepted boot_b header.
            const auto stock = create ? std::vector<uint8_t>(100663296) : read(argv[2]);
            const auto h = create ? Header{0, 0, 570425768, 0, 0, false} : inspect(stock);
            const auto kernel = read(argv[create ? 2 : 3]); raw_arm64(kernel);
            const auto capacity = create ? 100663296 : number(argv[5]);
            if (h.ramdisk || h.signature || capacity != stock.size() || capacity % page ||
                capacity > limit || page + aligned(kernel.size()) > capacity)
                throw std::runtime_error("Template or capacity does not admit a kernel-only v4 image");
            // Copy only the OS metadata. Neither stale signatures nor footer,
            // stock command line, kernel bytes or authentication data survive.
            std::vector<uint8_t> b(static_cast<size_t>(capacity), 0);
            std::memcpy(b.data(), "ANDROID!", 8);
            put32(b.data() + 8, static_cast<uint32_t>(kernel.size()));
            put32(b.data() + 16, h.os); put32(b.data() + 20, 1584); put32(b.data() + 40, 4);
            if (!profile.empty()) {
                const std::string selector = profile=="userdata-vrr" ?
                    "senemos.root=userdata msm.o82_vrr_test_min_hz=30" : "senemos.root=" + profile;
                std::memcpy(b.data() + 44, selector.c_str(), selector.size());
            }
            std::memcpy(b.data() + page, kernel.data(), kernel.size());
            write_new(argv[create ? 3 : 4], b);
            inspect(b);
        } else {
            throw std::runtime_error("Usage: boot-image inspect IMAGE | extract IMAGE NEW_KERNEL | pack STOCK IMAGE NEW_BOOT CAPACITY_BYTES | create IMAGE NEW_BOOT [linux|userdata|userdata-vrr]");
        }
    } catch (const std::exception& e) { std::cerr << "boot-image: " << e.what() << '\n'; return 1; }
}
