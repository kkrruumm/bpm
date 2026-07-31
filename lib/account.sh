# bpm system account handling
# prepare for a fucking mess
#
# a template might declare the following:
#
#     system_accounts="messagebus"
#     messagebus_uid=22
#     messagebus_gid=22
#     messagebus_descr="D-Bus system message bus"
#     messagebus_homedir="/var/lib/dbus"
#     messagebus_shell="/bin/false"
#     messagebus_groups="audio video"
#
# and for a group with no account behind it, system_groups="plugdev"
#
# everything else does what it says on the tin

acct_name_ok() {
    case $1 in
        ''|-*|*[!A-Za-z0-9_-]*) return 1 ;;
    esac
}

# the records stored in the packages db entry and read back at install time
#     user:<name>:<uid>:<gid>:<descr>:<home>:<shell>:<extra groups>
#     group:<name>:<gid>
# a - in an id field means allocate one
acct_records() {
    for _a in ${system_groups:-}; do
        acct_name_ok "$_a" || die "system_groups: bad group name '$_a'"
        eval "_ag=\${${_a}_gid:--}"
        printf 'group:%s:%s\n' "$_a" "$_ag"
    done
    for _a in ${system_accounts:-}; do
        acct_name_ok "$_a" || die "system_accounts: bad account name '$_a'"
        eval "_au=\${${_a}_uid:--}"
        eval "_ag=\${${_a}_gid:--}"
        eval "_ad=\${${_a}_descr:-\$_a}"
        eval "_ah=\${${_a}_homedir:-/var/empty}"
        eval "_as=\${${_a}_shell:-/bin/false}"
        eval "_ax=\${${_a}_groups:-}"
        case $_ad$_ah$_as$_ax in
            *:*) die "$_a: ':' cannot appear in a system_accounts field" ;;
        esac
        printf 'user:%s:%s:%s:%s:%s:%s:%s\n' "$_a" "$_au" "$_ag" \
            "$_ad" "$_ah" "$_as" "$(printf '%s' "$_ax" | tr ' ' ',')"
    done
}

# install side

# does <value> appear in field <n> of etc/<file>
acct_has() {
    _f=$BPM_ROOT/etc/$1
    [ -f "$_f" ] || return 1
    cut -d: -f"$2" "$_f" | grep -qxF -- "$3"
}

acct_user_exists() { acct_has passwd 1 "$1"; }
acct_group_exists() { acct_has group  1 "$1"; }
acct_uid_taken() { acct_has passwd 3 "$1"; }
acct_gid_taken() { acct_has group  3 "$1"; }

# name holding <id> in etc/<file>, this is for error messages
acct_id_owner() {
    _f=$BPM_ROOT/etc/$1
    [ -f "$_f" ] || return 0
    grep "^[^:]*:[^:]*:$2:" "$_f" | cut -d: -f1 | head -n1
}

acct_gid_of() {
    grep "^$1:" "$BPM_ROOT/etc/group" | cut -d: -f3 | head -n1
}

# lowest id free on both sides so a new account can usually have uid = gid
acct_free_id() {
    _i=${BPM_SYSID_MIN:-100} _max=${BPM_SYSID_MAX:-999}
    while [ "$_i" -le "$_max" ]; do
        if ! acct_uid_taken "$_i" && ! acct_gid_taken "$_i"; then
            printf '%s\n' "$_i"
            return 0
        fi
        _i=$((_i + 1))
    done
    die "no free system id left in ${BPM_SYSID_MIN:-100}..$_max"
}

# create <name> with <gid> or with an allocated one
# leaves the id it landed on in _acct_gid
group_create() {
    _gn=$1 _gg=$2
    if acct_group_exists "$_gn"; then
        _acct_gid=$(acct_gid_of "$_gn")
        return 0
    fi
    if [ "$_gg" = - ]; then
        _gg=$(acct_free_id)
    elif acct_gid_taken "$_gg"; then
        die "group $_gn: gid $_gg already belongs to $(acct_id_owner group "$_gg")"
    fi
    mkdir -p "$BPM_ROOT/etc"
    printf '%s:x:%s:\n' "$_gn" "$_gg" >> "$BPM_ROOT/etc/group"
    [ ! -f "$BPM_ROOT/etc/gshadow" ] ||
        printf '%s:!::\n' "$_gn" >> "$BPM_ROOT/etc/gshadow"
    sub "group $_gn ($_gg)"
    _acct_gid=$_gg
}

# add <user> to supplementary <group>
group_add_member() {
    _f=$BPM_ROOT/etc/group
    if ! acct_group_exists "$2"; then
        warn "$1: no group '$2' to join"
        return 0
    fi
    _mem=$(grep "^$2:" "$_f" | cut -d: -f4 | head -n1)
    case ",$_mem," in
        *",$1,"*) return 0 ;;
    esac
    if [ -n "$_mem" ]; then _mem=$_mem,$1; else _mem=$1; fi
    # rewritten through cat so the files mode and owner survive
    # this is a stupid ass hack but its "clean" so fuck it
    sed "s|^\($2:[^:]*:[^:]*:\).*|\1$_mem|" "$_f" > "$_f.bpm" && cat "$_f.bpm" > "$_f"
    rm -f "$_f.bpm"
}

user_create() {
    _un=$1 _uu=$2 _ug=$3 _ud=$4 _uh=$5 _us=$6 _ux=$7

    if acct_user_exists "$_un"; then return 0; fi

    # a pinned id is a promise and a clash is fatal, a mirrored one is only a
    # preference and quietly gives way
    if [ "$_ug" = - ]; then
        if [ "$_uu" != - ] && ! acct_gid_taken "$_uu"; then _ug=$_uu; else _ug=$(acct_free_id); fi
    fi
    group_create "$_un" "$_ug"
    _ug=$_acct_gid

    if [ "$_uu" = - ]; then
        if acct_uid_taken "$_ug"; then _uu=$(acct_free_id); else _uu=$_ug; fi
    elif acct_uid_taken "$_uu"; then
        die "$_un: uid $_uu already belongs to $(acct_id_owner passwd "$_uu")"
    fi

    mkdir -p "$BPM_ROOT/etc"
    printf '%s:x:%s:%s:%s:%s:%s\n' "$_un" "$_uu" "$_ug" "$_ud" "$_uh" "$_us" \
        >> "$BPM_ROOT/etc/passwd"
    # ! is not a valid hash so nothing will ever authenticate as this account
    [ ! -f "$BPM_ROOT/etc/shadow" ] ||
        printf '%s:!:%s::::::\n' "$_un" "$(( $(date +%s) / 86400 ))" \
            >> "$BPM_ROOT/etc/shadow"

    for _g in $(printf '%s' "$_ux" | tr ',' ' '); do group_add_member "$_un" "$_g"; done
    sub "account $_un ($_uu:$_ug)"
}

accounts_apply() {
    [ -s "$1" ] || return 0
    while IFS=: read -r _t _n _r1 _r2 _r3 _r4 _r5 _r6; do
        case $_t in
            user) user_create "$_n" "$_r1" "$_r2" "$_r3" "$_r4" "$_r5" "$_r6" ;;
            group) group_create "$_n" "$_r1" ;;
            ''|\#*) : ;;
            *) warn "unrecognised account record '$_t'" ;;
        esac
    done < "$1"
}
