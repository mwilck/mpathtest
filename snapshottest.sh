#! /bin/bash

CLEANUP=:
trap 'eval "$CLEANUP"' 0
trap 'echo error in $BASH_COMMAND >&2; exit 1' ERR
exec &> script.log

sholinx() {
	lvs	
	for x in /dev/mapper/vg*; do 
		dv=$(basename $(readlink $x))
		dmsetup table $x
		dmsetup info $x
        	udevadm info $x
		set +x
		ls -l /dev/mapper/* /dev/disk/by-id/* /dev/disk/by-uuid/* /dev/disk/by-label/* | egrep $dv
		set -x
	done
}

set -x

tar cfJ rules.tart.xz /usr/lib/udev/rules.d/{10,11,13,56,60,66}-*.rules /etc/udev/rules.d/*

dd=$(date +"%Y-%m-%d %H:%M:%S")
udevadm monitor --env -s block &>udevadm.log &
upid=$!
CLEANUP='kill $upid;'"$CLEANUP"
udevadm control -l debug
CLEANUP='udevadm control -l err;'"$CLEANUP"

sholinx

lvcreate -n snap -s /dev/vg/target1 -L 1G

sleep 1
sholinx

udevadm test -a change /block/dm-19
udevadm test -a change /block/dm-24

sleep 1
lvremove -y /dev/vg/snap

sleep 1
sholinx

journalctl --since "$dd" &>journal.log

