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
    multipathd show paths format "%m %d" | sed -n "s/$1 //p"
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

TMPD=$(mktemp -d /tmp/$ME-XXXXXX)
push_cleanup rm -rf "$TMPD"
msg 1 temp dir is $TMPD

[[ -b /dev/mapper/"$MPATH" ]]

PATHS=($(get_path_list "$MPATH"))
[[ ${#PATHS[@]} -gt 0 ]]

msg 2 Checking mpath $MPATH with ${#PATHS[@]} paths: ${PATHS[@]}

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
