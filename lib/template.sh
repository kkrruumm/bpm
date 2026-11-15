# bpm templates- lookup, loading, use flags, and the per run index

# the directory that has <pkg>s template
# this is in a specific order to honor repo priority
pkg_find() (
    for repo in $BPM_REPOS; do
        for found in "${repo}/${1}/template" "$repo"/*/"$1"/template "$repo"/*/*/"$1"/template; do
            [ -f "$found" ] && { printf '%s\n' "${found%/template}" ; return 0 ; }
        done
    done

    return 1
)

# use flags
#
# effective flags, lowest prio first:
#   use_flags (template) -> BPM_USE (global) -> package.use (per package)
# later entries will win here, "-flag" disables something, "flag" or "+flag" enables
#
# use_flags lists both the flags a package has and also provides defaults, so like
#   use_flags="man -nls x11"
#
# everything here runs while the template is loaded so their vars are prefixed with __
# so they dont fuck with templates

use_load() {
    USE=$BPM_USE
    [ -r "$BPM_USECONF" ] || return 0

    while read -r __pattern __flags; do
        case "$__pattern" in
            ''|\#*) continue ;;
        esac

        # shellcheck disable=SC2254
        case $1 in 
            $__pattern) USE="$USE $__flags" ;;
        esac
    done < "$BPM_USECONF"
    unset __pattern __flags
}

use() {
    __on=1
    for __use_flag in ${use_flags:-} ${USE:-}; do
        case $__use_flag in
            "$1"|"+$1") __on=0 ;;
            "-$1") __on=1 ;;

        esac
    done

    return $__on
}

usev() { if use "$1"; then printf '%s' "${2:-$1}"; fi; }
use_if() { if use "$1"; then printf '%s' "$2"; else printf '%s' "${3:-}"; fi; }
use_enable() { if use "$1"; then printf -- '--enable-%s' "${2:-$1}"; else printf -- '--disable-%s' "${2:-$1}"; fi; }
use_with() { if use "$1"; then printf -- '--with-%s' "${2:-$1}"; else printf -- '--without-%s' "${2:-$1}"; fi; }
use_bool() { if use "$1"; then printf -- '-D%s=true' "${2:-$1}"; else printf -- '-D%s=false' "${2:-$1}"; fi; }
use_cmake() { if use "$1"; then printf -- '-D%s=ON' "${2:-$1}"; else printf -- '-D%s=OFF' "${2:-$1}"; fi; }

# resolved state of every declared flag so like "-x11 wayland man"
use_effective() {
    __resolved=
    for __declared in ${use_flags:-}; do
        __declared=${__declared#[-+]}
        case " $__resolved " in
            *" $__declared "*|*" -$__declared "*) continue ;;
        esac

        if use "$__declared"; then
            __resolved="$__resolved $__declared"
        else
            __resolved="$__resolved -$__declared"
        fi
    done

    printf '%s\n' "${__resolved# }"
    unset __resolved __declared
}

# template loading
#
# outside of the build stage a template only gets sourced inside of a subshell
# so whatever it sets cant reach the caller
TMPL_VARS='pkg_name version revision short_desc maintainer license home_page
 build_style configure_script configure_args make_cmd make_build_args
 make_build_target make_install_args make_install_target make_check_args
 make_check_target meson_args cmake_build_type cargo_args cargo_install_path
 go_import_path go_package go_build_tags go_ldflags go_mod_mode
 dist_files checksum skip_extract wrk_src build_wrk_src create_wrk_src patch_args
 depends make_depends use_depends conflicts provides
 use_flags allow_network no_strip keep_libtool register_shell
 system_accounts system_groups config_files'

TMPL_FUNCS='do_fetch do_extract do_patch do_configure do_build do_check do_install
 pre_configure post_configure pre_build post_build pre_install post_install
 style_extract style_patch style_configure style_build style_check style_install perl_cleanup'

# no overlaps allowed
tmpl_clear() {
    # per account variables are named after the account
    # so they're cleared while the list naming them is
    # still aroudn
    for __acct in ${system_accounts:-} ${system_groups:-}; do
        for __field in uid gid descr homedir shell groups; do
            unset "${__acct}_$__field" 2>/dev/null || :
        done
    done

    for __var in $TMPL_VARS; do
        unset "$__var" 2>/dev/null || :
    done

    for __fn in $TMPL_FUNCS; do
        unset -f "$__fn" 2>/dev/null || :
    done

    USE= tmpl_dir= pkg_ver=
    unset __acct __field __var __fn
}

