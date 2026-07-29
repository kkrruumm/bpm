# build_style=scons
style_build() {
    scons "-j$BPM_JOBS" prefix=/usr CC="$CC" CXX="$CXX" \
        CCFLAGS="$CFLAGS" LINKFLAGS="$LDFLAGS" ${make_build_args:-}
}
style_install() {
    scons prefix=/usr DESTDIR="$DESTDIR" ${make_install_args:-} install
}
