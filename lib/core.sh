# bpm core library
# this is for shit like output, configuration, privilege, compression, hashing

# colors
if [ -t 2 ]; then
    c_ok='\033[1;32m' c_info='\033[1;36m' c_warn='\033[1;33m' c_err='\033[1;31m' c_off='\033[0m'
else
    c_ok= c_info= c_warn= c_err= c_off=
fi
tab=$(printf '\t')

# "typical output" funcs
msg() { printf "${c_ok}=>${c_off} %s\n" "$*" >&2; }
sub() { printf "${c_info}   ->${c_off} %s\n" "$*" >&2; }
warn() { printf "${c_warn}=> warning:${c_off} %s\n" "$*" >&2; }
die() { printf "${c_err}=> error:${c_off} %s\n" "$*" >&2; exit 1; }

# guys please stop using which
have() { command -v "$1" >/dev/null 2>&1; }

# count words without forking
# words "$list"
words() { set -f; set -- $1; set +f; printf '%s\n' "$#"; }

# confirm "<question>" "<what -y would do>"
confirm() {
    [ -t 0 ] || die "not a terminal, pass -y to $2"
    printf '%s [y/N] ' "$1" >&2
    read -r answer || answer=
    case $answer in
        y|Y|yes|YES) unset answer; return 0 ;;
    esac

    unset answer
    return 1
}

# shared opt parser
#
# this is used like:
#   opts "y=yes n=dry-run" "$@"; shift "$opt_shift"
#
# which sets opt_<letter> to 0 or 1 for every letter in the spec
opts() {
    opt_spec=$1; shift
    opt_shift=0

    for opt_s in $opt_spec; do
        eval "opt_${opt_s%%=*}=0"
    done

    while [ $# -gt 0 ]; do
        case $1 in
            --) opt_shift=$((opt_shift + 1))
                break
            ;;
            -?*) ;;
            *) break ;;
        esac

        opt_hit=
        for opt_s in $opt_spec; do
            case $1 in
                "-${opt_s%%=*}"|"--${opt_s#*=}") eval "opt_${opt_s%%=*}=1"; opt_hit=1 ;;
            esac
        done

        [ -n "$opt_hit" ] || die "unknown option: $1 (look at 'bpm help')"
        opt_shift=$((opt_shift + 1)); shift
    done

    unset opt_spec opt_s opt_hit
}

# background stuff and interruption
#
# a background command ignores SIGINT with no form of job control
# and a trap will only run when the foreground command returns, so
# anything long runs int he background and is waited on, which
# a trap actually can interrupt (this is annoying)
spinner_pid= killable_pid= fetch_jobs=

interrupted() {
    trap - INT TERM HUP
    for pid in $killable_pid $spinner_pid $fetch_jobs; do
        kill "${pid%%:*}" 2>/dev/null || :
    done

    wait 2>/dev/null || :
    spinner_wanted && spinner_clear
    warn interrupted

    exit "$1"
}

killable() {
    "$@" &
    killable_pid=$!
    killable_status=0
    wait "$killable_pid" || killable_status=$?
    killable_pid=

    set -- "$killable_status"
    unset killable_status
    return "$1"
}

elapsed() (
    secs=$(( $(date +%s) - $1 ))

    if [ "$secs" -ge 60 ]; then
        printf '%dm%02ds' "$((secs / 60))" "$((secs % 60))"
    else
        printf '%ds' "$secs"
    fi
)

# spinner, this only works on a terminal
# and only when output isnt set to verbose
# POSIX sleep only takes integers so this can
# only tick once per second, good enough
spinner_wanted() { [ -t 2 ] && [ "$BPM_VERBOSE" = 0 ]; }
spinner_clear() { printf '\r\033[K' >&2; }

spinner_start() {
    spinner_wanted || return 0
    spinner_text=$1 spinner_t0=$(date +%s)

    # not using tput here because i dont want
    # to pull in ncurses for no reason
    ( set -- '|' '/' '-' '\'
        while kill -0 "$$" 2>/dev/null; do
            printf "\r${c_info}   ->${c_off} %s %s %s\033[K" "$spinner_text" "$1" "$(elapsed "$spinner_t0")" >&2
            set -- "$2" "$3" "$4" "$1"
            sleep 1
        done ) &

    spinner_pid=$!
    unset spinner_text spinner_t0
}

spinner_stop() {
    [ -n "$spinner_pid" ] || return 0
    kill "$spinner_pid" 2>/dev/null || :
    wait "$spinner_pid" 2>/dev/null || :
    spinner_pid=
    spinner_clear
}

