set -e -E
trap 'LINE=$LINENO; _err_handler' ERR

_err_handler() {
    local i=1 bc0=$BASH_COMMAND bc1
    set +eE
    trap - ERR
    exec >&2
    bc1="$(eval "echo \"$bc0\"")"
    if [[ "$bc0" != "$bc1" ]]; then
	bc0="\"$bc0\" (=>\"$bc1\")"
    else
	bc0="\"$bc0\""
    fi
    echo "$0: Error in command $bc0 on line $LINE. Stack:"
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
