# bpm system account handling
# this script is a tad annoying to read, tried my best to comment it though
#
# a template can specify the following:
#   system_accounts="messagebus"
#   messagebus_uid=22
#   messagebus_gid=22
#   messagebus_descr="D-Bus system message bus"
#   messagebus_homedir="/var/lib/dbus"
#   messagebus_shell="/bin/false"
#   messagebus_groups="audio video"
#   ...for example.
#
#   to specify a group with no account, one may:
#   system_groups="plugdev"
#
# this all gets recorded in the packages database entry as:
#   user:<name>:<uid>:<gid>:<descr>:<home>:<shell>:<extra,groups>
#   group:<name>:<gid>
# where an id of - means allocate one

acct_name_ok() {
    case $1 in
        '')
            return 1
        ;;

        -*)
            return 1
        ;;

        *[!A-Za-z0-9_-]*)
            # at least one character outside of the allowed set
            # this also catches spaces, newlines, globs, quotes, '/', etc
            return 1
        ;;
    esac

    return 0
}

# build side, this bit runs with the template loaded
# oo spooky evals time
#
# () on purpose: this runs in the build stage alongside the template, so acct,
# uid, gid, home, shell and the rest must not stay set in that shell
acct_records() (
    for acct in ${system_groups:-}; do
        acct_name_ok "$acct" || die "system_groups: bad group name '$acct'"
        eval "gid=\${${acct}_gid:--}" # spit out like gid=1001 with name_gid=1001 for example
        printf 'group:%s:%s\n' "$acct" "$gid" # will output like group:name:1001 with alice_gid=1001
    done

    for acct in ${system_accounts:-}; do
        acct_name_ok "$acct" || die "system_accounts: bad account name '$acct'"
        eval "uid=\${${acct}_uid:--} gid=\${${acct}_gid:--}" # same type of indirect expansion as in the above loop
        eval "descr=\${${acct}_descr:-\$acct} home=\${${acct}_homedir:-/var/empty}"
        eval "shell=\${${acct}_shell:-/bin/false} groups=\${${acct}_groups:-}"

        # this is handled like this because posix shell
        # doesnt allow for wildcards otherwise
        case $descr$home$shell$groups in
            *:*) die "$acct: ':' cannot appear in a system_accounts field" ;;
        esac

        # globbing has to be off for this or something like * (lol) would be
        # replaced by filenames in the current dir
        #
        # if you're not super familiar with shell, set -- $groups then expands
        # the parts of $groups into arguments, so like $1 = wheel, $2 = audio for example
        set -f; set -- $groups; set +f
        groups=$(IFS=,; printf '%s' "$*")
        printf 'user:%s:%s:%s:%s:%s:%s:%s\n' "$acct" "$uid" "$gid" "$descr" "$home" "$shell" "$groups"
    done
)

# install side
# inlining awk for this stuff *is* a bit slower
# but for the sake of readability it's probably for the best
#
# a lot of these functions use () instead of {} intentionally
# so their body is run in a subshell which keeps their stuff local
# to that subshell

# field <file> <n> <value> - etc/<file> has <value> in field <n> of some line
# field <file> <n> <value> <m> - and prints field <m> of that line
acct_field() (
    [ -f "${BPM_ROOT}/etc/${1}" ] || return 1
    awk -F: -v n="$2" -v value="$3" -v m="${4:-0}" '
        $n == value { found = 1; if (m) print $m; exit }
        END { exit !found }' "${BPM_ROOT}/etc/${1}"
)

# the lowest id free as a uid and gid, new accounts usually get uid = gid
acct_free_id() (
    cat "${BPM_ROOT}/etc/passwd" "${BPM_ROOT}/etc/group" 2>/dev/null |
        awk -F: -v min="${BPM_SYSID_MIN:-100}" -v max="${BPM_SYSID_MAX:-999}" '
           { taken[$3] }
            END { for (id = min; id <= max; id++) if (!(id in taken)) { print id; exit 0 }; exit 1 }' ||
            die "no free system id left in ${BPM_SYSID_MIN:-100}..${BPM_SYSID_MAX:-999}"
)