log_tail() {
    [ -s "$1" ] || return 0
    warn "last ${BPM_LOGLINES:-20} lines of $1:"
    tail -n "${BPM_LOGLINES:-20}" "$1" >&2
    printf '\n' >&2
}

# run_logged <label> <logfile> <command>...
#
# output also goes to the terminal with -v
run_logged() {
    log_label=$1 log_file=$2; shift 2
    mkdir -p "${log_file%/*}"
    log_t0=$(date +%s)
    log_status=0

    if [ "$BPM_VERBOSE" = 0 ]; then
        spinner_start "$log_label"
        "$@" > "$log_file" 2>&1 || log_status=$?
        spinner_stop
    else
        # tee eats the status so this comes back through a file
        log_rc=$log_file.rc
        ( set +e; "$@" 2>&1; printf '%s\n' "$?" > "$log_rc" ) | tee "$log_file"
        read -r log_status < "$log_rc" || log_status=1
        rm -f "$log_rc"
    fi

    if [ "$log_status" = 0 ]; then
        sub "$log_label done in $(elapsed "$log_t0")"
    elif [ "$BPM_VERBOSE" = 0 ]; then
        log_tail "$log_file"
    fi

    set -- "$log_status"
    unset log_label log_file log_t0 log_status log_rc
    return "$1"
}

# per run tempdir
run_dir() {
    if [ -z "${BPM_RUN:-}" ]; then
        BPM_RUN=$(mktemp -d "${TMPDIR:-/tmp}/bpm.XXXXXX") || die "cannot create a temporary directory"
        trap 'rm -rf "$BPM_RUN"' EXIT
    fi
}

# configuration stuff
#
# precedence: environment > bpm.conf > the defaults below
# everything is exported because bpm needs to be able to
# read these when it re-execs itself in the sandbox or as root
# with identical settings
#
# bpm.conf also assigns with := so for the settings where
# being empty actually matters (BPM_BUILDROOT= means build against host)
# an empty value from the environment is put back after the file gets read
#
# whatever user runs build owns the cache so its default depends on who
# runs it, root gets /var/cache/bpm, anyone else a cache in their home
# bpm.conf sees that as BPM_DEFAULT_CACHE
config_load() {
    empty_from_env=
    for var in BPM_BUILDROOT BPM_USE; do
        # i'm just as concerned as you don't worry
        # yknow, this language kinda sucks
        eval "if [ -n \"\${$var+set}\" ] && [ -z \"\$$var\" ]; then empty_from_env=\"\$empty_from_env $var\"; fi"
    done

    BPM_UID=$(id -u)
    if [ "$BPM_UID" = 0 ]; then
        BPM_DEFAULT_CACHE=/var/cache/bpm
    else
        BPM_DEFAULT_CACHE=${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/bpm
    fi

    [ -r "$BPM_CONF" ] && . "$BPM_CONF"

    : "${BPM_ROOT:=/}"
    : "${BPM_CACHE:=$BPM_DEFAULT_CACHE}"
    : "${BPM_REPODIR:=/var/db/bpm/repos}"
    : "${BPM_REPOCONF:=/etc/bpm/repos.conf}"
    : "${BPM_USECONF:=/etc/bpm/package.use}"
    : "${BPM_HOOKDIR:=/etc/bpm/hooks}"
    : "${BPM_LOGDIR:=$BPM_CACHE/logs}"
    : "${BPM_CHO:=var/db/bpm/choices}"
    : "${BPM_JOBS:=$(cpu_count)}"
    : "${BPM_FETCH_JOBS:=4}"
    : "${BPM_USE:=}"
    : "${BPM_SANDBOX:=1}"
    : "${BPM_BUILDROOT:=}"
    : "${BPM_BASEPKGS:=}"
    : "${BPM_BROOT_OVERLAY:=1}"
    : "${BPM_BROOT_KEEP:=0}"
    : "${BPM_BROOT_PATH:=/usr/bin:/usr/sbin:/bin:/sbin}"
    : "${BPM_ENV_KEEP:=http_proxy https_proxy ftp_proxy no_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY SOURCE_DATE_EPOCH}"
    : "${BPM_KEEP:=}"
    : "${BPM_AUTOREMOVE:=0}"
    : "${BPM_STRIP:=1}"
    : "${BPM_CHECK:=0}"
    : "${BPM_COMPRESS:=gz}"
    : "${BPM_FORCE:=0}"
    : "${BPM_VERBOSE:=0}"
    : "${BPM_SU:=$(su_cmd)}"
    : "${CFLAGS:=-O2 -pipe}"
    : "${CXXFLAGS:=$CFLAGS}"
    : "${LDFLAGS:=-Wl,-O1,--as-needed}"
    : "${RUSTFLAGS:=-C opt-level=2 -C link-arg=$LDFLAGS}"
    : "${GOFLAGS:=-trimpath}"
    : "${CGO_ENABLED:=1}"

    for var in $empty_from_env; do
        eval "${var}="
    done

    case $BPM_FETCH_JOBS in
        ''|0|*[!0-9]*) die "BPM_FETCH_JOBS must be 1 or more, got '$BPM_FETCH_JOBS'" ;;
    esac

    BPM_ROOT=${BPM_ROOT%/}
    BPM_BUILDROOT=${BPM_BUILDROOT%/}
    BPM_DB=$BPM_ROOT/var/db/bpm/installed
    : "${BPM_REPOS:=$(repo_list)}"
    [ -n "$BPM_REPOS" ] || die "no repositories: set BPM_REPOS or fill $BPM_REPOCONF"

    # a buildroot needs namespaces to be assembled in
    [ -n "$BPM_BUILDROOT" ] && [ "$BPM_SANDBOX" = 0 ] && {
        warn "BPM_SANDBOX=0, ignoring BPM_BUILDROOT and building against the host"
        BPM_BUILDROOT=
    }

    export BPM_ROOT BPM_CACHE BPM_REPOS BPM_REPODIR BPM_REPOCONF BPM_USECONF \
       BPM_HOOKDIR BPM_CHO BPM_JOBS BPM_USE BPM_SANDBOX BPM_STRIP BPM_CHECK \
       BPM_KEEP BPM_AUTOREMOVE BPM_COMPRESS BPM_FORCE BPM_CONF BPM_LIBDIR \
       BPM_DB BPM_LOGDIR BPM_VERBOSE BPM_FETCH_JOBS BPM_BUILDROOT BPM_BASEPKGS \
       BPM_BROOT_OVERLAY BPM_BROOT_KEEP BPM_BROOT_PATH BPM_ENV_KEEP \
       CFLAGS CXXFLAGS LDFLAGS RUSTFLAGS GOFLAGS CGO_ENABLED GOAMD64

    unset empty_from_env var
}

