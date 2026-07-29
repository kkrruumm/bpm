# build_style=qmake - Qt project files
style_configure() {
    ${qmake_cmd:-qmake} \
        PREFIX=/usr \
        LIBDIR=/usr/lib \
        QMAKE_CFLAGS="$CFLAGS" \
        QMAKE_CXXFLAGS="$CXXFLAGS" \
        QMAKE_LFLAGS="$LDFLAGS" \
        ${configure_args:-}
}
style_build() { $make_cmd $make_jobs ${make_build_args:-}; }
style_check() { $make_cmd check ${make_check_args:-}; }
style_install() { $make_cmd INSTALL_ROOT="$DESTDIR" ${make_install_args:-} install; }
