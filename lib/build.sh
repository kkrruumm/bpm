# bpms build stage, runs inside the sandbox

build_env() {
    DESTDIR=$dest_dir
    FILESDIR=$tmpl_dir/files
    PATCHESDIR=$tmpl_dir/patches
    SOURCEDIR=$src_dir
    make_jobs=-j$BPM_JOBS
    : "${make_cmd:=make}"
    : "${CC:=cc}" ; : "${CXX:=c++}"
    export DESTDIR FILESDIR PATCHESDIR SOURCEDIR CC CXX CFLAGS CXXFLAGS LDFLAGS
    export MAKEFLAGS="$make_jobs"
    export LC_ALL=C
    export TMPDIR=/tmp
    export pkg_name version revision
}

# build styles supply style_configure/style_build/style_check/style_install
# a template's own do_* always wins, and pre_/post_ hooks always run
style_load() {
    case $build_style in
        custom|"") return 0 ;;
    esac
    _s=$BPM_LIBDIR/style/$build_style.sh
    [ -f "$_s" ] || die "unknown build_style: $build_style"
    . "$_s"
}

phase() {
    if have "pre_$1"; then sub "pre_$1"; "pre_$1";  fi
    if have "do_$1"; then sub "$1"; "do_$1"
    elif have "style_$1"; then sub "$1"; "style_$1"
    fi
    if have "post_$1"; then sub "post_$1"; "post_$1"; fi
}

# source preparation shit

extract() {
    if [ "${create_wrk_src:-no}" = yes ]; then mkdir -p "$build_dir/$wrk_src"; _into=$build_dir/$wrk_src
    else _into=$build_dir; fi

    for _d in ${dist_files:-}; do
        _f=$src_dir/$(dist_name "$_d")
        case ${skip_extract:-} in *"${_f##*/}"*) cp -f "$_f" "$_into"; continue ;; esac
        case $_d in
            git+*) cp -R "$_f" "$build_dir/$wrk_src" ; continue ;;
        esac
        sub "extract ${_f##*/}"
        case $_f in
            *.tar|*.tar.*|*.tgz|*.txz|*.tbz2)
                decomp "$_f" < "$_f" | tar xf - -C "$_into" ;;
            *.zip)
                have unzip || die "unzip is required for ${_f##*/}"
                unzip -qo "$_f" -d "$_into" ;;
            *)
                cp -f "$_f" "$_into" ;;
        esac
    done
}

apply_patches() {
    [ -d "$PATCHESDIR" ] || return 0
    # sorted across both extensions so patches come in the correct order
    # patch names must not contain whitespace
    _list=$(for _f in "$PATCHESDIR"/*.patch "$PATCHESDIR"/*.diff; do
            if [ -f "$_f" ]; then printf '%s\n' "$_f"; fi
        done | sort)
    for _p in $_list; do
        sub "patch ${_p##*/}"
        patch ${patch_args:--Np1} -i "$_p"
    done
}

# bextract <distfile> [subdir] - place an already fetched distfile into the
# build tree
#
# this is for packages that ship more than one archive or need one
# unpacked somewhere other than the root of the source directory
bextract() {
    _bf=$src_dir/$1
    [ -f "$_bf" ] || die "bextract: no such distfile: $1"
    _bd=$build_dir${2:+/$2}
    mkdir -p "$_bd"
    case $_bf in
        *.tar|*.tar.*|*.tgz|*.txz|*.tbz2)
            decomp "$_bf" < "$_bf" | tar xf - -C "$_bd" ;;
        *)
            cp -f "$_bf" "$_bd" ;;
    esac
}

# post processing shit

post_process() {
    if [ "${keep_libtool:-no}" != yes ]; then
        find "$DESTDIR" -name '*.la' -type f -exec rm -f {} + 2>/dev/null || :
    fi
    if [ "$BPM_STRIP" = 1 ] && [ "${no_strip:-no}" != yes ] && have strip; then
        sub "stripping"
        find "$DESTDIR" -type f -perm -u+x -exec strip --strip-unneeded {} + 2>/dev/null || :
    fi
}

# the manifest lists every path the package owns, directories with a trailing
# slash, reverse sorted so that removal deletes files before their directories
manifest_create() {
    ( cd "$DESTDIR" && find . ! -name . | while read -r f; do
        if [ -d "$f" ] && [ ! -L "$f" ]; then printf '%s/\n' "${f#.}"
        else printf '%s\n' "${f#.}"; fi
      done ) | sort -r
}

write_db() {
    _d=$DESTDIR/var/db/bpm/installed/$pkg_name
    mkdir -p "$_d"
    cp "$tmpl_dir/template" "$_d/template"
    printf '%s\n' "$pkg_ver" > "$_d/version"
    printf '%s\n' "$(use_effective)"  > "$_d/use"
    printf '%s\n' "${depends:-}" > "$_d/depends"
    acct_records > "$_d/accounts"
    [ -s "$_d/accounts" ] || rm -f "$_d/accounts"
    manifest_create > "$_d/manifest"
}

