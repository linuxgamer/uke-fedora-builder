// SPDX-License-Identifier: MIT
// Host-only audit of the installed RPM inventory against the frozen root.
#include <charconv>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <set>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
namespace fs = std::filesystem;
int main(int argc, char **argv) {
    try {
        if (argc != 3) throw std::runtime_error("Usage: audit-languages ROOT RPM_FILE_INVENTORY");
        const auto root = fs::canonical(argv[1]);
        if (root == "/") throw std::runtime_error("Offline target root required");
        std::ifstream input(argv[2]);
        if (!input) throw std::runtime_error("Cannot read RPM file inventory");
        std::string line; size_t rows=0, localized=0, missing=0, shell=0, setup=0, login=0, docs=0;
        std::set<std::string> locales;
        while (std::getline(input, line)) {
            if (++rows > 2000000 || line.size()>16384) throw std::runtime_error("RPM inventory exceeds audit bounds");
            const auto first=line.find('\t'), second=line.find('\t', first==std::string::npos ? 0 : first+1);
            if (first==std::string::npos || second==std::string::npos) throw std::runtime_error("RPM inventory is not TSV");
            const auto path=line.substr(0,first), flags=line.substr(first+1,second-first-1), language=line.substr(second+1);
            const fs::path relative=fs::path(path).relative_path();
            if (path.empty() || path[0]!='/' || relative.lexically_normal()!=relative) throw std::runtime_error("Unsafe RPM path");
            unsigned bits=0; const auto parsed=std::from_chars(flags.data(), flags.data()+flags.size(), bits);
            if (parsed.ec!=std::errc{} || parsed.ptr!=flags.data()+flags.size()) throw std::runtime_error("Invalid RPM flags");
            if ((bits&64) || ((language.empty() || language=="(none)") && !path.starts_with("/usr/share/locale/"))) continue;
            if ((bits&2) || path.starts_with("/usr/share/doc/") || path.starts_with("/usr/share/man/") || path.starts_with("/usr/share/info/")) {
                ++docs; continue; // The compose omits documentation, including translated manuals.
            }
            ++localized;
            struct stat st{};
            if (lstat((root/relative).c_str(), &st)!=0) { ++missing; std::cerr<<"Missing locale file: "<<path<<'\n'; continue; }
            if (path.starts_with("/usr/share/locale/")) {
                const auto start=std::string("/usr/share/locale/").size(), end=path.find('/',start);
                if (end!=std::string::npos) locales.insert(path.substr(start,end-start));
                if (path.ends_with("/plasmashell.mo")) ++shell;
                if (path.ends_with("/org.kde.plasmasetup.mo")) ++setup;
                if (path.ends_with("/plasma_login.mo")) ++login;
            }
        }
        if (!input.eof() || rows<10000 || localized<1000 || missing || locales.size()<80 || shell<40 || setup<30 || login<30)
            throw std::runtime_error("Incomplete language payload or invalid RPM inventory");
        std::cout<<"{\"rpm_file_rows\":"<<rows<<",\"localized_paths\":"<<localized
            <<",\"missing_localized_paths\":0,\"localized_documentation_entries_omitted_by_policy\":"<<docs
            <<",\"locale_directories\":"<<locales.size()
            <<",\"plasmashell_catalogs\":"<<shell<<",\"plasma_setup_catalogs\":"<<setup
            <<",\"plasmalogin_catalogs\":"<<login<<"}\n";
    } catch (const std::exception &error) { std::cerr<<error.what()<<'\n'; return 1; }
}
