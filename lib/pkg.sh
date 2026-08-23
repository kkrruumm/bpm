# bpm installed-package handling (install, remove, ownership, hooks)
#
# a binary package is a tarball whose payload already contains its own database
# entry under /var/db/bpm/installed/<name>/, so installing is pretty much just extracting

# helpers

# name and version encoded in an archive path: /path/foo@1.2.3-1.tar.zst
ar_name() { _b=${1##*/}; _b=${_b%.tar.*}; printf '%s\n' "${_b%@*}"; }
ar_ver() { _b=${1##*/}; _b=${_b%.tar.*}; printf '%s\n' "${_b#*@}"; }

# extract one member to stdout
ar_member() { decomp "$1" < "$1" | tar xOf - "$2"; }

hooks() {
    for _h in "$BPM_HOOKDIR/$1"/*; do
        if [ -x "$_h" ]; then "$_h" "$2" "$BPM_ROOT/" || warn "hook ${_h##*/} failed"; fi
    done
}

# replace the literal exact line $2 with $3, this needs to happen due to things like
# /usr/bin/[ fucking up regex
manifest_repoint() {
    _mr_hit=
    while IFS= read -r _mr_l; do
        if [ "$_mr_l" = "$2" ]; then _mr_hit=1; printf '%s\n' "$3"
        else printf '%s\n' "$_mr_l"
        fi
    done < "$1"
    [ -n "$_mr_hit" ]
}

# every path owned by an installed package other than $1
foreign_files() {
    for _m in "$BPM_DB"/*/manifest; do
        if [ -f "$_m" ] && [ "$_m" != "$BPM_DB/$1/manifest" ]; then cat "$_m"; fi
    done
}

# install

pkg_install() {
    _ar=$1
    [ -f "$_ar" ] || die "no such package archive: $_ar"
    _name=$(ar_name "$_ar") _ver=$(ar_ver "$_ar")
    _tmp=$BPM_CACHE/tmp/$_name; mkdir -p "$_tmp"

    ar_member "$_ar" "./var/db/bpm/installed/$_name/manifest" > "$_tmp/new" ||
        die "$_name: archive contains no manifest"

    # files someone else already owns get stashed as alternatives instead of
    # blowing up, whoever got there first keeps the real path
    _chos=
    foreign_files "$_name" | sort -u > "$_tmp/foreign"
    if [ -s "$_tmp/foreign" ]; then
        grep -Fxf "$_tmp/foreign" "$_tmp/new" | grep -v '/$' > "$_tmp/conflict" || :
        if [ -s "$_tmp/conflict" ]; then
            _chos=$(tr '\n' ' ' < "$_tmp/conflict")
            warn "$_name: $(wc -l < "$_tmp/conflict") file(s) stashed as alternatives (bpm a)"
        fi
    fi

    # never overwrite existing configuration, add it as <file>.new instead
    _keep=
    while read -r f; do
        case $f in
            /etc/*/|/etc/) continue ;;
            /etc/*) if [ -e "$BPM_ROOT$f" ]; then _keep="$_keep $f"; fi ;;
        esac
    done < "$_tmp/new"

    # accounts first, pre-install hooks and the payload itself may refer to them
    ar_member "$_ar" "./var/db/bpm/installed/$_name/accounts" > "$_tmp/accounts" 2>/dev/null || :
    accounts_apply "$_tmp/accounts"

    hooks pre-install "$_name"
    msg "installing $_name-$_ver"

    set -f
    set --
    for f in $_keep; do set -- "$@" "--exclude=.$f"; done
    for f in $_chos; do set -- "$@" "--exclude=.$f"; done
    set +f
    decomp "$_ar" < "$_ar" | tar xf - -C "${BPM_ROOT:-}/" "$@"

    # pull the conflicting files out into the choices store and repoint this
    # packages manifest at them, tar rather than ar_member so modes survive
    if [ -n "$_chos" ]; then
        rm -rf "$_tmp/cho"; mkdir -p "$_tmp/cho" "$BPM_ROOT/$BPM_CHO"
        set -f
        set --
        for f in $_chos; do set -- "$@" ".$f"; done
        set +f
        decomp "$_ar" < "$_ar" | tar xf - -C "$_tmp/cho" "$@"

        _m=$BPM_DB/$_name/manifest
        set -f
        for f in $_chos; do
            _c=$(cho_name "$_name" "$f")
            manifest_repoint "$_m" "$f" "/$BPM_CHO/$_c" > "$_m.t" ||
                die "$_name: $f missing from manifest, refusing to stash it"
            mv -f "$_tmp/cho$f" "$BPM_ROOT/$BPM_CHO/$_c"
            mv -f "$_m.t" "$_m"
        done
        set +f
        sort -r "$_m" > "$_m.t" && mv -f "$_m.t" "$_m"
        rm -rf "$_tmp/cho"
    fi

    set -f
    for f in $_keep; do
        ar_member "$_ar" ".$f" > "$BPM_ROOT$f.new"
        warn "config preserved: $f (new version in $f.new)"
    done
    set +f

    # on upgrade drop files the new version no longer ships
    if [ -f "$_tmp/old" ]; then
        grep -vxFf "$_tmp/new" "$_tmp/old" > "$_tmp/stale" || :
        while read -r f; do
            case $f in
                */) rmdir "$BPM_ROOT$f" 2>/dev/null || : ;;
                *) rm -f "$BPM_ROOT$f" ;;
            esac
        done < "$_tmp/stale"
        rm -f "$_tmp/old"
    fi

    hooks post-install "$_name"
    rm -f "$_tmp/new" "$_tmp/foreign" "$_tmp/conflict" "$_tmp/stale" "$_tmp/accounts"
}

