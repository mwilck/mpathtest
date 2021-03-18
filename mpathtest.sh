#! /bin/bash

ME=$(basename $0)
MYDIR=$(cd "$(dirname $0)" && pwd)
. $MYDIR/err_handler.sh
. $MYDIR/cleanup_lib.sh
set -E

# mpath name
MPATHS=()
: ${PREFIX:=}
: ${DEBUGLVL:=2}
: ${UUID_PATTERN:=54f41f67-bd36-%s-%04x-0966d6a9c810}
: ${VG:=tm_vg}
# Partitions to create. All parts will have equal size
: ${FS_TYPES:="btrfs lvm"}
# LVs to create. All LVs will have equal size
: ${LV_TYPES:="ext2 xfs"}
# debug levels for multipathd (0-5) and udev (err, info, debug)
: ${MULTIPATHD_DEBUG:=2}
: ${UDEV_DEBUG:=err}
: ${SD_DEBUG:=err}
: ${MONITOR_OPTS:=}
: ${ITERATIONS:=1}
: ${TESTS:=}
: ${FIO_OPTS:=--rw=rw --time_based --runtime=3600 --ioengine=libaio --iodepth=16 --direct=1}

PVS=()
LVS=()
MOUNTPOINTS=()
HOSTS=()
HEXID=$(printf %04x $(($$ % 0x1000)))
N_PARTS=0
N_FS=0
N_LVS=0
STEP=0
PASSES=0
ERRORS=0
WARNINGS=0
SWAPS=
FIO_PIDS=()

timestamp() {
    local x=$(date +%H:%M:%S.%N)
    echo ${x:0:-3}
}

wait_for_input() {
    local _a
    msg 1 hit ENTER:
    read _a
}

msg() {
    [[ $1 -gt $DEBUGLVL ]] && return
    shift
    if [[ "$TERMINAL" ]]; then
	echo "$(timestamp) $*" >&2
    else
	 echo "$*" >&2;
	 [[ ! -e /proc/self/fd/5 ]] || echo "$(timestamp) $*" >&5
    fi
}

add_to_set() {
    # arg $1: string
    # arg $2: array variable
    local var=$2 x
    eval "for x in \${$var[@]}; do [[ x\"\$x\" != x\"\$1\" ]] || return 0; done"
    eval "$var[\${#$var[@]}]=\$1"
}

build_symlink_filter() {
    local filter= p d
    for p in ${PATHS[@]}; do
	# hwid_to_block may fail for missing devs
	d=$(hwid_to_block $p) || continue
	[[ $d ]] || continue
	case $p in
	    scsi-*) filter="$filter|$d[0-9]*";;
	esac
    done
    for p in ${MPATHS[@]} ${SLAVES[@]}; do
	d=$(dm_name_to_devnode $p)
	[[ $d ]] || continue
	filter="$filter|${d#/dev/}"
    done
    echo "(${filter#|})\$"
}

