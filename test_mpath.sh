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
    SLAVES=$(get_slaves $DEVNO)
    for slv in $SLAVES; do
	msg 2 Slave $slv will be deleted
    done
    
    kpartx -d $DMDEV
    SLAVES=$(get_slaves $DEVNO)
    for slv in $SLAVES; do
	dmsetup remove /dev/mapper/$slv
    done
    # Wipe partition table
    dd if=/dev/null of=$DMDEV bs=1m count=1
}

TMPD=$(mktemp -d /tmp/$ME-XXXXXX)
push_cleanup rm -rf "$TMPD"
msg 1 temp dir is $TMPD

DMDEV=$(readlink -f /dev/mapper/$MP)
DMNAME=${DMDEV#/dev/}
DEVNO=$(dmsetup info -c -o major,minor --noheadings $DMDEV)
[[ -b $DMDEV ]]
DEVSZ_MB=$(($(blockdev --getsz /dev/dm-2)/2048))
[[ $DEVSZ_MB -gt 1 ]]

PATHS=($(get_path_list "$MPATH"))
[[ ${#PATHS[@]} -gt 0 ]]

msg 2 Checking mpath $MPATH with ${#PATHS[@]} paths: ${PATHS[@]}

delete_slaves

start_monitor
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
