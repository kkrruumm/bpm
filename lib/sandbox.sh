# bpm buildroots
# this runs inside namespaces sandbox() in bpm creates as uid0
# (the calling user mapped to root when unpriv'd) with its own mount
# namespace so every mount here is invisible to the host and is removed
# post build
#
# layout under $BPM_BUILDROOT:
#   base/         shared base system, only repopulated when BPM_BASEPKGS change
#   base.stamp    the package set base/ was populated from
#   <pkg>/root    what the build sees as /
#   <pkg>/up      overlay upper layer, thrown away after every build
#   <pkg>/work    overlay work dir
#
# the orchestrator (../bpm) figures out what archives need to go into the root,
# nothing here reads a template other than the one being built
#
# any undeclared dependencies kills the build instead of quietly getting picked
# up from the host since builds are done in a sandbox
#
# unpack archives into a root, no hooks, alternatives, or config handling
# since the root is disposable and every archive brings in its own db entry
broot_unpack() {
    unpack_root=$1; shift

    for archive; do
        sub "unpacking $(ar_name "$archive")-$(ar_ver "$archive")"
        untar "$archive" "${unpack_root}/"
    done

    unset unpack_root archive
}

# broot_base <stamp> <archive>... - (re)populate the base when its package set changed
broot_base() {
    base=${BPM_BUILDROOT}/base stamp=$1; shift
    mkdir -p "$BPM_BUILDROOT"

    [ -d "$base" ] && [ "$stamp" = "$(cat "${BPM_BUILDROOT}/base.stamp" 2>/dev/null)" ] && {
        unset base stamp
        return 0
    }

    msg "populating build root base in $base"
    rm -rf "$base" "${BPM_BUILDROOT}/base.stamp"
    mkdir -p "$base"
    broot_unpack "$base" "$@"
    printf '%s\n' "$stamp" > "${BPM_BUILDROOT}/base.stamp"

    unset base stamp
}

# overlayfs mounts inside a user namespace since linux 5.11 with its
# xattrs in user.* instead of truted.* (userxattr), anything else
# will get a copy of the base
broot_assemble() {
    layer=${BPM_BUILDROOT}/${1}
    rm -rf "$layer"
    mkdir -p "${layer}/root" "${layer}/up" "${layer}/work"

    [ "$BPM_BROOT_OVERLAY" = 1 ] && {
        options="lowerdir=${BPM_BUILDROOT}/base,upperdir=${layer}/up,workdir=${layer}/work"
        [ "${BPM_USERNS:-0}" = 1 ] && options="${options},userxattr"

        mount -t overlay bpm -o "$options" "${layer}/root" 2>/dev/null && {
            unset layer options
            return 0
        }

        warn "overlayfs unavailable, falling back to copying the base"
    }

    cp -a "${BPM_BUILDROOT}/base/." "${layer}/root/"
    unset layer options
}

# broot_bind <ro|rw> <path> - bind <path> into the root at the same path
# which is what enables the build stage to use $BPM_CACHE, $tmpl_dir, 
# and the r est without changing them
broot_bind() {
    [ -e "$2" ] || return 0
    target=${root}${2}

    if [ -d "$2" ]; then
        mkdir -p "$target"
    else
        mkdir -p "${target%/*}"
        [ -e "$target" ] || : > "$target"
    fi

    mount --bind "$2" "$target" || die "cannot bind $2 into the build root"
    [ "$1" = ro ] && { mount -o remount,bind,ro "$target" || :; }

    unset target
}

# devices cant be created inside of a user namespace so the handful that
# builds may need are bound from the host
broot_dev() {
    dev=${root}/dev
    mount -t tmpfs -o mode=0755 tmpfs "$dev"
    mkdir -p "${dev}/pts" "${dev}/shm"

    for node in null zero full random urandom tty; do
        [ -e "/dev/${node}" ] || continue
        : > "${dev}/${node}"
        mount --bind "/dev/${node}" "${dev}/${node}"
    done

    ln -s /proc/self/fd "${dev}/fd"
    ln -s /proc/self/fd/0 "${dev}/stdin"
    ln -s /proc/self/fd/1 "${dev}/stdout"
    ln -s /proc/self/fd/2 "${dev}/stderr"

    if mount -t devpts -o newinstance,ptmxmode=0666,mode=0620 devpts "${dev}/pts" 2>/dev/null; then
        ln -s pts/ptmx "${dev}/ptmx"
    else
        : > "${dev}/ptmx"
        mount --bind /dev/ptmx "${dev}/ptmx" 2>/dev/null || :
    fi

    mount -t tmpfs -o mode=1777 tmpfs "${dev}/shm"
    unset dev node
}

