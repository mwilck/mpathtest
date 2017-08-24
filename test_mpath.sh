#! /bin/bash

ME=$(basename $0)
MYDIR=$(cd "$(dirname $0)" && pwd)
. $MYDIR/err_handler.sh
. $MYDIR/cleanup_lib.sh

# mpath name
: ${MPATH:=3600601600a3020002282d7e2c5a6e411}
: ${DEBUGLVL:=2}

msg() {
    [[ $1 -lt $DEBUGLVL ]] && return
    shift
    echo "$ME: $*" >&2;
}

get_path_list() {
    # arg $1: multipath map name
    [[ $1 ]]
    multipathd show paths format "%m %d" | sed -n "s/$1 //p" | sort
}

get_symlinks() {
    # arg $1: dm device /dev/dm-$X
    [[ $1 ]]
    cd /dev
    find . -type l -ls  | \
	sed -n /"$1"'$/s,^.*\./\([^[:space:]]*\)[[:space:]].*$,\1,p'
    cd -
}

get_slaves() {
    # arg $1: dm device in major:minor format
    [[ $1 ]]
    dmsetup table | sed -n /" $1 "'/s/: .*//p'
}

start_monitor() {
    [[ -z "$_MONITOR_PID" && -z "$_MONITOR_CLEAN" ]]
    udevadm monitor --env -s block >& "$TMPD"/udev-monitor.log &
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
	msg 2 Slave $slv will be deleted
    done
    
    kpartx -d $1
    slaves=$(get_slaves $2)
    for slv in $slaves; do
	dmsetup remove /dev/mapper/$slv
    done

    msg 2 wiping partition table on $1
    sgdisk --zap-all $DMDEV
}

create_parts_simple() {
    # arg $1: dm device /dev/dm-$X
    # arg $2: device size in MiB
    # further args: partition types recognized by parted, or "lvm"
    [[ $1 && $2 && -b $1 ]]
    local dev=$1 sz=$2 p n i begin end type more
    shift; shift
    n=$#
    {
	cat <<EOF
unit MiB
mklabel gpt
EOF
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
	    echo mkpart part${i}_$p $type $begin $end
	    echo $more
	    begin=$end
	    end=$((end+sz/n))
	    if [[ $end -eq $sz ]]; then end=-1s; fi
	done
    } >$TMPD/parted.cmd
    cat $TMPD/parted.cmd
    parted $dev <$TMPD/parted.cmd
}

TMPD=$(mktemp -d /tmp/$ME-XXXXXX)
push_cleanup rm -rf "$TMPD"
msg 1 temp dir is $TMPD

DMDEV=$(readlink -f /dev/mapper/$MP)
DMNAME=${DMDEV#/dev/}
DEVNO=$(dmsetup info -c -o major,minor --noheadings $DMDEV)
[[ -b $DMDEV ]]
DEVSZ_MiB=$(($(blockdev --getsz /dev/dm-2)/2048))
[[ $DEVSZ_MiB -gt 1 ]]

PATHS=($(get_path_list "$MPATH"))
[[ ${#PATHS[@]} -gt 0 ]]

msg 2 Checking mpath $MPATH with ${#PATHS[@]} paths: ${PATHS[@]}

delete_slaves $DMDEV $DEVNO
create_parts_simple $DMDEV $DEVSZ_MiB ext2 xfs lvm

exit 0
start_monitor

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
