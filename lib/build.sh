# bpms build stage, everything runs inside of the sandbox with the template loaded
#
# anything here that a template might call or that runs between template functions
# keeps its vars under a __ prefix, templates freely use whatever vars in their own
# functions and whatnot

. "${BPM_LIBDIR}/account.sh"

build_env() {
    DESTDIR=$dest_dir
    FILESDIR=$tmpl_dir/files
    PATCHESDIR=$tmpl_dir/patches
    SOURCEDIR=$src_dir
    make_jobs=-j$BPM_JOBS
    : "${make_cmd:=make}" "${CC:=cc}" "${CXX:=c++}"
    MAKEFLAGS=$make_jobs LC_ALL=C TMPDIR=/tmp
    export DESTDIR FILESDIR PATCHESDIR SOURCEDIR CC CXX CFLAGS CXXFLAGS LDFLAGS \
        MAKEFLAGS LC_ALL TMPDIR pkg_name version revision
}

# build styles provide style_<phase>, a templates own do_<phase> will always win though
# pre_/post_ hooks always run
style_load() {
    case "$build_style" in custom|'') return 0 ;; esac # custom or unspecified means no style
    [ -f "${BPM_LIBDIR}/style/${build_style}.sh" ] || die "unknown build_style: $build_style"
    . "${BPM_LIBDIR}/style/${build_style}.sh" # these are just scripts that have functions
}

# step <name> <default> - do_<name> > style_<name> > the default, nothing if empty
step() {
    if have "do_${1}"; then
        sub "$1"
        "do_${1}"
    elif have "style_${1}"; then
        sub "$1"
        "style_${1}"
    elif [ -n "${2:-}" ]; then
        "$2"
    fi
}

phase() {
    have "pre_${1}" && {
        sub "pre_${1}"
        "pre_${1}"
    }

    step "$1"

    have "post_${1}" && {
        sub "post_${1}"
        "post_${1}"
    }

    # no post_ hook isn't a failure, the && above would otherwise be the status
    return 0
}

# sources

# unpack <file> <dir> - archives are extracted, anything else gets copied
unpack() {
    mkdir -p "$2"
    case $1 in
        *.tar|*.tar.*|*.tgz|*.txz|*.tbz2) untar "$1" "$2" ;;
        *.zip) have unzip || die "unzip is required for ${1##*/}"
            unzip -qo "$1" -d "$2" ;;
        *) cp -f "$1" "$2" ;;
    esac
}

extract() {
    __into=$build_dir
    [ "${create_wrk_src:-no}" = yes ] && {
        __into=${build_dir}/${wrk_src}
        mkdir -p "$__into"
    }

    for __dist in ${dist_files:-}; do
        __file=$src_dir/$(dist_name "$__dist")

        case ${skip_extract:-} in
            *"${__file##*/}"*)
                cp -f "$__file" "$__into"
                continue
            ;;
        esac

        case $__dist in
            git+*)
                cp -R "$__file" "${build_dir}/${wrk_src}"
                continue
            ;;
        esac

        sub "extract ${__file##*/}"
        unpack "$__file" "$__into"
    done
    unset __into __dist __file
}

# bextract <distfile> [subdir] - put a fetched distfile into the build tree
# this is for packages that have several archives or like, if one belongs
# somewhere specific
bextract() {
    [ -f "${src_dir}/${1}" ] || die "bextract: no such distfile: $1"
    __into=$build_dir${2:+/$2}

    case $1 in
        *.zip) 
            mkdir -p "$__into"
            cp -f "${src_dir}/${1}" "$__into"
        ;;
        *) unpack "${src_dir}/${1}" "$__into"
        ;;
    esac
    unset __into
}

# patches/*.patch and *.diff applied in name order
apply_patches() {
    [ -d "$PATCHESDIR" ] || return 0

    __patches=$(
        for __p in "$PATCHESDIR"/*.patch "$PATCHESDIR"/*.diff; do
            [ -f "$__p" ] && printf '%s\n' "$__p"
        done | sort
    )

    for __patch in $__patches; do
        sub "patch ${__patch##*/}"
        patch ${patch_args:--p1} -i "$__patch"
    done
    unset __patches __patch
}

