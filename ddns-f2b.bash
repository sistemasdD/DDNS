#!/usr/bin/env bash

set -o pipefail
shopt -s extglob

readonly _DEFAULT_PORTS='8443/tcp,3306/tcp'
readonly _DEFAULT_LOG_FILE='/var/log/plesk-txt-firewall.log'
readonly _LOCK_FILE='/run/lock/plesk-txt-firewall.lock'

_LOG_FILE=$_DEFAULT_LOG_FILE
_QUIET=0
_DRY_RUN=0
_PLESK_BIN=

_log()
{
    local -- _DATA="$*" _DATE=

    _DATE=$(date '+%Y-%m-%d %H:%M:%S')

    printf '%s - %s\n' "$_DATE" "$_DATA" >> "$_LOG_FILE"

    (( _QUIET == 0 )) && printf '%s - %s\n' "$_DATE" "$_DATA"

    return 0
}

_error()
{
    printf >&2 '\n\033[1;31m[!] %s\033[0m\n\n' "$*"
}

_showHelp()
{
    cat <<EOF_HELP

Usage:
  ${0##*/} -r <TXT_RECORD> [options]

Required:
  -r, --record <fqdn>       TXT record containing comma-separated IPv4 addresses.

Options:
  -p, --ports <list>        Plesk Firewall ports. Default: $_DEFAULT_PORTS
  -n, --name <rule-name>    Firewall rule name. Default: DDNS TXT - <TXT_RECORD>
  -l, --log <path>          Log file. Default: $_DEFAULT_LOG_FILE
  -q, --quiet               Do not write informational messages to stdout.
      --dry-run             Show changes without modifying Fail2Ban or the firewall.
  -h, --help                Display this help panel.

Accepted forms:
  --record _plesk-access.example.com
  --record=_plesk-access.example.com

Expected TXT value:
  203.0.113.10,198.51.100.25

Fail2Ban behavior:
  TXT addresses are added to Plesk's trusted IP list.
  Any active bans for those addresses are removed.

Example:
  ${0##*/} \
    --record _plesk-access.example.com \
    --name 'DDNS - Customer access' \
    --ports '8443/tcp,3306/tcp'

EOF_HELP
}

_trim()
{
    local -- _VALUE=$1

    _VALUE="${_VALUE#"${_VALUE%%[![:space:]]*}"}"
    _VALUE="${_VALUE%"${_VALUE##*[![:space:]]}"}"

    printf '%s' "$_VALUE"
}

_isIPv4()
{
    local -- _IP=$1 _OCTET=
    local -a -- _OCTETS=()

    [[ $_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    IFS='.' read -r -a _OCTETS <<< "$_IP"

    for _OCTET in "${_OCTETS[@]}"
    do
        [[ $_OCTET == 0 || $_OCTET =~ ^[1-9][0-9]{0,2}$ ]] || return 1
        (( 10#$_OCTET <= 255 )) || return 1
    done

    return 0
}

_validatePorts()
{
    local -- _PORT_LIST=$1 _ENTRY= _PORT= _PROTO=
    local -a -- _ENTRIES=()

    IFS=',' read -r -a _ENTRIES <<< "$_PORT_LIST"
    (( ${#_ENTRIES[@]} > 0 )) || return 1

    for _ENTRY in "${_ENTRIES[@]}"
    do
        _ENTRY=$(_trim "$_ENTRY")

        [[ $_ENTRY =~ ^([0-9]{1,5})/(tcp|udp)$ ]] || return 1

        _PORT=${BASH_REMATCH[1]}
        _PROTO=${BASH_REMATCH[2]}

        (( 10#$_PORT >= 1 && 10#$_PORT <= 65535 )) || return 1
        [[ $_PROTO == tcp || $_PROTO == udp ]] || return 1
    done

    return 0
}

_normalizePorts()
{
    local -- _PORT_LIST=$1 _ENTRY= _RESULT=
    local -a -- _ENTRIES=()

    IFS=',' read -r -a _ENTRIES <<< "$_PORT_LIST"

    for _ENTRY in "${_ENTRIES[@]}"
    do
        _ENTRY=$(_trim "$_ENTRY")
        _RESULT+="${_RESULT:+,}${_ENTRY}"
    done

    printf '%s' "$_RESULT"
}

_systemChecker()
{
    local -- _BINARY=

    (( EUID == 0 )) || {
        _error 'This script must be executed as root'
        return 1
    }

    (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )) || {
        _error 'Bash 4.3 or newer is required'
        return 1
    }

    for _BINARY in dig jq flock sort paste install
    do
        command -v "$_BINARY" >/dev/null 2>&1 || {
            _error "Missing dependency: $_BINARY"
            return 1
        }
    done

    if command -v plesk >/dev/null 2>&1
    then
        _PLESK_BIN=$(command -v plesk)
    elif [[ -x /usr/sbin/plesk ]]
    then
        _PLESK_BIN=/usr/sbin/plesk
    else
        _error 'The Plesk CLI binary could not be found'
        return 1
    fi

    return 0
}

_prepareLog()
{
    local -- _LOG_DIR=

    _LOG_DIR=${_LOG_FILE%/*}
    [[ $_LOG_DIR == "$_LOG_FILE" ]] && _LOG_DIR=.

    [[ -d $_LOG_DIR ]] || {
        _error "Log directory does not exist: $_LOG_DIR"
        return 1
    }

    if [[ ! -e $_LOG_FILE ]]
    then
        install -m 0600 /dev/null "$_LOG_FILE" || {
            _error "Unable to create log file: $_LOG_FILE"
            return 1
        }
    fi

    [[ -w $_LOG_FILE ]] || {
        _error "Log file is not writable: $_LOG_FILE"
        return 1
    }
}

_extractIPsFromTXT()
{
    local -n -- _IPS=$1
    local -- _TXT_RECORD=$2 _TXT_OUTPUT= _TXT_VALUE= _IP=
    local -a -- _ANSWERS=() _VALUES=()

    _TXT_OUTPUT=$(dig +time=3 +tries=2 +short TXT "$_TXT_RECORD" @1.1.1.1) || {
        _error "DNS query failed for TXT record: $_TXT_RECORD"
        return 1
    }

    [[ -n $_TXT_OUTPUT ]] || {
        _error "TXT record returned no data: $_TXT_RECORD"
        return 1
    }

    mapfile -t _ANSWERS <<< "$_TXT_OUTPUT"

    (( ${#_ANSWERS[@]} == 1 )) || {
        _error "Expected exactly one TXT answer for $_TXT_RECORD; received ${#_ANSWERS[@]}"
        return 1
    }

    _TXT_VALUE=${_ANSWERS[0]//\"/}
    IFS=',' read -r -a _VALUES <<< "$_TXT_VALUE"

    for _IP in "${_VALUES[@]}"
    do
        _IP=$(_trim "$_IP")

        [[ -n $_IP ]] || {
            _error "The TXT record contains an empty item: $_TXT_RECORD"
            return 1
        }

        _isIPv4 "$_IP" || {
            _error "Invalid IPv4 address in TXT record: $_IP"
            return 1
        }

        _IPS["$_IP"]=1
    done

    (( ${#_IPS[@]} > 0 )) || {
        _error "No valid IPv4 addresses were found in TXT record: $_TXT_RECORD"
        return 1
    }
}

_extractIPsFromString()
{
    local -n -- _IPS=$1
    local -- _VALUE=$2 _IP=
    local -a -- _VALUES=()

    [[ -n $_VALUE ]] || return 0

    IFS=',' read -r -a _VALUES <<< "$_VALUE"

    for _IP in "${_VALUES[@]}"
    do
        _IP=$(_trim "$_IP")
        [[ -n $_IP ]] && _IPS["$_IP"]=1
    done
}

_setsAreEqual()
{
    local -n -- _LEFT=$1 _RIGHT=$2
    local -- _ITEM=

    (( ${#_LEFT[@]} == ${#_RIGHT[@]} )) || return 1

    for _ITEM in "${!_LEFT[@]}"
    do
        [[ -n ${_RIGHT[$_ITEM]+x} ]] || return 1
    done

    return 0
}

_joinSortedIPs()
{
    local -n -- _IPS=$1

    printf '%s\n' "${!_IPS[@]}" | sort -V | paste -sd ',' -
}

_joinSortedIPsWithDelimiter()
{
    local -n -- _IPS=$1
    local -- _DELIMITER=$2

    printf '%s\n' "${!_IPS[@]}" | sort -V | paste -sd "$_DELIMITER" -
}

_extractLeadingIPv4sFromText()
{
    local -n -- _IPS=$1
    local -- _TEXT=$2 _LINE= _IP=

    while IFS= read -r _LINE
    do
        if [[ $_LINE =~ ^[[:space:]]*(([0-9]{1,3}\.){3}[0-9]{1,3})([[:space:]/]|$) ]]
        then
            _IP=${BASH_REMATCH[1]}
            _isIPv4 "$_IP" && _IPS["$_IP"]=1
        fi
    done <<< "$_TEXT"

    return 0
}

_syncFail2Ban()
{
    local -n -- _DESIRED_IPS=$1
    local -- _TXT_RECORD=$2 _TRUSTED_OUTPUT= _BANNED_OUTPUT=
    local -- _IP= _TRUST_LIST=
    local -A -- _TRUSTED_IPS=() _BANNED_IPS=() _MISSING_TRUSTED=()

    _TRUSTED_OUTPUT=$("$_PLESK_BIN" bin ip_ban --trusted) || {
        _error 'Unable to obtain the Plesk Fail2Ban trusted IP list'
        return 1
    }

    _extractLeadingIPv4sFromText _TRUSTED_IPS "$_TRUSTED_OUTPUT"

    for _IP in "${!_DESIRED_IPS[@]}"
    do
        [[ -n ${_TRUSTED_IPS[$_IP]+x} ]] || _MISSING_TRUSTED["$_IP"]=1
    done

    if (( ${#_MISSING_TRUSTED[@]} > 0 ))
    then
        _TRUST_LIST=$(_joinSortedIPsWithDelimiter _MISSING_TRUSTED ';')

        if (( _DRY_RUN == 1 ))
        then
            printf 'DRY-RUN:'
            printf ' %q' \
                "$_PLESK_BIN" bin ip_ban --add-trusted "$_TRUST_LIST" \
                -description "Managed by ${0##*/} from $_TXT_RECORD"
            printf '\n'
        else
            "$_PLESK_BIN" bin ip_ban \
                --add-trusted "$_TRUST_LIST" \
                -description "Managed by ${0##*/} from $_TXT_RECORD" || {
                    _error 'Unable to add the TXT addresses to the Plesk Fail2Ban trusted list'
                    return 1
                }
        fi

        _log "Fail2Ban trusted IPv4 addresses added: ${_TRUST_LIST//;/,}"
    else
        _log 'All TXT IPv4 addresses are already trusted by Fail2Ban'
    fi

    _BANNED_OUTPUT=$("$_PLESK_BIN" bin ip_ban --banned) || {
        _error 'Unable to obtain the Plesk Fail2Ban banned IP list'
        return 1
    }

    _extractLeadingIPv4sFromText _BANNED_IPS "$_BANNED_OUTPUT"

    for _IP in "${!_DESIRED_IPS[@]}"
    do
        [[ -n ${_BANNED_IPS[$_IP]+x} ]] || continue

        if (( _DRY_RUN == 1 ))
        then
            printf 'DRY-RUN:'
            printf ' %q' "$_PLESK_BIN" bin ip_ban --unban "$_IP"
            printf '\n'
        else
            "$_PLESK_BIN" bin ip_ban --unban "$_IP" || {
                _error "Unable to unban $_IP from Plesk Fail2Ban"
                return 1
            }
        fi

        _log "Fail2Ban active ban removed for IPv4 address: $_IP"
    done

    return 0
}

_getRuleJSON()
{
    local -- _RULE_NAME=$1 _ALL_RULES= _MATCHES= _COUNT=

    _ALL_RULES=$("$_PLESK_BIN" ext firewall --list-json) || {
        _error 'Unable to obtain Plesk Firewall rules'
        return 1
    }

    _MATCHES=$(jq -c \
        --arg _name "$_RULE_NAME" \
        '[.[] | select((.name // "") == $_name)]' \
        <<< "$_ALL_RULES") || {
            _error 'Plesk Firewall returned invalid JSON'
            return 1
        }

    _COUNT=$(jq -r 'length' <<< "$_MATCHES")

    (( _COUNT <= 1 )) || {
        _error "More than one firewall rule has the exact name: $_RULE_NAME"
        return 1
    }

    printf '%s' "$_MATCHES"
}

_setFWRule()
{
    local -- _RULE_ID=$1 _RULE_NAME=$2 _PORTS=$3 _REMOTE_ADDRESSES=$4
    local -a -- _COMMAND=(
        "$_PLESK_BIN" ext firewall --set-rule
    )

    if [[ -n $_RULE_ID ]]
    then
        _COMMAND+=( -id "$_RULE_ID" )
    else
        _COMMAND+=( -name "$_RULE_NAME" )
    fi

    _COMMAND+=(
        -direction input
        -action allow
        -ports "$_PORTS"
        -remote-addresses "$_REMOTE_ADDRESSES"
    )

    if (( _DRY_RUN == 1 ))
    then
        printf 'DRY-RUN:'
        printf ' %q' "${_COMMAND[@]}"
        printf '\n'
        return 0
    fi

    "${_COMMAND[@]}" || {
        _error 'Unable to create or update the Plesk Firewall rule'
        return 1
    }

    "$_PLESK_BIN" ext firewall \
        --apply \
        -auto-confirm-this-may-lock-me-out-of-the-server || {
            _error 'The firewall rule was staged but could not be applied'
            return 1
        }

    return 0
}

_setup()
{
    local -- _TXT_RECORD=$1 _RULE_NAME=$2 _PORTS=$3
    local -- _RULE_JSON= _RULE_ID= _CURRENT_FROM= _CURRENT_PORTS=
    local -- _CURRENT_ACTION= _CURRENT_DIRECTION= _REMOTE_ADDRESSES=
    local -A -- _CURRENT_IPS=() _NEW_IPS=()
    local -i -- _NEED_UPDATE=0

    _extractIPsFromTXT _NEW_IPS "$_TXT_RECORD" || return 1

    # Trust first, then remove any active ban. Adding an address to the
    # trusted list prevents future bans but does not necessarily remove an
    # existing Fail2Ban firewall rule.
    _syncFail2Ban _NEW_IPS "$_TXT_RECORD" || return 1

    _RULE_JSON=$(_getRuleJSON "$_RULE_NAME") || return 1

    if (( $(jq -r 'length' <<< "$_RULE_JSON") == 1 ))
    then
        _RULE_ID=$(jq -r '.[0].id' <<< "$_RULE_JSON")
        _CURRENT_FROM=$(jq -r '.[0].from // ""' <<< "$_RULE_JSON")
        _CURRENT_PORTS=$(jq -r '.[0].ports // ""' <<< "$_RULE_JSON")
        _CURRENT_ACTION=$(jq -r '.[0].action // ""' <<< "$_RULE_JSON")
        _CURRENT_DIRECTION=$(jq -r '.[0].direction // ""' <<< "$_RULE_JSON")

        _extractIPsFromString _CURRENT_IPS "$_CURRENT_FROM"

        _setsAreEqual _CURRENT_IPS _NEW_IPS || _NEED_UPDATE=1
        [[ $_CURRENT_PORTS == "$_PORTS" ]] || _NEED_UPDATE=1
        [[ $_CURRENT_ACTION == allow ]] || _NEED_UPDATE=1
        [[ $_CURRENT_DIRECTION == input ]] || _NEED_UPDATE=1
    else
        _NEED_UPDATE=1
    fi

    if (( _NEED_UPDATE == 0 ))
    then
        _log "No changes detected for $_RULE_NAME"
        return 0
    fi

    _REMOTE_ADDRESSES=$(_joinSortedIPs _NEW_IPS)

    if [[ -n $_RULE_ID ]]
    then
        _log "Updating firewall rule ID $_RULE_ID: $_RULE_NAME"
    else
        _log "Creating firewall rule: $_RULE_NAME"
    fi

    _log "Allowed IPv4 addresses: $_REMOTE_ADDRESSES"
    _log "Allowed ports: $_PORTS"

    _setFWRule "$_RULE_ID" "$_RULE_NAME" "$_PORTS" "$_REMOTE_ADDRESSES" || return 1

    (( _DRY_RUN == 1 )) || _log 'Plesk Firewall changes applied successfully'

    return 0
}

main()
{
    local -A -- _FLAGS=() _OPT_ARGS=()
    local -- _RULE_NAME=

    (( $# == 0 )) && {
        _error "No arguments provided. Try -h or --help"
        exit 99
    }

    while (( $# > 0 ))
    do
        [[ $1 == @(-r|--record|-p|--ports|-n|--name|-l|--log)=* ]] && {
            set -- "${1%%=*}" "${1#*=}" "${@:2}"
            continue
        }

        case $1 in
            -r | --record)
                _FLAGS[record]=$(( ${_FLAGS[record]:-0} + 1 ))
                (( _FLAGS[record] == 1 )) || {
                    _error 'The record option was specified more than once'
                    exit 99
                }

                [[ $# -ge 2 && -n ${2-} && ${2-} != -* ]] || {
                    _error "$1 requires a TXT record name"
                    exit 99
                }

                _OPT_ARGS[record]=$2
                shift
                ;;

            -p | --ports)
                _FLAGS[ports]=$(( ${_FLAGS[ports]:-0} + 1 ))
                (( _FLAGS[ports] == 1 )) || {
                    _error 'The ports option was specified more than once'
                    exit 99
                }

                [[ $# -ge 2 && -n ${2-} && ${2-} != -* ]] || {
                    _error "$1 requires a port list"
                    exit 99
                }

                _OPT_ARGS[ports]=$2
                shift
                ;;

            -n | --name)
                _FLAGS[name]=$(( ${_FLAGS[name]:-0} + 1 ))
                (( _FLAGS[name] == 1 )) || {
                    _error 'The name option was specified more than once'
                    exit 99
                }

                [[ $# -ge 2 && -n ${2-} ]] || {
                    _error "$1 requires a firewall rule name"
                    exit 99
                }

                _OPT_ARGS[name]=$2
                shift
                ;;

            -l | --log)
                _FLAGS[log]=$(( ${_FLAGS[log]:-0} + 1 ))
                (( _FLAGS[log] == 1 )) || {
                    _error 'The log option was specified more than once'
                    exit 99
                }

                [[ $# -ge 2 && -n ${2-} ]] || {
                    _error "$1 requires a file path"
                    exit 99
                }

                _OPT_ARGS[log]=$2
                shift
                ;;

            -q | --quiet)
                _FLAGS[quiet]=$(( ${_FLAGS[quiet]:-0} + 1 ))
                (( _FLAGS[quiet] == 1 )) || {
                    _error 'The quiet option was specified more than once'
                    exit 99
                }
                ;;

            --dry-run)
                _FLAGS[dry_run]=$(( ${_FLAGS[dry_run]:-0} + 1 ))
                (( _FLAGS[dry_run] == 1 )) || {
                    _error 'The dry-run option was specified more than once'
                    exit 99
                }
                ;;

            -h | --help)
                _showHelp
                exit 0
                ;;

            --)
                shift
                (( $# == 0 )) || {
                    _error "Unexpected positional argument: $1"
                    exit 99
                }
                break
                ;;

            *)
                _error "Unknown option: $1. Try -h or --help"
                exit 99
                ;;
        esac

        shift
    done

    [[ -n ${_OPT_ARGS[record]:-} ]] || {
        _error 'A TXT record must be provided with -r or --record'
        exit 99
    }

    [[ ${_OPT_ARGS[record]} =~ ^[A-Za-z0-9_.-]+$ ]] || {
        _error "Invalid TXT record name: ${_OPT_ARGS[record]}"
        exit 99
    }

    _OPT_ARGS[ports]=${_OPT_ARGS[ports]:-$_DEFAULT_PORTS}
    _validatePorts "${_OPT_ARGS[ports]}" || {
        _error "Invalid port list: ${_OPT_ARGS[ports]}. Expected format: 8443/tcp,3306/tcp"
        exit 99
    }

    _OPT_ARGS[ports]=$(_normalizePorts "${_OPT_ARGS[ports]}")

    _RULE_NAME=${_OPT_ARGS[name]:-DDNS TXT - ${_OPT_ARGS[record]}}
    _LOG_FILE=${_OPT_ARGS[log]:-$_DEFAULT_LOG_FILE}
    _QUIET=$(( ${_FLAGS[quiet]:-0} > 0 ? 1 : 0 ))
    _DRY_RUN=$(( ${_FLAGS[dry_run]:-0} > 0 ? 1 : 0 ))

    _systemChecker || exit 1
    _prepareLog || exit 1

    exec 9>"$_LOCK_FILE" || {
        _error "Unable to open lock file: $_LOCK_FILE"
        exit 1
    }

    flock -n 9 || {
        _log 'Another instance is already running; exiting'
        exit 0
    }

    _setup "${_OPT_ARGS[record]}" "$_RULE_NAME" "${_OPT_ARGS[ports]}" || exit 1

    return 0
}

main "$@"
