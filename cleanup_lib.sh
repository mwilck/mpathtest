trap _cleanup 0 INT TERM HUP

# must match format in _cleanup_name
__MAX_CLEANUP__=9999
_cleanup_name() {
    printf "%s/%04d" ${__CLEANUP__} $1
}

_init_cleanup() {
    __CLEANUP__=$(mktemp -d ${TMP:-/tmp}/cleanup-$$-XXXXXX)
    __CLEANUP_CTR__=0
}

push_cleanup() {
    if [[ ! -n "${__CLEANUP__}" || ! -d ${__CLEANUP__} ]]; then
	_init_cleanup
    fi
    # CAUTION! bash artihmetic expansion returns 1 if result is 0
    # therefore post-increment fails here
    ((++__CLEANUP_CTR__))
    [[ ${__CLEANUP_CTR__} -le $__MAX_CLEANUP__ ]]
    echo "$@" >$(_cleanup_name ${__CLEANUP_CTR__})
}

pop_cleanup() {
    local ctr=${1:-$((__CLEANUP_CTR__--))}
    rm $(_cleanup_name ${ctr})
}

get_cleanup_handle(){
    echo ${__CLEANUP_CTR__}
}

_cleanup() {
    local __clean__
    trap - 0 TERM HUP INT
    trap - ERR
    set +eE
    if [[ ! -n "${__CLEANUP__}" || ! -d ${__CLEANUP__} ]]; then
	return 0
    fi
    while read __clean__; do
	if [[ "$__CLEANUP_DEBUG__" ]]; then
	    echo -n "Cleanup ${__clean__}: "
	    cat "${__CLEANUP__}/${__clean__}"
	fi >&2
	source "${__CLEANUP__}/${__clean__}"
	rm -f "${__CLEANUP__}/${__clean__}"
    done < <(ls -r ${__CLEANUP__})
    rmdir ${__CLEANUP__}
    unset __CLEANUP__ __CLEANUP_CTR__
}

if [[ "$(basename $0)" == cleanup_lib.sh ]]; then
    . $(dirname $0)/err_handler.sh
    # Test
    rm_y() {
	# caution: bash functions will be executed in the context of _cleanup()
	rm $_TEST/y
    }
    _TEST=$(mktemp -d ${TMP:-/tmp}/sep-XXXXXX)
    push_cleanup 'echo cleanup finished >&2'
    push_cleanup rmdir "$_TEST"
    touch $_TEST/x
    push_cleanup rm $_TEST/x
    n=$(get_cleanup_handle)
    touch $_TEST/y
    push_cleanup rm_y
    rm $_TEST/x
    pop_cleanup $n
    touch $_TEST/z
    push_cleanup rm $_TEST/z
    rm $_TEST/z
    pop_cleanup
    touch $_TEST/a
    push_cleanup rm $_TEST/a
    push_cleanup echo 'cleanup started' '>&2'
    # Trigger error handler
    false
fi
