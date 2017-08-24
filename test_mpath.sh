#! /bin/bash

ME=$(basename $0)
MYDIR=$(cd "$(dirname $0)" && pwd)
. $MYDIR/err_handler.sh
. $MYDIR/cleanup_lib.sh
set -E

# mpath name
: ${MPATH:=3600601600a3020002282d7e2c5a6e411}
: ${DEBUGLVL:=2}
: ${UUID_PATTERN:=54f41f67-bd36-%s-%04x-0966d6a9c810}
: ${VG:=tm_vg}
# Partitions to create. All parts will have equal size
: ${FS_TYPES:="ext2 xfs lvm"}
# LVs to create. All LVs will have equal size
: ${LV_TYPES:="ext2 btrfs"}

HEXPID=$(printf %04x $$)
PVS=()
LVS=()
MOUNTPOINTS=()
N_PARTS=0
N_FS=0
N_LVS=0

msg() {
    [[ $1 -lt $DEBUGLVL ]] && return
    shift
    echo "== $ME: $*" >&2;
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
    [[ $1 ]]
    multipathd show paths format "%m %d" | sed -n "s/$1 //p" | sort
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

start_monitor() {
    # arg $1: output file
    [[ $1 ]]
    [[ -z "$_MONITOR_PID" && -z "$_MONITOR_CLEAN" ]]
    udevadm monitor --env -s block >& "$TMPD"/$1 &
    _MONITOR_PID=$!
    push_cleanup stop_monitor
}

stop_monitor() {
    [[ $_MONITOR_PID ]] || return 0
    kill $_MONITOR_PID
    unset _MONITOR_PID
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

    msg 2 wiping partition table on $1
    sgdisk --zap-all $DMDEV &>/dev/null
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
	    echo mkpart tm${HEXPID}p${i}$p $type $begin $end
	    echo $more
	    begin=$end
	    end=$((end+sz/n))
	    [[ $end -eq $sz ]] && end=-1s
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
	    pvcreate -q -u $uuid --norestorefile $pdev
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

    vgcreate -q $VG "${PVS[@]}"
    push_cleanup vgremove -q -f $VG
    
    while [[ $# -gt 0 ]]; do
	N_FS=$((N_FS+1))
	name=lv_${N_FS}_$1
	lvcreate -q -y -n $name -l ${sz}%FREE $VG
	push_cleanup lvremove -q -f /dev/$VG/$name
	LVS[${#LVS[@]}]=$name
	create_fs /dev/$VG/$name $1
	shift
    done
}

prepare() {
    delete_slaves $DMDEV $DEVNO

    start_monitor udev_prep.log

    create_parts $DMDEV $DEVSZ_MiB $FS_TYPES
    create_filesystems $MPATH $FS_TYPES
    create_lvs $LV_TYPES
    
    stop_monitor
}

TMPD=$(mktemp -d /tmp/$ME-XXXXXX)
push_cleanup rm -rf "$TMPD"
msg 1 temp dir is $TMPD

DMDEV=$(get_dmdev $MPATH)
DMNAME=${DMDEV#/dev/}
DEVNO=$(get_devno $DMDEV)
[[ -b $DMDEV ]]
DEVSZ_MiB=$(($(blockdev --getsz /dev/dm-2)/2048))
[[ $DEVSZ_MiB -gt 1 ]]

PATHS=($(get_path_list "$MPATH"))
[[ ${#PATHS[@]} -gt 0 ]]

msg 2 Checking mpath $MPATH with ${#PATHS[@]} paths: ${PATHS[@]}

prepare

SLAVES="$(get_slaves_rec $DEVNO)"
#msg 2 monitor output:
#cat $TMPD/udev_prep.log
msg 2 new slaves: "$SLAVES"

#for slv in $SLAVES; do
#    msg 2 symlinks for $slv:
#    for sl in $(get_symlinks $(get_dmdev $slv)); do
#	ls -l /dev/$sl
#    done
#done

msg 2 mounted file systems:
grep tm${HEXPID} /proc/mounts

for mp in ${MOUNTPOINTS[@]}; do
    grep -q /tmp/$mp /proc/mounts && continue
    msg 2 manually mounting $mp
    systemctl start tmp-$mp.mount
done

msg 2 mounted file systems now:
grep tm${HEXPID} /proc/mounts

msg 5 hit key:
read _a

exit 0

sleep 1

for path in ${PATHS[@]}; do
    msg 2 removing $path
    multipathd remove path $path
    sleep 1
done

multipathd show topology

for path in ${PATHS[@]}; do
    msg 2 adding $path
    multipathd add path $path
    sleep 1
done

multipathd show topology

stop_monitor

cat "$TMPD"/udev-monitor.log