create_archive() {
    mkdir -p "${pkg_ar%/*}"
    ( cd "$DESTDIR" && tar cf - . ) | comp "$pkg_ar" > "$pkg_ar.part"
    mv -f "$pkg_ar.part" "$pkg_ar"
    msg "built $pkg_ar"
}

build_run() {
    tmpl_load "$1"
    build_env
    style_load

    rm -rf "$build_dir" "$dest_dir"
    mkdir -p "$build_dir" "$dest_dir"
    # a private /tmp keeps build system bullshit out of the hosts, but must
    # not shadow a cache that lives underneath it
    if [ "$BPM_SANDBOX" = 1 ] && have mount; then
        case $BPM_CACHE in
            /tmp|/tmp/*) ;;
            *) mount -t tmpfs tmpfs /tmp 2>/dev/null || : ;;
        esac
    fi

    # archives don't always unpack "cleanly" if they'renamed after a tag or commit
    # if the expected directory isn't here but the archive created exactly one of its
    # own, use that instead
    if [ ! -d "$build_dir/$wrk_src" ]; then
        _ndir=0
        for _cand in "$build_dir"/*/; do
            if [ -d "$_cand" ]; then _ndir=$((_ndir + 1)); _wsrc=$_cand; fi
        done
        if [ "$_ndir" = 1 ]; then
            _wsrc=${_wsrc%/}
            wrk_src=${_wsrc##*/}
            sub "wrk_src: $wrk_src"
        fi
    fi

    # precedence everywhere: template do_* > style_* > bpms default
    if have do_extract; then do_extract
    elif have style_extract; then style_extract
    else extract; fi

    cd "$build_dir/$wrk_src" 2>/dev/null || cd "$build_dir"
    if have do_patch; then do_patch
    elif have style_patch; then style_patch
    else apply_patches; fi
    if [ -n "${build_wrk_src:-}" ]; then mkdir -p "$build_wrk_src"; cd "$build_wrk_src"; fi

    phase configure
    phase build
    if [ "$BPM_CHECK" = 1 ]; then phase check; fi
    phase install

    post_process
    write_db
    create_archive
}

# install wrappers for package templates
# these exist to try to keep templates consistent, idea more or less
# stolen from void linux
#
# everything below writes relative to $DESTDIR and is built from mkdir/cp/chmod

_bdest() { printf '%s\n' "$DESTDIR/${1#/}"; }

# bmkdir [-m mode] <dir>...
bmkdir() {
    _m=0755
    if [ "$1" = -m ]; then _m=$2; shift 2; fi
    for _d; do
        _t=$(_bdest "$_d")
        mkdir -p "$_t"
        chmod "$_m" "$_t"
    done
}

# binstall <file> <mode> <targetdir> [newname]
binstall() {
    [ $# -ge 3 ] || die "usage: binstall <file> <mode> <targetdir> [newname]"
    [ -f "$1" ] || die "binstall: no such file: $1"
    _t=$(_bdest "$3"); _n=${4:-${1##*/}}
    mkdir -p "$_t"
    cp -f "$1" "$_t/$_n"
    chmod "$2" "$_t/$_n"
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

# bman <file> [newname] - section taken from the file extension
bman() {
    _n=${2:-${1##*/}}
    _s=${_n##*.}
    case $_s in
        [0-9]*) ;;
        *) die "bman: cannot determine man section of $_n" ;;
    esac
    binstall "$1" 0644 "/usr/share/man/man${_s%%[!0-9]*}" "$_n"
}

# bcompletion <file> <bash|zsh|fish> [name]
bcompletion() {
    _n=${3:-$pkg_name}
    case $2 in
        bash) binstall "$1" 0644 /usr/share/bash-completion/completions "$_n" ;;
        zsh) binstall "$1" 0644 /usr/share/zsh/site-functions "_$_n" ;;
        fish) binstall "$1" 0644 /usr/share/fish/vendor_completions.d "$_n.fish" ;;
        *) die "bcompletion: unknown shell: $2" ;;
    esac
}

# bcopy <src>... <targetdir> - recursive, globs allowed
bcopy() {
    for _t; do :; done
    _t=$(_bdest "$_t")
    mkdir -p "$_t"
    _n=$(($# - 1))
    for _s; do
        [ "$_n" -gt 0 ] || break
        cp -R "$_s" "$_t"
        _n=$((_n - 1))
    done
}

# bmove <src> <dest> - both inside $DESTDIR
bmove() {
    _d=$(_bdest "$2")
    mkdir -p "${_d%/*}"
    mv -f "$(_bdest "$1")" "$_d"
}

# bln <target> <linkname>
bln() {
    _l=$(_bdest "$2")
    mkdir -p "${_l%/*}"
    ln -sf "$1" "$_l"
}

# bsed <expression> <file>... - portable in-place edit
bsed() {
    _e=$1; shift
    for _f; do
        sed "$_e" "$_f" > "$_f.bpmtmp"
        cat "$_f.bpmtmp" > "$_f"
        rm -f "$_f.bpmtmp"
    done
}

# brm <path>... - delete inside $DESTDIR (e.g. unwanted docs)
brm() { for _p; do rm -rf "$(_bdest "$_p")"; done; }
