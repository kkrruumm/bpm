# bpm installed package database, $BPM_DB/<name>/
#
#   version     version-revision
#   use         resolved use flags it was built with
#   depends     runtime dependencies, one per line
#   use_depends dep:flag requirements, one per line
#   files       every owned path
#   accounts    system users and groups
#   shells      paths registered in /etc/shells
#   template    the template it was built from
#   reason      explicit or auto
#   pin         present when pinned
#
# files, one owned path per line, tab separated:
# <path> <type> <class> <value>
#
# type  d directory (the path ends in /), f file, l symlink
# class c configuration (/etc and config_files), - everything else
# value blake3 of a file, target of a symlink, - for directories
#   the packages own db entry, and files built without b3sum
#
# reverse sorted in the C locale so files come before the dirs
# holding them, and a path taken up by an alternative is
# recorded where it's actually at in the choices store,
# 'cut -f1' of this file is the list of everything owned

pkg_installed() { [ -d "${BPM_DB}/${1}" ]; }
pkg_pinned() { [ -f "${BPM_DB}/${1}/pin" ]; }
pkg_version() { cat "${BPM_DB}/${1}/version"; }

pkg_reason() (
    reason=
    [ -f "${BPM_DB}/${1}/reason" ] && {
        read -r reason < "${BPM_DB}/${1}/reason" || :
    }

    case $reason in
        auto) printf '%s\n' 'auto' ;;
        *) printf '%s\n' 'explicit' ;;
    esac
)

require_installed() (
    for pkg; do
        pkg_installed "$pkg" || die "$pkg is not installed"
    done
)

# list every installed package, one per line
pkg_all() (
    for dir in "$BPM_DB"/*/; do
        [ -f "${dir}/version" ] || continue
        dir=${dir%/}
        printf '%s\n' "${dir##*/}"
    done
)

# what install time leaves in reason
#   explicit    requested by the user
#   auto        pulled in as a dep, never demotes an explicit package
#   keep        an upgrade, whatever is recorded stays
pkg_mark_installed() {
    case $2 in
        explicit) printf '%s\n' 'explicit' > "${BPM_DB}/${1}/reason" ;;
        auto) [ -f "${BPM_DB}/${1}/reason" ] || printf '%s\n' 'auto' > "${BPM_DB}/${1}/reason" ;;
        keep) ;;
        *) die "unknown install reason: $2" ;;
    esac
}

# a pin keeps a package at its installed version until the user unpins it
pkg_pin() {
    require_installed "$1"
    pkg_pinned "$1" && {
        sub "$1 is already pinned"
        return 0
    }
    : > "${BPM_DB}/${1}/pin"
    msg "pinned $1 at $(pkg_version "$1")"
}

pkg_unpin() {
    require_installed "$1"
    ! pkg_pinned "$1" && {
        sub "$1 is not pinned"
        return 0
    }
    rm -f "${BPM_DB}/${1}/pin"
    msg "unpinned $1"
}

# the installed packages as a graph.awk table, in $BPM_RUN/db
#
# flags: i installed, e explicit, k matches BPM_KEEP or BPM_BASEPKGS (globs),
# p pinned
db_table() {
    run_dir
    (
        slurp() {
            v=
            [ -f "$1" ] || return 0
            while IFS= read -r l || [ -n "$l" ]; do
                v=${v:+$v }$l
            done < "$1"
        }
        for dir in "$BPM_DB"/*/; do
            set -f; dir=${dir%/}; p=${dir##*/}
            [ -f "${dir}/version" ] || continue
            flags=i
            slurp "${dir}/reason"; [ "$v" != auto ] && flags=${flags}e
            [ -f "${dir}/pin" ] && flags=${flags}p

            for g in ${BPM_KEEP:-} ${BPM_BASEPKGS:-}; do
                case $p in
                    $g) flags=${flags}k; break ;;
                esac
            done

            slurp "${dir}/version"; ver=$v
            slurp "${dir}/use"; use=$v
            slurp "${dir}/depends"
            printf '%s|%s|%s|%s||||%s\n' "$p" "$ver" "$use" "$v" "$flags"
        done
    ) > "${BPM_RUN}/db"
}

# pkg_orphans {pkg...} - orphaned packages, treating the arguments as removed
pkg_orphans() { db_table; graph "${BPM_RUN}/db" orphans "$*"; }

# pkg_rdeps <pkg> [omitted...] - installed packages that still need <pkg>
pkg_rdeps() ( db_table; pkg=$1; shift; graph "${BPM_RUN}/db" rdeps "$pkg" "$*" )

# dependants first, the reverse of the order they went in
remove_order() { db_table; graph "${BPM_RUN}/db" remove "$*"; }

foreign_files() (
    for list in "$BPM_DB"/*/files; do
        if [ -f "$list" ] && [ "$list" != "${BPM_DB}/${1}/files" ]; then
            cut -f1 "$list"
        fi
    done | sort -u
)

pkg_owner() (
    for list in "$BPM_DB"/*/files; do
        if [ -f "$list" ] && flist has "$list" "$1"; then
            list=${list%/files}; printf '%s\n' "${list##*/}"
        fi
    done
)

# alternatives
#
# a path that belongs to another package is put into the choices store
# as <pkg><path> with / swapped for >
# for example, util-linuxs /usr/bin/mount becomes util-linux>usr>bin>mount
cho_name() { printf '%s%s\n' "$1" "$2" | tr '/' '>'; }
cho_path() { printf '/%s\n' "$(printf '%s' "${1#*>}" | tr '>' '/')"; }

pkg_list_alternatives() (
    for choice in "${BPM_ROOT}/${BPM_CHO}"/*; do
        [ -e "$choice" ] || [ -h "$choice" ] || continue
        choice=${choice##*/}
        printf '%s %s\n' "${choice%%>*}" "$(cho_path "$choice")"
    done
)

# files lists
#
# flist <mode> <list> [path]
#   configs     paths of class c
#   get <path>  "<type> <value>" of one path
#   has <path>  status only
#   checkable   "<type>|<value>|<path>" for what has a value to check against,
#               configs only with BPM_VERIFY_CONFIG=1
#
# this is substantially faster in awk as opposed to shell
flist() {
    awk -F'\t' -v mode="$1" -v want="${3:-}" -v configs="${BPM_VERIFY_CONFIG:-0}" '
        mode == "configs" && $3 == "c" && $2 != "d" { print $1 }
        mode == "get" && $1 == want { print $2 " " $4; exit }
        mode == "has" && $1 == want { found = 1; exit }
        mode == "checkable" && $2 != "d" && $4 != "-" && (configs == 1 || $3 != "c") {
            print $2 "|" $4 "|" $1
        }
        END { if (mode == "has") exit !found }' "$2"
}
