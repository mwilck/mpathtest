#! /bin/bash

ME=$(basename $0)
MYDIR=$(cd "$(dirname $0)" && pwd)
. $MYDIR/err_handler.sh
. $MYDIR/cleanup_lib.sh
set -E

# mpath name
#: ${MPATH:=3600601600a3020002282d7e2c5a6e411}
: ${MPATH:=}
: ${DEBUGLVL:=2}
: ${UUID_PATTERN:=54f41f67-bd36-%s-%04x-0966d6a9c810}
: ${VG:=tm_vg}
# Partitions to create. All parts will have equal size
: ${FS_TYPES:="ext2 xfs lvm"}
# LVs to create. All LVs will have equal size
: ${LV_TYPES:="ext2 btrfs"}
# debug levels for multipathd (0-5) and udev (err, info, debug)
: ${MULTIPATHD_DEBUG:=0}
: ${UDEV_DEBUG:=err}

PVS=()
LVS=()
MOUNTPOINTS=()
HOSTS=()
HEXPID=$(printf %04x $$)
N_PARTS=0
N_FS=0
N_LVS=0

timestamp() {
    local x=$(date +%H:%M:%S.%N)
    echo ${x:0:-3}
}

msg() {
    [[ $1 -gt $DEBUGLVL ]] && return
    shift
    echo "$*" >&2;
    [[ ! -e /proc/self/fd/5 ]] || echo "$(timestamp) $*" >&5;
}

add_to_set() {
    # arg $1: string
    # arg $2: array variable
    local var=$2 x
    eval "for x in \${$var[@]}; do [[ x\"\$x\" != x\"\$1\" ]] || return 0; done"
    eval "$var[\${#$var[@]}]=\$1"
}

get_dmdev() {
    # arg $1: device mapper name
    [[ $1 && -b /dev/mapper/$1 ]]
    readlink -f /dev/mapper/$1
}

get_devno() {
    # arg $1: dm device
    [[ $1 && -b $1 ]]
    dmsetup info -c -o major,minor --noheadings $1
}

get_path_list() {
    # arg $1: multipath map name
    # output: list of hwids e.g. scsi-1:0:0:8
    local pts dbl
    [[ $1 ]]
    pts="$(multipathd show paths format "%m %i" | sed -n "s/$1 /scsi-/p" | sort)"
    dbl=$(uniq -d <<< "$pts")
    [[ ! $dbl ]] || {
	msg 1 Error: duplicate paths in $1: $dbl; false
    }
    echo "$pts"
}

get_symlinks() {
    # arg $1: dm device name dm-$X
    [[ $1 ]]
    cd /dev
    find . -type l -ls  | \
	sed -n /"${1#/dev/}"'$/s,^.*\./\([^[:space:]]*\)[[:space:]].*$,\1,p'
    cd - >/dev/null
}

get_slaves() {
    # arg $1: dm device in major:minor format
    [[ $1 ]]
    dmsetup table | sed -n /" $1 "'/s/: .*//p'
}

get_slaves_rec() {
    # arg $1: dm device in major:minor format
    local slaves slv dn children=""
    [[ $1 ]]
    slaves="$(get_slaves $1)"
    for slv in $slaves; do
	dn=$(get_devno /dev/mapper/$slv)
	children="$children
$(get_slaves_rec $dn)"
    done
    echo "$slaves$children"
}

block_to_sysfsdir() {
    # arg $1: disk device e.g. sdc
    readlink -f /sys/block/$1/device
}

sysfsdir_to_scsi_hctl() {
    # arg $1: sysfs device dir
    [[ -d $1/scsi_disk ]] || return 0
    basename $1
}

block_to_scsi_hctl() {
    # arg $1: disk device e.g. sdc
    sysfsdir_to_scsi_hctl $(block_to_sysfsdir $1)
}

scsi_hctl_to_sysfsdir() {
    # arg $1: hctl e.g. 7:0:0:1
    readlink -f /sys/class/scsi_device/$1/device
}

