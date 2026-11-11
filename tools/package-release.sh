#!/usr/bin/env bash
# Package verified image pairs into release archives with a clean checksum file.
set -Eeuo pipefail

die() { printf 'package-release: %s\n' "$*" >&2; exit 1; }
usage() {
    cat >&2 <<'USAGE'
Usage: package-release.sh --tag TAG --output DIR [--twrp FILE] PAIR_DIR...

Each pair directory must contain fedora_boot.img, userdata.img, manifest.json
and PROFILE-ID. The archive gets its own SHA256SUMS covering exactly the three
shipped files; the output directory gets an outer SHA256SUMS covering the
archives (and the optional TWRP archive).
USAGE
    exit 2
}

tag=''
output=''
twrp=''
pairs=()
while (($#)); do
    case $1 in
        --tag) (($# >= 2)) || usage; tag=$2; shift 2;;
        --output) (($# >= 2)) || usage; output=$2; shift 2;;
        --twrp) (($# >= 2)) || usage; twrp=$2; shift 2;;
        -h|--help) usage;;
        -*) die "Unknown option: $1";;
        *) pairs+=("$1"); shift;;
    esac
done
[[ -n $tag && -n $output && ${#pairs[@]} -gt 0 ]] || usage
[[ $tag =~ ^[A-Za-z0-9._-]+$ ]] || die 'Invalid tag'
[[ ! -e $output ]] || die "Output already exists: $output"

mkdir -p "$output"
archives=()
seen=()
for pair in "${pairs[@]}"; do
    [[ -d $pair && ! -L $pair ]] || die "Missing pair directory: $pair"
    profile=$(cat "$pair/PROFILE-ID" 2>/dev/null) || die "Missing PROFILE-ID in $pair"
    [[ $profile =~ ^(tty|kde|gnome|phosh|plasma-mobile)$ ]] || die "Unexpected profile: $profile"
    [[ ! " ${seen[*]} " =~ " $profile " ]] || die "Duplicate profile: $profile"
    seen+=("$profile")
    for file in fedora_boot.img userdata.img manifest.json; do
        [[ -s $pair/$file && ! -L $pair/$file ]] || die "Missing $file in $pair"
    done
    stage=$(mktemp -d)
    cp -- "$pair/fedora_boot.img" "$pair/userdata.img" "$pair/manifest.json" "$stage/"
    (cd "$stage" && sha256sum fedora_boot.img userdata.img manifest.json > SHA256SUMS &&
        sha256sum -c --status SHA256SUMS) || { rm -rf -- "$stage"; die "Checksum failure in $pair"; }
    archive=$output/fedora-44-uke-$tag-$profile.tar.zst
    tar --zstd -cf "$archive" -C "$stage" .
    rm -rf -- "$stage"
    archives+=("$(basename "$archive")")
    printf 'Packaged %s from %s\n' "$(basename "$archive")" "$pair"
done

twrp_name=''
if [[ -n $twrp ]]; then
    [[ -s $twrp && ! -L $twrp ]] || die "Missing TWRP archive: $twrp"
    twrp_name=twrp_recovery_ab.tar.zst
    cp -- "$twrp" "$output/$twrp_name"
fi

if [[ -n $twrp_name ]]; then
    (cd "$output" && sha256sum "${archives[@]}" "$twrp_name" > SHA256SUMS)
else
    (cd "$output" && sha256sum "${archives[@]}" > SHA256SUMS)
fi
printf 'Release archives and outer SHA256SUMS are in %s\n' "$output"