# an archive named after a tag or commit or some other bullshit probably
# wont unpack into $wrk_src, if it made exactly one dir then thats probably it
find_wrk_src() {
    [ ! -d "${build_dir}/${wrk_src}" ] || return 0
    set -- "$build_dir"/*/
    if [ $# -eq 1 ] && [ -d "$1" ]; then
        __found=${1%/}
        wrk_src=${__found##*/}
        sub "wrk_src: $wrk_src"
        unset __found
    fi
}

# packaging section

post_process() {
    if [ "${keep_libtool:-no}" != yes ]; then
        find "$DESTDIR" -name '*.la' -type f -exec rm -f {} + 2>/dev/null || :
    fi

    if [ "$BPM_STRIP" = 1 ] && [ "${no_strip:-no}" != yes ] && have strip; then
        sub "stripping"
        find "$DESTDIR" -type f -perm -u+x -exec strip --strip-unneeded {} + 2>/dev/null || :
    fi
}

# a directory in $DESTDIR that is a symlink in the real root (/usr/sbin -> bin for example)
# gets folded into its target so the package only ever has the real directory
# and its files list doesnt lie about where things actually go
# this is mostly a fix for gtar replacing symlinks with real dirs when it
# extracts over one
dest_fold_symlinks() {
    while :; do
        # shallowest first so /usr/sbin folds before anything in it
        __fold=
        __dirs=$(
            cd "$DESTDIR" && find . -mindepth 1 -type d |
                awk '{ print gsub("/", "/"), substr($0, 2) }' |
                sort -n |
                cut -d' ' -f2-
        )

        for __dir in $__dirs; do
            if [ -h "$BPM_ROOT$__dir" ]; then
                __fold=$__dir
                break
            fi
        done
        [ -n "$__fold" ] || { unset __fold __dirs __dir __target; return 0; }

        __target=$(readlink "$BPM_ROOT$__fold")
        case $__target in
            /*) ;;
            *) __target=${__fold%/*}/$__target ;;
        esac
        [ -d "$BPM_ROOT$__target" ] ||
            die "dest_fold_symlinks: $__fold -> $__target is not a directory in the root"

        case $__target in
            "$__fold"|"$__fold"/*) die "dest_fold_symlinks: $__fold -> $__target is circular" ;;
        esac

        sub "folding $__fold into $__target"
        mkdir -p "$DESTDIR$__target"

        # tar instead of mv for this, nested directories merge instead of nesting
        # dotfiles arent missed and setuid and whatnot survive
        ( cd "$DESTDIR$__fold" && tar cf - . ) | ( cd "$DESTDIR$__target" && tar xf - ) ||
            die "dest_fold_symlinks: could not merge $__fold into $__target"

        rm -rf "${DESTDIR:?}$__fold"
    done
}

# the files list, also look at db.sh
#
# names with a tab or a newline can't be recorded, no real package needs this
# subshelled intentionally
files_create() (
    cd "$DESTDIR" || exit 1
    newline='
'
    odd=$(find . -name "*$tab*" -o -name "*$newline*" | head -n1)
    [ -z "$odd" ] || die "$pkg_name: a packaged path contains a tab or a newline: $odd"

    find . ! -name . -type f ! -path './var/db/bpm/*' > "$BPM_RUN/files.hash"
    : > "${BPM_RUN}/files.sums"
    
    if [ -s "${BPM_RUN}/files.hash" ]; then
        if hash_have; then
            blake3_list < "${BPM_RUN}/files.hash" > "${BPM_RUN}/files.sums"
            [ "$(wc -l < "$BPM_RUN/files.sums")" = "$(wc -l < "$BPM_RUN/files.hash")" ] ||
                die "$pkg_name: hashing the packaged files has failed"
        else
            warn "no blake3 implementation, files recorded without checksums"
        fi
    fi

    set -f; set -- ${config_files:-}; set +f
    configs=" $* "

    # <./path> <type> <value>, then the class goes in and the . comes off
    { awk 'FILENAME == ARGV[1] { sum[FNR] = $0; next }
           { print $0 "\tf\t" ((FNR in sum) ? sum[FNR] : "-") }' "$BPM_RUN/files.sums" "$BPM_RUN/files.hash"
      find . ! -name . -type d | awk '{ print $0 "/\td\t-" }'
      find . ! -name . ! -type d ! -type l \( ! -type f -o -path './var/db/bpm/*' \) | awk '{ print $0 "\tf\t-" }'
      find . ! -name . -type l | while IFS= read -r link; do
          printf '%s\tl\t%s\n' "$link" "$(readlink "$link")"
      done
    } | awk -F'\t' -v OFS='\t' -v configs="$configs" '{
        path = substr($1, 2)
        class = ($2 != "d" && (path ~ /^\/etc\// || index(configs, " " path " "))) ? "c" : "-"
        print path, $2, class, $3
    }' | LC_ALL=C sort -r
)

# write_lines <file> <words> - one word per line, the file only exists if there are any
write_lines() {
    __file=$1; shift
    set -f; set -- $*; set +f
    if [ $# -gt 0 ]; then
        printf '%s\n' "$@" > "$__file"
    else
        rm -f "$__file"
    fi
    unset __file
}

write_db() {
    __db=$DESTDIR/var/db/bpm/installed/$pkg_name
    mkdir -p "$__db"
    cp "${tmpl_dir}/template" "${__db}/template"
    printf '%s\n' "$pkg_ver" > "$__db/version"
    use_effective > "${__db}/use"
    write_lines "${__db}/depends" "${depends:-}"; : >> "${__db}/depends"
    write_lines "$__db/use_depends" "${use_depends:-}"
    write_lines "$__db/shells" "${register_shell:-}"
    acct_records > "$__db/accounts"
    [ -s "${__db}/accounts" ] || rm -f "${__db}/accounts"
    # last and through a redirect that creates it first so it lists itself
    files_create > "${__db}/files"
    unset __db
}

# the archive and next to it the copy of its db entry (look at ar_meta)
create_archive() {
    mkdir -p "${pkg_ar%/*}/meta"
    ( cd "$DESTDIR" && tar cf - . ) | compress "$pkg_ar" > "${pkg_ar}.part"
    __meta=${pkg_ar%/*}/meta/${pkg_ar##*/}
    rm -rf "$__meta" "$__meta.part"
    cp -R "$DESTDIR/var/db/bpm/installed/$pkg_name" "$__meta.part"
    mv -f "$pkg_ar.part" "$pkg_ar"
    mv -f "$__meta.part" "$__meta"
    : > "$__meta/.stamp"
    unset __meta
    msg "built $pkg_ar"
}