# back up the currently installed manifest before an upgrade overwrites it
pkg_save_old() {
    _tmp=$BPM_CACHE/tmp/$1; mkdir -p "$_tmp"
    if [ -f "$BPM_DB/$1/manifest" ]; then cp "$BPM_DB/$1/manifest" "$_tmp/old"; fi
}

# package removal

# rm and rmdir get ran once per manifest line so removing hte package that
# owns them deletes halfway down the list and every remaining file gets left on the disk
tools_stage() {
    _tsdir=$BPM_CACHE/tmp/.tools
    rm -rf "$_tsdir" || return 1
    mkdir -p "$_tsdir" || return 1
    for _t in rm rmdir; do
        _tp=$(command -v "$_t") || return 1
        [ -n "$_tp" ] || return 1
        cp -f "$_tp" "$_tsdir/$_t" || return 1
        chmod 755 "$_tsdir/$_t" || return 1
    done
}

pkg_remove() {
    _name=$1
    pkg_installed "$_name" || die "$_name is not installed"

    # anything still needed by another package stays
    _tmp=$BPM_CACHE/tmp/$_name; mkdir -p "$_tmp"
    foreign_files "$_name" | sort -u > "$_tmp/foreign"
    if [ -s "$_tmp/foreign" ]; then
        grep -vxFf "$_tmp/foreign" "$BPM_DB/$_name/manifest" > "$_tmp/rm" || :
    else
        cp "$BPM_DB/$_name/manifest" "$_tmp/rm"
    fi

    hooks pre-remove "$_name"
    msg "removing $_name"

    _oldpath=$PATH
    if tools_stage; then PATH=$_tsdir:$PATH
    else warn "$_name: could not stage rm/rmdir, removal may not finish"
    fi

    # the manifest is reverse sorted so files precede the directories holding them
    while read -r f; do
        case $f in
            */) rmdir "$BPM_ROOT$f" 2>/dev/null || : ;;
            *) rm -f "$BPM_ROOT$f" ;;
        esac
    done < "$_tmp/rm"
    rm -rf "${BPM_DB:?}/$_name" "$_tmp"

    # hooks keep the staged tools becuase they're likely to need a util
    # the package being removed used to provide
    # the staged rm should be able to delete the directory it lives in
    hooks post-remove "$_name"
    rm -rf "$BPM_CACHE/tmp/.tools" 2>/dev/null || :
    PATH=$_oldpath
}

# queries

pkg_owner() {
    for _m in "$BPM_DB"/*/manifest; do
        if [ -f "$_m" ] && grep -qFx "$1" "$_m"; then
            _o=${_m%/manifest}; printf '%s\n' "${_o##*/}"
        fi
    done
}

# alternatives

# a choice is stored as <pkg><path> with / swapped for >, so util-linux and
# /usr/bin/mount become util-linux>usr>bin>mount
cho_name() { printf '%s%s\n' "$1" "$2" | tr '/' '>'; }
cho_path() { printf '/%s\n' "$(printf '%s' "${1#*>}" | tr '>' '/')"; }

pkg_list_alternatives() {
    for _c in "$BPM_ROOT/$BPM_CHO"/*; do
        if [ -e "$_c" ] || [ -h "$_c" ]; then
            _b=${_c##*/}
            printf '%s %s\n' "${_b%%>*}" "$(cho_path "$_b")"
        fi
    done
}

# hand <path> over to <pkg>, demoting whoever owns it now
pkg_swap() {
    pkg_installed "$1" || die "$1 is not installed"
    _c=$(cho_name "$1" "$2")
    [ -e "$BPM_ROOT/$BPM_CHO/$_c" ] || [ -h "$BPM_ROOT/$BPM_CHO/$_c" ] ||
        die "no alternative '$1 $2'"

    # #2 might be one of the things this function runs, /usr/bin/mv being the main one
    # due to this, stage the transaction, this should be atomic
    _own= _oc=
    if [ -e "$BPM_ROOT$2" ] || [ -h "$BPM_ROOT$2" ]; then
        _own=$(pkg_owner "$2" | head -n1)
        [ -n "$_own" ] || die "$2 exists but no package owns it"
        _oc=$(cho_name "$_own" "$2")
    fi

    # both manifests are written to temps before anything on disk gets touched
    _mn=$BPM_DB/$1/manifest
    manifest_repoint "$_mn" "/$BPM_CHO/$_c" "$2" > "$_mn.t" ||
        die "$1: /$BPM_CHO/$_c missing from manifest, refusing to promote it"
    if [ -n "$_own" ]; then
        _mo=$BPM_DB/$_own/manifest
        manifest_repoint "$_mo" "$2" "/$BPM_CHO/$_oc" > "$_mo.t" ||
            die "$_own: $2 missing from manifest, refusing to demote it"
    fi

    _stage=$BPM_ROOT$2.bpm-new
    rm -f "$_stage"
    cp -a "$BPM_ROOT/$BPM_CHO/$_c" "$_stage" || die "$1: could not stage $2"
    if [ -n "$_own" ]; then
        msg "swapping $2 from $_own to $1"
        cp -a "$BPM_ROOT$2" "$BPM_ROOT/$BPM_CHO/$_oc" ||
            { rm -f "$_stage"; die "$_own: could not stash $2"; }
    fi

    # the only step that touches the live path, a rename within one directory
    mv -f "$_stage" "$BPM_ROOT$2"
    rm -f "$BPM_ROOT/$BPM_CHO/$_c"

    mv -f "$_mn.t" "$_mn"
    sort -r "$_mn" > "$_mn.t" && mv -f "$_mn.t" "$_mn"
    if [ -n "$_own" ]; then
        mv -f "$_mo.t" "$_mo"
        sort -r "$_mo" > "$_mo.t" && mv -f "$_mo.t" "$_mo"
    fi
}