broot_mounts() {
    mkdir -p "${root}/proc" "${root}/sys" "${root}/dev" "${root}/tmp" "${root}/run"

    # the scrubbed env has HOME=/root, some build systems
    # are going to write there anyway
    mkdir -p "${root}/root"
    chmod 0700 "${root}/root"

    mount -t proc proc "${root}/proc" || die "cannot mount /proc in the build root"
    broot_dev
    mount -t tmpfs -o mode=1777 tmpfs "${root}/tmp"
    mount -t tmpfs -o mode=0755 tmpfs "${root}/run"

    # a few build systems poke at sysfs, read only and not fatal
    mount --bind /sys "${root}/sys" 2>/dev/null && {
        mount -o remount,bind,ro "${root}/sys" 2>/dev/null || :
    }

    # the build writes its tree and finished archive straight to host storage
    broot_bind rw "${BPM_CACHE}/build"
    broot_bind rw "${BPM_CACHE}/dest"
    broot_bind rw "${BPM_CACHE}/bin"
    broot_bind ro "${BPM_CACHE}/sources"

    # bpm, its library and the templates, none of which are packages,
    # and the config so use flags resolve the same on both sides
    broot_bind ro "$BPM_SELF"
    broot_bind ro "$BPM_LIBDIR"
    for repo in $BPM_REPOS; do
        broot_bind ro "$repo"
    done
    broot_bind ro "$BPM_CONF"
    broot_bind ro "$BPM_USECONF"
    broot_bind ro "$BPM_REPOCONF"

    if [ "${allow_network:-no}" = yes ]; then
        broot_bind ro /etc/resolv.conf
    elif have ip; then
        # test suites binding 127.0.0.1 need loopback in the new netns
        ip link set lo up 2>/dev/null || :
    fi

    unset repo
}

# broot_run <pkg> <archive>... - assemble the root and then chroot into stage
# two with a scrubbed env, whatever the callr exported (CPPFLAGS for example)
# would otherwise get to the build quietly
broot_run() {
    tmpl_load "$1"; shift
    [ -d "${BPM_BUILDROOT}/base" ] || die "the build root base has not been populated"
    broot_assemble "$pkg_name"
    root=${BPM_BUILDROOT}/${pkg_name}/root
    broot_unpack "$root" "$@"
    broot_mounts

    # resolved now since env -i is about to drop PATH
    chroot=$(command -v chroot) || die "chroot(1) not found"
    env=$(command -v env 2>/dev/null) || env=
    [ -z "$env" ] && {
        warn "env(1) not found, the build inherits the caller's environment"
        exec "$chroot" "$root" "$BPM_SELF" __build "$pkg_name"
    }

    # every exported BPM_ variable is let through, the compiler flags
    # a fixed PATH and identity, and whatever BPM_ENV_KEEP specifies
    #
    # the names come from env(1) and the values from the shell so values with
    # whitespace survive
    set -- "$env" -i "PATH=$BPM_BROOT_PATH" HOME=/root USER=root LOGNAME=root \
        "TERM=${TERM:-dumb}" SHELL=/bin/sh

    for var in $(env | sed -n 's/^\(BPM_[A-Za-z0-9_]*\)=.*/\1/p') \
               CFLAGS CXXFLAGS LDFLAGS RUSTFLAGS GOFLAGS GOAMD64 CGO_ENABLED ${BPM_ENV_KEEP:-}; do
        eval "[ -n \"\${$var+set}\" ]" || continue
        eval "set -- \"\$@\" \"$var=\${$var}\""
    done

    exec "$@" "$chroot" "$root" "$BPM_SELF" __build "$pkg_name"
}
