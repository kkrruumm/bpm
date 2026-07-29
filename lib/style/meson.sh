# build_style=meson - configures into ./build
style_configure() {
    meson setup build \
        --prefix=/usr \
        --libdir=lib \
        --libexecdir=/usr/libexec \
        --sysconfdir=/etc \
        --localstatedir=/var \
        --buildtype=plain \
        --wrap-mode=nodownload \
        ${meson_args:-} ${configure_args:-}
}
style_build() { ninja -C build "-j$BPM_JOBS" ${make_build_args:-}; }
style_check() { meson test -C build ${make_check_args:-}; }
style_install() { DESTDIR="$DESTDIR" ninja -C build install; }
