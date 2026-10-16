#!/bin/sh
# Local development access deliberately enabled in this owner-test image.
dmesg -n 4
printf '\nFedora 44 on Uke — local development terminal\n'
printf 'Kernel: '; uname -r
printf 'Root: '; findmnt -n -o SOURCE,FSTYPE /
printf 'This shell is on the Fedora root partition.\n\n'
export PS1='Fedora Uke:\w# '
exec /usr/bin/bash --noprofile --norc -i
