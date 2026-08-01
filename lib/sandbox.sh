# bpm build root handling
#
# everything in here runs inside the namespaces created by sandbox() in bpm(1),
# which means as uid 0 (mapped from the calling user when unprivileged) with a
# private mount namespace, so every mount made here is invisible to the host and
# goes away on its own when the build exits
#
# layout under $BPM_BUILDROOT:
#    base/         shared base system, repopulated only when $BPM_BASEPKGS change
#    base.stamp    the package set base/ was populated from
#    <pkg>/root    what the build sees as /
#    <pkg>/up      overlay upper layer, thrown away after every build
#    <pkg>/work    overlay work directory
#
# only make_depends and host_make_depends (plus their runtime closure) are
# unpacked into the root, so a template that fails to declare something will
# fail to build instead of silently picking it up off of the host

# unpack a binary package into a root
# no hooks, no alternatives, no configuration preservation, the root is
# disposable so none of that applies and the archive carries its own
# /var/db/bpm entry, which means the root gets a usable package database
broot_unpack() {
    ( tmpl_load "$2"
      [ -f "$pkg_ar" ] || die "$2: no binary package at $pkg_ar"
      sub "unpacking $pkg_name-$pkg_ver"
      decomp "$pkg_ar" < "$pkg_ar" | tar xf - -C "$1/" )
}

# identity of a package set, used to notice that the base is out of date
broot_stamp() {
    for _bs in "$@"; do
        ( tmpl_load "$_bs"
          printf '%s@%s %s\n' "$pkg_name" "$pkg_ver" "$(use_effective)" )
    done | sort
}

# populate the shared base, this is the expensive part and it only happens when
# one of $BPM_BASEPKGS changed version or use flags
broot_base() {
    _bb=$BPM_BUILDROOT/base
    # shellcheck disable=SC2086
    _bw=$(broot_stamp $BPM_BASEPKGS)
    if [ -d "$_bb" ] &&
       [ "$_bw" = "$(cat "$BPM_BUILDROOT/base.stamp" 2>/dev/null || :)" ]; then
        return 0
    fi

    msg "populating build root base in $_bb"
    rm -rf "$_bb" "$BPM_BUILDROOT/base.stamp"
    mkdir -p "$_bb"
    # shellcheck disable=SC2086
    for _bp in $(rdeps_closure $BPM_BASEPKGS); do broot_unpack "$_bb" "$_bp"; done
    printf '%s\n' "$_bw" > "$BPM_BUILDROOT/base.stamp"
}

# overlayfs is mountable inside a user namespace since 5.11, where its xattrs
# live in user.* instead of trusted.*, hence userxattr
# anything older or otherwise unhappy falls back to copying the base,
# which should work everywhere
broot_assemble() {
    _bd=$BPM_BUILDROOT/$1
    rm -rf "$_bd"
    mkdir -p "$_bd/root" "$_bd/up" "$_bd/work"

    if [ "$BPM_BROOT_OVERLAY" = 1 ]; then
        _bo="lowerdir=$BPM_BUILDROOT/base,upperdir=$_bd/up,workdir=$_bd/work"
        if [ "${BPM_USERNS:-0}" = 1 ]; then _bo="$_bo,userxattr"; fi
        if mount -t overlay bpm -o "$_bo" "$_bd/root" 2>/dev/null; then
            printf '%s\n' "$_bd/root"
            return 0
        fi
        warn "overlayfs unavailable, falling back to copying the base"
    fi

    cp -a "$BPM_BUILDROOT/base/." "$_bd/root/"
    printf '%s\n' "$_bd/root"
}

# broot_bind <ro|rw> <path> - bind <path> into the root at the same path
#
# keeping the paths identical is what lets the build stage use $BPM_CACHE,
# $tmpl_dir and shit unmodified on both sides of the chroot
broot_bind() {
    _bt=$_BROOT$2
    [ -e "$2" ] || return 0
    if [ -d "$2" ]; then
        mkdir -p "$_bt"
    else
        mkdir -p "${_bt%/*}"
        [ -e "$_bt" ] || : > "$_bt"
    fi
    mount --bind "$2" "$_bt" || die "cannot bind $2 into the build root"
    if [ "$1" = ro ]; then mount -o remount,bind,ro "$_bt" || :; fi
}

# devices cannot be created in a user namespace, so the handful that builds
# actually want get bound in from the host instead
broot_dev() {
    mount -t tmpfs -o mode=0755 tmpfs "$_BROOT/dev"
    mkdir -p "$_BROOT/dev/pts" "$_BROOT/dev/shm"
    for _bn in null zero full random urandom tty; do
        [ -e "/dev/$_bn" ] || continue
        : > "$_BROOT/dev/$_bn"
        mount --bind "/dev/$_bn" "$_BROOT/dev/$_bn"
    done
    ln -s /proc/self/fd "$_BROOT/dev/fd"
    ln -s /proc/self/fd/0 "$_BROOT/dev/stdin"
    ln -s /proc/self/fd/1 "$_BROOT/dev/stdout"
    ln -s /proc/self/fd/2 "$_BROOT/dev/stderr"
    if mount -t devpts -o newinstance,ptmxmode=0666,mode=0620 devpts "$_BROOT/dev/pts" 2>/dev/null; then
        ln -s pts/ptmx "$_BROOT/dev/ptmx"
    else
        : > "$_BROOT/dev/ptmx"
        mount --bind /dev/ptmx "$_BROOT/dev/ptmx" 2>/dev/null || :
    fi
    mount -t tmpfs -o mode=1777 tmpfs "$_BROOT/dev/shm"
}

