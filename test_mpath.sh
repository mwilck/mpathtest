#! /bin/bash

ME=$(basename $0)
MYDIR=$(cd "$(dirname $0)" && pwd)
. $MYDIR/err_handler.sh
. $MYDIR/cleanup_lib.sh

# mpath name
MPATH=3600601600a3020002282d7e2c5a6e411

[[ -b /dev/mapper/$MPATH ]]

PATHS=($(multipathd show paths format "%m %d" | sed -n 's/3600601600a3020002282d7e2c5a6e411 //p'))

echo ${PATHS[@]}
[[ ${#PATHS[@]} -gt 0 ]]
