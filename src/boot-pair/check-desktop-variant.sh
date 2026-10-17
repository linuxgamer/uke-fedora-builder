#!/usr/bin/env bash
# Admit exactly the selected graphical session in a prepared Fedora root.
set -Eeuo pipefail
[[ $# == 2 && -d $1 ]] || exit 2
root=${1%/} variant=$2
case $variant in
    kde) own=kde-plasma-uke-meta other=gnome-uke-meta manager=sddm session=plasma;;
    gnome) own=gnome-uke-meta other=kde-plasma-uke-meta manager=gdm session=gnome;;
    *) exit 2;;
esac
rpm --root "$root" -q "$own" "$manager" >/dev/null
if rpm --root "$root" -q "$other" >/dev/null 2>&1; then
    echo "Unexpected $other in $variant root" >&2
    exit 1
fi
[[ -f $root/usr/lib/systemd/system/$manager.service ]] || {
    echo "Missing $manager display manager unit" >&2; exit 1;
}
shopt -s nullglob
sessions=("$root"/usr/share/wayland-sessions/*.desktop "$root"/usr/share/xsessions/*.desktop)
((${#sessions[@]})) || { echo 'Graphical root has no session' >&2; exit 1; }
found=0
for path in "${sessions[@]}"; do
    name=${path##*/}
    case $variant:$name in
        kde:*plasma*.desktop|gnome:*gnome*.desktop) found=1;;
        *) echo "Unexpected graphical session: $name" >&2; exit 1;;
    esac
done
((found)) || { echo "Missing $variant session" >&2; exit 1; }