# group_create <name> <gid|-> - leaves the gid it wound up with in group_gid
group_create() {
    group_gid=$(acct_field group 1 "$1" 3) && return 0
    group_gid=$2

    if [ "$group_gid" = - ]; then
        group_gid=$(acct_free_id) # grab a free ID
    elif acct_field group 3 "$group_gid" >/dev/null; then
        die "group $1: gid $group_gid already belongs to $(acct_field group 3 "$group_gid" 1)"
    fi

    mkdir -p "${BPM_ROOT}/etc"
    printf '%s:x:%s:\n' "$1" "$group_gid" >> "${BPM_ROOT}/etc/group"

    [ -f "${BPM_ROOT}/etc/gshadow" ] &&
        printf '%s:!::\n' "$1" >> "${BPM_ROOT}/etc/gshadow"

    # also what keeps a missing gshadow from becoming this function's status;
    # group_gid stays set, it's what the caller reads
    sub "group $1 ($group_gid)"
}

# group_add_member <user> <group>
group_add_member() {
    ! acct_field group 1 "$2" >/dev/null &&
        { warn "$1: no group '$2' to join"; return 0; }

    group_file=$BPM_ROOT/etc/group
    awk -F: -v OFS=: -v user="$1" -v group="$2" '
        $1 == group && index("," $4 ",", "," user ",") == 0 { $4 = ($4 == "" ? user : $4 "," user) }
        { print }' "$group_file" > "$group_file.bpm"

    # this is rewritten specifically with > so the file keeps its owner and mode
    cat "$group_file.bpm" > "$group_file"; rm -f "$group_file.bpm"
    unset group_file
}

user_create() {
    user=$1 uid=$2 gid=$3 descr=$4 home=$5 shell=$6 groups=$7
    acct_field passwd 1 "$user" >/dev/null && return 0

    if [ "$gid" = - ]; then
        if [ "$uid" != - ] && ! acct_field group 3 "$uid" > /dev/null; then
            gid=$uid
        else
            gid=$(acct_free_id)
        fi
    fi
    group_create "$user" "$gid"
    gid=$group_gid

    if [ "$uid" = - ]; then
        if acct_field passwd 3 "$gid" >/dev/null; then
            uid=$(acct_free_id)
        else
            uid=$gid
        fi
    elif acct_field passwd 3 "$uid" >/dev/null; then
        die "$user: uid $uid already belongs to $(acct_field passwd 3 "$uid" 1)"
    fi

    mkdir -p "${BPM_ROOT}/etc"
    printf '%s:x:%s:%s:%s:%s:%s\n' "$user" "$uid" "$gid" "$descr" "$home" "$shell" >> "$BPM_ROOT/etc/passwd"

    # ! isn't supposed to be a valid hash, nothing will ever auth as this account
    # in theory, unless someone makes another stinky
    [ -f "${BPM_ROOT}/etc/shadow" ] &&
        printf '%s:!:%s::::::\n' "$user" "$(( $(date +%s) / 86400 ))" >> "$BPM_ROOT/etc/shadow"

    saved_ifs=$IFS; IFS=,; set -f
    set -- $groups
    IFS=$saved_ifs; set +f

    for group; do
        group_add_member "$user" "$group"
    done

    sub "account $user ($uid:$gid)"
    unset user uid gid descr home shell groups saved_ifs group group_gid
}

accounts_apply() (
    [ -s "$1" ] || return 0
    while IFS=: read -r kind name f1 f2 f3 f4 f5 f6; do
        case $kind in
            user) user_create "$name" "$f1" "$f2" "$f3" "$f4" "$f5" "$f6" ;;
            group) group_create "$name" "$f1" ;;
            ''|\#*) ;;
            *) warn "unrecognised account record '$kind'" ;;
        esac
    done < "$1"
)
