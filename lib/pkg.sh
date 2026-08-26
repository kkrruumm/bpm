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

# the cached archive a package was installed with
ar_cached() {
    for _ac in "$BPM_CACHE"/bin/"$1@$2".tar.*; do
        if [ -f "$_ac" ]; then printf '%s\n' "$_ac"; return 0; fi
    done
    return 1
}

# fingerprint/integrity stuffs
#
# every package is built with one checksum per shipped file per line
# of course, without a blake3 impl there's not really a way to know
# if something has been modified or not, in the case of this just
# don't touch anything at all and err on the side of leaving the fs alone
#
# the reason i'm being so barbaric with integrity of package files is just
# because i can, blake3 is fast as fuck so this is probably cheap
hash_have() { have b3sum || have rhash; }

sum_flags() { printf '%s\n' "${1%% *}"; }
sum_value() { _sv=${1#* }; printf '%s\n' "${_sv%%  *}"; }
sum_path()  { _sp=${1#* }; printf '%s\n' "${_sp#*  }"; }

# checksum of a path on disk
sum_disk() {
    if [ -h "$1" ]; then readlink "$1"
    elif [ -f "$1" ] && [ -r "$1" ] && hash_have; then blake3 "$1"
    else return 1; fi
}

# output the checksum line for <path> in checksum file $1, this tolerates whitespace in paths
sums_lookup() {
    [ -n "$1" ] && [ -f "$1" ] || return 1
    while IFS= read -r _sl; do # _sl == _steam locomotive
        if [ "$(sum_path "$_sl")" = "$2" ]; then printf '%s\n' "$_sl"; return 0; fi
    done < "$1"
    return 1
}

# every config path in checksums file $1
sums_configs() {
    [ -n "$1" ] && [ -f "$1" ] || return 0
    while IFS= read -r _sc; do
        case $(sum_flags "$_sc") in *c) sum_path "$_sc" ;; esac
    done < "$1"
}

# this is true when $BPM_ROOT$2 is still what was shipped according to the checksums file $1
# if there isnt a checksum just conisder the file touched and don't do anything
sum_pristine() {
    _sp_l=$(sums_lookup "$1" "$2") || return 1
    _sp_w=$(sum_value "$_sp_l")
    _sp_g=$(sum_disk "$BPM_ROOT$2") || return 1
    case $(sum_flags "$_sp_l") in
        l*) [ -h "$BPM_ROOT$2" ] || return 1 ;;
        *) [ ! -h "$BPM_ROOT$2" ] || return 1 ;;
    esac
    [ "$_sp_w" = "$_sp_g" ]
}

# content comparison that doesnt follow symlinks into nowhere
same_file() {
    if [ -h "$1" ] || [ -h "$2" ]; then
        [ -h "$1" ] && [ -h "$2" ] && [ "$(readlink "$1")" = "$(readlink "$2")" ]
    else
        cmp -s "$1" "$2"
    fi
}

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

    # /etc/ config handling, for every config that exists already,
    # identical to what is being shipped = do nothing at all
    # identical to what was previously shipped = untouched, replace it with the new one
    # anything else = edited, leave it as is and put the new config file at <file>.new
    #
    # the packages checksum lines indicate what files are configs
    # if a package doesn't have a sum then just keep every /etc file it finds
    # since its impossible to know if it's been modified or not
    ar_member "$_ar" "./var/db/bpm/installed/$_name/sums" > "$_tmp/sums" 2>/dev/null || :

    _cand=
    if [ -s "$_tmp/sums" ]; then
        sums_configs "$_tmp/sums" > "$_tmp/cfg"
    else
        rm -f "$_tmp/sums"
        grep '^/etc/.*[^/]$' "$_tmp/new" > "$_tmp/cfg" || :
    fi
    while IFS= read -r f; do
        if [ -e "$BPM_ROOT$f" ] || [ -h "$BPM_ROOT$f" ]; then _cand="$_cand $f"; fi
    done < "$_tmp/cfg"

    _keep=
    if [ -n "$_cand" ]; then
        # staged in a single pass
        rm -rf "$_tmp/cfgstage"; mkdir -p "$_tmp/cfgstage"
        set -f
        set --
        for f in $_cand; do set -- "$@" ".$f"; done
        set +f
        decomp "$_ar" < "$_ar" | tar xf - -C "$_tmp/cfgstage" "$@"

        set -f
        for f in $_cand; do
            if [ ! -e "$_tmp/cfgstage$f" ] && [ ! -h "$_tmp/cfgstage$f" ]; then
                _keep="$_keep $f"; continue
            fi
            # already identical to what the new package has 
            if same_file "$_tmp/cfgstage$f" "$BPM_ROOT$f"; then continue; fi
            # not edited since it was installed
            if sum_pristine "$_tmp/oldsums" "$f"; then
                sub "config unmodified, updating: $f"
                continue
            fi
            _keep="$_keep $f"
        done
        set +f
    fi

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
        rm -f "$BPM_ROOT$f.new"
        cp -Pf "$_tmp/cfgstage$f" "$BPM_ROOT$f.new"
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
    rm -rf "$_tmp/cfgstage"
    rm -f "$_tmp/new" "$_tmp/foreign" "$_tmp/conflict" "$_tmp/stale" \
          "$_tmp/accounts" "$_tmp/sums" "$_tmp/oldsums" "$_tmp/cfg"
}