# if you're just now looking over this, this would be a good place to start to contextualize
build_run() {
    tmpl_load "$1"
    build_env
    style_load

    rm -rf "$build_dir" "$dest_dir"
    mkdir -p "$build_dir" "$dest_dir"

    # private /tmp keeps the build system droppings off of the host
    # unless the cache itself is there
    [ "$BPM_SANDBOX" = 1 ] && have mount && {
        case $BPM_CACHE in
            /tmp|/tmp/*) ;;
            *) mount -t tmpfs tmpfs /tmp 2>/dev/null || : ;;
        esac
    }
    run_dir

    step extract extract
    find_wrk_src
    cd "$build_dir/$wrk_src" 2>/dev/null || cd "$build_dir"
    step patch apply_patches
    [ -n "${build_wrk_src:-}" ] && {
        mkdir -p "$build_wrk_src"
        cd "$build_wrk_src"
    }

    phase configure
    phase build
    [ "$BPM_CHECK" = 1 ] && phase check
    phase install

    post_process
    dest_fold_symlinks
    write_db
    create_archive
}

# install helpers for templates
# this idea came from void linuxs xbps-src

__dest() { printf '%s\n' "$DESTDIR/${1#/}"; }

# bmkdir [-m mode] <dir>...
bmkdir() {
    __mode=0755
    [ "$1" = -m ] && {
        __mode=$2
        shift 2
    }

    for __d; do
        __t=$(__dest "$__d")
        mkdir -p "$__t"
        chmod "$__mode" "$__t"
    done
    unset __mode __d __t
}

# binstall <file> <mode> <targetdir> [newname]
binstall() {
    [ $# -ge 3 ] || die "usage: binstall <file> <mode> <targetdir> [newname]"
    [ -f "$1" ] || die "binstall: no such file: $1"
    __t=$(__dest "$3")
    __n=${4:-${1##*/}}

    mkdir -p "$__t"
    cp -f "$1" "${__t}/${__n}"
    chmod "$2" "${__t}/${__n}"
    unset __t __n
}