# This filter makes sure that we look only at devices that matter
# for our test.
BDEV_FILTER=
get_bdev_symlinks() {
    local link depth tgt rel id

    # We do not recalculate BDEV_FILTER between tests.
    # While block device names aren't persistent, we assume that
    # the SET of devices is. This allows us to see dangling links
    # to devices which may have been removed.
    [[ $BDEV_FILTER ]] || BDEV_FILTER="$(build_symlink_filter)"
    msg 3 gathering symlinks with filter "$BDEV_FILTER"
    cd /dev
    find . -name by-path -prune -o -name block -prune -o \
	 -type l -xtype b -printf "%h/%f %d %l\n" | \
	egrep "$BDEV_FILTER" | \
	# use depth (%d) to resolve symlink
	while read link depth tgt; do
	    rel=${tgt#../}
	    while [[ $rel != $tgt && $((depth--)) -gt 1 ]]; do
		tgt=$rel
		rel=${tgt#../}
	    done
	    [[ -b $tgt ]]
	    id=$(block_to_hwid $tgt) || true
	    [[ $id ]] || continue
	    echo ${link#./} $id
	done | sort
    cd - &>/dev/null
}

dm_name_to_devnode() {
    # arg $1: device mapper name
    [[ $1 && -b /dev/mapper/$1 ]]
    readlink -f /dev/mapper/$1
}

devnode_to_devno() {
    # arg $1: dm device
    local d
    [[ $1 && -b $1 ]]
    read d </sys/class/block/${1#/dev/}/dev
    [[ $d ]]
    echo $d
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

get_path_state() {
    # arg $1: multipath map name
    multipathd show paths format "%m %i %t %o %T" | sed -n "s/$1 //p" | sort
}

PATH_FILTER=
build_path_filter() {
    local p
    for p in ${PATHS[@]}; do
	case $p in
	    scsi-*)
		PATH_FILTER="$PATH_FILTER|${p#scsi-}"
		;;
	    *)
		msg 1 build_path_filter: $p is unsupported
		false
		;;
	esac
    done
    PATH_FILTER="(${PATH_FILTER#|})"
    msg 3 PATH_FILTER=$PATH_FILTER
}

get_path_state_all(){
    [[ $PATH_FILTER ]] || build_path_filter
    multipathd show paths format "%i %t %o %T" | egrep "$PATH_FILTER" | sort
}

get_symlinks() {
    # arg $1: dm device name dm-$X
    [[ $1 ]]
    cd /dev
    find . -type l -ls  | \
	sed -n /"${1#/dev/}"'$/s,^.*\./\([^[:space:]]*\)[[:space:]].*$,\1,p'
    cd - >/dev/null
}

get_multipath_maps() {
    dmsetup table | sed -n /" multipath "'/s/: .*//p'
}

get_opencount() {
    # arg $1: dm name
    dmsetup info -c -o open --noheadings /dev/mapper/$1
}

get_free_multipath_maps() {
    local maps mp

    maps=$(get_multipath_maps)
    for mp in $maps; do
	[[ $(get_opencount $mp) -gt 0 ]] || echo $mp
    done
}

get_slaves() {
    # arg $1: dm device name
    local devno
    [[ $1 ]]
    devno=$(devnode_to_devno $(dm_name_to_devnode $1))
    [[ $devno ]]
    dmsetup table | sed -n /" $devno "'/s/: .*//p'
}

get_slaves_rec() {
    # arg $1: dm device name
    local slaves slv children=""
    [[ $1 ]]
    slaves="$(get_slaves $1)"
    for slv in $slaves; do
	children="$children
$(get_slaves_rec $slv)"
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
    local bl=$(basename /sys/class/scsi_device/$1/device/block/*)
    # this errors out if sysfs dir doesn't exist
    [[ "$bl" != "*" ]] || return 1
    echo $bl
}

block_to_devno() {
    # arg $1: disk device e.g. sdc
    cat /sys/class/block/$1/dev 2>/dev/null
}

block_to_dm_name() {
    # arg $1: block device e.g. dm-1
    cat /sys/class/block/$1/dm/name 2>/dev/null
}

block_to_dm_uuid() {
    # arg $1: block device e.g. dm-1
    cat /sys/class/block/$1/dm/uuid 2>/dev/null
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

hwid_to_block() {
    # arg $1: hwid e.g. scsi-8:0:0:3
    case $1 in
	scsi-*)
	    scsi_hctl_to_block ${1#scsi-};;
	*)
	    msg 1 unkown hw type: $1; false;;
    esac
}

block_to_hwid() {
    # arg $1: block dev e.g. sdc
    local hwid parent
    hwid=$(block_to_scsi_hctl $1) || true
    if [[ $hwid ]]; then
	echo scsi-$hwid
	return 0
    fi
    hwid=$(block_to_dm_name $1) || true
    if [[ $hwid ]]; then
	echo dm-name-$hwid
	return 0
    fi
    if [[ -e /sys/class/block/$1/partition ]]; then
	read part </sys/class/block/$1/partition
	parent=$(basename $(dirname $(readlink /sys/class/block/$1)))
	hwid=$(block_to_hwid $parent)
	if [[ $hwid ]]; then
	    echo $hwid-part$part
	    return 0
	fi
    fi
    return 1
}

kernel_path_states() {
    local p
    for p in ${PATHS[@]}; do
	source $TMPD/status-$p
    done
}

_scsi_path_state() {
    # arg $1: scsi device hctl e.g. 7:0:0:1
    local sd=/sys/class/scsi_device/$1/device
    if [[ -f $sd/state ]]; then
	echo $1: $(cat $sd/state):$(cat $sd/dh_state 2>&-):$(cat $sd/access_state 2>&-)
    else
	echo $1: missing
    fi
}

_make_scsi_scripts() {
    # arg $1: scsi hctl e.g. 7:0:0:1
    # side effect: populates HOSTS
    local sd hctl host x
    sd=$(scsi_hctl_to_sysfsdir $1)
    [[ $sd && -d $sd ]] || return 0 # not a scsi device
    hctl=${1//:/ }
    host=$(sysfsdir_to_scsihost $sd)
    echo "_scsi_path_state $1" >$TMPD/status-scsi-$1
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
    bl="\$(hwid_to_block $1)"
    eval "bd=$bl"
    case $1 in
	scsi-*)
	    _make_scsi_scripts ${1#scsi-}
	    ;;
	*)
	    msg 1 unsupported blockdev type: $1; false
	    ;;
    esac
    echo "multipathd add path $bl >/dev/null" >$TMPD/mp-add-$1
    echo "multipathd remove path $bl >/dev/null" >$TMPD/mp-remove-$1
    echo "multipathd fail path $bl >/dev/null" >$TMPD/mp-fail-$1
    echo "multipathd reinstate path $bl >/dev/null" >$TMPD/mp-reinstate-$1
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

set_monitor_opts() {
    # arg $1: set of udev monitor options, comma separated, or "off"
    MONITOR_OPTS=
    [[ $1 != off ]] || return 0
    set -- ${1//,/ }
    while [[ $# -gt 0 ]]; do
	if [[ ${#1} -eq 1 ]]; then
	    MONITOR_OPTS="$MONITOR_OPTS -$1"
	else
	    MONITOR_OPTS="$MONITOR_OPTS --$1"
	fi
	shift
    done
}

create_monitor_service() {
    local serv=/etc/systemd/system/tm-udev-monitor@.service
    [[ ! -f $serv ]] || return 0
    cat >$serv <<EOF
[Unit]
Description=Udev monitor for multipath test
Requires=systemd-udevd.service
After=systemd-udevd.service

[Service]
Type=simple
ExecStart=/usr/bin/udevadm monitor -s %i $MONITOR_OPTS

[Install]
WantedBy=multi-user.target
EOF
    push_cleanup rm -f $serv
}

stop_monitor() {
    systemctl stop tm-udev-monitor@block.service
}

start_monitor() {
    [[ $MONITOR_OPTS ]] || return 0
    create_monitor_service
    push_cleanup stop_monitor
    reload_systemd
    msg 3 starting udev monitor, options $MONITOR_OPTS
    systemctl start tm-udev-monitor@block.service
}

restart_multipathd() {
    # arg $1: "on" or "off"
    if [[ x$1 = xon ]]; then
	msg 4 setting verbose level $MULTIPATHD_DEBUG for multipathd
	mkdir -p /etc/systemd/system/multipathd.service.d
	cat >/etc/systemd/system/multipathd.service.d/test.conf <<EOF
[Service]
ExecStart=
Environment=LD_LIBRARY_PATH=$LIBDIR
ExecStart=$BINDIR/multipathd -d -s ${MULTIPATHD_DEBUG:+-v$MULTIPATHD_DEBUG}
EOF
    else
	rm -f /etc/systemd/system/multipathd.service.d/test.conf
    fi
    reload_systemd
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

reload_systemd() {
    if [[ $SD_DEBUG = xerr ]]; then
	systemctl daemon-reload
    else
	systemd-analyze set-log-level err
	systemctl daemon-reload
	systemd-analyze set-log-level $SD_DEBUG
    fi
}

debug_systemd() {
    # arg $1: "on" or "off"
    if [[ x$1 = xon && x$SD_DEBUG != xerr ]]; then
	msg 4 setting debug level $SD_DEBUG for systemd
	systemd-analyze set-log-level $SD_DEBUG
    else
	systemd-analyze set-log-level err
    fi
}

delete_slaves() {
    # arg $1: dm device name
    local slaves slv dev

    [[ $1 ]]
    dev=$(dm_name_to_devnode $1)
    [[ $dev && -b $dev ]]
    slaves=$(get_slaves $1)
    for slv in $slaves; do
	# refuse deleting slaves that are in use
        [[ $(get_opencount $slv) -eq 0 ]]
	msg 2 old slave $slv will be deleted
    done

    kpartx -v -d $dev
    slaves=$(get_slaves $1)
    for slv in $slaves; do
	dmsetup remove /dev/mapper/$slv
    done
    # don't continue if still open
    [[ $(get_opencount $1) -eq 0 ]]
}

check_parts() {
    # arg $1: dm name
    # arg $2: number of partitions
    local i=0
    while [[ $((++i)) -le $n ]]; do
	[[ -b /dev/mapper/$1-part$i ]] || return 1
    done
    return 0
}

WAIT_FOR_PARTS=5
wait_for_parts() {
    # arg $1: dm name
    # arg $2: number of partitions
    local end=$(($(date +%s) + WAIT_FOR_PARTS))

    while ! check_parts $1 $2; do
	usleep 100000
	[[ $(date +%s) -le $end ]] || {
	    msg 0 timeout waiting for partitions on $1;
	    msg 1 hit key
	    read a
	    return 1
	}
    done
    return 0
}

start_fio_on_part() {
    # arg #1: block device
    local dev=$1 n

    [[ $FIO ]] || return
    n=${#FIO_PIDS[@]}
    fio --name=fio$$_$n --filename=$dev $FIO_OPTS &>$OUTD/fio_$n.log &
    pid=$!
    FIO_PIDS[$n]=$pid
    msg 2 started fio on device $dev as $pid
    push_cleanup "kill -TERM $pid"
}

create_parts() {
    # arg $1: dm name
    # arg $2: dm device /dev/dm-$X
    # arg $1: device size in MiB
    # further args: partition types recognized by parted, or "lvm"
    [[ $2 && $3 && -b $2 ]]
    local map=$1 dev=$2 sz=$3
    local p n i begin end type more pt lbl po
    shift; shift; shift

    n=$#
    {
	echo unit MiB
	echo mklabel gpt
	i=0
	begin=1
	end=$((sz/n))
	for p in "$@"; do
	    i=$((i+1))
	    more=
	    case $p in
		lvm)
		    type=ext2
		    more="set $i LVM on"
		    ;;
		raw|none)
		    type=ext2
		    ;;
		swap)
		    type=linux-swap
		    ;;
		*)
		    type=$p
		    ;;
	    esac
	    end=$((begin+sz/n-1))
	    lbl=tm${HEXID}p$((++N_PARTS))$p
	    [[ $end -lt $sz ]] || end=-1
	    echo mkpart $lbl $type $begin $end
	    echo $more
	    begin=$end
	done
	echo quit
    } >$TMPD/parted.cmd

    msg 4 parted commands: "
$(cat $TMPD/parted.cmd)"

    # parted blows binary blobs to stderr
    po=$(parted $dev <$TMPD/parted.cmd 2>&1)
    msg 4 parted output: "
$po"

    pt=$(parted -s $dev unit MiB print | grep '^ *[0-9]' || true)
    msg 3 created partition table: "
$pt"
    [[ $(wc -l <<< "$pt") -eq $n ]] || {
	msg 1 error in parted, not all partitions were created; false
    }

    push_cleanup kpartx -d $dev
    wait_for_parts $map $n
}

clear_parts() {
    # arg $1: dm device name
    # Make sure no symlinks to paths remain after run
    # these may mess up results in next run
    local p b
    sgdisk --zap-all /dev/mapper/$1 &>/dev/null
    for p in ${PATHS[@]}; do
	b=$(hwid_to_block $p) || true
	[[ $b && -b /dev/$b ]] || continue
	partprobe /dev/$b
    done
}

fstab_entry() {
    # arg $1: fs type
    # arg $2: label
    # arg $3: uuid
    mkdir -p "/tmp/$2"
    push_cleanup rmdir "/tmp/$2"
    case $1 in
	swap)
	    push_cleanup swapoff UUID=$uuid
	    ;;
	*)
	    MOUNTPOINTS[${#MOUNTPOINTS[@]}]="$2"
	    push_cleanup umount -l "/tmp/$2"
	    ;;
    esac
    push_cleanup reload_systemd
    if [[ $((${#MOUNTPOINTS[@]} % 2)) -eq 0 ]]; then
	echo LABEL=$2 /tmp/$2 $1 defaults 0 0 >>/etc/fstab
	push_cleanup sed -i "/LABEL=$2/d" /etc/fstab
    else
	echo UUID=$3 /tmp/$2 $1 defaults 0 0 >>/etc/fstab
	push_cleanup sed -i "/UUID=$3/d" /etc/fstab
    fi
    reload_systemd
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

    uuid=$(printf $UUID_PATTERN $HEXID $N_FS)
    [[ ! -e /dev/disk/by-uuid/$uuid ]]

    label=tm${HEXID}p${N_FS}$fs
    [[ ! -e /dev/disk/by-label/$label ]]

    msg 3 creating $fs on $pdev, label $label, uuid $uuid
    case $fs in
	ext2)
	    fstab_entry ext4 $label $uuid
	    mke2fs -q -F -t ext4 -L $label -U $uuid $pdev
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
	    run_lvm pvcreate -f -q -q -u $uuid --norestorefile $pdev
	    PVS[${#PVS[@]}]=$pdev
	    ;;
	swap)
	    fstab_entry swap $label $uuid
	    mkswap -f -L $label -U $uuid $pdev
	    SWAPS="$SWAPS $(readlink -f $pdev)"
	    ;;
	raw)
	    start_fio_on_part $pdev
	    ;;
    esac
}

create_filesystems() {
    # arg $1: multipath map name
    # further args: partition types recognized by parted, or "lvm"
    # (should match args of create_parts)
    local name=$1 pdev pn=0
    shift

    while [[ $# -gt 0 ]]; do
	N_FS=$((N_FS+1))
	pdev=/dev/mapper/$name-part$((++pn))
	[[ -b $pdev ]]
	create_fs $pdev $1
	shift
    done
}

create_lvs() {
    # args: fs types to create
    local sz name
    [[ ${#PVS[@]} -gt 0 ]] || return 0

    N_LVS=$#
    sz=$((100/N_LVS))

    run_lvm vgcreate -q -q $VG "${PVS[@]}"
    push_cleanup vgremove -q -q -f $VG

    while [[ $# -gt 0 ]]; do
	N_FS=$((N_FS+1))
	name=lv_${N_FS}_$1
	run_lvm lvcreate -q -q -y -n $name -l ${sz}%FREE $VG
	push_cleanup lvremove -q -q -f /dev/$VG/$name
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

prepare_mpath() {
    # arg $1: mpath name
    local dev

    [[ $1 ]]
    dev=$(dm_name_to_devnode $1)
    [[ $dev && -b $dev ]]

    msg 3 wiping partition table on $dev
    sgdisk --zap-all $dev &>/dev/null
    push_cleanup clear_parts $1

    if [[ o$NO_PARTITIONS = oyes ]]; then
	if [[ $LV_TYPES ]]; then
	    FS_TYPES=lvm
	    create_fs $dev lvm
	fi
    else
	devsz=$(($(blockdev --getsz $dev)/2048))
	[[ $devsz -gt 1 ]]
	create_parts $1 $dev $devsz $FS_TYPES
	create_filesystems $1 $FS_TYPES
    fi
}

prepare() {
    local dev devsz mp

    make_disk_scripts ${PATHS[@]}

    for mp in ${MPATHS[@]}; do
	delete_slaves $mp
    done

    start_monitor
    for mp in ${MPATHS[@]}; do
	prepare_mpath $mp
    done

    create_lvs $LV_TYPES
    push_cleanup cleanup_paths
}

get_udevinfo() {
    # arg $1: device
    # DEVLINKS must be sorted otherwise false errors are seen
    local dl rest sorted

    udevadm info $1 >$TMPD/_udevinfo || touch $TMPD/_udevinfo
    dl=($(sed -n 's/^E: DEVLINKS=//p' <$TMPD/_udevinfo))
    sed '
# devlinks are sorted, see above
/^E: DEVLINKS=/d
/^ *$/d
# Filter out properties that are known to be volatile
# event properties that change depending on event
/^E: DM_ACTIVATION=/d
/^E: DM_DISABLE_OTHER_RULES_FLAG_OLD=/d
/^E: DM_SUBSYSTEM_UDEV_FLAG[0-7]=/d
/^E: DM_UDEV_DISABLE_.*_FLAG=/d
/^E: DM_UDEV_PRIMARY_SOURCE_FLAG=/d
/^E: DM_UDEV_RULES_VSN=/d
# device properties that are expected to change
/^E: DM_DEPS=/d
/^E: DM_NOSCAN=/d
/^E: DM_LAST_EVENT_NR=/d
/^E: MPATH_DEVICE_READY=/d
/^E: MPATH_UNCHANGED=/d
# This changes if a device is removed and re-added
/^E: USEC_INITIALIZED=/d
# device properties that arent imported from db
/^E: ID_PART_TABLE_TYPE=/d
/^E: ID_PART_TABLE_UUID=/d
/^E: ID_PART_ENTRY_SIZE=/d
/^E: ID_PART_ENTRY_NUMBER=/d
/^E: ID_PART_ENTRY_DISK=/d
/^E: MPATH_SBIN_PATH=/d
# 69-dm-lvm-metad sets these on DM_ACTIVATION only
/^E: ID_MODEL=LVM PV .* on .*/d
/^E: SYSTEMD_ALIAS=/d
# This looks scary to suppress, but SYSTEMD_READY=0 is what matters
/^E: SYSTEMD_READY=1/d
/^E: SYSTEMD_WANTS=lvm2-pvscan@.*\.service/d
' <$TMPD/_udevinfo
    IFS=$'\n' 
    sorted=($(echo "${dl[*]}" | sort))
    unset IFS
    echo "E: DEVLINKS=${sorted[@]}"
}

write_state() {
    local mp
    kernel_path_states >$OUTD/kernel.$STEP
    get_path_state_all >$OUTD/paths.$STEP
    for mp in ${MPATHS[@]} ${SLAVES[@]}; do
	get_udevinfo /dev/mapper/$mp | sort
    done >$OUTD/udevinfo.$STEP
    get_bdev_symlinks >$OUTD/symlinks.$STEP
    grep tm${HEXID} /proc/mounts | sort >$OUTD/mounts.$STEP
    [[ ! $USING_SWAP ]] || \
	tail -n +2 /proc/swaps | sort >$OUTD/swaps.$STEP
}

start_mount_unit() {
    # arg $1: mount point
    local unit
    unit=${1//\//-}
    unit=${unit#-}.mount
    msg 3 starting $unit
    systemctl start $unit
}

pass() {
    msg 2 PASS $((++PASSES)): $*
}

warn() {
    msg 2 WARN $((++WARNINGS)): $*
}

error() {
    msg 1 ERR  $((++ERRORS)): $*
}


start_fio_on_fs() {
    local mp=$1
    local size n pid nr

    [[ $FIO ]] || return
    size=$(df -m $mp | awk 'NR==2 {print $4;}')
    size=$((size - 16))
    [[ $size > 16 ]] || {
	msg 2 skipping fio on $mp - too small
	return
    }
    nr=$((size / 16))
    [[ $nr > 0 ]] || nr=1
    n=${#FIO_PIDS[@]}
    fio --name=fio$$_$n --directory=$mp --nrfiles=$nr --size=${size}m $FIO_OPTS &>$OUTD/fio_$n.log &
    pid=$!
    FIO_PIDS[$n]=$pid
    msg 2 started fio on $mp as $pid
    push_cleanup "kill -TERM $pid"
}

check_initial_state() {
    # check the everything is set up as expected
    local mp
    for mp in ${MOUNTPOINTS[@]}; do
	msg 4 checking /tmp/$mp
	grep -q /tmp/$mp /proc/mounts || {
	    start_mount_unit /tmp/$mp
	    if grep -q /tmp/$mp /proc/mounts; then
		msg 2 /tmp/$mp was not mounted, started manually, see mounts.orig
		[[ -f  $OUTD/mounts.orig ]] || \
		    mv $OUTD/mounts.$STEP $OUTD/mounts.orig
		# Otherwise we will see mount diffs later
		grep tm${HEXID} /proc/mounts | sort >$OUTD/mounts.$STEP
	    else
		msg 0 failed to mount /tmp/$mp; false
	    fi
	}
	pass /tmp/$mp is mounted
	start_fio_on_fs /tmp/$mp
    done
    for mp in $SWAPS; do
	msg 4 checking swap $mp
	if grep -q ^$mp /proc/swaps; then
	    pass swap $mp is active
	else
	    error swap $mp is inactive
	    swapon $mp
	fi
    done
}

initial_step() {

    write_state
    msg 3 "paths:
$(cat $OUTD/paths.1)"
    msg 4 "symlinks:
$(cat $OUTD/symlinks.1)"
    msg 3 "mounts:
$(cat $OUTD/mounts.1)"
    [[ ! $USING_SWAP ]] || msg 3 "swaps:
$(cat $OUTD/swaps.1)"

    [[ ! $WAIT ]] || wait_for_input
    check_initial_state
}

check_diff() {
    # opt $1: -n: nonfatal -i: ignore
    # arg $1: basename
    local dif nf= lvl word
    case $1 in
	-*)
	    nf=$1
	    shift
	    ;;
    esac
    dif="$(diff -u $OUTD/$1.1 $OUTD/$1.$STEP)" || true
    if [[ $dif ]]; then
	if [[ $nf = -i ]]; then
	    msg 3 INFO: $1 diffs in step $STEP
	elif [[ $nf = -n ]]; then
	    warn $1 diffs in step $STEP
	else
	    error $1 diffs in step $STEP
	    msg 3 "
$dif"
	fi
    else
	[[ $nf = -i ]] || pass no $1 diffs in step $STEP
	rm -f $OUTD/$1.$STEP
    fi
}

new_step() {
    # opt $1: -k if kernel path list must be ok
    #         -s if symlink diffs are expected
    #         -u if udev diffs are expected
    # args: step description
    local dif kflag=-i uflag=-n sflag=
    while [[ $# -gt 0 ]]; do
	case $1 in
	    -k)
		kflag=
		;;
	    -u)
		uflag=-i
		shift
		;;
	    -s)
		sflag=-i
		shift
		;;
	    *)
		break
		;;
	esac
	shift
    done

    if [[ $((++STEP)) -eq 1 ]]; then
	initial_step
	return
    fi

    msg 2 === Step $STEP: $@ ===
    write_state
    msg 3 "paths after step $STEP:
$(cat $OUTD/paths.$STEP)"

    check_diff $kflag kernel
    check_diff $uflag udevinfo
    check_diff $sflag symlinks
    check_diff mounts
    [[ ! $USING_SWAP ]] || check_diff swaps
    [[ ! $WAIT ]] || wait_for_input
}

safe_filename() {
    # arg $1: filename
    echo -n "$1" | tr -s "'"'\\"/&;$?*[:cntrl:][:space:]' _
}

run_test() {
    # arg $1: test file and test args, separated by comma
    # file should provide a function named like the file
    local safe file test

    set -- ${1//,/ }
    file=$1
    test=$(basename "$file")
    shift
    safe=$(safe_filename $test)
    [[ -e $TMPD/__test_loaded_$safe ]] || {
	msg 3 loading $file
	source "$file"
	touch $TMPD/__test_loaded_$safe
    }
    msg 2 %%%% Running test $test %%%%
    eval "$test $@"
}

run_tests() {
    local test

    for test in $TESTS; do
	run_test $test
    done
}

SHORTOPTS=o:P:nFp:l:t:i:m:u:s:M:wvqeTh
LONGOPTS="output:,prefix:,no-partitions,fio,parts:,lvs,test:,iterations:,mp-debug:,udev-debug:,sd-debug:\
monitor:,wait,verbose,quiet,terminal,trace,help"
USAGE="
usage: $ME [options] mapname [mapname ...]
       -h|--help		print help
       -P|--prefix		prefix for installed multipath-tools
       -o|--output		output directory (default: auto)
       -n|--no-partitions	don't create partitions (ignore -p)
       -F|--fio			run fio on devices / file systems
       -p|--parts x,y,z		partition types (ext2, xfs, btrfs, lvm, raw, none)
       -l|--lvs x,y,z		logical volumes (ext2, xfs, btrfs, raw, none)
       -t|--test file,args	test case to run, with arguments
       -i|--iterations n	test iterations (default 1)
       -m lvl|--mp-debug lvl	set multipathd debug level
       -u lvl|--udev-debug lvl  set udev debug level
       -s lvl|--sd-debug lvl	set systemd debug level
       -M opts|--monitor opts   set udev monitor options e.g. \"k,u,p\" or \"off\"
       -w|--wait	 	wait after setup stage
       -q|--quiet	   	decrease verbose level for script
       -v|--verbose 	   	increase verbose level for script
       -e|--terminal		log to terminal, not log file
       -T|--trace	   	trace this script
"

usage() {
    msg 1 "$USAGE"
}

# This way we catch getopt errors, doesn't work with direct set command
OPTIONS=($(getopt -s bash -o "$SHORTOPTS" --longoptions "$LONGOPTS" -- "$@"))
set -- "${OPTIONS[@]}"
unset OPTIONS
msg 2 Startup: $ME "$*"

push_cleanup '[[ $OK ]] || : $((++ERRORS)); exit $((ERRORS > 0 ? 1 : 0))'
push_cleanup '[[ $OK ]] || msg 1 $0 encountered an error. Check logs in $OUTD'
push_cleanup 'msg 2 $ERRORS errors and $WARNINGS warnings encountered'

OK=
TERMINAL=
TRACE=
NO_PARTITIONS=
USING_SWAP=
FS_USED=
WAIT=
FIO=
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
	-P|--prefix)
	    shift
	    eval "PREFIX=$1"
	    ;;
	-n|--no-partitions)
	    NO_PARTITIONS=yes
	    ;;
	-F|--fio)
	    FIO=yes
	    ;;
	-p|--parts)
	    shift
	    eval "FS_TYPES=${1//,/ }"
	    ;;
	-l|--lvs)
	    shift
	    eval "LV_TYPES=${1//,/ }"
	    ;;
	-t|--test)
	    shift
	    eval "TESTS=\"\$TESTS \"$1"
	    ;;
	-i|--iterations)
	    shift
	    eval "ITERATIONS=$1"
	    ;;
	-m|--mp-debug)
	    shift
	    eval "MULTIPATHD_DEBUG=$1"
	    ;;
	-u|--udev-debug)
	    shift
	    eval "UDEV_DEBUG=$1"
	    ;;
	-s|--sd-debug)
	    shift
	    eval "SD_DEBUG=$1"
	    ;;
	-M|--monitor)
	    shift
	    eval "set_monitor_opts $1"
	    ;;
	-w|--wait)
	    WAIT=1
	    ;;
	-v|--verbose)
	    : $((++DEBUGLVL))
	    ;;
	-q|--quiet)
	    : $((--DEBUGLVL))
	    ;;
	-e|--terminal)
	    TERMINAL=1
	    ;;
	-T|--trace)
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