# back up the current manifest and checksum stuff before an upgrade
# overwrites the db with the one from the new archive
pkg_save_old() {
    _tmp=$BPM_CACHE/tmp/$1; mkdir -p "$_tmp"
    rm -f "$_tmp/old" "$_tmp/oldsums"
    if [ -f "$BPM_DB/$1/manifest" ]; then cp "$BPM_DB/$1/manifest" "$_tmp/old"; fi
    if [ -f "$BPM_DB/$1/sums" ]; then cp "$BPM_DB/$1/sums" "$_tmp/oldsums"; fi
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

    # config is decided one file at a time and everything else just goes
    # the list gets split immediately instead of testing inside the loop
    #
    # the checksum file is read here because the manifest is reverse sorted and
    # will delete /var/db/bpm before the loop gets to /etc
    if [ -f "$BPM_DB/$_name/sums" ]; then
        cp "$BPM_DB/$_name/sums" "$_tmp/sums"
        sums_configs "$_tmp/sums" > "$_tmp/cfg"
    else
        rm -f "$_tmp/sums"
        grep '^/etc/.*[^/]$' "$_tmp/rm" > "$_tmp/cfg" || :
    fi
    if [ -s "$_tmp/cfg" ]; then
        grep -Fxf "$_tmp/cfg" "$_tmp/rm" > "$_tmp/rmcfg" || :
        grep -vxFf "$_tmp/cfg" "$_tmp/rm" > "$_tmp/rmrest" || :
    else
        : > "$_tmp/rmcfg"; cp "$_tmp/rm" "$_tmp/rmrest"
    fi

    hooks pre-remove "$_name"
    msg "removing $_name"

    _oldpath=$PATH
    if tools_stage; then PATH=$_tsdir:$PATH
    else warn "$_name: could not stage rm/rmdir, removal may not finish"
    fi

    # config first, it goes with the package unless it was edited, see comments a bit higher up
    #
    # doing this before the rest means that dirs that had a deleted config still get cleaned up
    # a .new left over from an update is always gotten rid of, it's the default of a package that
    # doesn't exist anymore
    while IFS= read -r f; do
        rm -f "$BPM_ROOT$f.new"
        if sum_pristine "$_tmp/sums" "$f"; then
            rm -f "$BPM_ROOT$f"
        elif [ -e "$BPM_ROOT$f" ] || [ -h "$BPM_ROOT$f" ]; then
            warn "config kept: $f"
        fi
    done < "$_tmp/rmcfg"

    # the manifest is reverse sorted so files precede the directories holding them
    while read -r f; do
        case $f in
            */) rmdir "$BPM_ROOT$f" 2>/dev/null || : ;;
            *) rm -f "$BPM_ROOT$f" ;;
        esac
    done < "$_tmp/rmrest"
    rm -rf "${BPM_DB:?}/$_name" "$_tmp"

    # hooks keep the staged tools becuase they're likely to need a util
    # the package being removed used to provide
    # the staged rm should be able to delete the directory it lives in
    hooks post-remove "$_name"
    rm -rf "$BPM_CACHE/tmp/.tools" 2>/dev/null || :
    PATH=$_oldpath
}

# install reason
#
# a package can be explicit or auto, explicit means it was requested
# and auto means it was pulled as a dependency
#
# this gets written after a package is extracted and doesn't show up in a manifest
# anything that doesn't have this file (old installs or something ig) just falls
# back to explicit
#
# if a user wants to mark a package as explicit, they can just explicitly install it