broot_mounts() {
    _BROOT=$1
    mkdir -p "$_BROOT/proc" "$_BROOT/sys" "$_BROOT/dev" "$_BROOT/tmp" "$_BROOT/run"
    # the scrubbed environment sets HOME=/root, sadly plenty of build systems
    # write there whether anyone asked them to or not
    mkdir -p "$_BROOT/root"
    chmod 0700 "$_BROOT/root"

    mount -t proc proc "$_BROOT/proc" || die "cannot mount /proc in the build root"
    broot_dev
    mount -t tmpfs -o mode=1777 tmpfs "$_BROOT/tmp"
    mount -t tmpfs -o mode=0755 tmpfs "$_BROOT/run"
    # a few build systems poke at sysfs, it is read only and non fatal
    mount --bind /sys "$_BROOT/sys" 2>/dev/null &&
        { mount -o remount,bind,ro "$_BROOT/sys" 2>/dev/null || :; } || :

    # the build writes its staged tree and its finished archive straight onto
    # host storage, so nothing has to be copied back out afterwards
    broot_bind rw "$BPM_CACHE/build"
    broot_bind rw "$BPM_CACHE/dest"
    broot_bind rw "$BPM_CACHE/bin"
    broot_bind ro "$BPM_CACHE/sources"

    # bpm itself, its library and the templates, none of which are packages
    broot_bind ro "$BPM_SELF"
    broot_bind ro "$BPM_LIBDIR"
    for _br in $BPM_REPOS; do broot_bind ro "$_br"; done

    # use flag resolution has to come out the same inside as it did outside,
    # which means the configuration has to be readable in here too
    broot_bind ro "$BPM_CONF"
    broot_bind ro "$BPM_USECONF"
    broot_bind ro "$BPM_REPOCONF"

    if [ "${allow_network:-no}" = yes ]; then
        broot_bind ro /etc/resolv.conf
    elif have ip; then
        # test suites that bind to 127.0.0.1 need loopback up in the new netns
        ip link set lo up 2>/dev/null || :
    fi
}

# make_depends and host_make_depends of <pkg> plus everything those need at
# runtime, this is the entire contents of the build root on top of the base
broot_deps() {
    # shellcheck disable=SC2046
    rdeps_closure $(tmpl_get "$1" make_depends host_make_depends)
}

# the build root is hermetic on the filesystem, this makes it hermetic on the
# environment too, anything the caller happened to have exported, CPPFLAGS,
# LD_LIBRARY_PATH, PKG_CONFIG_PATH and whatnot would otherwise reach the build
# and quietly change its result
#
# what survives would be the BPM_ variables the build stage needs, the compiler flags,
# a fixed PATH and identity, and whatever BPM_ENV_KEEP names

# entry point, called by 'bpm __stage' from inside the namespaces
broot_run() {
    tmpl_load "$1"
    [ -n "$BPM_BASEPKGS" ] ||
        die "BPM_BUILDROOT is set but BPM_BASEPKGS is empty, nothing to build in"

    mkdir -p "$BPM_BUILDROOT"
    broot_base
    _bR=$(broot_assemble "$pkg_name")
    # shellcheck disable=SC2046
    for _bp in $(broot_deps "$1"); do broot_unpack "$_bR" "$_bp"; done
    broot_mounts "$_bR"

    # resolved here because env -i is about to bomb PATH 
    _bC=$(command -v chroot) || die "chroot(1) not found"
    _bE=$(command -v env 2>/dev/null) || _bE=

    if [ -z "$_bE" ]; then
        warn "env(1) not found, the build inherits the callers environment"
        exec "$_bC" "$_bR" "$BPM_SELF" __build "$pkg_name"
    fi

    # from here on the positional parameters are the scrubbed environment,
    # everything still needed below is a global that tmpl_load set
    set -- "$_bE" -i \
        "PATH=$BPM_BROOT_PATH" HOME=/root USER=root LOGNAME=root \
        "TERM=${TERM:-dumb}" SHELL=/bin/sh

    # names come from env(1)values from the shell, so values containing
    # whitespace or anything else exciting survive
    for _bv in $(env | sed -n 's/^\(BPM_[A-Za-z0-9_]*\)=.*/\1/p') \
               CFLAGS CXXFLAGS LDFLAGS ${BPM_ENV_KEEP:-}; do
        eval "[ -n \"\${$_bv+x}\" ]" || continue
        eval "set -- \"\$@\" \"$_bv=\${$_bv}\""
    done

    exec "$@" "$_bC" "$_bR" "$BPM_SELF" __build "$pkg_name"
}