if [[ $FIO ]]; then
    which fio &>/dev//null
fi

LIBDIR=
if [[ -d $PREFIX/lib64/multipath ]]; then
	LIBDIR=$PREFIX/lib64
elif [[ -d $PREFIX/lib/multipath ]]; then
	LIBDIR=$PREFIX/lib
fi
[[ $LIBDIR ]]

BINDIR=
if [[ -x $PREFIX/sbin/multipathd ]]; then
	BINDIR=$PREFIX/sbin
elif [[ -d $PREFIX/bin/multipathd ]]; then
	BINDIR=$PREFIX/bin
fi
[[ $BINDIR ]]

if [[ $PREFIX ]]; then
    export LD_LIBRARY_PATH=$LIBDIR
    export PATH=$BINDIR:$PATH
    [[ ! -e $PREFIX/etc/system.conf ]]
    mkdir -p $PREFIX/etc
    if [[ -e /etc/multipath.conf ]]; then
	mv -f /etc/multipath.conf $PREFIX/etc/system.conf
	push_cleanup 'mv -f $PREFIX/etc/system.conf /etc/multipath.conf'
    else
	push_cleanup 'rm -f /etc/multipath.conf'
    fi
    cat >/etc/multipath.conf <<EOF
defaults {
	 config_dir $PREFIX/etc
	 multipath_dir $LIBDIR/multipath
}
EOF
fi

