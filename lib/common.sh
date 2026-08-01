# bpm common library, sourced by bpm(1) and by the build stage

if [ -t 2 ]; then
    CG='\033[1;32m'; CB='\033[1;36m'; CY='\033[1;33m'; CR='\033[1;31m'; CN='\033[0m'
else
    CG=''; CB=''; CY=''; CR=''; CN=''
fi

msg() { printf "${CG}=>${CN} %s\n" "$*" >&2; }
sub() { printf "${CB}   ->${CN} %s\n" "$*" >&2; }
warn() { printf "${CY}=> warning:${CN} %s\n" "$*" >&2; }
die() { printf "${CR}=> error:${CN} %s\n" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# build output
# a builds stdout and stderr go to $BPM_LOGDIR/<pkg>.log instead of the
# terminal, -v (BPM_VERBOSE=1) tees it through as well
# the log is written either way, so 'bpm log <pkg> can read back a failure

elapsed() {
    _el=$(( $(date +%s) - $1 ))
    if [ "$_el" -ge 60 ]; then printf '%dm%02ds' "$((_el / 60))" "$((_el % 60))"
    else printf '%ds' "$_el"; fi
}

log_tail() {
    [ -s "$1" ] || return 0
    warn "last ${BPM_LOGLINES:-20} lines of $1:"
    tail -n "${BPM_LOGLINES:-20}" "$1" >&2
    printf '\n' >&2
}

# run_logged <label> <logfile> <command>... - returns the commands status
run_logged() {
    _rl_label=$1 _rl_log=$2
    shift 2
    mkdir -p "${_rl_log%/*}" "$BPM_CACHE/tmp"
    _rl_start=$(date +%s)
    _rl_st=0

    if [ "$BPM_VERBOSE" = 0 ]; then
        "$@" > "$_rl_log" 2>&1 || _rl_st=$?
    else
        # status comes back through a file
        _rl_rc=$BPM_CACHE/tmp/rc.$$
        rm -f "$_rl_rc"
        ( set +e; "$@" 2>&1; printf '%s\n' "$?" > "$_rl_rc" ) | tee "$_rl_log"
        _rl_st=$(cat "$_rl_rc" 2>/dev/null || echo 1)
        rm -f "$_rl_rc"
    fi

    if [ "$_rl_st" = 0 ]; then
        sub "$_rl_label done in $(elapsed "$_rl_start")"
    elif [ "$BPM_VERBOSE" = 0 ]; then
        log_tail "$_rl_log"
    fi
    return "$_rl_st"
}

# configuration
# precedence: environment > config file > built-in defaults
#
# exported variables here win which is what lets bpm re-exec itself
# with identical settings

# settings where an empty value in the environment is a potentially valid value,
# BPM_BUILDROOT= means "build against the host", BPM_USE= means "no
# global flags, leave the templates use_default alone"
#
# bpm.conf assigns with :=, which fills in its default over an empty value as
# readily as over an unset one, so which of these arrived empty has to be
# remembered before the file is read and applied again after
BPM_EMPTY_OK='BPM_BUILDROOT BPM_USE'

config_load() {
    _empty=
    for _e in $BPM_EMPTY_OK; do
        eval "if [ -n \"\${$_e+x}\" ] && [ -z \"\$$_e\" ]; then _empty=\"\$_empty $_e\"; fi"
    done

    if [ -r "$BPM_CONF" ]; then . "$BPM_CONF"; fi

    : "${BPM_ROOT:=/}"
    : "${BPM_CACHE:=/var/cache/bpm}"
    : "${BPM_REPODIR:=/var/db/bpm/repos}"
    : "${BPM_REPOCONF:=/etc/bpm/repos.conf}"
    : "${BPM_USECONF:=/etc/bpm/package.use}"
    : "${BPM_HOOKDIR:=/etc/bpm/hooks}"
    : "${BPM_LOGDIR:=$BPM_CACHE/logs}"
    : "${BPM_CHO:=var/db/bpm/choices}"
    : "${BPM_JOBS:=$(cpu_count)}"
    : "${BPM_USE:=}"
    : "${BPM_SANDBOX:=1}"
    : "${BPM_BUILDROOT:=}"
    : "${BPM_BASEPKGS:=}"
    : "${BPM_BROOT_OVERLAY:=1}"
    : "${BPM_BROOT_KEEP:=0}"
    : "${BPM_BROOT_PATH:=/usr/bin:/usr/sbin:/bin:/sbin}"
    : "${BPM_ENV_KEEP:=http_proxy https_proxy ftp_proxy no_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY SOURCE_DATE_EPOCH}"
    : "${BPM_STRIP:=1}"
    : "${BPM_CHECK:=0}"
    : "${BPM_COMPRESS:=gz}"
    : "${BPM_FORCE:=0}"
    : "${BPM_VERBOSE:=0}"
    : "${BPM_SU:=$(su_cmd)}"
    : "${CFLAGS:=-O2 -pipe}"
    : "${CXXFLAGS:=$CFLAGS}"
    : "${LDFLAGS:=-Wl,-O1,--as-needed}"

    for _e in $_empty; do eval "$_e="; done

    BPM_ROOT=${BPM_ROOT%/}
    BPM_BUILDROOT=${BPM_BUILDROOT%/}
    BPM_DB=$BPM_ROOT/var/db/bpm/installed
    : "${BPM_REPOS:=$(repo_list)}"
    [ -n "$BPM_REPOS" ] || die "no repositories: set BPM_REPOS or fill $BPM_REPOCONF"

    # a build root without namespaces to set it up in is not a build root
    if [ -n "$BPM_BUILDROOT" ] && [ "$BPM_SANDBOX" = 0 ]; then
        warn "BPM_SANDBOX=0, ignoring BPM_BUILDROOT and building against the host"
        BPM_BUILDROOT=
    fi

    export BPM_ROOT BPM_CACHE BPM_REPOS BPM_REPODIR BPM_REPOCONF BPM_USECONF \
           BPM_HOOKDIR BPM_CHO BPM_JOBS BPM_USE BPM_SANDBOX BPM_STRIP BPM_CHECK \
           BPM_COMPRESS BPM_FORCE BPM_CONF BPM_LIBDIR BPM_DB BPM_LOGDIR BPM_VERBOSE \
           BPM_BUILDROOT BPM_BASEPKGS BPM_BROOT_OVERLAY BPM_BROOT_KEEP \
           BPM_BROOT_PATH BPM_ENV_KEEP \
           CFLAGS CXXFLAGS LDFLAGS
}

cpu_count() {
    if have nproc; then nproc
    elif [ -r /proc/cpuinfo ]; then grep -c '^processor' /proc/cpuinfo || echo 1
    else echo 1; fi
}

su_cmd() {
    if have doas; then echo doas
    elif have sudo; then echo sudo
    else echo su; fi
}

# run "$@" as root, carrying the configuration
as_root() {
    if [ "$(id -u)" = 0 ]; then "$@"; return 0; fi
    sub "escalating with $BPM_SU"
    set -- env "BPM_ROOT=$BPM_ROOT" "BPM_CACHE=$BPM_CACHE" "BPM_CONF=$BPM_CONF" \
               "BPM_LIBDIR=$BPM_LIBDIR" "BPM_COMPRESS=$BPM_COMPRESS" "$@"
    case $BPM_SU in
        su) su root -c "$*" ;; # note: no quoting, use doas/sudo for odd paths
        *) "$BPM_SU" "$@" ;;
    esac
}

