# install side stuff for bpm
# install, remove, alternatives, restore, verify
#
# a binary package contains its db entry so installing is
# just an extraction
#
# an install operation decompresses the archive generally twice,
# once for the files that are decided before they're put on the fs
# (existing configs, paths another package owns) and once for the
# actual payload
#
# the metadata comes from the copy next to the archive (look at ar_meta)

. "${BPM_LIBDIR}/account.sh"

# hooks <event> <pkg> [version] - every hook is given <pkg> <root> <version>
# as arguments
hooks() (
    for hook in "${BPM_HOOKDIR}/${1}"/*; do
        [ -x "$hook" ] || continue
        "$hook" "$2" "${BPM_ROOT}/" "${3:-}" || warn "hook ${hook##*/} failed"
    done
)

exists() { [ -e "$1" ] || [ -h "$1" ]; }

# content comparison that won't follow symlinks into nowhere
same_file() {
    if [ -h "$1" ] || [ -h "$2" ]; then
        [ -h "$1" ] && [ -h "$2" ] && [ "$(readlink "$1")" = "$(readlink "$2")" ]
    else
        cmp -s "$1" "$2"
    fi
}

# pristine <files list> <path> - $BPM_ROOT<path> is still what the list says
# was shipped, no list no value or no hash impl means it cant be known
# so it isnt
pristine() (
    [ -f "$1" ] || return 1
    shipped=$(flist get "$1" "$2")
    case $shipped in
        ''|*' -') return 1 ;;
        l*) [ -h "$BPM_ROOT$2" ] && [ "$(readlink "$BPM_ROOT$2")" = "${shipped#* }" ] ;;
        *) [ ! -h "$BPM_ROOT$2" ] && [ -f "$BPM_ROOT$2" ] && hash_have &&
            [ "$(blake3 "$BPM_ROOT$2")" = "${shipped#* }" ] ;;
    esac
)

# repoint <files list> <map> - move entries to new paths
repoint() {
    awk -F'\t' -v OFS='\t' '
        FILENAME == ARGV[1] { to[$1] = $2; left++; next }
        ($1 in to) { if (!hit[$1]++) left--; $1 = to[$1] }
        { print }
        END { exit left > 0 }' "$2" "$1" > "${1}.new" || { rm -f "${1}.new"; return 1; }
    LC_ALL=C sort -r "${1}.new" > "$1" && rm -f "${1}.new"
}

# the paths column of a files list
paths() { cut -f1 "$1"; }

# paths on stdin, this is reverse sorted so files are before
# the dirs that contain them
remove_paths() (
    while IFS= read -r path; do
        case $path in
            */) rmdir "${BPM_ROOT}${path}" 2>/dev/null || : ;;
            *) rm -f "${BPM_ROOT}${path}" ;;
        esac
    done
)

# /etc/shells, register_shell="/usr/bin/bash /bin/bash" in a template
shells_add() (
    [ -s "$1" ] || return 0
    shells=$BPM_ROOT/etc/shells

    while IFS= read -r shell; do
        [ -n "$shell" ] || continue
        grep -qxF -- "$shell" "$shells" 2>/dev/null && continue
        printf '%s\n' "$shell" >> "$shells"
        sub "registered shell $shell"
    done < "$1"
)