if [[ $# -ge 1 ]]; then
    eval "MPATHS=($@)"
    for _mp in ${MPATHS[@]}; do
	[[ "$(dmsetup table $_mp | cut -d" " -f 3)" = multipath ]]
    done
else
    msg 2 no mpaths specified, checking for free ones
    MPATHS=($(get_free_multipath_maps))
fi
[[ ${#MPATHS[@]} -gt 0 ]]

if [[ $LV_TYPES ]]; then
    case $FS_TYPES in
	*lvm*) ;;
	*) FS_TYPES="$FS_TYPES lvm";;
    esac
fi
case "$FS_TYPES $LV_TYPES" in
    *swap*)
	USING_SWAP=1
	;;
esac
for _x in $FS_TYPES; do
    case $_x in
	none) ;;
	raw)  if [[ $FIO ]]; then FS_USED=yes; fi
	      ;;
	*)    FS_USED=yes;;
    esac
done

if [[ ! $TERMINAL ]]; then
    exec 5>&2
    ERR_FD=5 # for err_handler
    exec &> >(logger --id=$$ -t $ME)
fi
[[ o$TRACE = oyes ]] && set -x

STARTTIME=$(date +"%Y-%m-%d %H:%M:%S")

: ${OUTD:="$PWD/logs-$ME-${STARTTIME//[ :]/_}"}
mkdir -p $OUTD