# repository shit
#
# repos.conf, one per line, highest priority first:
#    name url [branch] -> cloned into $BPM_REPODIR/name
#    name /absolute/local/path -> used in place

repo_list() {
    [ -r "$BPM_REPOCONF" ] || return 0
    while read -r _rname _rurl _; do
        case $_rname in ''|\#*) continue ;; esac
        case $_rurl in
            /*) printf '%s ' "$_rurl" ;;
            *) printf '%s ' "$BPM_REPODIR/$_rname" ;;
        esac
    done < "$BPM_REPOCONF"
}

# print the directory holding <pkg>s template honoring repo order
pkg_find() {
    for _r in $BPM_REPOS; do
        if [ -f "$_r/$1/template" ]; then printf '%s\n' "$_r/$1"; return 0; fi
    done
    return 1
}

# use flags
#
# effective flag list, lowest priority first:
#    use_default (template) -> BPM_USE (global) -> package.use (per package)
# later entries win, "-flag" disables, "flag" or "+flag" enables

use_load() {
    USE=$BPM_USE
    [ -r "$BPM_USECONF" ] || return 0
    while read -r _pat _flags; do
        case $_pat in ''|\#*) continue ;; esac
        # shellcheck disable=SC2254
        case $1 in $_pat) USE="$USE $_flags" ;; esac
    done < "$BPM_USECONF"
}

# note: these run inside template loops, so their variables are named to not
# collide with anything a template or another helper is likely to be using
use() {
    __ur=1
    for __uf in ${use_default:-} ${USE:-}; do
        case $__uf in
            "$1"|"+$1") __ur=0 ;;
            "-$1") __ur=1 ;;
        esac
    done
    return $__ur
}

usev() { if use "$1"; then printf '%s' "${2:-$1}"; fi; }
use_if() { if use "$1"; then printf '%s' "$2"; else printf '%s' "${3:-}"; fi; }
use_enable() { if use "$1"; then printf -- '--enable-%s'  "${2:-$1}"; else printf -- '--disable-%s' "${2:-$1}"; fi; }
use_with() { if use "$1"; then printf -- '--with-%s' "${2:-$1}"; else printf -- '--without-%s' "${2:-$1}"; fi; }
use_bool() { if use "$1"; then printf -- '-D%s=true' "${2:-$1}"; else printf -- '-D%s=false' "${2:-$1}"; fi; }
use_cmake() { if use "$1"; then printf -- '-D%s=ON' "${2:-$1}"; else printf -- '-D%s=OFF' "${2:-$1}"; fi; }

# resolved state of every declared flag, so like "-x11 wayland doc"
use_effective() {
    __ue=
    for __un in ${use_flags:-}; do
        if use "$__un"; then __ue="$__ue $__un"; else __ue="$__ue -$__un"; fi
    done
    printf '%s\n' "${__ue# }"
}

# package templates

TMPL_VARS='pkg_name version revision short_desc maintainer license home_page
 build_style configure_script configure_args make_cmd make_build_args
 make_build_target make_install_args make_install_target make_check_args
 make_check_target meson_args cmake_build_type qmake_cmd zig_build_args
 cargo_args cargo_install_path gem_spec stackage
 go_import_path go_package go_build_tags go_ldflags go_mod_mode
 dist_files checksum skip_extract wrk_src build_wrk_src create_wrk_src patch_args
 depends make_depends host_make_depends conflicts provides
 use_flags use_default allow_network no_strip keep_libtool
 system_accounts system_groups'

TMPL_FUNCS='do_fetch do_extract do_patch do_configure do_build do_check do_install
 pre_configure post_configure pre_build post_build pre_install post_install
 style_extract style_patch style_configure style_build style_check style_install perl_cleanup'

tmpl_clear() {
    # the per account variables are named after the account, so they can only
    # be cleared while the list that names them is still around
    for _a in ${system_accounts:-} ${system_groups:-}; do
        for _s in uid gid descr homedir shell groups; do
            unset "${_a}_$_s" 2>/dev/null || :
        done
    done
    for _v in $TMPL_VARS; do unset "$_v" 2>/dev/null || :; done
    for _f in $TMPL_FUNCS; do unset -f "$_f" 2>/dev/null || :; done
    USE= tmpl_dir= pkg_ver=
}

tmpl_load() {
    tmpl_clear
    tmpl_dir=$(pkg_find "$1") || die "package '$1' not found in any repository"
    pkg_name=$1
    revision=1
    build_style=gnu-configure
    use_load "$1"
    . "$tmpl_dir/template"
    [ -n "${version:-}" ] || die "$1: template sets no version"
    [ "$pkg_name" = "$1" ] || die "$1: template declares pkg_name=$pkg_name"
    pkg_ver=$version-$revision
    : "${wrk_src:=$pkg_name-$version}"
    src_dir=$BPM_CACHE/sources/$pkg_name
    build_dir=$BPM_CACHE/build/$pkg_name
    dest_dir=$BPM_CACHE/dest/$pkg_name
    pkg_ar=$BPM_CACHE/bin/$pkg_name@$pkg_ver.tar.$BPM_COMPRESS
}

# read variables from a template without disturbing the current one
tmpl_get() {
    ( tmpl_load "$1" >/dev/null; shift
      for _v; do eval "printf '%s ' \"\${$_v:-}\""; done )
}

# dependency resolution
#
# post-order walk: dependencies are emitted before their dependants
# already installed dependencies are not revisited while explicitly named packages always are

deps_order() {
    _seen=' ' _order=''
    for _p; do dep_walk "$_p"; done
    printf '%s\n' "${_order% }"
}

dep_walk() {
    case $_seen in *" $1 "*) return 0 ;; esac
    _seen="$_seen$1 "
    for _d in $(tmpl_get "$1" depends make_depends host_make_depends); do
        if ! pkg_installed "$_d"; then dep_walk "$_d"; fi
    done
    _order="$_order$1 "
}

pkg_installed() { [ -d "$BPM_DB/$1" ]; }

# runtime closure of the named packages, post-order
#
# what the host has installed is irrelevant here: this answers "what has to be
# unpacked into a build root for these to work", not "what is missing"
rdeps_closure() {
    _rseen=' ' _rout=''
    for _rp in "$@"; do rdep_walk "$_rp"; done
    printf '%s\n' "${_rout% }"
}

rdep_walk() {
    case $_rseen in *" $1 "*) return 0 ;; esac
    _rseen="$_rseen$1 "
    for _rd in $(tmpl_get "$1" depends); do rdep_walk "$_rd"; done
    _rout="$_rout$1 "
}

# 0 if a binary package exists that matches the templates version, revision and
# resolved use flags, subshelled so the callers loaded template survives
ar_current() {
    ( tmpl_load "$1"
      [ -f "$pkg_ar" ] || exit 1
      _ac=$(ar_member "$pkg_ar" "./var/db/bpm/installed/$pkg_name/use" 2>/dev/null || echo)
      [ "$_ac" = "$(use_effective)" ] )
}

# filters on stdin/stdout, selected by file extension, so there's not a dependency on
# tars -a/-J/-z or on any particular tar implementation

comp() {
    case ${1##*.} in
        zst) zstd -c -T0 "-${BPM_ZLEVEL:-19}" ;;
        xz|txz) xz -c -T0 ;;
        gz|tgz) gzip -c ;;
        bz2|tbz2) bzip2 -c ;;
        *) cat ;;
    esac
}

decomp() {
    case ${1##*.} in
        zst) zstd -dc ;;
        xz|txz) xz -dc ;;
        gz|tgz) gzip -dc ;;
        bz2|tbz2) bzip2 -dc ;;
        lz) lzip -dc ;;
        *) cat ;;
    esac
}

# sources
# dist_files entries:
#    https://host/path/file.tar.gz - checksummed tarball
#    https://host/download?v=1>foo-1.tar.gz - renamed on disk
#    git+https://host/repo.git#tag - git checkout, checksum "SKIP"
#    file:///absolute/path.tar.gz - local file

dist_name() {
    case $1 in
        *'>'*) printf '%s\n' "${1##*>}" ;;
        git+*) _u=${1%%#*}; _u=${_u%.git}; printf '%s\n' "${_u##*/}" ;;
        *) _u=${1%%\?*}; printf '%s\n' "${_u##*/}" ;;
    esac
}