# shells_del <list> <pkg> - paths registered by other installed packages stay
shells_del() (
    shells=$BPM_ROOT/etc/shells
    [ -s "$1" ] && [ -f "$shells" ] || return 0
    run_dir

    for other in "$BPM_DB"/*/shells; do
        [ -f "$other" ] && [ "$other" != "${BPM_DB}/${2}/shells" ] && cat "$other"
    done > "${BPM_RUN}/shells.keep"

    awk 'FILENAME == ARGV[1] { keep[$0]; next } !($0 in keep)' \
        "${BPM_RUN}/shells.keep" "$1" > "${BPM_RUN}/shells.gone"
    [ -s "${BPM_RUN}/shells.gone" ] || return 0

    # rewritten with > so the file keeps owner and mode
    awk 'FILENAME == ARGV[1] { gone[$0]; next } !($0 in gone)' \
        "${BPM_RUN}/shells.gone" "$shells" > "${BPM_RUN}/shells.new"

    cat "${BPM_RUN}/shells.new" > "$shells"

    while IFS= read -r shell ; do
        sub "unregistered shell $shell"
    done < "${BPM_RUN}/shells.gone"
)

pkg_install() {
    archive=$1
    [ -f "$archive" ] || die "no such package archive: $archive"
    name=$(ar_name "$archive") ver=$(ar_ver "$archive")
    run_dir
    work=$BPM_RUN/install.${name}
    rm -rf "$work"; mkdir -p "${work}/stage"
    ar_meta "$archive" || die "${name}: no database entry next to $archive (rebuild it)"
    new_files=$meta_dir/files
    paths "$new_files" > "${work}/new.paths"

    # the installed versions entry before the payload overwrites it
    for file in files shells; do
        [ -f "${BPM_DB}/${name}/${file}" ] && cp "${BPM_DB}/${name}/${file}" "${work}/old.$file"
    done
    foreign_files "$name" > "${work}/foreign"

    # a file another package owns is stashed as an alternative
    # whatever put the file there first keeps the path
    lines_common "${work}/new.paths" "${work}/foreign" | grep -v '/$' > "${work}/conflicts" || :
    [ -s "${work}/conflicts" ] && warn "$name: $(wc -l < "${work}/conflicts") file(s) stashed as alternatives (bpm a)"

    # configs that already exist have a bit of "smart" handling,
    #   identical to the new one        nothing to do
    #   as shipped by the prior ver     replaced
    #   anything else                   edited, kept, the new one goes to <file>.new
    flist configs "$new_files" |
        while IFS= read -r path; do
            ! exists "$BPM_ROOT$path" || printf '%s\n' "$path"
        done > "${work}/configs"

    # just what has to be looked at before it's deployed
    cat "${work}/configs" "${work}/conflicts" | sed 's|^|.|' > "${work}/staged"
    [ -s "${work}/staged" ] && untar "$archive" "${work}/stage" -T "${work}/staged"

    : > "${work}/keep"
    while IFS= read -r path; do
        ! exists "${work}/stage${path}" && continue
        same_file "${work}/stage${path}" "$BPM_ROOT$path" && continue
        pristine "${work}/old.files" "$path" && sub "config unmodified, updating: $path" && continue
        printf '%s\n' "$path" >> "${work}/keep"
    done < "${work}/configs"

    # accounts first because hooks and payloads might need them
    accounts_apply "${meta_dir}/accounts"
    hooks pre-install "$name" "$ver"
    msg "installing ${name}-${ver}"

    # second step, the payload
    cat "${work}/keep" "${work}/conflicts" | sed 's|^|.|' > "${work}/exclude"
    untar "$archive" "${BPM_ROOT}/" -X "${work}/exclude"

    [ -s "${work}/conflicts" ] && {
        awk -v pkg="$name" -v store="/$BPM_CHO" \
            '{ choice = pkg $0; gsub("/", ">", choice); print $0 "\t" store "/" choice }' \
            "${work}/conflicts" > "${work}/repoint"

        repoint "${BPM_DB}/${name}/files" "${work}/repoint" ||
            die "$name: a conflicting path is missing from its files list"

        mkdir -p "${BPM_ROOT}/${BPM_CHO}"
        while IFS="$tab" read -r path choice; do
            mv -f "${work}/stage$path" "$BPM_ROOT$choice"
        done < "${work}/repoint"
    }

    while IFS= read -r path; do
        rm -f "$BPM_ROOT$path.new"
        cp -Pf "${work}/stage$path" "$BPM_ROOT$path.new"
        warn "config preserved: $path (new version in $path.new)"
    done < "${work}/keep"

    # an upgrade drops what the new version no longer ships, except paths
    # this package lost to an alternative, which belong to whatever package
    # took their spot
    [ -f "${work}/old.files" ] && {
        paths "${work}/old.files" > "${work}/old.paths"
        paths "${BPM_DB}/${name}/files" > "${work}/now.paths"
        lines_minus "${work}/old.paths" "${work}/now.paths" "${work}/foreign" | remove_paths
    }

    [ -f "${work}/old.shells" ] && {
        new_shells=$BPM_DB/$name/shells; [ -f "$new_shells" ] || new_shells=/dev/null
        lines_minus "${work}/old.shells" "$new_shells" > "${work}/gone.shells"
        shells_del "${work}/gone.shells" "$name"
    }
    shells_add "${BPM_DB}/${name}/shells"

    hooks post-install "$name" "$ver"
    rm -rf "$work"
    unset archive name ver work new_files meta_dir file path choice new_shells
}

# rm and rmdir would be deleted halfway down the files list of the package
# providing them which would leave the rest of it on the fs
tools_stage() {
    tools=$BPM_RUN/tools
    rm -rf "$tools" && mkdir -p "$tools" || return 1

    for tool in rm rmdir; do
        tool_path=$(command -v "$tool") && [ -n "$tool_path" ] || { unset tool tool_path; return 1; }
        cp -f "$tool_path" "${tools}/${tool}" && chmod 755 "${tools}/${tool}" || { unset tool tool_path; return 1; }
    done

    # tools stays, pkg_remove puts it on PATH and removes it
    unset tool tool_path
}

pkg_remove() {
    name=$1
    require_installed "$name"
    run_dir
    work=$BPM_RUN/remove.$name
    rm -rf "$work"; mkdir -p "$work"
    ver=$(pkg_version "$name" 2>/dev/null || :)

    # anything another package owns stays, the list is copied out since 
    # the reverse sorted walk would hit /var/db before /etc
    cp "${BPM_DB}/${name}/files" "${work}/files"
    foreign_files "$name" > "${work}/foreign"
    paths "${work}/files" > "${work}/paths"
    lines_minus "${work}/paths" "${work}/foreign" > "${work}/owned"

    # configs go unless they were edited, everything else just goes
    flist configs "${work}/files" > "${work}/configs"
    awk -v dir="$work" 'FILENAME == ARGV[1] { config[$0]; next }
         ($0 in config) { print > (dir "/owned.configs"); next }
         { print > (dir "/owned.rest") }' "${work}/configs" "${work}/owned"
    : >> "${work}/owned.configs"; : >> "${work}/owned.rest"

    hooks pre-remove "$name" "$ver"
    msg "removing $name"
    shells_del "${BPM_DB}/${name}/shells" "$name"

    saved_path=$PATH
    if tools_stage; then
        PATH=$tools:$PATH
    else
        warn "${name}: could not stage rm/rmdir, removal may not finish"
    fi

    # configs get removed first so the dirs they're in still get cleaned up
    # a leftover .new is always removed, its the default of a package that is
    # being removed
    while IFS= read -r path; do
        rm -f "$BPM_ROOT$path.new"
        if pristine "${work}/files" "$path"; then
            rm -f "$BPM_ROOT$path"
        elif exists "$BPM_ROOT$path"; then
            warn "config kept: $path"
        fi
    done < "${work}/owned.configs"

    remove_paths < "${work}/owned.rest"
    rm -rf "${BPM_DB:?}/$name"

    # hooks keep the staged tools because they might need something
    # the removed package provided
    hooks post-remove "$name" "$ver"
    PATH=$saved_path
    rm -rf "$work" "$tools"
    unset name work ver path saved_path tools
}

# the cached archive a package was installed with
ar_cached() (
    for cached in "${BPM_CACHE}/bin/${1}@${2}".tar.*; do
        [ -f "$cached" ] && { printf '%s\n' "$cached"; return 0; }
    done
    return 1
)

# put one file back from the package it came from
pkg_restore() {
    name=$1 path=$2
    require_installed "$name"
    ver=$(pkg_version "$name")
    archive=$(ar_cached "$name" "$ver") ||
        die "${name}: no cached archive for $ver in ${BPM_CACHE}/bin, rebuild it first"

    run_dir
    work=$BPM_RUN/restore.${name}
    rm -rf "$work"; mkdir -p "$work"
    untar "$archive" "$work" ".$path" 2>/dev/null && exists "$work$path" ||
        die "${name}: $path is not in $archive"

    # a path lost to an alternative is repaired in the choices store, and the
    # copy is renamed into place since <path> could be something this runs on
    location=/$BPM_CHO/$(cho_name "$name" "$path")
    flist has "${BPM_DB}/${name}/files" "$location" || location=$path
    mkdir -p "$BPM_ROOT${location%/*}"
    staged=$BPM_ROOT$location.bpm-new
    rm -f "$staged"
    cp -Pp "$work$path" "$staged" || { rm -f "$staged"; die "${name}: could not stage $location"; }
    mv -f "$staged" "$BPM_ROOT$location"
    rm -rf "$work"
    msg "restored $location from ${name}-${ver}"
    unset name path ver archive work location staged
}

# replaces <path> with one from <pkg>, demoting whatever owns that path now
pkg_swap() {
    name=$1 path=$2
    require_installed "$name"
    choice=/$BPM_CHO/$(cho_name "$name" "$path")
    exists "$BPM_ROOT$choice" || die "no alternative '$name $path'"

    owner= owner_choice=
    exists "$BPM_ROOT$path" && {
        owner=$(pkg_owner "$path" | head -n1)
        [ -n "$owner" ] || die "$path exists but no package owns it"
        owner_choice=/$BPM_CHO/$(cho_name "$owner" "$path")    
    }

    # both lists are rewritten before anything on the disk is moved
    run_dir
    printf '%s\t%s\n' "$choice" "$path" > "${BPM_RUN}/promote"
    cp "${BPM_DB}/${name}/files" "${BPM_RUN}/files.${name}"
    repoint "${BPM_RUN}/files.${name}" "${BPM_RUN}/promote" ||
        die "${name}: $choice missing from its files list, refusing to promote it"
    [ -n "$owner" ] && {
        printf '%s\t%s\n' "$path" "$owner_choice" > "${BPM_RUN}/demote"
        cp "${BPM_DB}/${owner}/files" "${BPM_RUN}/files.${owner}"
        repoint "${BPM_RUN}/files.${owner}" "${BPM_RUN}/demote" ||
            die "${owner}: $path missing from its files list, refusing to demote it"
    }

    # <path> might be something this function needs (mv) so its staged beside
    # the target and the real path is just renamed in its dir
    staged=$BPM_ROOT$path.bpm-new
    rm -f "$staged"
    cp -a "$BPM_ROOT$choice" "$staged" || die "${name}: could not stage $path"
    [ -n "$owner" ] && {
        msg "swapping $path from $owner to $name"
        cp -a "$BPM_ROOT$path" "$BPM_ROOT$owner_choice" ||
            { rm -f "$staged"; die "${owner}: could not stash $path"; }
    }
    mv -f "$staged" "$BPM_ROOT$path"
    rm -f "$BPM_ROOT$choice"

    cat "${BPM_RUN}/files.${name}" > "${BPM_DB}/${name}/files"

    [ -z "$owner" ] || cat "${BPM_RUN}/files.${owner}" > "${BPM_DB}/${owner}/files"
    unset name path choice owner owner_choice staged
}

# pkg_verify <pkg> - print "<pkg> <path> <reason>" for every mismatch
#
# all files provided by a bpm package are hashed via b3sum, the list
# holds where things are at so an alternative is checked in the choices
# store and reported via the path it was placed at
pkg_verify() {
    name=$1 files_list=${BPM_DB}/${1}/files
    [ -f "$files_list" ] || die "${name}: no files list in its database entry"
    run_dir
    work=${BPM_RUN}/verify.${name}
    rm -rf "$work"; mkdir -p "$work"
    : > "${work}/expected"; : > "${work}/hash"; : > "${work}/bad"
    flist checkable "$files_list" > "${work}/checkable"
    [ ! -s "${work}/checkable" ] && {
        verify_unsummed=$((verify_unsummed + 1))
        rm -rf "$work"
        unset name files_list work
        return 0
    }
    hash_have || die "no blake3 implementation found (install b3sum or rhash)"

    while IFS='|' read -r type value path; do
        shown=$path
        case $path in
            "/${BPM_CHO}/"*) shown=$(cho_path "${path##*/}") ;;
        esac
        on_disk=$BPM_ROOT$path
        if ! exists "$on_disk"; then
            reason=missing
        elif [ -h "$on_disk" ]; then
            if [ "$type" != l ]; then
                reason=type
            elif [ "$(readlink "$on_disk")" != "$value" ]; then
                reason=changed
            else
                continue
            fi
        elif [ "$type" = l ]; then
            reason=type
        elif [ ! -r "$on_disk" ]; then
            reason=unreadable
        else
            printf '%s\n' "$on_disk" >> "${work}/hash"
            printf '%s\t%s\n' "$value" "$shown" >> "${work}/expected"
            continue
        fi
        printf '%s %s %s\n' "$name" "$shown" "$reason" >> "${work}/bad"
    done < "${work}/checkable"

    [ -s "${work}/hash" ] && {
        blake3_list < "${work}/hash" > "${work}/got" 2>/dev/null || :
        # hashes pair with paths by line so anything short of one per file
        # (a file vanishing midway) gets them one at a time instead
        [ "$(wc -l < "${work}/got")" != "$(wc -l < "${work}/hash")" ] && {
            while IFS= read -r file; do blake3 "$file" 2>/dev/null || printf '%s\n' -; done < "${work}/hash" > "${work}/got"
        }
        awk -F'\t' -v pkg="$name" '
            FILENAME == ARGV[1] { got[FNR] = $0; next }
            got[FNR] != $1 { print pkg " " $2 " changed" }' "${work}/got" "${work}/expected" >> "${work}/bad"
    }
    cat "${work}/bad"
    verify_status=0
    [ ! -s "${work}/bad" ] || verify_status=1
    rm -rf "$work"

    set -- "$verify_status"
    unset name files_list work type value path shown on_disk reason file verify_status
    return "$1"
}