pkg_reason() {
    if [ -f "$BPM_DB/$1/reason" ]; then
        read -r _pr < "$BPM_DB/$1/reason" || _pr=
        case $_pr in auto|explicit) printf '%s\n' "$_pr"; return 0 ;; esac
    fi
    printf 'explicit\n'
}

pkg_mark() {
    case $1 in
        auto|explicit) ;;
        *) die "unknown install reason: $1 (auto or explicit)" ;;
    esac
    pkg_installed "$2" || die "$2 is not installed"
    printf '%s\n' "$1" > "$BPM_DB/$2/reason"
}

# what pkg_install puts in the db once the package has been extracted
#    explicit - user explicitly installed this
#    auto - pulled as a dep, never demotes a package that was
#           already explicitly installed
#    keep - an upgrade, leave whatever is already recorded alone
pkg_mark_installed() {
    case $2 in
        explicit) pkg_mark explicit "$1" ;;
        auto|keep)
            if [ ! -f "$BPM_DB/$1/reason" ] && [ "$2" = auto ]; then
                pkg_mark auto "$1"
            fi ;;
        *) die "unknown install reason: $2" ;;
    esac
}

# orphans
#
# the runtime dependencies as they were recorded when <pkg> was installed
# package template is read as a fallback
pkg_depends() {
    if [ -f "$BPM_DB/$1/depends" ]; then
        cat "$BPM_DB/$1/depends"
    elif pkg_find "$1" >/dev/null 2>&1; then
        tmpl_get "$1" depends 2>/dev/null || :
    fi
}

# 0 when installed package $1 depends on $2
dep_has() {
    for _dh in $(pkg_depends "$1"); do
        if [ "$_dh" = "$2" ]; then return 0; fi
    done
    return 1
}

# every installed package
pkg_all() {
    for _pa in "$BPM_DB"/*/; do
        [ -f "$_pa/version" ] || continue
        _pa=${_pa%/}
        printf '%s\n' "${_pa##*/}"
    done
}

# packages the caller pretends are already removed so "what would this orphan"
# and "what is already orphaned" are the same walk
pkg_omitted() {
    case " ${BPM_OMIT:-} " in *" $1 "*) return 0 ;; esac
    return 1
}

# installed packages that still depend on $1
pkg_rdeps() {
    for _rd in $(pkg_all); do
        if [ "$_rd" = "$1" ]; then continue; fi
        if pkg_omitted "$_rd"; then continue; fi
        if dep_has "$_rd" "$1"; then printf '%s\n' "$_rd"; fi
    done
}

# mark packages that are on the system in their own right
# anything explicitly installed, anything BPM_KEEP matches, and the buildroot base
keep_walk() {
    case $BPM_KEPT in *" $1 "*) return 0 ;; esac
    pkg_installed "$1" || return 0
    if pkg_omitted "$1"; then return 0; fi
    BPM_KEPT="$BPM_KEPT$1 "
    for _kw in $(pkg_depends "$1"); do keep_walk "$_kw"; done
}

# pkg_orphans [pkg...] - the arguments are treated as already removed
pkg_orphans() {
    BPM_OMIT=$*
    BPM_KEPT=' '
    _oall=$(pkg_all)

    for _op in $_oall; do
        if pkg_omitted "$_op"; then continue; fi
        case $(pkg_reason "$_op") in explicit) keep_walk "$_op" ;; esac
    done

    # globs so "linux*" or "grub" in BPM_KEEP both work
    for _ok in $BPM_KEEP $BPM_BASEPKGS; do
        for _op in $_oall; do
            # shellcheck disable=SC2254
            case $_op in $_ok) keep_walk "$_op" ;; esac
        done
    done

    for _op in $_oall; do
        if pkg_omitted "$_op"; then continue; fi
        case $BPM_KEPT in *" $_op "*) ;; *) printf '%s\n' "$_op" ;; esac
    done
    BPM_OMIT=
}

# dependants are removed before the things they depend on
# which is the reverse of what order they got installed in
#
# post order walk, then reverse, dependencies outside the set are ignored
remove_order() {
    BPM_RSET=" $* " BPM_RSEEN=' ' BPM_RORD=''
    for _ro; do remove_walk "$_ro"; done
    _rrev=
    for _ro in $BPM_RORD; do _rrev="$_ro $_rrev"; done
    printf '%s\n' "${_rrev% }"
}

