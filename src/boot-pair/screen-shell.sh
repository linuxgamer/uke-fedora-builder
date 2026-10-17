#!/bin/sh
# Local development access deliberately enabled in this owner-test image.
# Keep kernel diagnostics in the journal without overwriting the local shell.
dmesg -n 1
printf '\033[H\033[2J'
printf '\nFedora 44 on Uke — local development terminal\n'
printf 'Kernel: '; uname -r
printf 'Root: '; findmnt -n -o SOURCE,FSTYPE /
printf 'This shell is on the Fedora root partition.\n\n'
export PS1='Fedora Uke:\w# '
exec /usr/bin/bash --noprofile --norc -i