cpu_count() {
    if have nproc; then
        nproc
    else
        grep -c '^processor' /proc/cpuinfo 2>/dev/null || printf '1\n'
    fi
}

su_cmd() {
    for cmd in doas sudo; do
        have "$cmd" && { printf '%s\n' "$cmd"; return 0; }
    done
    printf 'su\n'
}

# 'single quote' every argument so 'su -c' gets back exactly what it was given
shell_quote() (
    for arg; do
        printf "'%s' " "$(printf '%s' "$arg" | sed "s/'/'\\\\''/g")"
    done
)

# run "$@" as root and keep the config
as_root() {
    [ "$BPM_UID" = 0 ] && { "$@"; return; }
    sub "escalating to root with $BPM_SU"
    set -- env "BPM_ROOT=$BPM_ROOT" "BPM_CACHE=$BPM_CACHE" "BPM_CONF=$BPM_CONF" \
            "BPM_LIBDIR=$BPM_LIBDIR" "BPM_COMPRESS=$BPM_COMPRESS" \
            "BPM_REPODIR=$BPM_REPODIR" "BPM_REPOCONF=$BPM_REPOCONF" "$@"

    case $BPM_SU in
        su) su root -c "$(shell_quote "$@")" ;;
        *) "$BPM_SU" "$@" ;;
    esac
}

# the directories a build makes/uses belong to whatever user invokes a build,
# root only ever reads them to install what was build, so check these before
# anything starts
#
# these must be writable, and root building into someone elses cache would
# leave files there its owner can't remove
dir_owner() { ls -ld "$1" | awk '{ print $3 }'; }

builder_dirs_check() {
    for dir in "$BPM_CACHE" "$BPM_LOGDIR" ${BPM_BUILDROOT:+"$BPM_BUILDROOT"}; do
        mkdir -p "$dir" 2>/dev/null || :

        if [ ! -d "$dir" ] || [ ! -w "$dir" ]; then
            owner=$(dir_owner "$dir" 2>/dev/null) || owner=

            die "cannot write to $dir${owner:+ owned by $owner}
    builds write there as the user invoking bpm, which for you defaults to
        BPM_CACHE=$BPM_DEFAULT_CACHE
    set BPM_CACHE (plus BPM_BUILDROOT and BPM_LOGDIR) in $BPM_CONF, or fix its ownership"
        fi

        [ "$BPM_UID" != 0 ] || [ "$(dir_owner "$dir")" = root ] ||
            die "refusing to build as root in $dir, which belongs to $(dir_owner "$dir")
    run bpm as that user (it escalates for installation), or point BPM_CACHE elsewhere"
    done

    unset dir owner
}

