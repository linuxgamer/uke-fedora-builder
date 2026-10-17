#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/root/usr/lib/systemd/system" \
    "$fixture/root/usr/share/wayland-sessions"
cat > "$fixture/bin/rpm" <<'EOF'
#!/bin/sh
case " $* " in
    *' kde-plasma-uke-meta '*|*' sddm '*) [ "$MOCK_VARIANT" = kde ];;
    *' gnome-uke-meta '*|*' gdm '*) [ "$MOCK_VARIANT" = gnome ];;
    *) exit 1;;
esac
EOF
chmod +x "$fixture/bin/rpm"
check() { PATH="$fixture/bin:$PATH" MOCK_VARIANT=$1 bash "$root/src/boot-pair/check-desktop-variant.sh" "$fixture/root" "$1"; }
reject() { if check "$1" >/dev/null 2>&1; then echo 'Invalid desktop root accepted' >&2; exit 1; fi; }
touch "$fixture/root/usr/lib/systemd/system/sddm.service"
touch "$fixture/root/usr/share/wayland-sessions/plasma.desktop"
check kde
reject gnome
touch "$fixture/root/usr/share/wayland-sessions/gnome.desktop"
reject kde
rm "$fixture/root/usr/share/wayland-sessions/plasma.desktop"
touch "$fixture/root/usr/lib/systemd/system/gdm.service"
check gnome
rm "$fixture/root/usr/lib/systemd/system/gdm.service"
reject gnome
echo 'Desktop session and manager admission contracts passed'
