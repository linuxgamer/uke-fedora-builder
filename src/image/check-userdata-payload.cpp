// SPDX-License-Identifier: MIT
// Read-only, bounded recovery payload validation; no device or write operation.
#include <openssl/evp.h>
#include <zstd.h>
#include <algorithm>
#include <array>
#include <cerrno>
#include <charconv>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>
namespace {
void need(bool ok, const char *why) { if (!ok) throw std::runtime_error(why); }
constexpr uint64_t gib=1024ULL*1024*1024, boot_bytes=100663296;
struct File {
    int fd;
    explicit File(const char *path):fd(open(path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK)) {
        need(fd>=0,"Cannot open a regular payload");
        struct stat st{};
        if (fstat(fd,&st) || !S_ISREG(st.st_mode) || st.st_size<=0 || uint64_t(st.st_size)>8*gib) {
            close(fd); fd=-1; throw std::runtime_error("Payload must be a bounded regular file");
        }
    }
    ~File() { if(fd>=0) close(fd); }
    File(const File&)=delete;
    File& operator=(const File&)=delete;
};
size_t read_chunk(int fd, unsigned char *data, size_t size) {
    ssize_t count;
    do { count=read(fd,data,size); } while(count<0 && errno==EINTR);
    need(count>=0,"Payload read failed"); return static_cast<size_t>(count);
}
uint32_t le32(const unsigned char *p) {
    return uint32_t(p[0]) | uint32_t(p[1])<<8 | uint32_t(p[2])<<16 | uint32_t(p[3])<<24;
}
uint64_t le64(const unsigned char *p) { return le32(p) | uint64_t(le32(p+4))<<32; }
uint32_t be32(const unsigned char *p) {
    return uint32_t(p[3]) | uint32_t(p[2])<<8 | uint32_t(p[1])<<16 | uint32_t(p[0])<<24;
}
uint64_t be64(const unsigned char *p) { return be32(p+4) | uint64_t(be32(p))<<32; }
void label(const unsigned char *p, bool wide=false) {
    constexpr char expected[]="UKE_LINUX";
    for(size_t i=0;i<sizeof(expected);++i)
        need(p[i*(wide?2:1)]==expected[i] && (!wide || p[i*2+1]==0),"Root filesystem label differs");
}
void uuid(const unsigned char *p) {
    need(std::any_of(p,p+16,[](auto byte){return byte!=0;}),"Root filesystem UUID is empty");
}
uint64_t number(const std::string &text) {
    uint64_t n=0; const auto p=std::from_chars(text.data(),text.data()+text.size(),n);
    need(p.ec==std::errc{} && p.ptr==text.data()+text.size() && n>=256*1024*1024 && n<=64*gib && n%4096==0,
         "Invalid raw root byte count"); return n;
}
struct Digest {
    std::unique_ptr<EVP_MD_CTX, decltype(&EVP_MD_CTX_free)> context{EVP_MD_CTX_new(),EVP_MD_CTX_free};
    Digest() { need(context && EVP_DigestInit_ex(context.get(),EVP_sha256(),nullptr)==1,"Cannot initialize SHA-256"); }
    void add(const unsigned char *p,size_t count) { need(EVP_DigestUpdate(context.get(),p,count)==1,"Cannot hash payload"); }
    void check(const std::string &wanted) {
        need(wanted.size()==64 && wanted.find_first_not_of("0123456789abcdef")==std::string::npos,"Invalid SHA-256");
        std::array<unsigned char,32> bytes{}; unsigned size=0;
        need(EVP_DigestFinal_ex(context.get(),bytes.data(),&size)==1 && size==bytes.size(),"Cannot finish SHA-256");
        constexpr char hex[]="0123456789abcdef"; std::string actual;
        for(const auto c:bytes) { actual+=hex[c>>4]; actual+=hex[c&15]; }
        need(actual==wanted,"Payload SHA-256 differs");
    }
};
struct Stream {
    Digest digest;
    std::array<unsigned char,65536+4096> prefix{};
    uint64_t bytes=0;
    void add(const unsigned char *data,size_t count,uint64_t limit) {
        need(count<=limit-bytes,"Expanded payload exceeds its declared size");
        if(bytes<prefix.size()) std::memcpy(prefix.data()+bytes,data,std::min<uint64_t>(count,prefix.size()-bytes));
        digest.add(data,count); bytes+=count;
    }
};
void root(const char *path,uint64_t expected,const char *hash,const std::string &filesystem) {
    File file(path); Stream stream;
    std::unique_ptr<ZSTD_DCtx, decltype(&ZSTD_freeDCtx)> context{ZSTD_createDCtx(),ZSTD_freeDCtx};
    need(bool(context),"Cannot create Zstandard decoder");
    need(!ZSTD_isError(ZSTD_DCtx_setParameter(context.get(),ZSTD_d_windowLogMax,25)),"Cannot bound Zstandard memory");
    std::array<unsigned char,128*1024> input{}, output{};
    bool ended=false;
    for(;;) {
        const auto bytes=read_chunk(file.fd,input.data(),input.size());
        if(!bytes) break;
        need(!ended,"Trailing data or a second Zstandard frame refused");
        ZSTD_inBuffer in{input.data(),bytes,0};
        size_t produced;
        do {
            ZSTD_outBuffer out{output.data(),output.size(),0};
            const auto result=ZSTD_decompressStream(context.get(),&out,&in);
            need(!ZSTD_isError(result),"Corrupt or oversized-window Zstandard frame");
            stream.add(output.data(),out.pos,expected);
            produced=out.pos;
            if(result==0) { need(in.pos==in.size,"Trailing compressed data refused"); ended=true; break; }
        } while(in.pos<in.size || produced==output.size());
    }
    need(ended && stream.bytes==expected,"Truncated or incorrectly sized root payload");
    const auto *p=stream.prefix.data();
    if(filesystem=="f2fs") {
        for(const auto offset:{1024U,5120U}) {
            const auto *super=p+offset;
            need(le32(super)==0xf2f52010 && le32(super+16)==12,"Expected two 4 KiB F2FS superblocks");
            need(le64(super+36)==expected/4096,"F2FS geometry differs from the declared root image");
            uuid(super+108);label(super+124,true);
        }
    } else if(filesystem=="ext4") {
        const auto *super=p+1024;
        const auto blocks=le32(super+4) | (le32(super+96)&0x80 ? uint64_t(le32(super+336))<<32 : 0);
        need(super[56]==0x53 && super[57]==0xef && le32(super+24)==2 && blocks==expected/4096,
             "EXT4 identity or geometry differs from the declared image");
        uuid(super+104);label(super+120);
    } else if(filesystem=="xfs") {
        need(!std::memcmp(p,"XFSB",4) && be32(p+4)==4096 && be64(p+8)==expected/4096,
             "XFS identity or geometry differs from the declared image");
        uuid(p+32);label(p+108);
    } else if(filesystem=="btrfs") {
        const auto *super=p+65536;
        need(!std::memcmp(super+64,"_BHRfS_M",8) && le64(super+48)==65536 && le64(super+112)==expected &&
             le64(super+136)==1 && le32(super+144)==4096,
             "Single-device Btrfs identity or geometry differs from the declared image");
        uuid(super+32);label(super+299);
    } else {
        throw std::runtime_error("Unsupported root filesystem");
    }
    stream.digest.check(hash);
}
void boot(const char *path,const char *hash,bool require_filesystems) {
    File file(path); Stream stream; std::array<unsigned char,128*1024> chunk{};
    std::array<unsigned char,84> note{4,0,0,0,68,0,0,0,1,0x45,0x4b,0x55,'U','K','E',0};
    constexpr char descriptor[]="root-selector-v2;userdata=f2fs,ext4,xfs,btrfs;slot=a,b;vrr-min=0,30";
    static_assert(sizeof(descriptor)==68);
    std::memcpy(note.data()+16,descriptor,sizeof(descriptor));
    std::vector<unsigned char> carry;
    size_t matches=0;
    uint64_t note_offset=0;
    for(;;) {
        const auto count=read_chunk(file.fd,chunk.data(),chunk.size()); if(!count)break;
        if(require_filesystems) {
            const auto base=stream.bytes-carry.size();
            carry.insert(carry.end(),chunk.data(),chunk.data()+count);
            auto found=carry.begin();
            while((found=std::search(found,carry.end(),note.begin(),note.end()))!=carry.end()) {
                ++matches;note_offset=base+static_cast<size_t>(found-carry.begin());++found;
            }
            // Less than one complete note cannot be counted twice between chunks.
            if(carry.size()>=note.size())carry.erase(carry.begin(),carry.end()-(note.size()-1));
        }
        stream.add(chunk.data(),count,boot_bytes);
    }
    need(stream.bytes==boot_bytes,"Expected the Uke 96 MiB boot partition payload");
    const auto *p=stream.prefix.data();
    need(!std::memcmp(p,"ANDROID!",8) && le32(p+20)==1584 && le32(p+40)==4,"Expected Android boot v4");
    need(le32(p+12)==0 && le32(p+1580)==0,"Ramdisk/signature fields must be empty");
    need(le32(p+8)>=64 && le32(p+8)<=boot_bytes-4096,"Kernel exceeds the boot image");
    need(std::memchr(p+44,0,1536),"Unterminated boot command line");
    const std::string command(reinterpret_cast<const char*>(p+44));
    need(command=="senemos.root=userdata" || command=="senemos.root=userdata msm.o82_vrr_test_min_hz=30",
         "Expected the exact userdata root selector and reviewed VRR policy");
    need(le32(p+4096+56)==0x644d5241,"Expected a raw ARM64 Image");
    if(require_filesystems)need(matches==1 && note_offset>=4096 && note_offset%4==0 &&
         note_offset+note.size()<=4096+uint64_t(le32(p+8)),"Boot Image lacks a unique four-filesystem root capability");
    stream.digest.check(hash);
}
}
int main(int argc,char **argv) {
    try {
        need(argc==6 || argc==7,"Usage: check-userdata-payload ROOT_ZST RAW_BYTES ROOT_SHA256 BOOT_IMG BOOT_SHA256 [f2fs|ext4|xfs|btrfs]");
        const std::string filesystem=argc==7?argv[6]:"f2fs";
        need(filesystem=="f2fs" || filesystem=="ext4" || filesystem=="xfs" || filesystem=="btrfs","Unsupported root filesystem");
        const auto size=number(argv[2]); root(argv[1],size,argv[3],filesystem); boot(argv[4],argv[5],filesystem!="f2fs");
        std::cout<<"{\"verified\":true,\"root_filesystem\":\""<<filesystem<<"\",\"root_bytes\":"<<size
                 <<",\"root_partition\":\"userdata\",\"device_write\":false,\"hardware_tested\":false}\n";
    } catch(const std::exception &error) { std::cerr<<error.what()<<'\n'; return 1; }
}
