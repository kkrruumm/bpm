# build_style=zig-build - zig compiles and installs in one step, and does not
# know about DESTDIR, so the prefix carries it instead
style_build() { :; }
style_install() {
    zig build install \
        --prefix "$DESTDIR/usr" \
        ${zig_build_args:-${ZIGFLAGS:--Doptimize=ReleaseSafe}} \
        ${make_install_args:-}
}