# repository stuff
#
# configured in repos.conf, one per line, highest prio first:
#   name url [branch]           cloned into $BPM_REPODIR/name
#   name /absolute/local/path   used in place
repo_list() {
    [ -r "$BPM_REPOCONF" ] || return 0
    awk -v dir="$BPM_REPODIR" '
        /^[ \t]*(#|$)/ { next }
        { printf "%s ", ($2 ~ /^\//) ? $2 : dir "/" $1 }' "$BPM_REPOCONF"
}

# compression, stdin -> stdout filters picked by file extension
# so nothing depends on tar -z/-J/-a or any specific tar impl
compress() {
    case ${1##*.} in
        zst) zstd -c -T0 "-${BPM_ZLEVEL:-19}" ;;
        xz|txz) xz -c -T0 ;;
        gz|tgz) gzip -c ;;
        bz2|tbz2) bzip2 -c ;;
        *) cat ;;
    esac
}

decompress() {
    case ${1##*.} in
        zst) zstd -dc ;;
        xz|txz) xz -dc ;;
        gz|tgz) gzip -dc ;;
        bz2|tbz2) bzip2 -dc ;;
        lz) lzip -dc ;;
        *) cat ;;
    esac
}

# builds are run with LC_ALL=C which libarchives tar has IsSuEs with
tar() { LC_ALL=C.UTF-8 command tar "$@"; }

# untar <archive> <dir> [member...]
untar() (
    untar_file=$1 untar_dir=$2; shift 2
    decompress "$untar_file" < "$untar_file" | tar xf - -C "$untar_dir" "$@"
)

# blake3
hash_have() { have b3sum || have rhash; }

blake3() {
    if have b3sum; then
        # through a variable rather than a pipe so b3sums status sticks
        b3_line=$(b3sum "$1") || { unset b3_line; return 1; }
        b3_line=${b3_line#\\}
        printf '%s\n' "${b3_line%% *}"
        unset b3_line
    elif have rhash; then
        rhash --blake3 --printf='%{blake3}' "$1"
    else
        die "no blake3 implementation found (install b3sum or rhash)"
    fi
}

# newline separated paths on stdin -> one hash per line in the same order
blake3_list() {
    if have b3sum; then
        tr '\n' '\0' | xargs -0 b3sum | sed 's/^\\//; s/ .*//'
    else
        tr '\n' '\0' | xargs -0 rhash --blake3 --printf='%{blake3}\n'
    fi
}

# binary packages
#
# $BPM_CACHE/bin/<name>@<version>-<revision>.tar.<ext> which has its
# own database entry under /var/db/bpm/installed/<name>/
#
# next to it, $BPM_CACHE/bin/meta/<archive name>/ has a copy of that entry
# written by the build so "is this built and with which flags" and "what
# does this install" don't need to decompress anything
ar_path() { printf '%s\n' "${BPM_CACHE}/bin/${1}@${2}.tar.${BPM_COMPRESS}"; }
ar_name() ( ar_base=${1##*/}; ar_base=${ar_base%.tar.*}; printf '%s\n' "${ar_base%@*}" )
ar_ver() ( ar_base=${1##*/}; ar_base=${ar_base%.tar.*}; printf '%s\n' "${ar_base#*@}" )

# ar_meta <archive> - point meta_dir at the archives db entry which
# needs to be there and shouldnt be older than the archive
ar_meta() {
    meta_dir=${1%/*}/meta/${1##*/}
    [ -f "$meta_dir/.stamp" ] && [ -f "$meta_dir/files" ] && [ ! "$1" -nt "$meta_dir/.stamp" ]
}

# ar_current <name> <version> <use> - a binary package exists for exactly this
ar_current() {
    ar_file=$(ar_path "$1" "$2")
    [ -f "$ar_file" ] && ar_meta "$ar_file" || { unset ar_file; return 1; }
    unset ar_file
    ar_use=

    # meta_dir stays, it's what ar_meta hands back
    [ -f "${meta_dir}/use" ] && { read -r ar_use < "${meta_dir}/use" || : ; }
    [ "$ar_use" = "$3" ] || { unset ar_use; return 1; }
    unset ar_use
}

# set operations on files of lines, no grep -f because busybox
# and gnu function differently with what an empty pattern file matches
#   lines_minus <file> <file>...    lines of the first that are in none of the others
#   lines_common <file> <file>      lines of the first that are also in the second
lines_minus() (
    lines_subject=$1; shift
    awk -v subject="$lines_subject" 'FILENAME != subject { drop[$0]; next } !($0 in drop)' "$@" "$lines_subject"
)

lines_common() (
    awk -v subject="$1" 'FILENAME != subject { keep[$0]; next } ($0 in keep)' "$2" "$1"
)