remove_walk() {
    case $BPM_RSEEN in *" $1 "*) return 0 ;; esac
    BPM_RSEEN="$BPM_RSEEN$1 "
    for _rw in $(pkg_depends "$1"); do
        case $BPM_RSET in *" $_rw "*) remove_walk "$_rw" ;; esac
    done
    BPM_RORD="$BPM_RORD$1 "
}

# verification
#
# where a packaged path is actually at, if it lost a conflict at install time
# the real file in the choices db and the packaged path belongs to whoever won
# see alternatives below
pkg_location() {
    if [ -e "$BPM_ROOT$2" ] || [ -h "$BPM_ROOT$2" ]; then printf '%s\n' "$2"; return 0; fi
    _pl=/$BPM_CHO/$(cho_name "$1" "$2")
    if [ -e "$BPM_ROOT$_pl" ] || [ -h "$BPM_ROOT$_pl" ]; then printf '%s\n' "$_pl"; return 0; fi
    printf '%s\n' "$2"
}

# check a package against its recorded checksums
# this prints <pkg> <path> <reason> per mismatch,
# config files get skipped unless BPM_VERIFY_CONFIG is set to 1
pkg_verify() {
    _name=$1
    _vs=$BPM_DB/$_name/sums
    if [ ! -f "$_vs" ]; then
        BPM_VERIFY_NOSUMS=$((BPM_VERIFY_NOSUMS + 1))
        return 0
    fi
    hash_have || die "no blake3 implementation found (install b3sum)"

    _vst=0
    while IFS= read -r _vl; do
        [ -n "$_vl" ] || continue
        _vf=$(sum_flags "$_vl"); _vw=$(sum_value "$_vl"); _vp=$(sum_path "$_vl")
        case $_vf in *c) [ "$BPM_VERIFY_CONFIG" = 1 ] || continue ;; esac
        _vl_at=$(pkg_location "$_name" "$_vp")
        _vr=
        if [ ! -e "$BPM_ROOT$_vl_at" ] && [ ! -h "$BPM_ROOT$_vl_at" ]; then
            _vr=missing
        elif [ -h "$BPM_ROOT$_vl_at" ]; then
            case $_vf in
                l*) [ "$(readlink "$BPM_ROOT$_vl_at")" = "$_vw" ] || _vr=changed ;;
                *) _vr=type ;;
            esac
        else
            case $_vf in
                l*) _vr=type ;;
                *) if [ ! -r "$BPM_ROOT$_vl_at" ]; then _vr=unreadable
                   elif [ "$(blake3 "$BPM_ROOT$_vl_at")" != "$_vw" ]; then _vr=changed
                   fi ;;
            esac
        fi
        if [ -n "$_vr" ]; then
            printf '%s %s %s\n' "$_name" "$_vp" "$_vr"
            _vst=1
        fi
    done < "$_vs"
    return "$_vst"
}

# put a file back from the original package
pkg_restore() {
    _name=$1 _path=$2
    pkg_installed "$_name" || die "$_name is not installed"
    _rv=$(cat "$BPM_DB/$_name/version")
    _ra=$(ar_cached "$_name" "$_rv") ||
        die "$_name: no cached archive for $_rv in $BPM_CACHE/bin, rebuild it first"

    _rt=$BPM_CACHE/tmp/$_name.restore
    rm -rf "$_rt"; mkdir -p "$_rt"
    decomp "$_ra" < "$_ra" | tar xf - -C "$_rt" ".$_path" 2>/dev/null ||
        die "$_name: $_path is not in $_ra"
    [ -e "$_rt$_path" ] || [ -h "$_rt$_path" ] ||
        die "$_name: $_path is not in $_ra"

    # a path this package lost to an alternative is repaired in the choices db,
    # not moved out of it
    _rl=$(pkg_location "$_name" "$_path")
    mkdir -p "$BPM_ROOT${_rl%/*}"

    # staged beside the target and renamed into place because $_path might be
    # something this is running with
    _rs=$BPM_ROOT$_rl.bpm-new
    rm -f "$_rs"
    cp -Pp "$_rt$_path" "$_rs" || { rm -f "$_rs"; die "$_name: could not stage $_rl"; }
    mv -f "$_rs" "$BPM_ROOT$_rl"
    rm -rf "$_rt"
    msg "restored $_rl from $_name-$_rv"
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