bbin() { binstall "$1" 0755 /usr/bin "${2:-}"; }
blib() { binstall "$1" 0644 /usr/lib "${2:-}"; }
blibexec() { binstall "$1" 0755 "/usr/libexec/$pkg_name" "${2:-}"; }
binclude() { binstall "$1" 0644 /usr/include "${2:-}"; }
bpkgconfig() { binstall "$1" 0644 /usr/lib/pkgconfig "${2:-}"; }
bconf() { binstall "$1" 0644 /etc "${2:-}"; }
blicense() { binstall "$1" 0644 "/usr/share/licenses/$pkg_name" "${2:-}"; }
bdoc() { binstall "$1" 0644 "/usr/share/doc/$pkg_name${2:+/$2}"; }
bdata() { binstall "$1" 0644 "/usr/share/$pkg_name${2:+/$2}"; }

# bman <file> [newname] - the section comes from the extension
bman() {
    __n=${2:-${1##*/}}
    __s=${__n##*.}

    case $__s in 
        [0-9]*) ;;
        *) die "bman: cannot determine man section of $__n" ;;
    esac

    binstall "$1" 0644 "/usr/share/man/man${__s%%[!0-9]*}" "$__n"
    unset __n __s
}

# bcompletion <file> <bash|zsh|fish> [name]
bcompletion() {
    __n=${3:-$pkg_name}
    case $2 in
        bash) binstall "$1" 0644 /usr/share/bash-completion/completions "$__n" ;;
        zsh) binstall "$1" 0644 /usr/share/zsh/site-functions "_$__n" ;;
        fish) binstall "$1" 0644 /usr/share/fish/vendor_completions.d "$__n.fish" ;;
        *) die "bcompletion: unknown shell: $2" ;;
    esac
    unset __n
}

# bcopy <src>... <targetdir> - recursive, globs allowed
bcopy() {
    for __t; do :; done
    __t=$(__dest "$__t")
    mkdir -p "$__t"
    __n=$(($# - 1))
    for __s; do
        [ "$__n" -gt 0 ] || break
        cp -R "$__s" "$__t"
        __n=$((__n - 1))
    done
    unset __t __n __s
}

# bmove <src> <dest> - both inside $DESTDIR
bmove() {
    __d=$(__dest "$2")
    mkdir -p "${__d%/*}"
    mv -f "$(__dest "$1")" "$__d"
    unset __d
}

# bln <target> <linkname>
bln() {
    __l=$(__dest "$2")
    mkdir -p "${__l%/*}"
    ln -sf "$1" "$__l"
    unset __l
}

# bsed <expression> <file>... - portable in place edit, keeps owner and mode
bsed() {
    __e=$1; shift
    for __f; do
        sed "$__e" "$__f" > "$__f.bpmtmp"
        cat "$__f.bpmtmp" > "$__f"
        rm -f "$__f.bpmtmp"
    done
    unset __e __f
}

# brm <path>... - delete inside $DESTDIR (unwanted stuff)
brm() { for __p; do rm -rf "$(__dest "$__p")"; done; unset __p; }