scsi_hctl_to_block() {
    # arg $1: hctl e.g. 7:0:0:1
    # this errors out if there are multiple entries
    local bl=$(basename $(scsi_hctl_to_sysfsdir $1)/block/*)
    # this errors out if sysfs dir doesn't exist
    [[ $bl != "*" ]]
    echo $bl
}

block_to_devno() {
    # arg $1: disk device e.g. sdc
    cat /sys/class/block/$1/dev
}

sysfsdir_to_scsihost() {
    # arg $1: sysfs device dir
    local d=$1
    while [[ $d && $d != / && ! -d $d/scsi_host ]]; do
	d=$(dirname $d)
    done
    d=$d/scsi_host/$(basename $d)
    [[ -d $d ]]
    echo $d
}
    
_make_scsi_scripts() {
    # arg $1: scsi hctl e.g. 7:0:0:1
    # side effect: populates HOSTS
    local sd hctl host x
    sd=$(scsi_hctl_to_sysfsdir $1)
    [[ $sd && -d $sd ]] || return 0 # not a scsi device
    hctl=${1//:/ }
    host=$(sysfsdir_to_scsihost $sd)
    echo "echo offline >$sd/state" >$TMPD/offline-scsi-$1
    echo "echo running >$sd/state" >$TMPD/online-scsi-$1
    echo "echo 1 >$sd/delete" >$TMPD/remove-scsi-$1
    echo "echo ${hctl#* } >$host/scan" >$TMPD/add-scsi-$1
    add_to_set $host HOSTS
}

_make_disk_scripts() {
    # arg $1: hw id e.g. scsi-7:0:0:1
    # SCSI device names may change
    local bl bd
    case $1 in
	scsi-*)
	    bl="\$(scsi_hctl_to_block ${1#scsi-})"
	    eval "bd=$bl"
	    _make_scsi_scripts ${1#scsi-}
	    ;;
	*)
	    msg 1 unkown hw type: $1
	    false
	    ;;
    esac
    echo multipathd add path "$bl" "# $bd=$1" >$TMPD/mp-add-$1
    echo multipathd remove path "$bl" >$TMPD/mp-remove-$1
    echo multipathd fail path $bl >$TMPD/mp-fail-$1
    echo multipathd reinstate path $bl >$TMPD/mp-reinstate-$1
}

make_disk_scripts() {
    # args: list of hwids e.g. scsi-2:0:0:2
    local x
    while [[ $# -gt 0 ]]; do
	_make_disk_scripts $1
	shift
    done
    for x in $TMPD/*-scsi-*; do
	msg 5 $x
	msg 5 $(cat $x)
    done
}

action() {
    # arg $1: add, remove, offline, online
    # arg $2: disk, e.g. sdn
    local script=$TMPD/$1-${2#/dev/}
    [[ -f $script ]]
    msg 3 $1 $2
    source $script
}

create_monitor_service() {
    local serv=/etc/systemd/system/tm-udev-monitor@.service
    [[ ! -f $serv ]] || return 0
    cat >$serv <<\EOF
[Unit]
Description=Udev monitor for multipath test
Requires=systemd-udevd.service
After=systemd-udevd.service

[Service]
Type=simple
ExecStart=/usr/bin/udevadm monitor -s %i --env

[Install]
WantedBy=multi-user.target
EOF
}

stop_monitor() {
    systemctl stop tm-udev-monitor@block.service
}

start_monitor() {
    create_monitor_service
    push_cleanup stop_monitor
    systemctl start tm-udev-monitor@block.service
}

debug_multipathd() {
    # arg $1: "on" or "off"
    [[ $MULTIPATHD_DEBUG -gt 0 ]] || return 0
    if [[ x$1 = xon ]]; then
	msg 4 setting verbose level $MULTIPATHD_DEBUG for multipathd
	mkdir -p /etc/systemd/system/multipathd.service.d
	cat >/etc/systemd/system/multipathd.service.d/debug.conf <<EOF
[Service]
ExecStart=
ExecStart=/sbin/multipathd -d -s -v$MULTIPATHD_DEBUG
EOF
    else
	rm -f /etc/systemd/system/multipathd.service.d/debug.conf
    fi
    systemctl daemon-reload
    msg 3 restarting multipathd
    systemctl restart multipathd
}

debug_udev() {
    # arg $1: "on" or "off"
    if [[ x$1 = xon && x$UDEV_DEBUG != xerr ]]; then
	msg 4 setting debug level $UDEV_DEBUG for udev
	udevadm control -l $UDEV_DEBUG
    else
	udevadm control -l err
    fi
}

delete_slaves() {
    # arg $1: dm device /dev/dm-$X
    # arg $2: dm device in major:minor format
    local slaves slv
    [[ $1 && $2 && -b $1 ]]
    slaves=$(get_slaves $2)
    for slv in $slaves; do
	msg 2 old slave $slv will be deleted
    done
    
    kpartx -d $1
    slaves=$(get_slaves $2)
    for slv in $slaves; do
	dmsetup remove /dev/mapper/$slv
    done

}

create_parts() {
    # arg $1: dm device /dev/dm-$X
    # arg $2: device size in MiB
    # further args: partition types recognized by parted, or "lvm"
    [[ $1 && $2 && -b $1 ]]
    local dev=$1 sz=$2
    local p n i begin end type more
    shift; shift

    n=$#
    {
	echo unit MiB
	echo mklabel gpt
	i=0
	begin=1
	end=$((sz/n))
	for p in "$@"; do
	    i=$((i+1))
	    case $p in
		lvm) type=ext2
		     more="set $i LVM on"
		     ;;
		*) type=$p
		   more=
		   ;;
	    esac
	    end=$((begin+sz/n-1))
	    [[ $end -lt $sz ]] || end=-1
	    echo mkpart tm${HEXPID}p${i}$p $type $begin $end
	    echo $more
	    begin=$end
	done
    } >$TMPD/parted.cmd

    N_PARTS=$n
    parted $dev <$TMPD/parted.cmd &>/dev/null
    kpartx -a -p -part $dev 

}

fstab_entry() {
    # arg $1: fs type
    # arg $2: label
    # arg $3: uuid
    mkdir -p "/tmp/$2"
    push_cleanup rmdir "/tmp/$2"
    push_cleanup umount -l "/tmp/$2"
    MOUNTPOINTS[${#MOUNTPOINTS[@]}]="$2"
    push_cleanup systemctl daemon-reload
    if [[ $((${#MOUNTPOINTS[@]} % 2)) -eq 0 ]]; then
	echo LABEL=$2 /tmp/$2 $1 defaults 0 0 >>/etc/fstab
	push_cleanup sed -i "/LABEL=$2/d" /etc/fstab
    else
	echo UUID=$3 /tmp/$2 $1 defaults 0 0 >>/etc/fstab
	push_cleanup sed -i "/UUID=$3/d" /etc/fstab
    fi
    systemctl daemon-reload
    usleep 100000
}

run_lvm() {
    "$@" 5>&-
}

create_fs() {
    # arg $1: device to create FS on
    # arg $2: fs type or "lvm"
    local pdev=$1 fs=$2
    local uuid label
    
    [[ $pdev && $fs && -b $pdev ]]
    
    uuid=$(printf $UUID_PATTERN $HEXPID $N_FS)
    [[ ! -e /dev/disk/by-uuid/$uuid ]]

    label=tm${HEXPID}p${N_FS}$fs
    msg 2 creating $fs on $pdev, label $label, uuid $uuid
    case $fs in
	ext2)
	    fstab_entry ext4 $label $uuid
	    mke2fs -F -q -t ext4 -L $label -U $uuid $pdev
	    ;;
	xfs)
	    fstab_entry xfs $label $uuid
	    mkfs.xfs -f -q -L $label $pdev
	    xfs_admin -U $uuid $pdev &>/dev/null
	    ;;
	btrfs)
	    fstab_entry btrfs $label $uuid
	    mkfs.btrfs -q -f -L $label -U $uuid $pdev
	    ;;
	lvm)
	    run_lvm pvcreate -q -u $uuid --norestorefile $pdev
	    PVS[${#PVS[@]}]=$pdev
	    ;;
    esac
}

create_filesystems() {
    # arg $1: multipath map name
    # further args: partition types recognized by parted, or "lvm"
    # (should match args of create_parts)
    local name=$1 pdev
    shift

    while [[ $# -gt 0 ]]; do
	N_FS=$((N_FS+1))
	pdev=/dev/mapper/$name-part$N_FS
	[[ -b $pdev ]]
	create_fs $pdev $1
	shift
    done
}

create_lvs() {
    # args: fs types to create
    local sz name
    [[ ${#PVS[@]} -gt 0 ]] || return

    N_LVS=$#
    sz=$((100/N_LVS))

    run_lvm vgcreate -q $VG "${PVS[@]}"
    push_cleanup vgremove -q -f $VG
    
    while [[ $# -gt 0 ]]; do
	N_FS=$((N_FS+1))
	name=lv_${N_FS}_$1
	run_lvm lvcreate -q -y -n $name -l ${sz}%FREE $VG
	push_cleanup lvremove -q -f /dev/$VG/$name
	LVS[${#LVS[@]}]=$name
	create_fs /dev/$VG/$name $1
	shift
    done
}

cleanup_paths() {
    # try to bring up all temporarily deleted or disabled paths again
    local act
    for act in $TMPD/add-* $TMPD/online-* $TMPD/mp-add-* $TMPD/mp-reinstate-*; do
	. $act
    done
}

prepare() {
    make_disk_scripts ${PATHS[@]}

    delete_slaves $DMDEV $DEVNO

    start_monitor

    msg 3 wiping partition table on $DMDEV
    sgdisk --zap-all $DMDEV &>/dev/null

    if [[ o$NO_PARTITIONS = oyes ]]; then
	FS_TYPES=lvm
	create_fs $DMDEV lvm
    else
	create_parts $DMDEV $DEVSZ_MiB $FS_TYPES
	create_filesystems $MPATH $FS_TYPES
    fi
    create_lvs $LV_TYPES
    push_cleanup cleanup_paths
}

SHORTOPTS=o:np:l:m:u:vth
LONGOPTS='output:,parts:,lvs,mp-debug:,udev-debug:,verbose,trace,help'
USAGE="
usage: $ME [options] mapname
       -h|--help		print help
       -o|--output		output directory (default: auto)
       -n|--no-partitions	don't create partitions (ignore -p)
       -p|--parts x,y,z		partition types (ext2, xfs, btrfs, lvm)
       -l|--lvs x,y,z		logical volumes (ext2, xfs, btrfs, lvm)
       -m lvl|--mp-debug lvl	set multipathd debug level
       -u lvl|--udev-debug lvl  set udev debug level
       -q|--quiet	   	decrease verbose level for script
       -v|--verbose 	   	increase verbose level for script
       -t|--trace	   	trace this script
"

usage() {
    msg 1 "$USAGE"
}

# This way we catch getopt errors, doesn't work with direct set command
OPTIONS=($(getopt -s bash -o "$SHORTOPTS" --longoptions "$LONGOPTS" -- "$@"))
set -- "${OPTIONS[@]}"
unset OPTIONS

TRACE=
NO_PARTITIONS=
while [[ $# -gt 0 ]]; do
    case $1 in
	-h|--help)
	    usage
	    exit 0
	    ;;
	-o|--output)
	    shift
	    eval "OUTD=$1"
	    ;;
	-n|--no-partitions)
	    NO_PARTITIONS=yes
	    ;;
	-p|--parts)
	    shift
	    eval "FS_TYPES=${1//,/ }"
	    ;;
	-l|--lvs)
	    shift
	    eval "LV_TYPES=${1//,/ }"
	    ;;
	-m|--mp-debug)
	    shift
	    eval "MULTIPATHD_DEBUG=$1"
	    ;;
	-u|--udev-debug)
	    shift
	    eval "UDEV_DEBUG=$1"
	    ;;
	-v|--verbose)
	    : $((++DEBUGLVL))
	    ;;
	-q|--quiet)
	    : $((--DEBUGLVL))
	    ;;
	-t|--trace)
	    TRACE=yes
	    ;;
	--)
	    shift
	    break
	    ;;
	-?|--*)
	    usage
	    exit 1
	    ;;
	*)
	    break
	    ;;
    esac
    shift
done
[[ $# -eq 1 ]] || { usage; exit 1; }
eval "MPATH=$1"

[[ $LV_TYPES || $FS_TYPES ]]
if [[ $LV_TYPES ]]; then
    case $FS_TYPES in
	*lvm*) ;;
	*) FS_TYPES="$FS_TYPES lvm";;
    esac
fi
[[ o$TRACE = oyes ]] && set -x

exec 5>&2
ERR_FD=5 # for err_handler

STARTTIME=$(date +"%Y-%m-%d %H:%M:%S")
: ${OUTD:="$PWD/logs-$ME-${STARTTIME//[ :]/_}"}
mkdir -p $OUTD

exec &> >(logger --id=$$ -t $ME)
TMPD=$(mktemp -d /tmp/$ME-XXXXXX)

push_cleanup rm -rf "$TMPD"
msg 1 output dir is $OUTD

push_cleanup journalctl -o short-precise --since '"$STARTTIME"' '>$OUTD/journal.log'
debug_multipathd on
push_cleanup debug_multipathd off
debug_udev on
push_cleanup debug_udev off

DMDEV=$(get_dmdev $MPATH)
DMNAME=${DMDEV#/dev/}
DEVNO=$(get_devno $DMDEV)
[[ -b $DMDEV ]]
DEVSZ_MiB=$(($(blockdev --getsz /dev/dm-2)/2048))
[[ $DEVSZ_MiB -gt 1 ]]

PATHS=($(get_path_list "$MPATH"))
[[ ${#PATHS[@]} -gt 0 ]]

msg 2 Checking mpath $MPATH with ${#PATHS[@]} paths: ${PATHS[@]}
msg 3 FS_TYPES: $FS_TYPES
msg 3 LV_TYPES: $LV_TYPES

prepare

SLAVES="$(get_slaves_rec $DEVNO)"
[[ -n "$SLAVES" ]]

#msg 2 monitor output:
#cat $TMPD/udev_prep.log
msg 2 new slaves: "$SLAVES"

#for slv in $SLAVES; do
#    msg 2 symlinks for $slv:
#    for sl in $(get_symlinks $(get_dmdev $slv)); do
#	ls -l /dev/$sl
#    done
#done

sleep 2
msg 2 mounted file systems: "$(grep tm${HEXPID} /proc/mounts)"
grep tm${HEXPID} /proc/mounts

for mp in ${MOUNTPOINTS[@]}; do
    grep -q /tmp/$mp /proc/mounts && continue
    msg 2 manually mounting $mp
    systemctl start tmp-$mp.mount
done

msg 2 mounted file systems: "$(grep tm${HEXPID} /proc/mounts)"

msg 1 hit key:
read _a

start_monitor remove-add

for path in ${PATHS[@]}; do
    action remove $path
    usleep 100000
done

multipathd show map $MPATH topology >&5
msg 2 mounted file systems: "$(grep tm${HEXPID} /proc/mounts)"

for path in ${PATHS[@]}; do
    action add $path
    usleep 100000
done

multipathd show map $MPATH topology >&5
msg 2 mounted file systems: "$(grep tm${HEXPID} /proc/mounts)"