fetch_url() {
    sub "fetch ${1}"
    case $1 in
        file://*) cp -f "${1#file://}" "$2.part" ;;
        *) if have curl; then curl -fL --retry 3 -o "$2.part" "$1"
           elif have wget; then wget -O "$2.part" "$1"
           else die "neither curl nor wget found"; fi ;;
    esac
    mv -f "$2.part" "$2"
}

fetch_git() {
    _url=${1#git+}; _ref=${_url##*#}; _url=${_url%%#*}
    [ "$_ref" = "$_url" ] && _ref=HEAD || :
    if [ -d "$2/.git" ]; then
        sub "update $_url"
        git -C "$2" fetch -q --tags origin
    else
        sub "clone $_url"
        git clone -q "$_url" "$2"
    fi
    git -C "$2" checkout -q --detach "$_ref"
    git -C "$2" submodule -q update --init --recursive
}

src_fetch() {
    mkdir -p "$src_dir"
    for _d in ${dist_files:-}; do
        _f=$src_dir/$(dist_name "$_d")
        case $_d in
            git+*) fetch_git "$_d" "$_f" ;;
            *) if [ ! -f "$_f" ]; then fetch_url "${_d%%>*}" "$_f"; fi ;;
        esac
    done
}

blake3() {
    if have b3sum; then b3sum "$1" | cut -d' ' -f1
    elif have rhash; then rhash --blake3 --printf='%{blake3}' "$1"
    else die "no blake3 implementation found (install b3sum or rhash)"; fi
}

src_verify() {
    _n=0
    set -- ${checksum:-}
    for _d in ${dist_files:-}; do
        _n=$((_n + 1))
        case $_d in git+*) continue ;; esac
        _f=$src_dir/$(dist_name "$_d")
        eval "_want=\${$_n:-}"
        [ -n "$_want" ] || die "$pkg_name: missing checksum for ${_f##*/}"
        case $_want in SKIP) continue ;; esac
        _got=$(blake3 "$_f")
        _cmp=${#_want}
        if [ "${#_got}" -lt "$_cmp" ]; then _cmp=${#_got}; fi
        if [ "$(printf '%s' "$_want" | cut -c"1-$_cmp")" != \
             "$(printf '%s' "$_got"  | cut -c"1-$_cmp")" ]; then
            die "$pkg_name: blake3 mismatch for ${_f##*/}
    expected $_want
    got      $_got"
        fi
    done
}