TMPD=$(mktemp -d /tmp/$ME-XXXXXX)

push_cleanup rm -rf "$TMPD"
msg 1 output dir is $OUTD

push_cleanup journalctl -o short-monotonic --since '"$STARTTIME"' '>$OUTD/journal.log'
restart_multipathd on
push_cleanup restart_multipathd off
debug_udev on
push_cleanup debug_udev off
debug_systemd on
push_cleanup debug_systemd off

if [[ $TESTS ]]; then
    for _t in $TESTS; do
	# error if a test doesn't exist
	[[ -f ${_t%%,*} ]]
    done
else
    for _t in test_*; do
	case $_t in
	    *\*)
		# Nothing found
		break
		;;
	    *~)
		continue
		;;
	    *rmmap)
		if [[ $FS_USED ]]; then
		    msg 2 skipping $_t because file systems are used
		else
		    TESTS="$TESTS $_t"
		fi
		;;
	    *)
		TESTS="$TESTS $_t"
		;;
	esac
    done
fi
[[ $TESTS ]]
for _t in $TESTS; do
    # Test must define a function that is equal to the file name
    grep -q "^$(basename ${_t%%,*})() {" ${_t%%,*} || {
	msg 1 ERROR: $_t is not a valid test case
	false
    }
    if [[ $FS_USED && $_t = *rmmap ]]; then
	msg 1 ERROR: $_t fails for FS_TYPES=\"$FS_TYPES\"
	false
    fi
