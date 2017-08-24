set -e -E
trap 'LINE=$LINENO; BC=$BASH_COMMAND; _err_handler' ERR

_err_handler() {
    local i=1 
    set +eE
    trap - ERR
    if [[ $ERR_FD ]]; then
	exec 2>&$ERR_FD
    fi
    exec >&2
    echo "$0: Error in command \"$BC\" on line $LINE. Stack:"
    while [[ $i < ${#FUNCNAME[@]} ]]; do
	printf "file %s:%s() line %d \n" \
	       "${BASH_SOURCE[$i]}" "${FUNCNAME[$i]}" "${BASH_LINENO[((i-1))]}"
	((i++))
    done
    exit 129
}

error() {
    return ${1:-129};
}

if [[ "$(basename $0)" == err_handler.sh ]]; then
    # Test
    func2() {
	false
    }
    func1() {
	func2
    }
    func1
fi