tmpl_load() {
    tmpl_clear
    tmpl_dir=$(pkg_find "$1") || die "package '$1' not found in any repository"
    pkg_name=$1
    revision=1
    build_style=gnu-configure
    use_load "$1"
    . "${tmpl_dir}/template"
    [ -n "${version:-}" ] || die "$1: template sets no version"
    [ "$pkg_name" = "$1" ] || die "$1: template declares pkg_name=$pkg_name"
    pkg_ver=$version-$revision
    : "${wrk_src:=$pkg_name-$version}"
    src_dir=$BPM_CACHE/sources/$pkg_name
    build_dir=$BPM_CACHE/build/$pkg_name
    dest_dir=$BPM_CACHE/dest/$pkg_name
    pkg_ar=$(ar_path "$pkg_name" "$pkg_ver")
}

# the index
#
# every template a command interacts with (like bpm i) is sourced once per run
# and what dependency resolution needs goes in $BPM_RUN/index, one line per package:
#
#   name|pkg_ver|use|depends|make_depends|use_depends|tmpl_dir
#
# a package no repo has gets pkg_ver "?", whatever hits that decides
# whether or not that's an error, an installed dep that isnt in
# the repos anymore is not, for example
index_seen=' '

# index_add <pkg>... - index these and everything they depend/makedepend on
index_add() {
    run_dir
    index=$BPM_RUN/index
    : >> "$index"
    queue=$*

    while [ -n "$queue" ]; do
        set -f; set -- $queue; set +f
        queue=

        for name; do
            case $index_seen in
                *" $name "*) continue ;;
            esac

            index_seen="$index_seen$name "
            if ! pkg_find "$name" >/dev/null; then
                printf '%s|?|||||\n' "$name" >> "$index"
                continue
            fi

            # the subshell prints the index line and hands back what to go to next
            next=$(
                tmpl_load "$name" >&2
                set -f
                set -- ${depends:-}; deps=$*
                set -- ${make_depends:-}; mdeps=$*
                set -- ${use_depends:-}; udeps=$*
                printf '%s|%s|%s|%s|%s|%s|%s\n' "$name" "$pkg_ver" "$(use_effective)" \
                    "$deps" "$mdeps" "$udeps" "$tmpl_dir" >> "$index"

                for ud in $udeps; do
                    deps="$deps ${ud%%:*}"
                done

                printf '%s %s' "$deps" "$mdeps"
            ) || exit 1
            queue="$queue $next"
        done
    done
    unset index queue name next
}

# index_get <pkg> <field> - one field of an indexed package by column name
index_get() {
    awk -F'|' -v name="$1" -v field="$2" '
        BEGIN { split("name ver use depends make_depends use_depends dir", col, " ")
                for (i in col) num[col[i]] = i }
        $1 == name { print $num[field]; exit }' "$BPM_RUN/index"
}

# the table graph.awk walks, in $BPM_RUN/table
# this is the index plus a column of flags, ? means in no repo
# c means binary package current, i means installed
index_table() {
    while IFS='|' read -r name ver use deps mdeps udeps dir; do
        flags=
        if [ "$ver" = '?' ]; then
            flags=?
        elif ar_current "$name" "$ver" "$use"; then
            flags=c
        fi

        [ -d "${BPM_DB}/${name}" ] && flags=${flags}i

        printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$name" "$ver" "$use" "$deps" "$mdeps" "$udeps" "$dir" "$flags"
    done < "${BPM_RUN}/index" > "${BPM_RUN}/table"
    unset name ver use deps mdeps udeps dir flags
}

# graph <table> <mode> [list] [list] - a walk over a table, look at graph.awk for more info
# 
# errors come back as the output with status 1 and are fatal
graph() {
    graph_out=$(awk -v mode="$2" -v args="${3:-}" -v extra="${4:-}" -v force="$BPM_FORCE" \
                    -v buildroot="$BPM_BUILDROOT" -v bootstrap="${BPM_BOOTSTRAP:-}" \
                    -f "$BPM_LIBDIR/graph.awk" "$1") || die "$graph_out"
    [ -z "$graph_out" ] || printf '%s\n' "$graph_out"
    unset graph_out
}