done
msg 2 Tests to be run: $TESTS

PATHS=()
PLISTS=()
set_PATHS() {
    local i=0 pls
    while [[ $i -lt ${#MPATHS[@]} ]]; do
	PLISTS[$i]=$(get_path_list ${MPATHS[$i]})
	PATHS=("${PATHS[@]}" ${PLISTS[$i]})
	: $((++i))
    done
    # https://stackoverflow.com/questions/7442417/how-to-sort-an-array-in-bash
    IFS=$'\n' PATHS=($(sort <<<"${PATHS[*]}"))
    unset IFS
}

set_PATHS
[[ ${#PATHS[@]} -gt 0 ]]

msg 2 multipath maps "(${#MPATHS[@]})": ${MPATHS[@]}
msg 2 Paths: "(${#PATHS[@]})" ${PATHS[@]}
msg 3 FS_TYPES: $FS_TYPES
msg 3 LV_TYPES: $LV_TYPES

prepare

SLAVES=
set_SLAVES() {
    local mp
    for mp in "${MPATHS[@]}"; do
	SLAVES="$SLAVES $(get_slaves_rec "$mp")"
    done
}
set_SLAVES

msg 3 slaves: "
$SLAVES"

# give systemd some time
sleep 2
new_step
[[ ! $WAIT ]] || wait_for_input

sleep 2

while [[ $((ITERATIONS--)) -gt 0 ]]; do
    run_tests
done

OK=yes
